#!/usr/bin/env python3
"""Create the pinned Pixel 6a development vbmeta copy. Never overwrites input."""
import hashlib
from pathlib import Path
import sys

EXPECTED_ORIGINAL = 'ab3c765b0449c44fb2048008d1e80fda9fc2a3cbb0a17b5837c3fdc77026d422'
EXPECTED_PATCHED = 'ce183b1f275bb1c949ccb96c347fbae19b07ed91d00a2aa964a94152793b9b8a'

def main():
    if len(sys.argv) != 3:
        raise SystemExit('Usage: prepare-pixel-vbmeta.py ORIGINAL OUTPUT (Pixel 6a CP1A.260405.005 only)')
    source, destination = map(Path, sys.argv[1:])
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED_ORIGINAL or data[:4] != b'AVB0':
        raise SystemExit('Not the pinned matching stock Pixel vbmeta; refusing modification')
    if int.from_bytes(data[120:124], 'big') != 0:
        raise SystemExit('Unexpected existing AVB flags')
    patched = bytearray(data)
    patched[120:124] = (3).to_bytes(4, 'big')
    if hashlib.sha256(patched).hexdigest() != EXPECTED_PATCHED:
        raise SystemExit('Patched metadata digest mismatch')
    with destination.open('xb') as output:
        output.write(patched)
    print('Created separate development metadata for an UNLOCKED Pixel 6a.')
    print('SHA256:', EXPECTED_PATCHED)
    print('Do not relock the bootloader while modified images are installed.')

if __name__ == '__main__':
    main()
