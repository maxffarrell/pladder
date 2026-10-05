@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PladderEngines

@Test(.enabled(if: ProcessInfo.processInfo.environment["PLADDER_COREAI_TEST_WAV"] != nil))
func actualModelsPreserveFullTranscriptAndStreamBoundaries() async throws {
    let url = URL(filePath: ProcessInfo.processInfo.environment["PLADDER_COREAI_TEST_WAV"]!)
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    #expect(file.processingFormat.sampleRate == 16_000)
    #expect(file.processingFormat.channelCount == 1)
    let pcm = try #require(buffer.floatChannelData)
    let samples = Array(UnsafeBufferPointer(start: pcm[0], count: Int(buffer.frameLength)))
    for choice in CoreAIParakeetModel.allCases {
        let engine = CoreAIParakeetEngine(model: choice)
        try await engine.load()
        let batch = try await engine.transcribe(samples)
        // A 30-second fixture closes multiple endpoint segments; returning
        // finishStream alone produced an empty string in the original bug.
        #expect(batch.text.split(whereSeparator: \.isWhitespace).count > 80)
        try await engine.beginUtterance()
        var previous = ""
        for offset in stride(from: 0, to: samples.count, by: 4096) {
            await engine.feed(Array(samples[offset..<min(offset + 4096, samples.count)]))
            if let live = await engine.livePass() {
                #expect(live.hasPrefix(previous))
                previous = live
            }
        }
        let streamed = try await engine.endUtterance([])
        #expect(streamed.text == batch.text)
        #expect(!previous.isEmpty)
        try await engine.beginUtterance()
        await engine.feed(Array(samples.prefix(32_000)))
        await engine.abandonUtterance()
        let fresh = try await engine.transcribe(samples)
        #expect(fresh.text == batch.text)
        await engine.unload()
    }
}
