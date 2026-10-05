import SwiftUI
import PladderCore

/// The state the overlay renders. Kept separate from the coordinator so the
/// panel can be driven independently (and shown while fading out after the
/// coordinator has already returned to `.idle`).
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    /// Appearance forced by the Appearance setting; `.system` means follow.
    /// AppKit's window propagation reaches a borderless panel inconsistently,
    /// so the color scheme is set in SwiftUI directly.
    var appearance: Appearance = .system
    /// Which pill the user picked. `.menuBar` never presents except for
    /// errors; the controller decides that, not the view.
    var style: OverlayStyle = .compact
    /// Liquid Glass behind the pill, or a flat window-background fill.
    var glass: Bool = true
    /// How fast the pill flies in and out.
    var speed: OverlayAnimationSpeed = .quick
    /// Where the pill is in the fly-in/fly-out presentation. The panel does
    /// the sliding below the screen edge; this phase keeps the pill as the
    /// Minimal disc whenever it is not settled, so it flies as the disc and
    /// morphs to its style's shape once it has arrived.
    var presentation: OverlayPresentation = .hidden
    /// What the engine has heard so far, for the Live Transcript style. Nil in
    /// every other style, and nil again the moment the key is released.
    var partialTranscript: String?
    init() {}
}

enum OverlayPresentation: Equatable {
    /// Off screen, parked as the disc so the next flight starts from it.
    case hidden
    /// Rising from the bottom edge as the disc; content forced to Minimal.
    case flyingIn
    /// At rest, in the style's own shape.
    case settled
    /// Collapsing to the disc, about to dive; content forced to Minimal.
    case flyingOut
}

/// The timing the animation setting maps to. Panel and view read the same
/// values so the slide and the morph stay in sync; the mapping lives here
/// because PladderCore never imports SwiftUI.
extension OverlayAnimationSpeed {
    /// How long the panel takes to slide up from (or back down behind) the
    /// bottom edge of the screen.
    var flightDuration: TimeInterval {
        switch self {
        case .instant: 0.06
        case .quick: 0.20
        case .expressive: 0.35
        }
    }

    /// How long the disc↔row morph takes, in both directions. Arrival is
    /// slide-up then expand; departure is collapse then slide-down. The
    /// controller waits exactly this long between the collapse and the dive,
    /// so the two directions are mirror images, and the content crossfade
    /// runs over the same span so what is inside the pill never outruns the
    /// pill.
    var morphDuration: TimeInterval {
        switch self {
        case .instant: 0.10
        case .quick: 0.26
        case .expressive: 0.5
        }
    }

    /// The spring the disc↔row geometry uses. A spring's duration is
    /// perceptual, so the bounce is kept small enough that the settle stays
    /// inside `morphDuration`.
    var morphAnimation: Animation {
        switch self {
        case .instant: .smooth(duration: morphDuration)
        case .quick: .spring(duration: morphDuration, bounce: 0.12)
        case .expressive: .spring(duration: morphDuration, bounce: 0.22)
        }
    }

    /// How the content arriving with a morph fades in: over the same span as
    /// the geometry, but no bounce, since a spring on opacity would dip past
    /// zero and flash the content back. What is leaving goes quickly instead
    /// (`OverlayPill.contentHandover`), so the eye never sees two dots.
    var contentFade: Animation { .easeInOut(duration: morphDuration) }
}

/// What the pill looks like, with the live audio level projected out.
///
/// `DictationState.recording` carries a level that changes many times a second.
/// Driving the capsule's morph animation off the state itself would restart
/// that animation on every meter update, so the morph animates on this
/// level-free phase instead while the bars animate on their own.
private enum OverlayPhase: Equatable {
    case empty
    case recording
    case transcribing
    case polishing
    case copied
    case error(DictationFailure)

    init(_ state: DictationState) {
        switch state {
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .polishing: self = .polishing
        case .copied: self = .copied
        // The controller never mirrors `.inserting` onto the model, so this
        // is only reached by a preview, and it draws nothing.
        case .inserting: self = .empty
        case .error(let failure): self = .error(failure)
        case .idle, .unavailable: self = .empty
        }
    }
}

/// Liquid Glass pill: a capsule that samples the desktop behind the
/// transparent panel and morphs between the recording, transcribing, copied
/// and error states.
struct OverlayView: View {
    let model: OverlayModel

    private var phase: OverlayPhase { OverlayPhase(model.state) }

    var body: some View {
        OverlayPill(
            state: model.state,
            style: model.style,
            glass: model.glass,
            partial: model.partialTranscript,
            presentation: model.presentation,
            animationSpeed: model.speed
        )
            // Glass carries its own edge highlight; this is only enough shadow
            // to lift the pill off a light desktop. The flat background gets
            // the same treatment.
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .animation(.smooth(duration: 0.25), value: phase)
            .animation(model.speed.morphAnimation, value: model.presentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ForcedScheme(appearance: model.appearance))
    }
}

/// The pill itself, without the panel's shadow or forced scheme, so the
/// settings previews can render a live replica of each style.
struct OverlayPill: View {
    let state: DictationState
    let style: OverlayStyle
    let glass: Bool
    /// A static replica in settings: no dot timer, no pulse, seeded bars.
    var isPreview: Bool = false
    /// The words so far, for the Live Transcript style. Ignored by the others.
    var partial: String?
    /// The live row is a fixed box on screen so the capsule cannot jitter as
    /// the text grows. A settings card has no room for that box, so its
    /// replica hugs its sample text, wrapped onto two short lines.
    var hugsContent: Bool = false
    /// While the pill flies in or out (or waits off screen) it is always the
    /// Minimal disc: the bigger styles expand from it after arriving and
    /// collapse back into it before diving. Settings replicas never fly, so
    /// they are always settled.
    var presentation: OverlayPresentation = .settled
    /// The speed whose spring drives the disc↔row geometry on both sides of
    /// the flight, so contracting to the disc takes exactly as long as
    /// expanding out of it. Settings replicas never fly, so they keep the
    /// default.
    var animationSpeed: OverlayAnimationSpeed = .quick

    @Namespace private var glassNamespace
    /// Minimal shows a pulsing dot for the first 0.7 s, then the bars.
    @State private var showDot = true
    @State private var pulsing = false

    private var phase: OverlayPhase { OverlayPhase(state) }

    private var flying: Bool { presentation != .settled }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
                // The size driver: in flight the pill is proposed the disc's
                // width, at rest its own — animated with the speed's morph
                // spring on *both* sides of the flight, so contracting to the
                // disc and expanding out of it are the same rate. The glass
                // bubble outside this point follows the proposal.
                .frame(width: flying ? Self.minimalDiameter : nil)
                // What arrives inside fades in over the same span (the branch
                // transitions below), so the row is still faint while the
                // capsule is small; this clip keeps it inside the capsule
                // rather than poking out of the disc.
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .animation(animationSpeed.morphAnimation, value: flying)
                .modifier(PillBackground(glass: glass, namespace: glassNamespace))
        }
        .task(id: phase) {
            guard !isPreview else { return }
            // Runs on every phase change, so leaving `.recording` is where
            // the pulse is reset; otherwise the next take's dot would appear
            // already at full scale with no animation left to run.
            guard phase == .recording else {
                pulsing = false
                return
            }
            showDot = true
            try? await Task.sleep(for: .milliseconds(700))
            // A phase change cancels this task, which is exactly what should
            // stop the swap; nothing else to unwind.
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { showDot = false }
        }
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    private var isCopied: Bool { state == .copied }

    /// Both an error and the clipboard hint carry text, which needs the
    /// Compact row's width, so they render as the row in every style.
    private var needsRow: Bool { isError || isCopied || style != .minimal }

    /// The transition on every content branch: what is arriving fades in
    /// over the morph, so it comes up with the capsule around it; what is
    /// leaving goes at once, so its dot is gone before the arriving dot is
    /// visible and nothing is seen sliding towards the centre of a shrinking
    /// capsule.
    private var contentHandover: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(animationSpeed.contentFade),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        // In flight the pill is the Minimal disc whatever the style: the disc
        // rises with the dot inside it, and the style's own shape comes out
        // of it on arrival. Minimal shares that branch whether flying or
        // not, so its bars and dot keep their identity — and their state —
        // across the arrival.
        if flying || !needsRow {
            // A fixed square so the disc never changes size between the
            // dot, the wave and the spinner. On release a row style's
            // content goes at once and the Minimal wave comes up in the
            // shrinking capsule, so every style leaves the way Minimal does.
            minimalContent
                .frame(width: Self.minimalDiameter, height: Self.minimalDiameter)
                .transition(contentHandover)
        }
        // An error presents in every style (the controller makes sure of it),
        // and the message needs the Compact row's width, so errors always
        // render as the Compact row; the "press ⌘V" hint is text too and
        // follows the same rule. `.menuBar` only ever reaches the view for
        // those two. Live has its own recording row and falls back to the
        // Compact rows for everything else.
        else if style == .liveTranscript && !isError {
            liveContent
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
                .transition(contentHandover)
        } else {
            compactContent
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
                .transition(contentHandover)
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        switch state {
        case .recording(let level):
            HStack(spacing: 10) {
                RecordingDot()
                LevelBars(level: level, count: 14, maxHeight: 32, opacity: 1, seeded: isPreview)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .polishing:
            // Only a dictation on its way to the refiner gets here, and it
            // waits seconds rather than milliseconds, so the pill says why.
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .copied:
            // Nothing pasted the text, so the user has to. The one thing the
            // pill still says after a release: the paste that is normally the
            // confirmation never happened.
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Text("Copied — press ⌘V")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .error(let failure):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure.text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Keeps a long message inside the panel instead of letting
                    // the capsule grow past its edges.
                    .frame(maxWidth: 232)
            }
        // `.inserting` is never mirrored onto the model, so it draws nothing.
        case .inserting, .idle, .unavailable:
            Color.clear.frame(width: 100)
        }
    }

    /// The words as they are recognised, beside a narrower meter. Only the
    /// recording row differs from Compact: the spinner, the clipboard hint and
    /// the error say the same thing in every style, and letting them keep the
    /// live row's width would leave a mostly empty capsule on screen.
    @ViewBuilder
    private var liveContent: some View {
        switch state {
        case .recording(let level):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    LevelBars(level: level, count: 5, maxHeight: 16, opacity: 1, seeded: isPreview)
                        .foregroundStyle(.cyan)
                    Text("Listening")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    RecordingDot(size: 5)
                }
                if let partial, !partial.isEmpty {
                    LiveTranscriptText(text: partial, hugs: hugsContent,
                                       width: hugsContent ? Self.previewTextWidth : Self.liveTextWidth, animate: !isPreview)
                } else {
                    Text("Start speaking…")
                        .font(LiveTranscriptText.font)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: hugsContent ? nil : Self.liveRowWidth, alignment: .leading)
            .frame(minHeight: hugsContent ? nil : 72, alignment: .topLeading)
        default:
            compactContent
        }
    }

    /// Width of the live row's contents. With the 18 pt padding either side
    /// the capsule comes to 440 pt, inside the 480 pt panel with room for its
    /// shadow.
    static let liveRowWidth: CGFloat = 404

    /// The text measures itself against this fixed width
    /// to decide how much of the tail fits in three lines.
    static var liveTextWidth: CGFloat { liveRowWidth }

    /// The words in a settings card: wide enough for two short lines, so the
    /// card reads as text beside the meter rather than a long thin pill.
    static let previewTextWidth: CGFloat = 62

    /// Diameter of the Minimal disc. Five bars at 3 pt with 3 pt gaps are
    /// 27 pt wide and 20 pt tall, which sits inside the disc with room to
    /// spare at the chord where the bars reach.
    static let minimalDiameter: CGFloat = 44

    /// Just enough to say "recording", and "still working" when a
    /// transcription runs long: no text, and a disc rather than a pill. The
    /// dot marks the start of a take, then a narrow wave takes over so the
    /// disc still shows the microphone is live.
    @ViewBuilder
    private var minimalContent: some View {
        switch state {
        case .recording(let level):
            ZStack {
                if showsDot {
                    // The pulse is Minimal's own start-of-take cue. A row
                    // style flying in keeps the dot at the row's size, so
                    // the dot it hands over to on arrival is the same dot.
                    RecordingDot()
                        .scaleEffect(pulsing && !needsRow ? 1.3 : 1.0)
                        .onAppear {
                            guard !isPreview else { return }
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                pulsing = true
                            }
                        }
                        .transition(.opacity)
                } else {
                    LevelBars(level: level, count: 5, maxHeight: 20, opacity: 0.8, seeded: isPreview)
                        .transition(.opacity)
                }
            }
        case .transcribing, .polishing:
            ProgressView()
                .controlSize(.small)
        case .copied:
            // The hint leaves by the dive like a pasted dictation, and the
            // disc it collapses into keeps the row's clipboard glyph rather
            // than going empty, so what slides away still says what happened.
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
                .transition(.opacity)
        // An error is rendered as the row above, so it never reaches this;
        // `.inserting` is never mirrored onto the model.
        case .inserting, .error, .idle, .unavailable:
            Color.clear
        }
    }

    /// A replica has no timer, so it goes straight to the bars. A row style
    /// collapsing after a short take would otherwise put the dot back in the
    /// middle of the capsule its own dot just left; the wave is what the
    /// disc shows on the way out.
    private var showsDot: Bool {
        if isPreview { return false }
        if presentation == .flyingOut && needsRow { return false }
        return showDot
    }
}

/// Only the engine's committed words arrive here. Absolute word identities
/// survive tail cropping, so existing words never replay their entrance.
struct LiveTranscriptText: View {
    let text: String
    var hugs: Bool = false
    var width: CGFloat?
    var animate = true
    @State private var previousWordCount = 0
    static let maximumLines = 3
    static let font = Font.system(size: 16, weight: .medium, design: .rounded)

    private var visibleWords: [(index: Int, text: String)] {
        let all = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = width.map {
            LiveTranscriptMetrics.tail(of: text, fittingLines: hugs ? 2 : Self.maximumLines, width: $0)
        } ?? text
        let tail = shown.split(whereSeparator: \.isWhitespace).map(String.init)
        return tail.enumerated().map { (all.count - tail.count + $0.offset, $0.element) }
    }

    var body: some View {
        WordFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(visibleWords, id: \.index) { word in
                RevealedWord(text: word.text, delay: animate ? min(0.35, Double(max(0, word.index - previousWordCount)) * 0.055) : 0, animate: animate)
            }
        }
        .frame(width: hugs ? width : nil, alignment: .leading)
        .frame(maxWidth: hugs ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onChange(of: text) { old, _ in previousWordCount = old.split(whereSeparator: \.isWhitespace).count }
    }
}

private struct RevealedWord: View {
    let text: String
    let delay: Double
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        Text(text)
            .font(LiveTranscriptText.font)
            .foregroundStyle(.primary)
            .opacity(visible || reduceMotion || !animate ? 1 : 0)
            .blur(radius: visible || reduceMotion || !animate ? 0 : 2)
            .task {
                if animate && !reduceMotion { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion || !animate ? nil : .easeOut(duration: 0.45)) { visible = true }
            }
    }
}

/// Word wrapping uses the same measurements for placement and height. The
/// available width is fixed while recording, keeping the glass surface still.
private struct WordFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func positions(_ subviews: Subviews, width: CGFloat) -> ([CGPoint], CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: min(width, maxX), height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(subviews, width: proposal.width ?? 404).1
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (points, _) = positions(subviews, width: bounds.width)
        for (view, point) in zip(subviews, points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                       anchor: .topLeading, proposal: .unspecified)
        }
    }
}

/// The red "live" dot, shared by Compact, Minimal and the settings replicas.
struct RecordingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .shadow(color: .red.opacity(0.6), radius: 4)
    }
}

/// What sits behind the pill: Liquid Glass, or a flat window-background
/// capsule with a hairline border for people who want the desktop to stay
/// still. The shadow is added by whoever hosts the pill.
struct PillBackground: ViewModifier {
    let glass: Bool
    /// Only the live overlay morphs between states, so the glass identity is
    /// optional; the settings replicas pass nothing.
    var namespace: Namespace.ID?

    /// One shape for the rows and the Minimal disc: a capsule in a square is
    /// a circle, so the disc↔row morph is purely the animated size. A
    /// separate `Circle` would snap — `Circle()` in a row-sized frame draws a
    /// disc in the middle of the row at once, and `AnyShape` cannot
    /// interpolate between two shape types, so the collapse would be over
    /// before it started.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 26, style: .continuous) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            if let namespace {
                content
                    .glassEffect(.regular, in: shape)
                    .glassEffectID("pill", in: namespace)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}

/// Bars whose heights follow the input level. The shaping (amplitude curve,
/// bell envelope, wobble, rise/fall blend) lives in the shared
/// `WaveformMeter`, so this wave matches the menu bar glyph exactly.
struct LevelBars: View {
    let level: Float
    let count: Int
    let maxHeight: CGFloat
    let opacity: Double

    private static let minScale: CGFloat = 0.1

    @State private var meter: WaveformMeter
    @State private var heights: [CGFloat]

    /// `seeded` pre-rolls the meter so a static replica (the settings cards,
    /// which never see a level change) shows a wave rather than a row of
    /// stubs.
    init(level: Float, count: Int, maxHeight: CGFloat, opacity: Double, seeded: Bool = false) {
        self.level = level
        self.count = count
        self.maxHeight = maxHeight
        self.opacity = opacity

        var meter = WaveformMeter(count: count)
        var initial = Array(repeating: Self.minScale, count: count)
        if seeded {
            var shaped: [Float] = []
            for _ in 0..<8 { shaped = meter.update(level: level) }
            initial = shaped.map { max(Self.minScale, CGFloat($0)) }
        }
        _meter = State(initialValue: meter)
        _heights = State(initialValue: initial)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(opacity))
                    .frame(width: 3, height: max(3, heights[index] * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .onChange(of: level) { _, new in
            let next = meter.update(level: new)
            withAnimation(.easeOut(duration: 0.1)) {
                heights = next.map { max(Self.minScale, CGFloat($0)) }
            }
        }
    }
}

/// Overrides the SwiftUI color scheme under a forced appearance. AppKit's
/// window-appearance propagation reaches a borderless panel inconsistently,
/// so this sets the scheme in the environment directly, which is what
/// `glassEffect` and the text colours follow.
private struct ForcedScheme: ViewModifier {
    let appearance: Appearance

    func body(content: Content) -> some View {
        switch appearance {
        case .system: content
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        }
    }
}
