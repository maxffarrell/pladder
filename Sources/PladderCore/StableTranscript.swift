import Foundation

/// Display-only commitment. ASR scores are not calibrated confidence; agreement
/// across advancing hypotheses plus a withheld trailing word is the gate.
/// Once committed, a word's spelling and punctuation never change on screen.
/// The final paste remains the engine's complete transcript, independently.
public struct StableTranscript: Sendable {
    private var previous: [String] = []
    public private(set) var words: [String] = []
    private var lastRevision = -1

    public init() {}

    @discardableResult
    public mutating func observe(_ text: String, revision: Int) -> String {
        guard revision > lastRevision else { return words.joined(separator: " ") }
        lastRevision = revision
        let candidate = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let common = zip(previous, candidate).prefix { $0 == $1 }.count
        let limit = min(common, max(0, candidate.count - 1))
        // Divergent hypotheses never erase or overwrite already revealed words.
        if candidate.starts(with: words), limit > words.count {
            words.append(contentsOf: candidate[words.count..<limit])
        }
        previous = candidate
        return words.joined(separator: " ")
    }
}
