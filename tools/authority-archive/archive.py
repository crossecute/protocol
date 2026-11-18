#!/usr/bin/env python3
"""Offline, content-checked authority archive. Requires Foundry cast; never sends transactions."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

RECORD = '(address,uint256,(address,uint8)[])'
GRAPH = f'(({RECORD},bytes32)[])'
TX = '(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)'
SIGNED = f'({TX},bytes)'
EVIDENCE = f'({SIGNED},(address,bytes32,{SIGNED})[])'
CHILD = f'(address,{EVIDENCE},{RECORD},(bytes32,bytes32)[])'
SUBMISSION = f'{EVIDENCE},{GRAPH},{CHILD}[]'
ZERO = '0x' + '00' * 32


def hex_value(value, size=None):
    if not isinstance(value, str) or not value.startswith('0x'):
        raise ValueError('expected 0x-prefixed hex')
    raw = bytes.fromhex(value[2:])
    if len(value) != 2 + 2 * len(raw) or (size is not None and len(raw) != size):
        raise ValueError('incorrect hex length')
    return '0x' + raw.hex()


def record_literal(record):
    safe, threshold, owners = record
    return f'({safe},{threshold},[' + ','.join(f'({a},{k})' for a, k in owners) + '])'


def graph_literal(graph):
    return '([' + ','.join(f'({record_literal(r)},{p})' for r, p in graph[0]) + '])'


class Cast:
    def __init__(self):
        self.path = shutil.which('cast')
        if not self.path:
            raise ValueError('Foundry cast must be on PATH')

    def run(self, *args):
        result = subprocess.run([self.path, *map(str, args)], capture_output=True, text=True)
        if result.returncode:
            raise ValueError('cast failed: ' + result.stderr.strip())
        return result.stdout.strip()

    def decode(self, types, data):
        result = json.loads(self.run('abi-decode', '--json', f'f()({types})', data))
        if not result['success']:
            raise ValueError('ABI decoding failed')
        return result['data']

    def abi(self, types, *values):
        return self.run('abi-encode', f'f({types})', *values)

    def hash(self, data):
        return self.run('keccak', data).lower()


class Archive:
    def __init__(self, directory, chain, guard, safe):
        if chain <= 0:
            raise ValueError('chain must be positive')
        self.chain = chain
        self.guard = hex_value(guard, 20)
        self.safe = hex_value(safe, 20)
        self.root = Path(directory) / str(chain) / self.guard / self.safe
        self.cast = Cast()

    def path(self, kind, key):
        return self.root / kind / (hex_value(key, 32)[2:] + '.json')

    def write(self, kind, key, value):
        path = self.path(kind, key)
        path.parent.mkdir(parents=True, exist_ok=True)
        encoded = json.dumps(value, sort_keys=True, indent=2) + '\n'
        # A complete immutable object appears at once; conflicting writers cannot replace it.
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
            temporary = Path(out.name)
            out.write(encoded)
            out.flush()
            os.fsync(out.fileno())
        try:
            try:
                os.link(temporary, path)
            except FileExistsError:
                if path.read_text() != encoded:
                    raise ValueError(f'conflicting archive object: {path}')
            descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            temporary.unlink()

    def read(self, kind, key):
        path = self.path(kind, key)
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            raise ValueError(f'missing {kind} object: {key}') from None

    def graph_info(self, encoded):
        graph, = self.cast.decode(GRAPH, hex_value(encoded))
        nodes = graph[0]
        if not nodes or hex_value(nodes[0][0][0], 20) != self.safe:
            raise ValueError('graph root differs from archive Safe')
        canonical = self.cast.abi(GRAPH, graph_literal(graph))
        if canonical.lower() != encoded.lower():
            raise ValueError('noncanonical graph ABI')
        entries = [(self.cast.hash(self.cast.abi(RECORD, record_literal(r))), p) for r, p in nodes]
        text = '[' + ','.join(f'({h},{p})' for h, p in entries) + ']'
        digest = self.cast.hash(self.cast.abi('bytes32,uint256,(bytes32,bytes32)[]',
                                            self.cast.hash('0x' + b'Crossecute.AuthorityGraph.v1'.hex()),
                                            self.chain, text))
        return digest

    def put_graph(self, encoded, expected):
        expected = hex_value(expected, 32)
        if self.graph_info(encoded) != expected:
            raise ValueError('graph hash differs from expected authority hash')
        self.write('graphs', expected, {'graph': encoded.lower()})

    def get_graph(self, expected):
        expected = hex_value(expected, 32)
        encoded = self.read('graphs', expected)['graph']
        if self.graph_info(encoded) != expected:
            raise ValueError('corrupt graph object')
        return encoded

    def submission_info(self, submission):
        evidence, graph, _ = self.cast.decode(SUBMISSION, hex_value(submission))
        tx = evidence[0][0]
        to, value, data, operation, *rest = tx
        operation = int(operation)
        raw = bytes.fromhex(data[2:])
        select = self.cast.run('sig', 'selectAuthority((bytes32,bytes32))')
        register = self.cast.run('sig', 'registerOwnershipChange((bytes32,bytes32))')
        if operation == 0 and hex_value(to, 20) == self.guard and data[:10] == select:
            update_data = '0x' + raw[4:].hex()
        elif operation == 1 and data[:10] == self.cast.run('sig', 'multiSend(bytes)'):
            packed, = self.cast.decode('bytes', '0x' + raw[4:].hex())
            packed = bytes.fromhex(packed[2:])
            if len(packed) < 85 or packed[0] != 0 or '0x' + packed[1:21].hex() != self.guard:
                raise ValueError('unrecognized ownership registration')
            length = int.from_bytes(packed[53:85], 'big')
            call = packed[85:85 + length]
            if int.from_bytes(packed[21:53], 'big') or len(call) != length or '0x' + call[:4].hex() != register:
                raise ValueError('unrecognized ownership registration')
            update_data = '0x' + call[4:].hex()
        else:
            raise ValueError('not an authority successor')
        if int(value):
            raise ValueError('authority transaction has nonzero value')
        (previous, authority), = self.cast.decode('(bytes32,bytes32)', update_data)
        encoded_graph = self.cast.abi(GRAPH, graph_literal(graph))
        if self.graph_info(encoded_graph) != authority:
            raise ValueError('submission graph differs from signed authority hash')
        domain_type = self.cast.hash('0x' + b'EIP712Domain(uint256 chainId,address verifyingContract)'.hex())
        domain = self.cast.hash(self.cast.abi('bytes32,uint256,address', domain_type, self.chain, self.safe))
        tx_type = self.cast.hash('0x' + ('SafeTx(address to,uint256 value,bytes data,uint8 operation,'
                                      'uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,'
                                      'address refundReceiver,uint256 nonce)').encode().hex())
        struct = self.cast.hash(self.cast.abi('bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256',
                                             tx_type, to, value, self.cast.hash(data), operation, *rest))
        head = self.cast.hash('0x1901' + domain[2:] + struct[2:])
        return head, previous, authority, encoded_graph

    def put_submission(self, submission, head, publication):
        head, publication = hex_value(head, 32), hex_value(publication, 32)
        if self.cast.hash(hex_value(submission)) != publication:
            raise ValueError('submission differs from expected publication hash')
        actual, _, authority, graph = self.submission_info(submission)
        if actual != head:
            raise ValueError('submission head differs from expected SafeTx hash')
        self.put_graph(graph, authority)
        self.write('updates', head, {'submission': submission.lower(), 'publicationHash': publication})

    def chain_to(self, start, target):
        start, target = hex_value(start, 32), hex_value(target, 32)
        cursor, seen, result = target, set(), []
        while cursor != start:
            if cursor == ZERO or cursor in seen:
                raise ValueError('target does not descend from requested start')
            seen.add(cursor)
            obj = self.read('updates', cursor)
            submission = obj['submission']
            if self.cast.hash(submission) != hex_value(obj['publicationHash'], 32):
                raise ValueError('corrupt submission object')
            actual, previous, _, _ = self.submission_info(submission)
            if actual != cursor:
                raise ValueError('corrupt update head')
            result.append(submission)
            cursor = previous
        return list(reversed(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True)
    parser.add_argument('--chain', required=True, type=int)
    parser.add_argument('--guard', required=True)
    parser.add_argument('--safe', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    graph = commands.add_parser('put-graph')
    graph.add_argument('--file', required=True, type=Path)
    graph.add_argument('--hash', required=True)
    get = commands.add_parser('get-graph')
    get.add_argument('--hash', required=True)
    update = commands.add_parser('put-submission')
    update.add_argument('--file', required=True, type=Path)
    update.add_argument('--head', required=True)
    update.add_argument('--publication', required=True)
    chain = commands.add_parser('get-chain')
    chain.add_argument('--start', required=True)
    chain.add_argument('--target', required=True)
    args = parser.parse_args()
    archive = Archive(args.archive, args.chain, args.guard, args.safe)
    if args.command == 'put-graph':
        archive.put_graph(args.file.read_text().strip(), args.hash)
    elif args.command == 'get-graph':
        print(archive.get_graph(args.hash))
    elif args.command == 'put-submission':
        archive.put_submission(args.file.read_text().strip(), args.head, args.publication)
    else:
        print(json.dumps(archive.chain_to(args.start, args.target), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, IndexError, TypeError) as error:
        print(f'archive: {error}', file=sys.stderr)
        sys.exit(1)
