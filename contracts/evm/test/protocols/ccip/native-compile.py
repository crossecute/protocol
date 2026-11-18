#!/usr/bin/env python3
"""Compile the CCIP implementation targets with an explicitly supplied native compiler."""
import argparse
import hashlib
import json
import posixpath
import re
import subprocess
import tomllib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kind', choices=['eravm', 'tron'], required=True)
parser.add_argument('--compiler', type=Path, required=True)
parser.add_argument('--solc', type=Path, help='zkSync Solidity frontend, required for EraVM')
parser.add_argument('--out', type=Path)
args = parser.parse_args()
if args.kind == 'eravm' and args.solc is None:
    parser.error('--solc is required for EraVM')
root = Path(__file__).resolve().parents[3]
config = tomllib.loads((root / 'foundry.toml').read_text())['profile']['default']
remappings = config['remappings']
sources = {}


def resolve(spec, parent):
    if spec.startswith('.'):
        return posixpath.normpath(posixpath.join(posixpath.dirname(parent), spec))
    for mapping in remappings:
        prefix, target = mapping.split('=', 1)
        if ':' in prefix:
            context, prefix = prefix.split(':', 1)
            if not parent.startswith(context):
                continue
        if spec.startswith(prefix):
            return target + spec[len(prefix):]
    return spec


def add(name):
    if name in sources:
        return
    content = (root / name).read_text()
    sources[name] = {'content': content}
    for spec in re.findall(r'^\s*import[\s\S]*?["\']([^"\']+)["\']\s*;', content, re.M):
        add(resolve(spec, name))


targets = {
    'src/protocols/ccip/CcipDivergentTransceiver.sol': [
        'CcipZkSyncTransceiver' if args.kind == 'eravm' else 'CcipTronTransceiver'
    ],
    'src/protocols/ccip/CcipReceiver.sol': ['CcipReceiver'],
    'src/protocols/ccip/CcipTransmitter.sol': ['CcipTransmitter'],
}
for source in targets:
    add(source)
settings = {
    'remappings': remappings,
    'evmVersion': config['evm_version'],
    'optimizer': {'enabled': config['optimizer'], 'runs': config['optimizer_runs']},
    'metadata': {'bytecodeHash': config['bytecode_hash']},
    'outputSelection': {source: {name: (['evm.bytecode.object', 'evm.deployedBytecode.object'] if args.kind == 'tron' else ['evm.bytecode.object']) for name in names}
                        for source, names in targets.items()},
}
if args.kind == 'tron':
    settings['metadata']['appendCBOR'] = config['cbor_metadata']
compiler_input = json.dumps({'language': 'Solidity', 'sources': sources, 'settings': settings})
output = args.out or root / 'out' / 'ccip-native' / args.kind
output.mkdir(parents=True, exist_ok=True)
(output / 'input.json').write_text(compiler_input)
command = [str(args.compiler.resolve())]
if args.kind == 'eravm':
    command += ['--solc', str(args.solc.resolve())]
result = subprocess.run(command + ['--standard-json'], input=compiler_input, text=True, capture_output=True)
(output / 'output.json').write_text(result.stdout)
(output / 'stderr.log').write_text(result.stderr)
result.check_returncode()
compiled = json.loads(result.stdout)
errors = [error for error in compiled.get('errors', []) if error['severity'] == 'error']
if errors:
    raise SystemExit('\n'.join(error.get('formattedMessage', error['message']) for error in errors))
summary = {
    'kind': args.kind,
    'compiler': subprocess.check_output([str(args.compiler.resolve()), '--version'], text=True).strip(),
    'compilerSha256': hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
    'sourceSha256': hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest(),
    'settings': settings,
    'contracts': {},
    'warnings': [error.get('formattedMessage', error['message'])
                 for error in compiled.get('errors', []) if error['severity'] == 'warning'],
}
if args.solc:
    summary['frontendSha256'] = hashlib.sha256(args.solc.read_bytes()).hexdigest()
for source, names in targets.items():
    for name in names:
        bytecode = compiled['contracts'][source][name]['evm']['bytecode']['object']
        if not bytecode:
            raise SystemExit(f'Missing native bytecode for {name}')
        runtime = compiled['contracts'][source][name]['evm'].get('deployedBytecode', {}).get('object')
        summary['contracts'][name] = {
            'creationBytes': len(bytecode) // 2,
            'sha256': hashlib.sha256(bytes.fromhex(bytecode)).hexdigest(),
            **({'runtimeBytes': len(runtime) // 2} if runtime else {}),
        }
(output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
