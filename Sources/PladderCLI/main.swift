@preconcurrency import AVFoundation
import Darwin
import Foundation
import PladderAudio
import PladderBench
import PladderCore
import PladderEngines
import PladderRefine
import PladderSystem

// Developer tool.
//
//   pladder-cli <audio file>              load Parakeet, print the transcript and nothing else,
//                                         so a script or another program's STT hook can read
//                                         stdout. Errors go to stderr with exit status 1.
//       [--process]                       run the app's processors over it with the app's
//                                         dictionary and toggles, read from its settings file
//                                         (or PLADDER_SETTINGS_PATH), which is never written.
//       [--verbose]                       also print the load and processing times.
//   pladder-cli bench <fixtures dir>      run the benchmark (see docs/BENCHMARKS.md)
//       [--runs N]                        runs per fixture, default 6; the first is discarded.
//                                         Use 11 to settle a result near the noise line.
//       [--pause S]                       idle seconds before every run, default 10
//       [--paced]                         push fixtures in one-second chunks paced at real
//                                         time, as a live recording arrives, and time
//                                         `endUtterance` instead. Also transcribes each
//                                         fixture whole and reports whether the two texts
//                                         are identical, which is the gate on the
//                                         incremental path.
//                                         Fixtures under 13 s are skipped unless --all.
//       [--all]                           paced bench only: keep the short fixtures too.
//       [--live]                          paced bench only: run the Live Transcript style's
//                                         pass over the audio so far every 0.5 s while the
//                                         fixture is paced, as the overlay does, and report
//                                         how many there were and what they cost. The
//                                         `identical:` column then also proves the live
//                                         passes leave the release's windows alone.
//   pladder-cli polish <text file | ->    run the polisher over a transcript: once cold,
//                                         once after prepare() and a two-second wait, the
//                                         way a real press warms it. Prints both timings.
//       [--model <name>]                  apple (default), s1-mini or s1-mini-8bit. An S1-mini
//                                         file is downloaded first if the app has not yet.
//       [--instructions <file>]           Apple only: try another system prompt before
//                                         committing it.
//       [--gguf <file>]                   instead of --model: any S1-mini-family GGUF, such as a
//                                         fine-tune being judged before it goes in the picker.
//       [--control <line>]                S1-mini only: another control line than the app's.
//   pladder-cli polish-set <set.json>     run a polish model over a test set (docs/polish-set.json)
//       [--model <name>]                  after the app's processors, warm, and print each
//                                         answer, the word error rate against the expected
//                                         text per language, exact matches and timings.
//       [--gguf <file>] [--control <line>] as for polish.
//
// Fixtures are audio files with a sibling .txt holding the spoken script, as
// produced by scripts/make-fixtures.sh.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: pladder-cli <audio file> [--process] [--verbose]
           pladder-cli bench <fixtures dir> [--runs N] [--pause S]
           pladder-cli bench <fixtures dir> --paced [--runs N] [--pause S] [--all] [--live]
           pladder-cli polish <text file | -> [--model apple|s1-mini|s1-mini-8bit | --gguf <file>] [--control <line>] [--instructions <file>]
           pladder-cli polish-set <set.json> [--model apple|s1-mini|s1-mini-8bit | --gguf <file>] [--control <line>]

    """.utf8))
    exit(2)
}

/// The first word where two raw engine transcripts diverge, for the identity
/// gate. Nil when they are the same word sequence.
func firstWordDifference(
    batch: String,
    paced: String
) -> (index: Int, batch: String, paced: String)? {
    let left = batch.split(whereSeparator: \.isWhitespace).map(String.init)
    let right = paced.split(whereSeparator: \.isWhitespace).map(String.init)
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : "<end>"
        let b = index < right.count ? right[index] : "<end>"
        if a != b { return (index, a, b) }
    }
    return nil
}

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"]) }
    try file.read(into: input)
    let target = try AudioResampler.monoFloat32Format()
    return try AudioResampler.convert(input, to: target)
}

/// Loads the engine, printing download progress, and returns the wall-clock
/// load time. In a fresh process this is the cold start the app pays at launch.
func loadEngine(_ engine: any TranscriptionEngine) async throws -> Duration {
    let clock = ContinuousClock()
    let started = clock.now
    var lastPrinted = -1
    let statusTask = Task {
        while !Task.isCancelled {
            if case .downloading(let p) = await engine.status, let p {
                let pct = Int(p * 100)
                // stderr, so a first run's download never lands in a transcript.
                if pct != lastPrinted {
                    FileHandle.standardError.write(Data("downloading \(pct)%\n".utf8))
                    lastPrinted = pct
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    defer { statusTask.cancel() }
    do {
        try await engine.load()
    } catch {
        // The engine's own wording for the failure — the line the menu shows —
        // rather than a top-level trap printing the raw error, so a download
        // that never finished can be diagnosed from the terminal.
        if case .failed(let failure) = await engine.status {
            // A developer tool: the enum's own shape is the diagnosis, and
            // the wording that reaches users lives in the app.
            FileHandle.standardError.write(Data("model failed: \(failure)\n".utf8))
            exit(1)
        }
        throw error
    }
    return clock.now - started
}

func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

/// Physical memory footprint of this process, the number Activity Monitor
/// shows in its Memory column.
func physicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

/// One-minute load average, so the conditions of a run are on the record.
func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : 0
}

/// Empty when the chip is at its normal thermal state, else a tag for the
/// run line, because a throttled run is not comparable.
func thermalTag() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return ""
    case .fair: return " [thermal: fair]"
    case .serious: return " [thermal: serious]"
    case .critical: return " [thermal: critical]"
    @unknown default: return " [thermal: unknown]"
    }
}

// MARK: - Transcribe one file

/// The app's settings, for `--process`. Decoded here rather than through
/// `SettingsStore.load()`, which moves a file it cannot decode aside: a CLI
/// built from another branch must never touch the live configuration.
func appSettings() -> Settings {
    let url = ProcessInfo.processInfo.environment["PLADDER_SETTINGS_PATH"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Pladder/settings.json")
    let fallback = Settings(engineID: CoreAIParakeetModel.v3.engineID)
    guard let data = try? Data(contentsOf: url) else { return fallback }
    do {
        return try JSONDecoder().decode(Settings.self, from: data)
    } catch {
        FileHandle.standardError.write(Data("pladder-cli: \(url.path): \(error); processing with the defaults\n".utf8))
        return fallback
    }
}

func selectedSpeechEngine() -> CoreAIParakeetEngine {
    let selected = ProcessInfo.processInfo.environment["PLADDER_SPEECH_MODEL"]
        .flatMap(CoreAIParakeetModel.init(rawValue:)) ?? .v3
    return CoreAIParakeetEngine(model: selected)
}

func transcribeFile(_ path: String, process: Bool, verbose: Bool) async {
    do {
        let engine = selectedSpeechEngine()
        let loadTime = try await loadEngine(engine)
        if verbose { print(String(format: "model ready in %.1fs", seconds(loadTime))) }

        let samples = try loadSamples(URL(fileURLWithPath: path))
        let transcript = try await engine.transcribe(samples)
        var text = transcript.text
        if process {
            let settings = appSettings()
            let pipeline = ProcessorPipeline(StandardProcessors.factories.map { $0(settings) }, onFailure: { id, error in
                FileHandle.standardError.write(Data("pladder-cli: processor \(id) failed: \(error)\n".utf8))
            })
            text = await pipeline.run(text, disabled: settings.disabledProcessors)
        }
        if verbose {
            print(String(format: "audio %.2fs, processed in %.3fs (%.0fx realtime)", transcript.audioDuration, transcript.processingTime, transcript.realtimeFactor))
            if process { print("RAW: \(transcript.text)") }
            print("TEXT: \(text)")
        } else {
            print(text)
        }
    } catch {
        // A file Core Audio cannot open (WebM, say) is the likely failure; a
        // message and a status rather than a trap, for whatever called us.
        FileHandle.standardError.write(Data("pladder-cli: \(path): \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Benchmark

struct Fixture {
    var name: String
    var samples: [Float]
    var reference: String
    var duration: Double { Double(samples.count) / CapturedAudio.sampleRate }
}

/// Every audio file in `dir` that has a sibling `.txt`, shortest first so the
/// longest fixture, which heats the chip the most, runs last.
func loadFixtures(in dir: URL) throws -> [Fixture] {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    var fixtures: [Fixture] = []
    for url in files where url.pathExtension.lowercased() != "txt" && !url.lastPathComponent.hasPrefix(".") {
        let script = url.deletingPathExtension().appendingPathExtension("txt")
        guard let reference = try? String(contentsOf: script, encoding: .utf8) else {
            FileHandle.standardError.write(Data("skipping \(url.lastPathComponent): no \(script.lastPathComponent)\n".utf8))
            continue
        }
        let samples = try loadSamples(url)
        fixtures.append(Fixture(name: url.deletingPathExtension().lastPathComponent, samples: samples, reference: reference))
    }
    return fixtures.sorted { $0.duration < $1.duration }
}

func runBench(dir: String, runs: Int, pause: Double) async throws {
    guard runs >= 2 else {
        FileHandle.standardError.write(Data("--runs must be at least 2 (the first run is discarded)\n".utf8))
        exit(2)
    }
    guard pause >= 0 else {
        FileHandle.standardError.write(Data("--pause must not be negative\n".utf8))
        exit(2)
    }
    let fixtures = try loadFixtures(in: URL(fileURLWithPath: dir))
    guard !fixtures.isEmpty else {
        FileHandle.standardError.write(Data("no fixtures in \(dir); run scripts/make-fixtures.sh first\n".utf8))
        exit(1)
    }

    let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let engine = selectedSpeechEngine()
    print("Pladder benchmark")
    print("machine: \(chip), macOS \(os)")
    print("model:   \(engine.id) (\(engine.displayName))")
    print("runs:    \(runs) per fixture, first discarded, median reported")
    print(String(format: "pause:   %.0f s idle before every run, as between real dictations", pause))
    print(String(format: "load:    %.2f (one-minute average at start)", loadAverage()))
    print("")

    let loadTime = try await loadEngine(engine)
    print(String(format: "model load (cold): %.2f s", seconds(loadTime)))
    if let bytes = physicalFootprintBytes() {
        print(String(format: "memory after load: %.0f MB (physical footprint)", Double(bytes) / 1_048_576))
    }
    print("")

    struct Row { var name: String; var duration: Double; var engine: Double; var spread: Double; var wer: Double }
    var rows: [Row] = []
    let clock = ContinuousClock()
    var throttled = false
    for fixture in fixtures {
        var times: [Double] = []
        var errors: [Double] = []
        for run in 1...runs {
            // Every run starts from idle, like a dictation does. Back-to-back
            // runs would hand each other warm clocks and residual heat.
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            let started = clock.now
            let transcript = try await engine.transcribe(fixture.samples)
            let elapsed = seconds(clock.now - started)
            let wer = WordErrorRate.compute(reference: fixture.reference, hypothesis: transcript.text)
            let thermal = thermalTag()
            throttled = throttled || !thermal.isEmpty
            let note = (run == 1 ? " (warm-up, discarded)" : "") + thermal
            print(String(format: "%@ run %d: %.3f s, WER %.1f%%%@", fixture.name, run, elapsed, wer * 100, note))
            if run > 1 {
                times.append(elapsed)
                errors.append(wer)
            }
        }
        let engineTime = median(times)
        // Spread of the kept runs relative to the median: the noise floor
        // for this fixture, so a difference smaller than it means nothing.
        let spread = (times.max()! - times.min()!) / engineTime
        rows.append(Row(name: fixture.name, duration: fixture.duration, engine: engineTime, spread: spread, wer: median(errors)))
    }

    print("")
    print("| Fixture | Audio | Engine (median) | Spread | Realtime | WER |")
    print("|---|---:|---:|---:|---:|---:|")
    for row in rows {
        print(String(
            format: "| %@ | %.1f s | %.3f s | %.0f %% | %.0fx | %.1f %% |",
            row.name, row.duration, row.engine, row.spread * 100, row.duration / row.engine, row.wer * 100))
    }
    print("")
    print(String(format: "load:    %.2f (one-minute average at end)", loadAverage()))
    if throttled {
        print("warning: the chip left its normal thermal state during the run; numbers are not comparable")
    }
}

/// What the live passes of one paced run cost. Lock-protected because the
/// live task records into it while the run's own task paces the audio.
final class LivePassLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _times: [Double] = []
    var times: [Double] { lock.withLock { _times } }
    func record(_ elapsed: Double) { lock.withLock { _times.append(elapsed) } }
}

/// Paced bench variant: pushes each fixture in one-second chunks paced at real
/// time, like a live recording, then times `endUtterance` alone. Pacing takes
/// as long as the audio, so keep the fixture set small.
///
/// Every fixture also goes through the same engine once, whole, and the two
/// raw engine texts are compared before any processor runs. For the
/// incremental engine that line is the identity gate; for the sliding-window
/// engine it is a record of how far its seams drift.
///
/// With `live`, the Live Transcript style is modelled too: a second task asks
/// the engine for the text so far every 0.5 s while the fixture is paced and
/// is cancelled just before the release, exactly as the coordinator's feed
/// loop is. That answers the two questions the style raises — what a live pass
/// costs, and whether a release that lands next to one is slower — and the
/// identity gate becomes a gate on the live passes as well, since a pass that
/// disturbed the session's windows would change the text.
func runPacedBench(dir: String, runs: Int, pause: Double, includeShort: Bool, live: Bool) async throws {
    guard runs >= 2 else {
        FileHandle.standardError.write(Data("--runs must be at least 2 (the first run is discarded)\n".utf8))
        exit(2)
    }
    guard pause >= 0 else {
        FileHandle.standardError.write(Data("--pause must not be negative\n".utf8))
        exit(2)
    }
    var fixtures = try loadFixtures(in: URL(fileURLWithPath: dir))
    // Below ~13 s both paths run one padded window, so there is nothing paced
    // about the result; --all keeps them anyway.
    if !includeShort { fixtures = fixtures.filter { $0.duration >= 13 } }
    guard !fixtures.isEmpty else {
        FileHandle.standardError.write(Data("no paced fixtures in \(dir)\n".utf8))
        exit(1)
    }

    let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    // One engine, two ways in. The paced path feeds it while the audio
    // arrives; `transcribe` hands it the whole buffer, which is the call a
    // recording transcribed at release makes. Comparing the two is the gate.
    let engine = selectedSpeechEngine()
    print("Pladder benchmark (paced)")
    print("machine: \(chip), macOS \(os)")
    print("model:   \(engine.id) (\(engine.displayName))")
    print("runs:    \(runs) per fixture, first discarded, median of `endUtterance` reported")
    print(String(format: "pause:   %.0f s idle before every run", pause))
    print("compare: the same engine, whole buffer, once per fixture, raw text")
    if live {
        print("live:    a live pass every 0.5 s while the fixture is paced, as the Live Transcript overlay makes")
    }
    print("")

    let loadTime = try await loadEngine(engine)
    print(String(format: "model load (cold): %.2f s", seconds(loadTime)))
    print("")

    struct Row {
        var name: String
        var duration: Double
        var engine: Double
        var spread: Double
        var wer: Double
        var identical: Bool
        var livePasses: Int
        var livePass: Double
    }
    var rows: [Row] = []
    let clock = ContinuousClock()
    var throttled = false
    for fixture in fixtures {
        var times: [Double] = []
        var errors: [Double] = []
        var livePassTimes: [Double] = []
        var livePassCounts: [Int] = []
        var lastText = ""
        for run in 1...runs {
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            try await engine.beginUtterance()
            // The overlay's loop: a pass over the audio so far, every half
            // second, for as long as the "key" is held.
            let passes = LivePassLog()
            let liveTask: Task<Void, Never>? = live ? Task {
                while !Task.isCancelled {
                    let started = clock.now
                    _ = await engine.livePass()
                    passes.record(seconds(clock.now - started))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            } : nil
            // One-second chunks paced at real time, as the coordinator's
            // feed task would deliver them.
            var offset = 0
            let oneSecond = Int(CapturedAudio.sampleRate)
            while offset + oneSecond < fixture.samples.count {
                await engine.feed(Array(fixture.samples[offset..<offset + oneSecond]))
                try await Task.sleep(for: .seconds(1))
                offset += oneSecond
            }
            let tail = Array(fixture.samples[offset...])
            // Cancelled and not awaited, exactly as the release does it: a
            // pass already inside CoreML cannot be aborted, so the timed call
            // below waits for it, and that wait is part of what the style
            // costs.
            liveTask?.cancel()
            let started = clock.now
            let transcript = try await engine.endUtterance(tail)
            let elapsed = seconds(clock.now - started)
            var final = transcript
            final.audioDuration = fixture.duration
            lastText = final.text
            let wer = WordErrorRate.compute(reference: fixture.reference, hypothesis: final.text)
            let thermal = thermalTag()
            throttled = throttled || !thermal.isEmpty
            let note = (run == 1 ? " (warm-up, discarded)" : "") + thermal
            let runPasses = passes.times
            let liveNote = live
                ? String(format: ", %d live passes (median %.3f s)", runPasses.count, median(runPasses))
                : ""
            print(String(format: "%@ run %d: %.3f s, WER %.1f%%%@%@", fixture.name, run, elapsed, wer * 100, liveNote, note))
            if run > 1 {
                times.append(elapsed)
                errors.append(wer)
                livePassTimes.append(contentsOf: runPasses)
                livePassCounts.append(runPasses.count)
            }
        }

        // The identity gate: the same samples through the same engine, whole.
        // Anything but `identical: yes` is a bug in the incremental path, not
        // a tuning matter.
        //
        // Timed like the paced runs above and after the same idle pause, so
        // the two columns are comparable: a call made straight after a paced
        // run would find the Neural Engine warm when every release the bench
        // models is cold.
        if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
        let batchStarted = clock.now
        let batchTranscript = try await engine.transcribe(fixture.samples)
        let batchElapsed = seconds(clock.now - batchStarted)
        let batchWer = WordErrorRate.compute(reference: fixture.reference, hypothesis: batchTranscript.text)
        print(String(format: "%@ whole: %.3f s, WER %.1f%%", fixture.name, batchElapsed, batchWer * 100))
        let difference = firstWordDifference(batch: batchTranscript.text, paced: lastText)
        if let difference {
            print("\(fixture.name) identical: no, first differing word \(difference.index): whole \"\(difference.batch)\" vs paced \"\(difference.paced)\"")
        } else {
            print("\(fixture.name) identical: yes")
        }

        let engineTime = median(times)
        let spread = (times.max()! - times.min()!) / engineTime
        rows.append(Row(
            name: fixture.name, duration: fixture.duration, engine: engineTime,
            spread: spread, wer: median(errors), identical: difference == nil,
            livePasses: Int(median(livePassCounts.map(Double.init)).rounded()),
            livePass: median(livePassTimes)))
    }

    print("")
    let liveHeader = live ? " Live passes | Live pass (median) |" : ""
    print("| Fixture | Audio | endUtterance (median) | Spread | Realtime | WER | Identical whole-buffer |\(liveHeader)")
    print("|---|---:|---:|---:|---:|---:|---|\(live ? "---:|---:|" : "")")
    for row in rows {
        let liveCells = live ? String(format: " %d | %.3f s |", row.livePasses, row.livePass) : ""
        print(String(
            format: "| %@ | %.1f s | %.3f s | %.0f %% | %.0fx | %.1f %% | %@ |%@",
            row.name, row.duration, row.engine, row.spread * 100, row.duration / row.engine,
            row.wer * 100, row.identical ? "yes" : "no", liveCells))
    }
    print("")
    print(String(format: "load:    %.2f (one-minute average at end)", loadAverage()))
    if throttled {
        print("warning: the chip left its normal thermal state during the run; numbers are not comparable")
    }
}

// MARK: - Polish

/// Runs `TranscriptPolisher` over one transcript twice and prints what the
/// polish toggle would paste. The first run is cold (no `prepare()`), the second
/// warm, which is what a real press gets: the session is made and prewarmed
/// at key-down, seconds before the release.
func runPolish(_ path: String, model: PolishModel, options: PolishOptions) async throws {
    let text: String
    if path == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }
    let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if model == .appleIntelligence {
        print("availability: \(TranscriptPolisher.availability)")
    }
    print("input (\(transcript.split(whereSeparator: \.isWhitespace).count) words):")
    print(transcript)

    func show(_ label: String, _ report: TranscriptPolisher.Report) {
        print("")
        let timing = String(format: "%.3f", seconds(report.elapsed))
        if let polished = report.text {
            print("\(label): \(timing) s, \(report.wordsIn) words in, \(report.wordsOut) out, \(report.mode.rawValue)")
            print(polished)
        } else {
            let reason = report.failure ?? "unknown"
            print("\(label): \(timing) s, no polish (\(reason)); the text would be pasted as dictated")
        }
    }

    let polisher = try await makePolisher(model, options: options)
    show("cold", await polisher.polish(transcript))
    await polisher.prepare()
    try await Task.sleep(for: .seconds(2))
    show("warm", await polisher.polish(transcript))
}

/// Either polisher behind one face, for the CLI: both report the same way.
struct CLIPolisher {
    let polish: @Sendable (String) async -> TranscriptPolisher.Report
    let prepare: @Sendable () async -> Void
}

/// What the command line changes about a polisher; nil is the app's own.
struct PolishOptions {
    var instructionsPath: String?
    var gguf: String?
    var control: String?
}

/// The polisher the app would use for `model`, downloading an S1-mini file
/// into the app's own model directory first if it is not there yet. With
/// `--gguf`, an S1-mini polisher over that file instead.
func makePolisher(_ model: PolishModel, options: PolishOptions = PolishOptions()) async throws -> CLIPolisher {
    let instructionsPath = options.instructionsPath
    if let gguf = options.gguf {
        if instructionsPath != nil { usage() }
        let url = URL(fileURLWithPath: gguf)
        let file = ModelFile(fileName: url.lastPathComponent, url: url, sha256: "", byteCount: 0)
        let polisher = S1MiniPolisher(file: file, location: url, control: options.control ?? S1MiniPolisher.controlLine)
        print("model: \(gguf)")
        if let control = options.control { print("control: \(control)") }
        return CLIPolisher(polish: { await polisher.polish($0) }, prepare: { await polisher.prepare() })
    }
    guard let file = ModelFile(for: model) else {
        if options.control != nil { usage() }
        let polisher: TranscriptPolisher
        if let instructionsPath {
            let instructions = try String(contentsOf: URL(fileURLWithPath: instructionsPath), encoding: .utf8)
            polisher = TranscriptPolisher(instructions: instructions)
            print("instructions: \(instructionsPath)")
        } else {
            polisher = TranscriptPolisher()
        }
        return CLIPolisher(polish: { await polisher.polish($0) }, prepare: { await polisher.prepare() })
    }
    if instructionsPath != nil { usage() }
    let files = ModelFiles(directory: ModelFiles.defaultDirectory) { _, status in
        if case .downloading(let fraction) = status {
            FileHandle.standardError.write(Data(String(format: "\rdownloading %3.0f%%", fraction * 100).utf8))
        } else if status == .verifying {
            FileHandle.standardError.write(Data("\rverifying          \n".utf8))
        }
    }
    await files.ensure(file)
    let status = await files.finished(file)
    guard status == .ready else {
        FileHandle.standardError.write(Data("\(file.fileName): \(status)\n".utf8))
        exit(1)
    }
    let polisher = S1MiniPolisher(
        file: file, location: files.location(of: file), control: options.control ?? S1MiniPolisher.controlLine)
    print("model: \(file.fileName)")
    if let control = options.control { print("control: \(control)") }
    return CLIPolisher(polish: { await polisher.polish($0) }, prepare: { await polisher.prepare() })
}

/// One case of a polish test set: what the speech model heard and what
/// should be pasted.
struct PolishCase: Decodable {
    let id: String
    let lang: String
    let input: String
    let expected: String
}

/// Runs `model` over a test set the way the app would: the app's processors
/// first, then the polish, warm. Prints every answer, then per-language word
/// error rates against the expected text (case and punctuation ignored),
/// exact matches (everything counts) and the polish time.
func runPolishSet(_ path: String, model: PolishModel, options: PolishOptions) async throws {
    let cases = try JSONDecoder().decode([PolishCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let hint: @Sendable (String) -> String? = { TranscriptLanguage.hint(for: $0) }
    let pipeline = ProcessorPipeline([
        FillerRemover(languageHint: hint), WhitespaceNormalizer(), SpokenPunctuation(languageHint: hint),
    ])
    let polisher = try await makePolisher(model, options: options)
    await polisher.prepare()
    // The first call pays for whatever prepare() could not warm.
    _ = await polisher.polish("Warm up.")

    var rates: [String: [Double]] = [:]
    var exact = 0
    var times: [Double] = []
    for item in cases {
        let processed = await pipeline.run(item.input)
        let report = await polisher.polish(processed)
        let output = report.text ?? processed
        times.append(seconds(report.elapsed))
        rates[item.lang, default: []].append(WordErrorRate.compute(reference: item.expected, hypothesis: output))
        let matched = output.trimmingCharacters(in: .whitespacesAndNewlines) == item.expected
        if matched { exact += 1 }
        let failure = report.failure.map { " (\($0))" } ?? ""
        print(String(format: "%@ %-26@ %5.2f s%@", matched ? "=" : " ", item.id, seconds(report.elapsed), failure))
        print("    \(output.replacingOccurrences(of: "\n", with: "⏎"))")
    }
    print("")
    let all = rates.values.flatMap { $0 }
    let mean = { (values: [Double]) in values.reduce(0, +) / Double(max(values.count, 1)) }
    let perLanguage = rates.keys.sorted().map { String(format: "%@ %.3f", $0, mean(rates[$0]!)) }.joined(separator: "  ")
    times.sort()
    print(String(format: "WER %.3f (%@), exact %d of %d, polish median %.2f s, p90 %.2f s",
                 mean(all), perLanguage, exact, cases.count, times[times.count / 2], times[Int(Double(times.count) * 0.9)]))
}

func polishModel(named name: String) -> PolishModel? {
    switch name {
    case "apple": .appleIntelligence
    case "s1-mini": .s1Mini
    case "s1-mini-8bit": .s1Mini8Bit
    default: nil
    }
}

// MARK: - Entry

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil, "-h", "--help":
    usage()
case "bench":
    arguments.removeFirst()
    var runs = 6
    var pause = 10.0
    var paced = false
    var includeShort = false
    var live = false
    var dir: String?
    while let arg = arguments.first {
        arguments.removeFirst()
        if arg == "--runs" {
            guard let value = arguments.first, let n = Int(value) else { usage() }
            arguments.removeFirst()
            runs = n
        } else if arg == "--pause" {
            guard let value = arguments.first, let s = Double(value) else { usage() }
            arguments.removeFirst()
            pause = s
        } else if arg == "--paced" {
            paced = true
        } else if arg == "--all" {
            includeShort = true
        } else if arg == "--live" {
            live = true
        } else if dir == nil {
            dir = arg
        } else {
            usage()
        }
    }
    guard let dir else { usage() }
    if paced {
        try await runPacedBench(dir: dir, runs: runs, pause: pause, includeShort: includeShort, live: live)
    } else {
        // Both flags only mean something while audio is being paced in.
        if includeShort || live { usage() }
        try await runBench(dir: dir, runs: runs, pause: pause)
    }
case "polish", "polish-set":
    let command = arguments.removeFirst()
    var options = PolishOptions()
    var model = PolishModel.appleIntelligence
    var textPath: String?
    while let arg = arguments.first {
        arguments.removeFirst()
        if arg == "--instructions", command == "polish" {
            guard let value = arguments.first else { usage() }
            arguments.removeFirst()
            options.instructionsPath = value
        } else if arg == "--gguf" || arg == "--control" {
            guard let value = arguments.first else { usage() }
            arguments.removeFirst()
            if arg == "--gguf" { options.gguf = value } else { options.control = value }
        } else if arg == "--model" {
            guard let value = arguments.first, let chosen = polishModel(named: value) else { usage() }
            arguments.removeFirst()
            model = chosen
        } else if textPath == nil {
            textPath = arg
        } else {
            usage()
        }
    }
    guard let textPath else { usage() }
    if command == "polish" {
        try await runPolish(textPath, model: model, options: options)
    } else {
        try await runPolishSet(textPath, model: model, options: options)
    }
default:
    var process = false
    var verbose = false
    var path: String?
    for arg in arguments {
        if arg == "--process" {
            process = true
        } else if arg == "--verbose" {
            verbose = true
        } else if path == nil {
            path = arg
        } else {
            usage()
        }
    }
    guard let path else { usage() }
    await transcribeFile(path, process: process, verbose: verbose)
}
