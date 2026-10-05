import Foundation

/// Which interface style the app uses. `NSApp.appearance` maps this: `nil`
/// for system, `.aqua` for light, `.darkAqua` for dark.
public enum Appearance: String, Codable, Sendable, CaseIterable, Equatable {
    case system, light, dark
}

/// Which interface appears while dictating. Live Transcript reads stable
/// words from the stream without an additional inference pass.
public enum OverlayStyle: String, Codable, Sendable, CaseIterable, Equatable {
    case menuBar, minimal, compact, liveTranscript
}

/// How fast the pill flies in from the bottom edge and dives back down. Pure
/// data; the durations it maps to live with the overlay, so PladderCore stays
/// free of AppKit and SwiftUI.
public enum OverlayAnimationSpeed: String, Codable, Sendable, CaseIterable, Equatable {
    case instant, quick, expressive

    /// How long the "press ⌘V" hint rests before it leaves. A hold, not
    /// motion, but it scales with the speed all the same: without
    /// Accessibility the hint follows every dictation, and someone who chose
    /// Instant wants the overlay out of the way, not a message to read.
    public var copiedHoldDuration: Duration {
        switch self {
        case .instant: .milliseconds(700)
        case .quick: .seconds(1)
        case .expressive: .seconds(1.5)
        }
    }
}

/// Which model the polish runs through. Pure data; PladderRefine maps each
/// case to a model and the app words it.
public enum PolishModel: String, Codable, Sendable, CaseIterable, Equatable {
    /// Apple's on-device model, part of macOS: nothing to download.
    case appleIntelligence
    /// S1-mini by Superwhisper at full precision (16-bit), downloaded once.
    case s1Mini
    /// The same model at 8-bit: about half the download and memory, and
    /// faster, for a little accuracy (docs/BENCHMARKS.md).
    case s1Mini8Bit
}

/// Everything the user can change. Persisted as JSON by `SettingsStore`.
public struct Settings: Codable, Sendable, Equatable {
    public var engineID: EngineID
    public var hotkey: Hotkey
    /// Pressed at any point while `hotkey` is held, this makes the dictation
    /// end with Return, which sends a chat message or runs a command. V by
    /// default, within reach of the hand holding the default hotkey. Empty
    /// turns it off.
    public var submitKey: Hotkey
    /// Every dictation runs through the on-device model before it is pasted.
    /// Experimental and off by default: the model costs one to three seconds,
    /// so this sits on the normal hotkey's release path.
    public var polishDictations: Bool
    /// What `polishDictations` runs the text through.
    public var polishModel: PolishModel
    /// A chord that starts a recording on one press and ends it on the next.
    /// The same chord as `hotkey` makes that key hybrid: a tap latches, a hold
    /// stops at release. Empty, the default, turns it off.
    public var toggleHotkey: Hotkey
    /// Processor IDs that are turned off. Absent means enabled.
    public var disabledProcessors: Set<String>
    public var dictionary: [DictionaryEntry]
    /// Insert a trailing space after each dictation so consecutive dictations
    /// don't run together.
    public var appendTrailingSpace: Bool
    public var launchAtLogin: Bool
    /// Play a short sound on record start/stop.
    public var playSounds: Bool
    /// Mute the default output device while the key is held, so music or a
    /// call does not end up in the microphone. Off by default: some people
    /// want the audio to keep playing.
    public var muteOutputWhileDictating: Bool
    public var appearance: Appearance
    public var overlayStyle: OverlayStyle
    /// Liquid Glass behind the overlay pill; off gives a flat
    /// window-background fill.
    public var overlayGlass: Bool
    /// Speed of the fly-in/fly-out presentation animation.
    public var overlayAnimationSpeed: OverlayAnimationSpeed

    public init(
        engineID: EngineID,
        hotkey: Hotkey = .optionSpace,
        submitKey: Hotkey = .keyV,
        polishDictations: Bool = false,
        polishModel: PolishModel = .appleIntelligence,
        toggleHotkey: Hotkey = Hotkey(keyCodes: []),
        disabledProcessors: Set<String> = [],
        dictionary: [DictionaryEntry] = [],
        appendTrailingSpace: Bool = true,
        launchAtLogin: Bool = false,
        playSounds: Bool = true,
        muteOutputWhileDictating: Bool = false,
        appearance: Appearance = .system,
        overlayStyle: OverlayStyle = .liveTranscript,
        overlayGlass: Bool = true,
        overlayAnimationSpeed: OverlayAnimationSpeed = .quick
    ) {
        self.engineID = engineID
        self.hotkey = hotkey
        self.submitKey = submitKey
        self.polishDictations = polishDictations
        self.polishModel = polishModel
        self.toggleHotkey = toggleHotkey
        self.disabledProcessors = disabledProcessors
        self.dictionary = dictionary
        self.appendTrailingSpace = appendTrailingSpace
        self.launchAtLogin = launchAtLogin
        self.playSounds = playSounds
        self.muteOutputWhileDictating = muteOutputWhileDictating
        self.appearance = appearance
        self.overlayStyle = overlayStyle
        self.overlayGlass = overlayGlass
        self.overlayAnimationSpeed = overlayAnimationSpeed
    }

    // Decoding tolerates missing keys so adding a field in a later version
    // never makes an existing settings file unreadable.
    private enum CodingKeys: String, CodingKey {
        case engineID, hotkey, submitKey, polishDictations, polishModel, disabledProcessors, dictionary, appendTrailingSpace, launchAtLogin, playSounds, appearance
        case overlayStyle, overlayGlass, overlayAnimationSpeed, muteOutputWhileDictating
        case toggleHotkey
        // Read once for the migration, never written.
        case polishHotkey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineID = try c.decode(EngineID.self, forKey: .engineID)
        // An empty chord can never fire, so treat it like a missing key.
        let decodedHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        hotkey = decodedHotkey.flatMap { $0.keyCodes.isEmpty ? nil : $0 } ?? .optionSpace
        // Unlike the hotkey, an empty submit key is meaningful: it is how the
        // feature is switched off.
        submitKey = try c.decodeIfPresent(Hotkey.self, forKey: .submitKey) ?? .keyV
        // Once a chord of its own, the polish is now a Processing toggle.
        // A stored chord migrates to `true`, so the feature the user asked
        // for turns on with the update; nothing is written under the old key.
        let legacyPolish = try c.decodeIfPresent(Hotkey.self, forKey: .polishHotkey) ?? Hotkey(keyCodes: [])
        polishDictations = try c.decodeIfPresent(Bool.self, forKey: .polishDictations)
            ?? (!legacyPolish.isEmpty)
        // A model this build does not know, say from a newer version, falls
        // back to Apple's rather than making the whole file unreadable.
        polishModel = (try? c.decodeIfPresent(PolishModel.self, forKey: .polishModel)) ?? .appleIntelligence
        // Like the submit key, empty is meaningful: off.
        toggleHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .toggleHotkey) ?? Hotkey(keyCodes: [])
        disabledProcessors = try c.decodeIfPresent(Set<String>.self, forKey: .disabledProcessors) ?? []
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? []
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? true
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        overlayStyle = try c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle) ?? .compact
        overlayGlass = try c.decodeIfPresent(Bool.self, forKey: .overlayGlass) ?? true
        overlayAnimationSpeed = try c.decodeIfPresent(OverlayAnimationSpeed.self, forKey: .overlayAnimationSpeed) ?? .quick
        muteOutputWhileDictating = try c.decodeIfPresent(Bool.self, forKey: .muteOutputWhileDictating) ?? false
    }

    // Encoding mirrors the synthesized one, minus the legacy `polishHotkey`
    // key that only the decoder above reads.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(engineID, forKey: .engineID)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(submitKey, forKey: .submitKey)
        try c.encode(polishDictations, forKey: .polishDictations)
        try c.encode(polishModel, forKey: .polishModel)
        try c.encode(toggleHotkey, forKey: .toggleHotkey)
        try c.encode(disabledProcessors, forKey: .disabledProcessors)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(appendTrailingSpace, forKey: .appendTrailingSpace)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(muteOutputWhileDictating, forKey: .muteOutputWhileDictating)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(overlayStyle, forKey: .overlayStyle)
        try c.encode(overlayGlass, forKey: .overlayGlass)
        try c.encode(overlayAnimationSpeed, forKey: .overlayAnimationSpeed)
    }

    public func isProcessorEnabled(_ id: String) -> Bool {
        !disabledProcessors.contains(id)
    }

    public mutating func setProcessor(_ id: String, enabled: Bool) {
        if enabled { disabledProcessors.remove(id) } else { disabledProcessors.insert(id) }
    }
}

/// Loads and saves `Settings` as JSON. Pure Foundation, so it is testable with
/// a temp directory.
public final class SettingsStore: Sendable {
    public let url: URL
    private let defaults: Settings

    public init(url: URL, defaults: Settings) {
        self.url = url
        self.defaults = defaults
    }

    /// Returns the saved settings, or the defaults when there is no file. A
    /// file that exists but cannot be decoded is moved aside rather than left
    /// in place to be overwritten by the next save, so a user's dictionary is
    /// never silently lost.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return defaults }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            let broken = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            return defaults
        }
    }

    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
