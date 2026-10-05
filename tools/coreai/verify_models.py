"""Compare each exported graph against its pinned source on macOS Core AI.

Exercises encoder masks, recurrent decoder state, and joint logits. This is
conversion parity, not an accuracy benchmark or a confidence calibration.
"""
import argparse
import asyncio
import json
from pathlib import Path
import numpy as np
import torch
from coreai.runtime import AIModel, NDArray, SpecializationOptions, ComputeUnitKind
from export_models import load_source
import apple_parakeet_export as apple

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    provenance = json.loads((args.bundle / 'provenance.json').read_text())
    model, processor, _ = load_source(provenance['source'], provenance['revision'], args.sources)
    model = model.to(torch.float16)
    torch.manual_seed(42)
    metadata = json.loads((args.bundle / 'metadata.json').read_text())
    config = model.config
    geometry = metadata['streaming']
    encoder = {'input_features': torch.randn(1, geometry['window_mel_frames'], 128, dtype=torch.float16),
               'attention_mask': torch.ones(1, geometry['window_mel_frames'], dtype=torch.bool)}
    encoder['attention_mask'][:, -201:] = False
    decoder = apple._decoder_step_inputs(config, torch.float16)
    decoder['input_ids'].fill_(42)
    decoder['hidden_state'] = torch.randn_like(decoder['hidden_state']) * 0.1
    decoder['cell_state'] = torch.randn_like(decoder['cell_state']) * 0.1
    joint = apple._joint_inputs(config, torch.float16)
    cases = [('encoder', apple.ParakeetEncoderModule(model), encoder, ['encoder_hidden_states']),
             ('decoder_step', apple.ParakeetDecoderStepModule(model), decoder, ['decoder_output', 'new_hidden_state', 'new_cell_state']),
             ('joint', apple.ParakeetJointModule(model), joint, ['logits'])]
    rows = []
    for name, module, inputs, names in cases:
        with torch.no_grad(), torch.autocast(device_type='cpu', dtype=torch.float16):
            ref = module(**inputs)
        ref = ref if isinstance(ref, tuple) else (ref,)
        asset = await AIModel.load(args.bundle / metadata['assets'][name], SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()))
        function = asset.load_function(asset.function_names[0])
        out = await function({key: NDArray(value.detach().numpy()) for key, value in inputs.items()})
        for expected, key in zip(ref, names):
            expected = expected.float().numpy().flatten()
            actual = out[key].numpy().astype(np.float32).flatten()
            assert actual.shape == expected.shape
            assert np.isfinite(actual).all()
            cosine = float(np.dot(actual, expected) / max(1e-12, np.linalg.norm(actual) * np.linalg.norm(expected)))
            relative_rmse = float(np.sqrt(np.mean((actual - expected)**2)) / max(1e-12, np.sqrt(np.mean(expected**2))))
            row = dict(graph=name, output=key, cosine=cosine, relative_rmse=relative_rmse)
            rows.append(row)
            print(json.dumps(row), flush=True)
            assert cosine > 0.995 and relative_rmse < 0.05, row
    args.report.write_text(json.dumps(dict(provenance=provenance, passed=True, graph_parity=rows), indent=2) + '\n')

if __name__ == '__main__':
    torch.set_num_threads(4)
    asyncio.run(main())
