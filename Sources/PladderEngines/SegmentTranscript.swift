/// CoreAISpeech's finish result contains only its last segment. Retain every
/// segment by identity, replacing partial updates until that segment closes.
struct SegmentTranscript {
    private var segments: [Int: String] = [:]
    mutating func update(index: Int, text: String) { segments[index] = text }
    var text: String {
        segments.keys.sorted().compactMap { segments[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
