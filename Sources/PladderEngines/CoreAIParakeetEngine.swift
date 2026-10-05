import CoreAISpeech
import Foundation
import PladderCore

/// Apple's CoreAISpeech owns feature extraction, TDT decoding and streaming
/// windows. One resident model, no FluidAudio, Python or model server at runtime.
public actor CoreAIParakeetEngine: StreamingTranscriptionEngine {
    public nonisolated let id: EngineID
    public nonisolated let displayName: String
    public private(set) var status: EngineStatus = .unloaded
    private let selection: CoreAIParakeetModel
    private var model: SpeechRecognitionModel?
    private var consumer: Task<Void, Error>?
    private var segments = SegmentTranscript()
    private var sampleCount = 0
    private var pcm = StreamingPCMBuffer()
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var revision = 0
    private var stable = StableTranscript()
    private var generation = 0
    private var streamFailure: String?

    public init(model: CoreAIParakeetModel = .v3) {
        selection = model
        id = model.engineID
        displayName = model.displayName
    }

    public func load() async throws {
        guard model == nil else { return }
        status = .downloading(progress: nil)
        do {
            let bundle = try await CoreAIBundleStore.shared.prepare(selection)
            status = .loading
            model = try await SpeechRecognitionModel(resourcesAt: bundle)
            status = .ready
        } catch {
            status = .failed(.loadFailed(detail: error.localizedDescription))
            throw error
        }
    }

    public func beginUtterance() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        await abandonLocked()
        guard let model, status.isReady else { throw TranscriptionError.notLoaded }
        sampleCount = 0
        pcm = StreamingPCMBuffer()
        segments = SegmentTranscript()
        revision = 0
        stable = StableTranscript()
        streamFailure = nil
        let token = generation
        let updates = try await model.startStream()
        consumer = Task { [weak self] in
            for try await update in updates {
                guard !Task.isCancelled else { return }
                await self?.accept(update, generation: token)
            }
        }
    }

    private func accept(_ update: TranscriptionUpdate, generation token: Int) {
        guard generation == token else { return }
        switch update {
        case .partial(let segment), .finalized(let segment):
            segments.update(index: segment.segmentIndex, text: segment.text)
            revision += 1
        }
    }

    public func feed(_ samples: [Float]) async {
        await acquireOperation()
        defer { releaseOperation() }
        guard let model, consumer != nil, streamFailure == nil else { return }
        sampleCount += samples.count
        do {
            for frame in pcm.append(samples) { try await model.append(pcm: frame) }
        }
        catch { streamFailure = String(describing: error) }
    }

    public func livePass() async -> String? {
        let text = segments.text
        let committed = stable.observe(text, revision: revision)
        return committed.isEmpty ? nil : committed
    }

    public func endUtterance(_ tail: [Float]) async throws -> Transcript {
        await acquireOperation()
        defer { releaseOperation() }
        guard let model, let consumer else { throw TranscriptionError.notLoaded }
        let started = ContinuousClock.now
        defer { self.consumer = nil }
        do {
            if let streamFailure { throw StreamError.inference(streamFailure) }
            sampleCount += tail.count
            for frame in pcm.append(tail) { try await model.append(pcm: frame) }
            try await model.append(pcm: pcm.finish())
            _ = try await model.finishStream()
            try await consumer.value
            // finishStream returns only the last endpoint segment. Join every
            // finalized segment after the consumer has drained its updates.
            let text = segments.text
            return Transcript(text: text, audioDuration: Double(sampleCount) / 16_000,
                              processingTime: Self.seconds(ContinuousClock.now - started), engineID: id)
        } catch {
            await abandonLocked()
            throw error
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        let started = ContinuousClock.now
        try await beginUtterance()
        do {
            // Bounded pushes preserve the exact online window and state sequence.
            for start in stride(from: 0, to: samples.count, by: 16_000) {
                await feed(Array(samples[start..<min(start + 16_000, samples.count)]))
            }
            var transcript = try await endUtterance([])
            transcript.processingTime = Self.seconds(ContinuousClock.now - started)
            return transcript
        } catch {
            await abandonUtterance()
            throw error
        }
    }

    public func abandonUtterance() async {
        await acquireOperation()
        defer { releaseOperation() }
        await abandonLocked()
    }

    private func abandonLocked() async {
        generation += 1
        consumer?.cancel()
        consumer = nil
        // CoreAISpeech exposes finish, but not cancel. Finish drains the private
        // stream and restores its state before another utterance can start.
        if let model, await model.activeStreamingConfig != nil {
            do { _ = try await model.finishStream() }
            catch {
                // A failed finish can leave Apple's private session open.
                // Recreate the model on retry instead of reusing that session.
                self.model = nil
                status = .failed(.loadFailed(detail: error.localizedDescription))
            }
        }
        pcm = StreamingPCMBuffer()
        segments = SegmentTranscript()
        stable = StableTranscript()
        streamFailure = nil
    }

    public func unload() async {
        await abandonUtterance()
        model = nil
        status = .unloaded
    }

    // Actor reentrancy must not let release/cancel call finishStream while
    // an encoder hop is still inside append. Display reads may still run.
    private func acquireOperation() async {
        if operationInProgress {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else { operationInProgress = true }
    }
    private func releaseOperation() {
        if operationWaiters.isEmpty { operationInProgress = false }
        else { operationWaiters.removeFirst().resume() }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private enum StreamError: Error { case inference(String) }
}
