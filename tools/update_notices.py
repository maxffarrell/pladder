"""Refresh bundled notices after resolving SwiftPM dependency pins."""
from pathlib import Path
import argparse
parser=argparse.ArgumentParser()
parser.add_argument('--llama-license',type=Path,required=True)
args=parser.parse_args()
parts=['Third-party notices for Pladder Core AI\n\nIncludes SwiftPM build dependencies. Model attribution ships separately inside downloaded bundles.\n']
parts += ['\n===== Pladder upstream (MIT) =====\n', Path('LICENSE').read_text()]
for checkout in sorted(Path('.build/checkouts').iterdir()):
    for license in sorted(checkout.glob('LICENSE*')):
        if license.is_file():
            parts += [f'\n===== {checkout.name} / {license.name} =====\n', license.read_text()]
parts += ['\n===== llama.cpp b11191 =====\n',args.llama_license.read_text()]
Path('Sources/Pladder/Resources/ThirdPartyNotices.txt').write_text(''.join(parts))
