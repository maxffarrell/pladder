import AppKit
import AVFoundation
import Foundation
import Observation
import PladderCore
import os

import PladderSystem
import PladderAudio
import PladderEngines
import PladderRefine

/// Composition root. Builds the engine registry, the settings store and the
/// coordinator, owns the overlay, and exposes everything the UI needs.
@MainActor
@Observable
final class AppModel {
    let registry: EngineRegistry
    let coordinator: DictationCoordinator

    /// Text processors in pipeline order. The single source of truth for both
    /// the settings toggles (ids, display names, details) and the runtime
    /// pipeline `makePipeline` builds below.
    let processors: [any TextProcessor]

    /// Mirrored permission state, refreshed on a timer so the menu and the
    /// settings window stay correct after the user flips a switch in System
    /// Settings (neither API offers a change notification).
    private(set) var accessibilityTrusted: Bool = Permissions.isAccessibilityTrusted
    private(set) var microphoneStatus: AVAuthorizationStatus = Permissions.microphoneStatus

    /// Secure Event Input, polled with the permissions. While it is on an
    /// event tap sees no key-downs, so a chord with a regular key would fire
    /// for nothing; `refreshPermissions()` hands such a chord to Carbon until
    /// it clears. Only a *sustained* reading counts, so the password field the
    /// user tabs through does not swap the monitor twice in four seconds.
    private var secureInput = SustainedCondition()
    private(set) var secureInputSustained = false

    /// The keyboard shortcuts macOS itself handles. Read on explicit triggers
    /// only — launch, a permission flip, a hotkey edit, the settings window
    /// opening — because `CopySymbolicHotKeys` is main-thread work linear in
    /// the number of shortcuts and the answer changes about as often as
    /// someone visits System Settings. Never on a key press.
    private(set) var systemShortcuts: Set<Hotkey> = []

    /// Whether Apple Intelligence can polish right now, for the polish
    /// toggle's row. Polled with the permissions: it can be switched on or
    /// off in System Settings while the app runs, and the read is cheap. The
    /// coordinator never asks; an unavailable model makes the toggle a
    /// no-op that pastes as dictated.
    private(set) var polishAvailability: OnDeviceModelAvailability = TranscriptPolisher.availability

    /// Where the chosen polish model's file stands; nil for Apple's, which
    /// has none. Shown under the model picker.
    private(set) var polishModelStatus: ModelFileStatus?
    /// The coordinator's refiner; `applyPolishModel` points it at the model
    /// the settings name.
    private let polishRouter: PolishRouter
    private let applePolisher = TranscriptPolisher()
    /// The S1-mini polisher for the chosen file, nil while Apple's is chosen.
    /// Only one is ever held, so switching frees the other's memory.
    private var s1MiniPolisher: S1MiniPolisher?
    private let modelFiles: ModelFiles
    private let modelStatusRelay = ModelStatusRelay()

    /// The default chord, standing in for a stored chord Carbon cannot
    /// register while Accessibility is missing. The stored chord is never
    /// rewritten and returns with the grant.
    var standInHotkey: Hotkey? {
        accessibilityTrusted ? nil : settings.hotkey.standInWithoutAccessibility
    }

    /// So the first `refreshPermissions()` sets the stand-in even though
    /// nothing flipped; `hotkeyUsesTap` already matches the grant at that point.
    private var didComputeEffectiveHotkey = false

    private let store: SettingsStore
    private let events = EventRelay()
    private let overlay: OverlayController
    private var permissionTask: Task<Void, Never>?
    private var didRequestAccessibility = false

    /// Both hotkey sources, kept for the app's life so switching between them
    /// costs nothing. The tap swallows the chord's regular key and matches
    /// left and right modifiers exactly, but needs Accessibility; Carbon needs
    /// no permission at all and is what a standard account gets.
    private let tapHotkey = GlobalHotkeyMonitor()
    private let carbonHotkey = CarbonHotkeyMonitor()
    /// Which of the two the coordinator is currently driven by.
    private var hotkeyUsesTap: Bool

    /// When the hotkey was released, for the release-to-paste measurement.
    private var releaseInstant: ContinuousClock.Instant?
    /// Release-to-paste time per dictation, the number the user feels. Read
    /// it with: log show --last 1h --predicate 'subsystem == "de.dinooo13.pladder"'
    private static let timing = Logger(subsystem: "de.dinooo13.pladder", category: "timing")
    /// A processor that throws is skipped by `ProcessorPipeline` rather than
    /// losing the dictation; this is where that gets logged. `Logger` is
    /// `Sendable`, so this is safe to reach from the `@Sendable` failure
    /// closure below without hopping back to the main actor.
    private nonisolated static let processorLog = Logger(subsystem: "de.dinooo13.pladder", category: "processors")
    /// Every mute and unmute of the output device. A mute that gets stuck —
    /// the app quitting mid-recording, a device vanishing — is silent and
    /// baffling otherwise, so both ends of it are logged `.public`.
    private nonisolated static let muteLog = Logger(subsystem: "de.dinooo13.pladder", category: "mute")
    /// The correction learner's stages. They quote the user's words, so the
    /// text is `.private`: `log show` prints it only with private data on.
    private nonisolated static let learningLog = Logger(subsystem: "de.dinooo13.pladder", category: "learning")

    /// Watches a field after the paste and proposes what the user corrected.
    private let learner: CorrectionLearner
    private let dismissedCorrections: DismissedCorrections
    private let proposalRelay = ProposalRelay()
    /// Corrections the model agreed with, newest first, waiting in the menu
    /// for Add or Dismiss. Kept for the app's life or until answered.
    private(set) var proposals: [CorrectionProposal] = []
    static let maximumProposals = 3
    /// Hotkey behaviour worth knowing about after the fact, such as a
    /// keyboard that bounces.
    private static let hotkeyLog = Logger(subsystem: "de.dinooo13.pladder", category: "hotkey")

    /// Settings live in the coordinator (it reacts to hotkey/engine changes);
    /// this forwards and persists. Applying the appearance covers every
    /// window and menu at once, so no view has to care.
    ///
    /// Each side effect runs only when its own keys changed. Re-assigning
    /// `NSApp.appearance` is not free: with a forced Light or Dark it makes
    /// AppKit re-theme every window, so doing it on every click of a settings
    /// card made the card rows lag behind the click.
    var settings: Settings {
        get { coordinator.settings }
        set {
            let old = coordinator.settings
            guard newValue != old else { return }
            coordinator.settings = newValue
            if newValue.appearance != old.appearance {
                applyAppearance(newValue.appearance)
            }
            if newValue.overlayStyle != old.overlayStyle || newValue.overlayGlass != old.overlayGlass {
                overlay.applyStyle(newValue.overlayStyle, glass: newValue.overlayGlass)
            }
            if newValue.overlayAnimationSpeed != old.overlayAnimationSpeed {
                overlay.applySpeed(newValue.overlayAnimationSpeed)
            }
            if newValue.hotkey != old.hotkey {
                // A chord with a regular key no longer needs a stand-in, and a
                // modifier-only one does.
                updateEffectiveHotkey()
            }
            if newValue.polishModel != old.polishModel || newValue.polishDictations != old.polishDictations {
                applyPolishModel()
            }
            try? store.save(newValue)
        }
    }

    private func applyAppearance(_ appearance: Appearance) {
        let resolved: NSAppearance? = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = resolved
        overlay.applyAppearance(appearance)
    }

    init() {
        // Engines, in the order the settings picker shows them. The first
        // entry is the default for new installs.
        var registry = EngineRegistry()
        for model in CoreAIParakeetModel.allCases {
            registry.register(.init(
                id: model.engineID,
                displayName: model.displayName,
                detail: String(localized: "Apple Core AI · on-device · 25 languages"),
                make: { CoreAIParakeetEngine(model: model) }
            ))
        }
        #if DEBUG
        registry.register(
            EngineRegistry.Entry(
                id: EchoEngine.engineID,
                displayName: "Echo (testing)",
                detail: "Returns fixed text, for testing",
                make: { EchoEngine() }
            )
        )
        #endif
        self.registry = registry

        let store = SettingsStore(
            url: Self.settingsURL,
            defaults: Settings(engineID: CoreAIParakeetModel.v3.engineID)
        )
        // A test copy starts from the defaults, not from an old install.
        if Self.settingsPathOverride == nil {
            Self.migrateLegacySettings(to: Self.settingsURL)
        }
        self.store = store

        // One read: the store moves an undecodable file aside on load, so a
        // second read could see different settings than the first.
        var initial = store.load()

        // An engine that was removed in an update leaves a stale ID behind.
        // `EngineRegistry.make` already falls back to the first entry, so the
        // app works either way; rewriting the ID keeps the settings picker
        // showing what is actually running.
        if registry.entry(for: initial.engineID) == nil,
            let fallback = registry.available.first {
            initial.engineID = fallback.id
            initial.overlayStyle = .liveTranscript
        }

        // Processors, in pipeline order; the list and its reasons are in
        // `StandardProcessors`, which the CLI shares.
        let processorFactories = StandardProcessors.factories
        self.processors = processorFactories.map { $0(initial) }

        let router = PolishRouter(applePolisher)
        polishRouter = router
        let modelStatusRelay = self.modelStatusRelay
        modelFiles = ModelFiles(directory: ModelFiles.defaultDirectory) { file, status in
            modelStatusRelay.send(file, status)
        }

        let events = self.events
        let trusted = Permissions.isAccessibilityTrusted
        hotkeyUsesTap = trusted
        let coordinator = DictationCoordinator(
            settings: initial,
            registry: registry,
            capture: AVAudioEngineCapture(),
            output: PasteboardOutput(),
            outputMuter: OutputMuteController(
                control: CoreAudioOutputMute(),
                log: { Self.muteLog.info("\($0, privacy: .public)") }),
            refiner: router,
            hotkeyMonitor: trusted ? tapHotkey : carbonHotkey,
            makePipeline: { s in
                ProcessorPipeline(processorFactories.map { $0(s) }, onFailure: { id, error in
                    Self.processorLog.error("processor \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                })
            },
            onEvent: { [events] event in events.send(event) }
        )
        self.coordinator = coordinator

        // Nothing here runs before the paste: `handle(.inserted)` hands the
        // pasted text over, and the learner watches and reviews on its own
        // thread and task.
        let dismissed = DismissedCorrections(url: Self.dismissedCorrectionsURL)
        dismissedCorrections = dismissed
        let proposalRelay = self.proposalRelay
        learner = CorrectionLearner(
            observer: AXPasteObserver(),
            reviewer: FoundationModelsCorrectionReviewer(),
            dismissed: dismissed,
            dictionary: { await coordinator.settings.dictionary },
            log: { Self.learningLog.info("\($0, privacy: .private)") },
            onProposal: { proposalRelay.send($0) }
        )

        overlay = OverlayController(coordinator: coordinator)
        events.handler = { [weak self] event, at in self?.handle(event, at: at) }
        proposalRelay.handler = { [weak self] proposal in self?.propose(proposal) }
        modelStatusRelay.handler = { [weak self] file, status in
            guard let self, ModelFile(for: self.settings.polishModel) == file else { return }
            self.polishModelStatus = status
        }
    }

    /// `PLADDER_SETTINGS_PATH` points a copy launched for testing at a file
    /// of its own, so it neither reads nor writes the configuration of the
    /// copy in daily use; every recorder commit is saved at once. Development
    /// only: no UI, and a normal launch never has it set.
    static var settingsPathOverride: String? {
        guard let path = ProcessInfo.processInfo.environment["PLADDER_SETTINGS_PATH"],
              !path.isEmpty else { return nil }
        return path
    }

    static var settingsURL: URL {
        if let path = settingsPathOverride { return URL(filePath: path) }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Pladder/settings.json")
    }

    /// The corrections the user dismissed, beside the settings but not in
    /// them (see `DismissedCorrections`).
    static var dismissedCorrectionsURL: URL {
        settingsURL.deletingLastPathComponent().appending(path: "dismissed-corrections.json")
    }

    /// One-time migration from the pre-rename location. The dictionary and
    /// hotkey settings were kept in `~/Library/Application Support/SpeakUp/`
    /// before the app was called Pladder; copy them across exactly once, only
    /// when the new file does not exist yet. The old file is left in place.
    static func migrateLegacySettings(to destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let legacy = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/SpeakUp/settings.json")
        try? FileManager.default.copyItem(at: legacy, to: destination)
    }

    // MARK: Lifecycle

    func start() {
        applyAppearance(settings.appearance)
        overlay.applyStyle(settings.overlayStyle, glass: settings.overlayGlass)
        overlay.applySpeed(settings.overlayAnimationSpeed)
        refreshPermissions()
        if !accessibilityTrusted && !didRequestAccessibility {
            didRequestAccessibility = true
            Permissions.requestAccessibility()
        }
        overlay.start()
        coordinator.start()
        applyPolishModel()
        startPermissionMirroring()
    }

    // MARK: Polish model

    /// Points the coordinator's refiner at the chosen model. An S1-mini file
    /// is downloaded only while polish is on and that model is chosen, the
    /// one network use besides the speech model's; it is loaded at the first
    /// key-down, not here, and freed when polish goes off or another model
    /// is picked.
    private func applyPolishModel() {
        guard let file = ModelFile(for: settings.polishModel) else {
            releaseS1Mini()
            polishRouter.use(applePolisher)
            polishModelStatus = nil
            return
        }
        if s1MiniPolisher?.file != file {
            releaseS1Mini()
            let polisher = S1MiniPolisher(file: file, location: modelFiles.location(of: file))
            s1MiniPolisher = polisher
            polishRouter.use(polisher)
        }
        let polishing = settings.polishDictations
        if !polishing, let polisher = s1MiniPolisher {
            Task { await polisher.unload() }
        }
        if polishing {
            Task.detached(priority: .utility) { await S1MiniPolisher.warmUpRuntime() }
        }
        let files = modelFiles
        Task { [weak self] in
            if polishing { await files.ensure(file) }
            let status = await files.status(of: file)
            guard let self, ModelFile(for: self.settings.polishModel) == file else { return }
            self.polishModelStatus = status
        }
    }

    /// Tries a failed download again; the picker's "Try Again".
    func retryPolishModelDownload() {
        guard let file = ModelFile(for: settings.polishModel) else { return }
        let files = modelFiles
        Task { await files.ensure(file) }
    }

    private func releaseS1Mini() {
        guard let polisher = s1MiniPolisher else { return }
        s1MiniPolisher = nil
        Task { await polisher.unload() }
    }

    func stop() {
        permissionTask?.cancel()
        overlay.stop()
        coordinator.stop()
    }

    private func handle(_ event: DictationCoordinator.Event, at instant: ContinuousClock.Instant) {
        func fmt(_ duration: Duration) -> String {
            let d = Self.seconds(duration)
            return String(format: "%.3f", d)
        }
        switch event {
        case .recordingStarted:
            if settings.playSounds { SoundPlayer.playStart() }
        case .recordingStopped:
            releaseInstant = instant
            if settings.playSounds { SoundPlayer.playStop() }
        case .inserted(let transcript, let timing):
            defer {
                // Strictly after the paste and off the measured window, which
                // ended when the coordinator emitted this event: the learner
                // spawns its own task and reads the field on its own thread.
                // Without the grant nothing was pasted, only copied.
                if accessibilityTrusted { learner.pasted(transcript.text) }
            }
            guard let released = releaseInstant else { return }
            releaseInstant = nil
            let total = Self.seconds(instant - released)
            // A polish cycle gets its own line, so the plain one stays the
            // number the benchmark rule watches; one predicate finds both.
            let polish = timing.polish.map { "polish \(fmt($0)) (\(settings.polishModel.rawValue)), " } ?? ""
            let label = timing.polish == nil ? "release-to-paste" : "polished release-to-paste"
            let stages = "stop \(fmt(timing.captureStop)), engine \(fmt(timing.engine)), " +
                "process \(fmt(timing.processing)), \(polish)paste \(fmt(timing.insert))"
            Self.timing.log(
                """
                \(label, privacy: .public) \(total, format: .fixed(precision: 3), privacy: .public) s: \(stages, privacy: .public); \
                audio \(transcript.audioDuration, format: .fixed(precision: 1), privacy: .public) s, \
                engine-time \(transcript.processingTime, format: .fixed(precision: 3), privacy: .public) s
                """
            )
        case .failed:
            releaseInstant = nil
        case .recordingDiscarded:
            // Escape: no paste follows, so no timing line either, but the
            // microphone did go off and the user should hear it.
            releaseInstant = nil
            if settings.playSounds { SoundPlayer.playStop() }
        case .keyboardBounceObserved:
            // That wait comes before `recordingStopped`, so the timing line
            // cannot show it; this line is what explains a felt delay.
            Self.hotkeyLog.notice("keyboard bounce observed: releases now settle for 50 ms before stopping")
        }
    }

    // MARK: Learned corrections

    private func propose(_ proposal: CorrectionProposal) {
        let key = proposal.pair.key
        guard !proposals.contains(where: { $0.pair.key == key }),
              !Self.dictionary(settings.dictionary, has: proposal.pair.heard) else { return }
        proposals = Array(([proposal] + proposals).prefix(Self.maximumProposals))
    }

    /// Adds `heard → corrected` to the dictionary, overwriting a rule with the
    /// same `from` the way the Dictionary tab's import does. Through the
    /// settings setter, so it is saved and the next dictation uses it.
    func acceptProposal(_ proposal: CorrectionProposal) {
        proposals.removeAll { $0.id == proposal.id }
        let from = proposal.pair.heard.lowercased()
        var dictionary = settings.dictionary
        let entry = DictionaryEntry(from: proposal.pair.heard, to: proposal.pair.corrected)
        if let index = dictionary.firstIndex(where: {
            $0.from.trimmingCharacters(in: .whitespaces).lowercased() == from
        }) {
            dictionary[index].to = entry.to
            dictionary[index].matchCase = false
        } else {
            dictionary.append(entry)
        }
        settings.dictionary = dictionary
    }

    /// Drops the line and remembers the pair so it is never proposed again.
    func dismissProposal(_ proposal: CorrectionProposal) {
        proposals.removeAll { $0.id == proposal.id }
        let dismissed = dismissedCorrections
        Task { await dismissed.dismiss(proposal.pair) }
    }

    private static func dictionary(_ entries: [DictionaryEntry], has heard: String) -> Bool {
        let key = heard.lowercased()
        return entries.contains { $0.from.trimmingCharacters(in: .whitespaces).lowercased() == key }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: Permissions

    func refreshPermissions() {
        accessibilityTrusted = Permissions.isAccessibilityTrusted
        microphoneStatus = Permissions.microphoneStatus
        let polish = TranscriptPolisher.availability
        if polish != polishAvailability { polishAvailability = polish }
        let sustained = secureInput.observe(SecureInput.isEnabled)
        if sustained != secureInputSustained { secureInputSustained = sustained }
        // Granting Accessibility upgrades the hotkey to the tap; revoking it
        // drops back to Carbon. Either way a recording in progress is dropped
        // by the coordinator, since the old monitor's release can no longer
        // arrive.
        //
        // Secure input is the second reason to leave the tap: it stops taps
        // seeing key-downs, so a chord with a regular key is dead there.
        // Carbon can take over only for a chord it can register, and a
        // modifier-only chord is unaffected by secure input anyway, so both
        // stay on the tap and nothing swaps. The push-to-talk chord alone
        // decides; the toggle chord follows whichever monitor is up.
        let wantsTap = accessibilityTrusted
            && !(sustained && settings.hotkey.canBeRegisteredWithoutAccessibility)
        let flipped = wantsTap != hotkeyUsesTap
        if flipped {
            hotkeyUsesTap = wantsTap
            coordinator.replaceHotkeyMonitor(wantsTap ? tapHotkey : carbonHotkey)
        }
        // After the swap: the new monitor is started with the old stand-in and
        // then, if it changed, once more with the new one. The other order
        // would make the Carbon monitor log a failure for a modifier-only
        // chord on the way to being replaced by the tap.
        if flipped || !didComputeEffectiveHotkey {
            didComputeEffectiveHotkey = true
            updateEffectiveHotkey()
            refreshSystemShortcuts()
        }
    }

    /// Re-reads the shortcuts macOS owns, which feed the warnings shown in the
    /// settings window. Called when that window opens, the moment the answer
    /// is about to be shown to the user and the recorder about to be handed it.
    func refreshSystemShortcuts() {
        let shortcuts = SystemShortcuts.enabled()
        if shortcuts != systemShortcuts { systemShortcuts = shortcuts }
    }

    /// With the grant the tap matches anything; without it a chord Carbon
    /// cannot register listens for nothing, so the default takes its place.
    private func updateEffectiveHotkey() {
        coordinator.hotkeyOverride = standInHotkey
    }

    /// The enabled macOS shortcut that swallows `hotkey`, if any. Shown as a
    /// warning in both modes: the tap sees such a chord, but the system
    /// shortcut fires as well.
    func systemShortcutConflict(for hotkey: Hotkey) -> Hotkey? {
        hotkey.systemShortcutConflict(in: systemShortcuts)
    }

    var needsAccessibility: Bool { !accessibilityTrusted }
    /// Without Accessibility the chord has to contain a regular key, so the
    /// recorder refuses modifier-only chords and settings says why.
    var hotkeyNeedsRegularKey: Bool { !accessibilityTrusted }
    var needsMicrophone: Bool { microphoneStatus != .authorized }
    var needsAnyPermission: Bool { needsAccessibility || needsMicrophone }

    /// Polls permission status every 2 s for the app's life. Neither API
    /// offers a change notification, so this is how the menu and the settings
    /// window notice a permission flipped in System Settings — and, since
    /// `refreshPermissions()` swaps the hotkey source, how the app moves
    /// between the event tap and Carbon in both directions. It used to stop
    /// once both permissions were granted; a later revoke has to be picked up
    /// too, and two cheap status reads every two seconds cost nothing.
    private func startPermissionMirroring() {
        refreshPermissions()
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshPermissions()
            }
        }
    }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        startPermissionMirroring()
    }

    func grantMicrophone() {
        Task { [weak self] in
            if Permissions.microphoneStatus == .notDetermined {
                _ = await Permissions.requestMicrophone()
            } else {
                Permissions.openMicrophoneSettings()
            }
            self?.refreshPermissions()
            self?.startPermissionMirroring()
        }
    }

    /// Set when `setLaunchAtLogin` fails, so settings can show the reason
    /// under the toggle. `LaunchAtLogin.isEnabled` is the source of truth for
    /// the toggle itself, since it can be changed behind the app's back in
    /// System Settings.
    private(set) var launchAtLoginError: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
            settings.launchAtLogin = enabled
        } catch {
            launchAtLoginError = error.localizedDescription
            settings.launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: Menu presentation

    /// The app icon's waveform glyph, varied by state (see `MenuBarIcon`).
    var menuBarImage: NSImage {
        MenuBarIcon.image(for: coordinator.state)
    }

    /// One line describing what the app is doing right now.
    var statusLine: String {
        switch coordinator.state {
        case .recording:
            // The Menu style has no pill, so this line is its latched cue.
            guard coordinator.isLatched else { return String(localized: "Recording…") }
            return String(localized: "Recording — press \(stopKeyName) to stop")
        case .transcribing: return String(localized: "Transcribing…")
        case .polishing: return String(localized: "Polishing…")
        case .inserting: return String(localized: "Inserting…")
        case .error(let failure): return String(localized: "Error: \(failure.text)")
        case .copied: return String(localized: "Copied — press ⌘V")
        case .idle:
            return readyLine
        case .unavailable:
            switch coordinator.engineStatus {
            case .downloading(let progress):
                if let progress {
                    return String(localized: "Model: downloading \(Int((progress * 100).rounded()))%")
                }
                return String(localized: "Model: downloading…")
            case .loading: return String(localized: "Model: loading…")
            case .unloaded: return String(localized: "Model: not loaded")
            case .failed(let failure): return String(localized: "Model failed: \(failure.text)")
            case .ready: return readyLine
            }
        }
    }

    /// The chord to hold, named the way the monitor that matches it sees the
    /// keys: the tap tells Left from Right, Carbon's mask cannot.
    var effectiveHotkeyName: String {
        guard !hotkeyUsesTap else { return settings.hotkey.displayName }
        return settings.hotkey.sideAgnosticDisplayName
    }

    /// What ends a latched recording. Any chord does; this names the one that
    /// latched it: the toggle key when it is a chord of its own, otherwise
    /// the key, or what stands in for it.
    private var stopKeyName: String {
        let toggle = settings.toggleHotkey
        if !toggle.isEmpty, toggle.canonical != settings.hotkey.canonical {
            return hotkeyUsesTap ? toggle.displayName : toggle.sideAgnosticDisplayName
        }
        return standInHotkey?.sideAgnosticDisplayName ?? effectiveHotkeyName
    }

    /// True while a working Accessibility grant is being ignored because
    /// Secure Event Input has the tap deaf and Carbon is standing in.
    var usesCarbonForSecureInput: Bool { accessibilityTrusted && !hotkeyUsesTap }

    /// What to say when nothing is happening. Without Accessibility the stored
    /// chord may be listening for nothing, in which case the stand-in is named
    /// instead; "hold Right Command" would be a lie.
    private var readyLine: String {
        if let standIn = standInHotkey {
            return String(localized: "Ready — hold \(standIn.sideAgnosticDisplayName) (Accessibility is off)")
        }
        // Say why the send key and the swallowing stopped: both are the tap's,
        // and the tap is deaf until Secure Keyboard Entry goes off again. A
        // whole sentence either way: a suffix glued on cannot be translated.
        if usesCarbonForSecureInput {
            return String(localized: "Ready — hold \(effectiveHotkeyName) (Secure Keyboard Entry is on)")
        }
        return String(localized: "Ready — hold \(effectiveHotkeyName)")
    }

    var canRetryEngine: Bool {
        if case .failed = coordinator.engineStatus { return true }
        return false
    }

    /// A short, word-boundary-aware summary of the most recent transcript for
    /// the menu; longer previews make the menu bar menu comically wide.
    var lastTranscriptSummary: String? {
        guard let text = coordinator.lastTranscript?.text, !text.isEmpty else { return nil }
        let limit = 32
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > 20 {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }
}

/// Bridges `ModelFiles`' status changes onto the main actor, and lets the
/// files be set up before `self` exists, as `EventRelay` does for the
/// coordinator.
@MainActor
final class ModelStatusRelay {
    var handler: ((ModelFile, ModelFileStatus) -> Void)?

    nonisolated func send(_ file: ModelFile, _ status: ModelFileStatus) {
        Task { @MainActor in self.handler?(file, status) }
    }
}

/// Bridges the learner's proposals onto the main actor, and lets the learner
/// be built before `self` exists, as `EventRelay` does for the coordinator.
@MainActor
final class ProposalRelay {
    var handler: ((CorrectionProposal) -> Void)?

    nonisolated func send(_ proposal: CorrectionProposal) {
        Task { @MainActor in self.handler?(proposal) }
    }
}

/// Bridges the coordinator's nonisolated `onEvent` callback back onto the main
/// actor, and lets us hand the coordinator a callback before `self` exists.
///
/// Each event is stamped when the coordinator emits it, not when the main
/// actor gets around to handling it, so the release-to-paste measurement does
/// not include scheduling delay.
@MainActor
final class EventRelay {
    var handler: ((DictationCoordinator.Event, ContinuousClock.Instant) -> Void)?

    nonisolated func send(_ event: DictationCoordinator.Event) {
        let at = ContinuousClock.now
        Task { @MainActor in self.handler?(event, at) }
    }
}
