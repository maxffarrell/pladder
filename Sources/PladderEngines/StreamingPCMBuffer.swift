/// Feed the non-causal encoder at identical boundaries regardless of capture
/// buffer size. Otherwise newly available future audio changes punctuation.
struct StreamingPCMBuffer {
    static let frameSamples = 1280 // One encoder frame: 80 ms at 16 kHz.
    private var pending: [Float] = []
    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        var offset = 0
        while offset + Self.frameSamples <= pending.count {
            frames.append(Array(pending[offset..<offset + Self.frameSamples]))
            offset += Self.frameSamples
        }
        if offset > 0 { pending.removeFirst(offset) }
        return frames
    }
    mutating func finish() -> [Float] {
        let tail = pending
        pending = []
        return tail
    }
}
