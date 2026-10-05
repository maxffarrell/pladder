# Model conversion

Use Python 3.13 on macOS 27, with the pinned `requirements.txt` (`uv pip install --prerelease allow -r ...`). PyTorch 2.14.1 emits a warning that coreai-torch officially validates through 2.13; these particular exports were qualified separately by graph parity and the Swift runtime tests. The tested environment is recorded rather than silently changing it.

```sh
python export_models.py --model redux --revision SOURCE_COMMIT --output exports --sources sources
python verify_models.py --bundle exports/parakeet-redux_float16_streaming150 --sources sources/redux --report redux-parity.json
```

Run with immutable source revisions from the published model's `provenance.json`. `apple_parakeet_export.py` is Apple's unmodified BSD-3-Clause recipe at commit `52c84ba874b2c57adcede08a671ce96ed1b3f433`; `APPLE_LICENSE` preserves its license. The wrapper replaces model loading with strict source weight and tokenizer checks, exact Redux ternary unpacking, and attribution. Source tensors are expanded to FP16; no packed ternary compute is retained.

The parity harness exercises the encoder with a partial attention mask, decoder with nonzero recurrent state, and joint outputs on the OS Core AI runtime with GPU preference. It requires finite output, matching shapes, cosine above 0.995 and relative RMSE below 0.05. Use `PLADDER_COREAI_TEST_WAV=/absolute/path/30s.wav PLADDER_COREAI_BUNDLE_ROOT=/absolute/path/exports swift test -c release` for actual model tests across all three selections, irregular feed sizes, stable display reads, cancellation and restarting. Normal tests skip that opt-in integration test.

Model ZIPs contain one named bundle directory. App archives must be SHA-256/size verified, installed from immutable HF commits, and recorded in `CoreAIParakeetModel.swift`. Redux, Ultra and v3 model cards must credit Moondream/NVIDIA appropriately, state CC-BY-4.0 and describe precision/format/VAD changes. Preserve Apple's recipe license in the archive too. Do not advertise Core AI as faster or exclusively ANE without device measurements.
