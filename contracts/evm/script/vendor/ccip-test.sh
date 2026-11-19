#!/usr/bin/env bash
# Reproduce the pinned CCIP integration binaries without installing or executing package scripts.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
npm pack --ignore-scripts --silent @chainlink/contracts-ccip@2.0.0 --pack-destination "$work" > /dev/null
archive="$work/chainlink-contracts-ccip-2.0.0.tgz"
echo "59c3ea7be405d68cadd948ac1c8ee5e0b7df4d1cdcde709bf1515e009d5dd759  $archive" | sha256sum --check
python3 - "$archive" <<'PY'
import sys, tarfile
from pathlib import Path
root = Path('contracts/evm/test/fixtures/ccip-v2')
with tarfile.open(sys.argv[1]) as archive:
    for source, dest in [
        ('bytecode/v2_0_0/offramp.bin', 'offramp.bin'),
        ('bytecode/v1_2_0/router.bin', 'router.bin'),
        ('contracts/LICENSE.md', 'LICENSE.md'),
        ('contracts/v2.0-CCIP-License-grants.md', 'v2.0-CCIP-License-grants.md'),
    ]:
        (root / dest).write_bytes(archive.extractfile('package/' + source).read())
PY
(cd contracts/evm/test/fixtures/ccip-v2 && sha256sum --check SHA256SUMS)
