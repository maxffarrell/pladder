"""Apple-compatible Core AI exports, with pinned source weights and attribution.

Uses Apple's BSD-3-Clause Parakeet recipe at 52c84ba874b2c57adcede08a671ce96ed1b3f433.
Redux's base-3 packing is expanded exactly before FP16 conversion. This export
does NOT retain Photon's 178 MB packed representation or its specialized kernels.
"""
import argparse
import json
from pathlib import Path
import hashlib
import shutil

import numpy as np
import torch
import transformers
from huggingface_hub import snapshot_download, model_info
from safetensors.torch import load_file
import apple_parakeet_export as apple


def load_source(repo, revision, directory):
    source = Path(snapshot_download(repo, revision=revision, local_dir=directory))
    config = transformers.AutoConfig.from_pretrained(source)
    model = transformers.AutoModelForTDT.from_config(config)
    weights = load_file(source / "model.safetensors")
    ternary = source / "ternary.json"
    if ternary.exists():
        spec = json.loads(ternary.read_text())
        assert spec["format"] == "thrush-ternary-v2"
        for module in spec["quantized_modules"]:
            name, cols = module["name"], module["in_features"]
            packed = weights.pop(name + ".qweight").to(torch.int64)
            scales = weights.pop(name + ".scales").float()
            # Least-significant base-3 digit first, five elements per byte.
            digits = torch.stack([(packed // (3 ** i)) % 3 for i in range(5)], -1)
            codes = digits.flatten(1)[:, :cols]
            dense = (codes.float() - 1) * scales.repeat_interleave(module["group_size"], 1)[:, :cols]
            if module["as_conv1d"]:
                dense = dense.unsqueeze(-1)
            weights[name + ".weight"] = dense
    # The optional Photon VAD head is separate from the ASR architecture.
    omitted = [key for key in weights if key.startswith("vad_head.")]
    for key in omitted:
        del weights[key]
    model.load_state_dict(weights, strict=True)
    model.eval()
    processor = transformers.AutoProcessor.from_pretrained("nvidia/parakeet-tdt-0.6b-v3", revision="541d1f99c6b0c3cd0b11a95167540bb8edefd82b")
    if (source / "tokenizer.json").exists():
        reference = json.loads(processor.tokenizer.backend_tokenizer.to_str())["model"]["vocab"]
        actual = json.loads((source / "tokenizer.json").read_text())["model"]["vocab"]
        assert reference == actual, "Source tokenizer differs from NVIDIA v3"
    return model, processor, omitted


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["v3", "ultra", "redux"], required=True)
    parser.add_argument("--revision", help="Immutable source revision; defaults to resolving the current source once")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    args = parser.parse_args()
    repo = {"v3": "nvidia/parakeet-tdt-0.6b-v3", "ultra": "moondream/parakeet-ultra", "redux": "moondream/parakeet-redux"}[args.model]
    revision = args.revision or model_info(repo).sha
    model, processor, omitted = load_source(repo, revision, args.sources / args.model)
    # Bind the official exporter to the exact model and processor we validated.
    transformers.AutoModelForTDT.from_pretrained = lambda *a, **kw: model.to(dtype=kw.get("dtype", torch.float16))
    transformers.AutoProcessor.from_pretrained = lambda *a, **kw: processor
    def metadata(graph):
        value = apple.AIModelAssetMetadata()
        value.author = "NVIDIA" if args.model == "v3" else "Moondream; based on NVIDIA Parakeet TDT v3"
        value.license = "CC-BY-4.0"
        value.model_description = f"{repo}@{revision}, {graph}; converted with Apple's Core AI Parakeet recipe by maxffarrell. No training. Redux ternary weights expanded before FP16 export."
        return value
    apple._build_aimodel_metadata = metadata
    apple.create_parakeet(str(args.output), repo, torch.float16, False, False, 5.0, False, apple.StreamingWindowArgs(chunk_frames=12, right_context_frames=25, left_context_frames=113))
    bundle, _ = apple._bundle_paths(str(args.output), repo, torch.float16, False, {"usable_encoder_frames": 150})
    provenance = {"source": repo, "revision": revision, "license": "CC-BY-4.0", "apple_recipe_revision": "52c84ba874b2c57adcede08a671ce96ed1b3f433", "precision": "float16", "omitted_auxiliary_tensors": omitted, "redux_packing_preserved": False, "streaming": True, "streaming_geometry": json.loads((bundle / "metadata.json").read_text())["streaming"]}
    (bundle / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (bundle / "NOTICE.md").write_text(f"# Attribution\n\nSource: [{repo}](https://huggingface.co/{repo}/tree/{revision}).\n\nParakeet TDT v3 is by NVIDIA. Ultra and Redux are post-trained by Moondream.\nWeights remain CC-BY-4.0: https://creativecommons.org/licenses/by/4.0/\n\nConversion by maxffarrell using Apple's BSD-3-Clause exporter. No training or endorsement. The optional Photon VAD head is not exported. Redux ternary weights are expanded then stored at FP16; the original packed size and Photon performance do not apply.\n")
    shutil.copyfile(Path(__file__).with_name("APPLE_LICENSE"), bundle / "APPLE_LICENSE")
    files = sorted(p for p in bundle.rglob("*") if p.is_file())
    (bundle / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(bundle)}\n" for p in files))
    print("BUNDLE", bundle, flush=True)


if __name__ == "__main__":
    torch.set_num_threads(4)
    main()
