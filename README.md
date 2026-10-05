# Pladder — Core AI fork

Simple local dictation for Apple Silicon Macs, forked from [dinooo13/pladder](https://github.com/dinooo13/pladder). Hold the hotkey to speak and release to paste into the focused app. A toggle hotkey is also available.

This fork requires **macOS 27 and Xcode 27**. Speech recognition uses Apple's [CoreAISpeech](https://github.com/apple/coreai-models) and Core AI framework. FluidAudio has been removed from the app and its dependencies.

Choose **Parakeet v3**, **Parakeet Ultra**, or **Parakeet Redux** in Settings → Engine. Each model downloads once from a pinned Hugging Face revision, with archive size and SHA-256 verification, then runs locally. Switching unloads the previous engine. Audio and transcripts stay on the Mac.

The default dictation HUD uses native SwiftUI Liquid Glass. Words agree across advancing streaming updates before appearing, with the unfinished trailing word withheld. Revealed words fade in and never change; the HUD shows the recent three lines. This is a stability heuristic, not calibrated recognition confidence. The final paste uses the full completed transcript, independently of the display gate. Reduce Motion disables word entrance effects.

## Build

```sh
git clone --branch codex/coreai-dictation https://github.com/maxffarrell/pladder.git
cd pladder
./script/build_and_run.sh
```

The script builds and opens `dist/Pladder.app`. This path links to a signed local build outside synchronized Documents folders, avoiding File Provider metadata that breaks signing. Grant Microphone and Accessibility permissions when prompted. This fork has its own bundle identifier, `com.maxffarrell.pladder`. Your existing dictionary and hotkeys are retained; an unavailable old engine falls back to v3 and the new Live HUD.

For development, use `PLADDER_SETTINGS_PATH=/absolute/path/test-settings.json` to isolate settings. The Codex Run action invokes the same script.

## Models and limitations

All three releases use FP16 weights and Apple's buffered streaming recipe: 12-second encoder windows, 0.96-second hops, and 2 seconds of future context. First words therefore take at least 2.96 seconds of audio plus inference and display stabilization. Core AI chooses available compute devices; this fork does not promise exclusive Neural Engine execution or better efficiency than FluidAudio. See [the conversion and validation report](docs/COREAI.md).

Redux's ternary weights are expanded before FP16 export. Its original 178 MB packed size and Photon's specialized kernel performance **do not apply** to this conversion. Each installed model is about 1.2 GB. Ultra and Redux's auxiliary Photon VAD heads are not used; the app captures audio through pauses and uses CoreAISpeech endpointing.

The existing optional Apple Foundation Models polish remains available. HUD actions for Concise, Professional and Bulleted cleanup are the next phase, after the speech backend and HUD are qualified and committed.

## Validation

```sh
swift test -c release
./scripts/make-fixtures.sh
PLADDER_COREAI_BUNDLE_ROOT=/absolute/path/exports .build/release/pladder-cli bench bench/fixtures --runs 3 --pause 1
```

`PLADDER_SPEECH_MODEL=v3|ultra|redux` selects the CLI model. `--paced --all --live` checks that displaying partial words leaves the final transcript identical to unpaced ingestion. Model exports and graph parity tools are in `tools/coreai/`.

## Attribution

Pladder is MIT licensed, by its upstream contributors. Parakeet TDT v3 is by NVIDIA; Ultra and Redux are post-trained by Moondream. Model weights remain **CC-BY-4.0**, with pinned source revisions and conversion notices in each bundle. Apple's export recipe is **BSD-3-Clause**; its license is retained in `tools/coreai/APPLE_LICENSE`. Conversion changes precision, graph format and streaming shape; it does not train the models or imply endorsement.
