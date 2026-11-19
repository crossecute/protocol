#!/usr/bin/env python3
"""Run the isolated baseline benchmark offline and preserve measured CSV results."""
import csv
import os
from pathlib import Path
import shutil
import subprocess

bench = Path(__file__).resolve().parent
repo = bench.parents[2]
forge = os.environ.get('FORGE') or shutil.which('forge')
if not forge:
    raise SystemExit('Set FORGE to the installed forge executable.')
candidates = [
    Path(os.environ['FORGE_STD_SRC']) if 'FORGE_STD_SRC' in os.environ else repo / 'contracts/evm/lib/forge-std/src',
    repo.parent / 'protocol/contracts/evm/lib/forge-std/src',
]
stdlib = next((p for p in candidates if (p / 'Test.sol').is_file()), None)
if stdlib is None:
    raise SystemExit('Set FORGE_STD_SRC to an existing forge-std src directory.')
env = os.environ.copy()
env['FOUNDRY_REMAPPINGS'] = '\n'.join([
    f'src/={repo}/contracts/evm/src/',
    f'fixtures/={repo}/contracts/evm/test/signed/',
    f'@crossecute/safe-guard/={repo}/contracts/safe-guard/src/',
    f'forge-std/={stdlib}/',
])
result = subprocess.run([forge, 'test', '--root', str(bench), '--offline', '-vv'],
                        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(bench / 'run.log').write_text(result.stdout)
print(result.stdout)
if result.returncode:
    raise SystemExit(result.returncode)
rows = [line.strip().split(',')[1:] for line in result.stdout.splitlines() if line.strip().startswith('BENCH,')]
if len(rows) != 43:
    raise SystemExit(f'Expected 43 benchmark rows, received {len(rows)}.')
headers = ['case', 'eoa_signatures', 'nested_safes', 'max_depth', 'owner_entries',
           'signature_bytes', 'calldata_bytes', 'cold_verify_gas', 'warm_verify_gas',
           'intrinsic_calldata_gas_paris', 'cold_plus_intrinsic_gas_paris']
with (bench / 'results.csv').open('w', newline='') as file:
    writer = csv.writer(file, lineterminator="\n")
    writer.writerow(headers)
    for row in sorted(rows):
        assert int(row[7]) > int(row[8]), f'Cold/warm control failed: {row[0]}'
        writer.writerow(row + [int(row[7]) + int(row[9])])

wires = [line.strip().split(',')[1:] for line in result.stdout.splitlines() if line.strip().startswith('WIRE,')]
if len(wires) != len(rows):
    raise SystemExit('Missing wire-size fixtures.')
with (bench / 'wire-sizes.csv').open('w', newline='') as file:
    writer = csv.writer(file, lineterminator="\n")
    writer.writerow(['case', 'native_transfer_wire_bytes', 'erc20_transfer_wire_bytes'])
    writer.writerows(sorted(wires))
