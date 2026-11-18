#!/usr/bin/env python3
"""Offline, content-checked authority archive. Requires eth-abi and Foundry cast; never sends transactions."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from eth_abi import decode, encode
from eth_abi.exceptions import DecodingError, EncodingError
from eth_abi.grammar import parse

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


def raw(value):
    return bytes.fromhex(hex_value(value)[2:]) if isinstance(value, str) else value


class Codec:
    def __init__(self):
        self.path = shutil.which('cast')
        if not self.path:
            raise ValueError('Foundry cast must be on PATH')

    def _run(self, *args, input=None):
        result = subprocess.run([self.path, *args], input=input, capture_output=True, text=True)
        if result.returncode:
            raise ValueError('cast failed: ' + result.stderr.strip())
        return result.stdout.strip()

    def decode(self, types, data):
        try:
            # Match Solidity's padding rules; graph ABI canonicality is checked by re-encoding.
            return decode(self._types(types), raw(data), strict=False)
        except DecodingError as error:
            raise ValueError(f'ABI decoding failed: {error}') from error

    def abi(self, types, *values):
        return '0x' + encode(self._types(types), values).hex()

    @staticmethod
    def _types(types):
        return [component.to_type_str() for component in parse(f'({types})').components]

    def selector(self, signature):
        return raw(self._run('sig', signature))

    def hash(self, data):
        return self._run('keccak', input='0x' + raw(data).hex()).lower()


class Archive:
    def __init__(self, directory, chain, guard, safe):
        if chain <= 0:
            raise ValueError('chain must be positive')
        self.chain = chain
        self.guard = hex_value(guard, 20)
        self.safe = hex_value(safe, 20)
        self.root = Path(directory) / str(chain) / self.guard / self.safe
        self.codec = Codec()

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
        graph, = self.codec.decode(GRAPH, hex_value(encoded))
        nodes = graph[0]
        if not nodes or hex_value(nodes[0][0][0], 20) != self.safe:
            raise ValueError('graph root differs from archive Safe')
        canonical = self.codec.abi(GRAPH, graph)
        if canonical.lower() != encoded.lower():
            raise ValueError('noncanonical graph ABI')
        entries = [(raw(self.codec.hash(self.codec.abi(RECORD, r))), p) for r, p in nodes]
        digest = self.codec.hash(self.codec.abi('bytes32,uint256,(bytes32,bytes32)[]',
                                              raw(self.codec.hash(b'Crossecute.AuthorityGraph.v1')),
                                              self.chain, entries))
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
        evidence, graph, _ = self.codec.decode(SUBMISSION, hex_value(submission))
        tx = evidence[0][0]
        to, value, data, operation, *rest = tx
        operation = int(operation)
        select = self.codec.selector('selectAuthority((bytes32,bytes32))')
        register = self.codec.selector('registerOwnershipChange((bytes32,bytes32))')
        if operation == 0 and hex_value(to, 20) == self.guard and data[:4] == select:
            update_data = data[4:]
        elif operation == 1 and data[:4] == self.codec.selector('multiSend(bytes)'):
            packed, = self.codec.decode('bytes', data[4:])
            if len(packed) < 85 or packed[0] != 0 or '0x' + packed[1:21].hex() != self.guard:
                raise ValueError('unrecognized ownership registration')
            length = int.from_bytes(packed[53:85], 'big')
            call = packed[85:85 + length]
            if int.from_bytes(packed[21:53], 'big') or len(call) != length or call[:4] != register:
                raise ValueError('unrecognized ownership registration')
            update_data = call[4:]
        else:
            raise ValueError('not an authority successor')
        if int(value):
            raise ValueError('authority transaction has nonzero value')
        (previous, authority), = self.codec.decode('(bytes32,bytes32)', update_data)
        previous, authority = '0x' + previous.hex(), '0x' + authority.hex()
        encoded_graph = self.codec.abi(GRAPH, graph)
        if self.graph_info(encoded_graph) != authority:
            raise ValueError('submission graph differs from signed authority hash')
        domain_type = raw(self.codec.hash(b'EIP712Domain(uint256 chainId,address verifyingContract)'))
        domain = self.codec.hash(self.codec.abi('bytes32,uint256,address', domain_type, self.chain, self.safe))
        tx_type = raw(self.codec.hash(b'SafeTx(address to,uint256 value,bytes data,uint8 operation,'
                                      b'uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,'
                                      b'address refundReceiver,uint256 nonce)'))
        struct = self.codec.hash(self.codec.abi('bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256',
                                               tx_type, to, value, raw(self.codec.hash(data)), operation, *rest))
        head = self.codec.hash(b'\x19\x01' + raw(domain) + raw(struct))
        return head, previous, authority, encoded_graph

    def put_submission(self, submission, head, publication):
        head, publication = hex_value(head, 32), hex_value(publication, 32)
        if self.codec.hash(hex_value(submission)) != publication:
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
            if self.codec.hash(submission) != hex_value(obj['publicationHash'], 32):
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
    except (ValueError, OSError, KeyError, IndexError, TypeError, EncodingError) as error:
        print(f'archive: {error}', file=sys.stderr)
        sys.exit(1)
