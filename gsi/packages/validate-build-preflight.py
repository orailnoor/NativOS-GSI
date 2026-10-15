#!/usr/bin/python3
"""Allow experimental image assembly only for the exact reviewed policy source."""
from pathlib import Path
import hashlib
import json

directory = Path(__file__).resolve().parent
report = json.loads((directory / 'compiled-boundaries.json').read_text())
if report.get('experimental_build_preflight_passed') is not True:
    raise SystemExit('Package policy experimental preflight has not passed')
for relative, expected in report['source_sha256'].items():
    path = directory.parent / relative
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('Package policy changed since compiled review: ' + relative)
print('EXPERIMENTAL package policy preflight verified; NOT a production security certification')
