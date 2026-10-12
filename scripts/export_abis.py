#!/usr/bin/env python3
"""Export the three deployable contract ABIs from a completed local forge build."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="fail if committed ABIs differ from the build")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
for name in ("LaunchToken", "HiveWars", "ConquerorBadge"):
    artifact_path = root / "out" / f"{name}.sol" / f"{name}.json"
    if not artifact_path.exists():
        parser.error(f"Missing {artifact_path.name}; run forge build first")
    artifact = json.loads(artifact_path.read_text())
    encoded = json.dumps(artifact["abi"], indent=2) + "\n"
    destination = root / "docs" / "abi" / f"{name}.json"
    if args.check:
        if not destination.exists() or destination.read_text() != encoded:
            parser.error(f"ABI differs: {destination.relative_to(root)}")
        print(f"Verified {destination.relative_to(root)}")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(encoded)
        print(f"Exported {destination.relative_to(root)}")
