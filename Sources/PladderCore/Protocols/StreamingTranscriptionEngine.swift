import Foundation

/// An engine that consumes audio while it is being recorded, so that only
/// the tail remains to transcribe at release.
public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    /// Start an empty utterance. Cancel any previous one first.
    func beginUtterance() async throws
    /// 16 kHz mono samples captured since the previous call.
    func feed(_ samples: [Float]) async
    /// Feeds the last samples and returns the transcript for the whole utterance.
    func endUtterance(_ tail: [Float]) async throws -> Transcript
    /// Stop feeding and drop whatever was fed this utterance.
    func abandonUtterance() async
    /// Brings the engine's compute up to speed while the user is still
    /// speaking, before the first real work arrives. Fire and forget.
    func warmPass() async
    /// Display-only committed text from advancing streaming updates. This
    /// never changes decoding state or the final transcript sent to output.
    func livePass() async -> String?
}

extension StreamingTranscriptionEngine {
    public func warmPass() async {}

    /// An engine with no live pass still has to be kept warm, so the default
    /// does the job the warm loop would have done and shows nothing.
    public func livePass() async -> String? {
        await warmPass()
        return nil
    }
}
