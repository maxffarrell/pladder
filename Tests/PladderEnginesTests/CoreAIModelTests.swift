import Testing
@testable import PladderEngines

@Test func modelChoicesHaveDistinctIdentities() {
    #expect(Set(CoreAIParakeetModel.allCases.map { $0.engineID }).count == 3)
    #expect(CoreAIParakeetModel.allCases.allSatisfy { $0.bundleName.hasSuffix("_float16_streaming150") })
}

@Test func retainsEarlierSegmentsWhenFinalSegmentIsEmpty() {
    var transcript = SegmentTranscript()
    transcript.update(index: 0, text: "The morning")
    transcript.update(index: 0, text: "The morning train.")
    transcript.update(index: 2, text: "Then we arrived.")
    transcript.update(index: 1, text: "We crossed the river.")
    transcript.update(index: 3, text: "")
    #expect(transcript.text == "The morning train. We crossed the river. Then we arrived.")
}

@Test func captureBufferSizesDoNotChangeEncoderPushBoundaries() {
    let samples = (0..<50_013).map(Float.init)
    var whole = StreamingPCMBuffer()
    let expected = whole.append(samples)
    let expectedTail = whole.finish()
    var fragmented = StreamingPCMBuffer()
    var frames: [[Float]] = []
    for offset in stride(from: 0, to: samples.count, by: 4096) {
        frames += fragmented.append(Array(samples[offset..<min(offset + 4096, samples.count)]))
    }
    #expect(frames == expected)
    #expect(fragmented.finish() == expectedTail)
    #expect(expected.flatMap { $0 } + expectedTail == samples)
}

@Test func downloadsArePinnedAndIntegrityChecked() {
    for model in CoreAIParakeetModel.allCases {
        let artifact = model.artifact
        #expect(artifact.revision.count == 40)
        #expect(artifact.sha256.count == 64)
        #expect(artifact.bytes > 300_000_000)
        #expect(artifact.url.path.contains(artifact.revision))
    }
}
