# Core AI conversion and validation

This fork replaces FluidAudio speech recognition with Apple's CoreAISpeech
runtime at commit `52c84ba874b2c57adcede08a671ce96ed1b3f433`. It requires
macOS 27 and Xcode 27 on Apple Silicon. Existing cleanup engines were not
changed in this first phase.

## Published artifacts

The app pins immutable commits, exact archive sizes and SHA-256 digests in
`Sources/PladderEngines/CoreAIParakeetModel.swift`. Public releases:

- [v3](https://huggingface.co/maxffarrell/parakeet-v3-coreai)
- [Ultra](https://huggingface.co/maxffarrell/parakeet-ultra-coreai)
- [Redux](https://huggingface.co/maxffarrell/parakeet-redux-coreai)

Source revisions and CC-BY-4.0 attribution are in each bundle's
`provenance.json` and `NOTICE.md`. NVIDIA developed v3; Moondream post-trained
Ultra and Redux. Apple's unmodified BSD-3-Clause recipe and license are in
`tools/coreai/`; dependency notices also ship with the app.

An existing Ultra conversion was available at
[coder543/parakeet-ultra-coreai](https://huggingface.co/coder543/parakeet-ultra-coreai),
but its split encoder and ANE batch decoder use a different contract from
Apple's CoreAISpeech. These releases share Apple's three-graph interface so
the app can switch models without maintaining separate decoder implementations.
No compatible Redux CoreAISpeech bundle was found, so Redux was converted.

Redux's packed base-3 weights are expanded exactly, then exported at FP16.
Its archive compresses to about 345 MB, versus about 1.17 GB for v3/Ultra;
**all three occupy about 1.2 GB installed**. The original 178 MB packed model
and Photon kernel performance are not retained. Auxiliary Photon VAD heads
are omitted. NVIDIA's pinned v3 tokenizer vocabulary matches the sources.

## Streaming and display

The graph has a static 1201-mel-frame window (12 seconds): left/chunk/right
encoder frames 113/12/25. Hops consume 0.96 seconds, with 2 seconds of future
context. Minimum audio delay is 2.96 seconds plus inference and stabilization.
The extra future context reduced v3 word error on the ten-minute synthetic
fixture from 4.7% (12 right-context frames) to 1.5% (25). This is buffered
inference over an offline model, not a causal encoder with cached attention.

Microphone pushes are reframed at fixed 1280-sample boundaries. Without that,
additional future audio available in a larger capture buffer changed sentence
punctuation. An operation gate prevents release or cancellation from finishing
a stream while its append call is still running. The app collects every
endpoint segment: Apple's `finishStream()` returns only the last segment,
which may be empty after the last pause.

The HUD commits the common word prefix of advancing observations, withholding
the trailing word. Committed words never change. This is stability agreement,
**not calibrated confidence or a promise of correctness**. The final paste is
the full engine result, independently of display commitment. Stable word IDs
survive tail cropping; newly inserted words fade in over 450 ms with short
staggering, disabled for Reduce Motion. The native glass panel remains
nonactivating and click-through in this phase.

## What was tested

On this Mac: Apple M4 Max, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).

- **407 Swift tests passed**, including actual runtime integration with all
  three models, the same 30-second fixture under regular/irregular feeds,
  live display reads, cancellation and restarting. Normal tests skip model
  integration unless `PLADDER_COREAI_TEST_WAV` is supplied.
- **All three graph parity checks passed** against pinned PyTorch sources:
  masked encoder input, nonzero recurrent state, joint logits; matching
  shapes and finite outputs, cosine > 0.995, relative RMSE < 0.05. Worst
  encoder relative RMSE: v3 0.00893, Ultra 0.04310, Redux 0.00115. Decoder
  output cosine exceeds 0.999999. This validates conversion, not broad
  multilingual accuracy.
- **Paced v3 with live display:** 10- and 30-second final transcripts exactly
  match unpaced ingestion; WER 0% on both. End-of-recording inference was
  94–96 ms in the measured run; display reads rounded to 0 ms. This excludes
  microphone stop, processors, paste and UI dismissal.
- **Long audio:** v3 returns the complete 623.1-second fixture, WER 1.5%,
  processing 21.85 s at unpaced ingestion (29× realtime). Ultra's 124.9-second
  fixture has 0.2% WER; Redux's has 0.9%. Synthetic English fixtures use macOS
  Samantha at 175 words/minute; they do not represent natural or multilingual
  speech.
- Public HF archive sizes and LFS SHA-256 hashes match all app pins. Fresh
  downloads exercise the app's HTTP download, size/hash verification,
  extraction, local loading and transcription path.
- Native light/dark HUD screenshots were inspected during development. Fresh
  captures of the final build failed under macOS screen-capture permissions;
  the native UI inspection tool also timed out. The word entrance animation
  still needs a fresh visual check. Screenshot mode now reports failure
  instead of claiming it wrote images. The real coordinator's six demo paths completed: plain, delayed, slow,
  clipboard fallback, polish, and short polish bypass. These use stand-ins
  for the microphone, hotkey, insertion and refiner.
- The app builds and passes strict/deep code signature verification. Signed
  bundles are assembled outside synchronized Documents folders, which can
  attach FinderInfo and invalidate signatures; `dist/Pladder.app` links to
  that local build. The downloadable ZIP preserves the signed bundle.

A real microphone-to-paste session with the user's permissions has not been
performed. The packaged build is locally ad-hoc signed, not notarized.

## Performance interpretation

The previous upstream FluidAudio baseline on this same Mac processed the
623.1-second fixture in 1.46 s with 0.6% WER and had a 105 MB measured physical
footprint after load. This buffered Core AI v3 path used about 369 MB and
21.85 s with 1.5% WER. The old live-display paced release inference was
128–139 ms on 10-/30-second fixtures; the new path measured 94–96 ms, with
no extra inference for display reads.

These runs used short pauses and had varying host load; they are diagnostic
measurements, not controlled speed or energy comparisons. The architectures
also perform different work. **This fork does not establish a Core AI
throughput, memory or power advantage.** No power measurements or exclusive
Neural Engine placement have been proven. Core AI chooses available devices.
Older `BENCHMARKS.md` and `PERFORMANCE.md` results describe upstream FluidAudio;
use this report for this fork.

## Reproduce

See `tools/coreai/README.md` and dependency pins. For runtime qualification:

```sh
./scripts/make-fixtures.sh
PLADDER_COREAI_TEST_WAV="$PWD/bench/fixtures/30s.wav" \
PLADDER_COREAI_BUNDLE_ROOT=/absolute/path/exports swift test -c release
PLADDER_COREAI_BUNDLE_ROOT=/absolute/path/exports \
.build/release/pladder-cli bench bench/fixtures --runs 3 --pause 1
```

For download-path checks, omit the bundle override and use
`PLADDER_COREAI_CACHE_ROOT=/absolute/path/test-cache` to isolate the cache.
Use `PLADDER_SETTINGS_PATH` to isolate configuration. `PLADDER_SPEECH_MODEL`
selects `v3`, `ultra` or `redux` for the CLI.
