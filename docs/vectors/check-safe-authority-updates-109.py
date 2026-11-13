#!/usr/bin/env python3
"""Generate/check offline baseline Safe hash vectors and #109 semantic cases.

Requires Foundry cast on PATH or CODEX_SAFE_VECTOR_CAST. No RPC is used.
Fixture private key 1 is public test material. New #109 ABI vectors await ABI freeze.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
TARGET = ROOT / 'safe-authority-updates-109.json'
CAST = os.environ.get('CODEX_SAFE_VECTOR_CAST') or shutil.which('cast')
if not CAST:
    candidate = Path('/home/carter/.foundry/bin/cast')
    if candidate.is_file():
        CAST = str(candidate)
if not CAST:
    raise SystemExit('Foundry cast is required; set CODEX_SAFE_VECTOR_CAST.')

KEY = '0x' + '0' * 63 + '1'
SAFE = '0x1111111111111111111111111111111111111111'
CHILD = '0x2222222222222222222222222222222222222222'
ZERO = '0x' + '00' * 20


def cast(*args):
    result = subprocess.run([CAST, *map(str, args)], check=True,
                            capture_output=True, text=True)
    return result.stdout.strip()


def digest_hex(value):
    return cast('keccak', value)


def typehash(value):
    return digest_hex('0x' + value.encode().hex())


def abi(types, *values):
    return cast('abi-encode', 'f(' + types + ')', *values)


DOMAIN_TYPE = 'EIP712Domain(uint256 chainId,address verifyingContract)'
TX_TYPE = ('SafeTx(address to,uint256 value,bytes data,uint8 operation,'
           'uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,'
           'address refundReceiver,uint256 nonce)')
MSG_TYPE = 'SafeMessage(bytes message)'
DOMAIN_TYPEHASH = typehash(DOMAIN_TYPE)
TX_TYPEHASH = typehash(TX_TYPE)
MSG_TYPEHASH = typehash(MSG_TYPE)


def domain(chain_id, safe):
    preimage = abi('bytes32,uint256,address', DOMAIN_TYPEHASH, chain_id, safe)
    return preimage, digest_hex(preimage)


def typed_digest(domain_hash, struct_hash):
    return digest_hex('0x1901' + domain_hash[2:] + struct_hash[2:])


def signed_vector(name, safe, chain_id, preimage, struct_hash, message_digest):
    signer = cast('wallet', 'address', '--private-key', KEY)
    raw = cast('wallet', 'sign', '--private-key', KEY, '--no-hash', message_digest)
    prefixed = cast('wallet', 'sign', '--private-key', KEY, message_digest)
    safe_eth_sign = prefixed[:-2] + f'{int(prefixed[-2:], 16) + 4:02x}'
    return {
        'id': name, 'safe': safe, 'chainId': chain_id,
        'domainPreimage': domain(chain_id, safe)[0],
        'domainSeparator': domain(chain_id, safe)[1],
        'structPreimage': preimage, 'structHash': struct_hash,
        'digest': message_digest, 'expectedSigner': signer,
        'rawSafeSignature': raw, 'ethSignSafeSignature': safe_eth_sign,
    }


def generate():
    vectors = []
    fields = {'to': '0x3333333333333333333333333333333333333333',
              'value': 0, 'data': '0x12345678', 'operation': 0,
              'safeTxGas': 0, 'baseGas': 0, 'gasPrice': 0,
              'gasToken': ZERO, 'refundReceiver': ZERO, 'nonce': 7}
    for name, chain_id, safe in [
        ('safe-tx-chain1', 1, SAFE),
        ('safe-tx-chain10', 10, SAFE),
        ('safe-tx-other-safe', 1, CHILD),
    ]:
        preimage = abi('bytes32,address,uint256,bytes32,uint8,uint256,uint256,'
                       'uint256,address,address,uint256', TX_TYPEHASH,
                       fields['to'], fields['value'], digest_hex(fields['data']),
                       fields['operation'], fields['safeTxGas'], fields['baseGas'],
                       fields['gasPrice'], fields['gasToken'],
                       fields['refundReceiver'], fields['nonce'])
        struct_hash = digest_hex(preimage)
        vector = signed_vector(name, safe, chain_id, preimage, struct_hash,
                               typed_digest(domain(chain_id, safe)[1], struct_hash))
        vector['safeTx'] = dict(fields)
        vectors.append(vector)
    parent_hash = vectors[0]['digest']
    for name, child in [('nested-child', CHILD), ('nested-root-revisited', SAFE)]:
        preimage = abi('bytes32,bytes32', MSG_TYPEHASH, digest_hex(parent_hash))
        struct_hash = digest_hex(preimage)
        vector = signed_vector(name, child, 1, preimage, struct_hash,
                               typed_digest(domain(1, child)[1], struct_hash))
        vector['parentHash'] = parent_hash
        vector['message'] = parent_hash
        vectors.append(vector)
        parent_hash = vector['digest']
    def contract_signature(owner, payload):
        # Safe v=0 entry: r=owner, s=65-byte offset, followed by length and payload.
        return ('0x' + owner[2:].rjust(64, '0') + f'{65:064x}' + '00'
                + f'{(len(payload) - 2) // 2:064x}' + payload[2:])
    leaf = vectors[-1]['rawSafeSignature']
    child_blob = contract_signature(SAFE, leaf)
    root_blob = contract_signature(CHILD, child_blob)
    return {
        'schema': 'crossecute-authority-review-v1',
        'status': 'Offline baseline crypto vectors; semantic #109 expectations, not Solidity test results.',
        'abiCoverage': 'Existing SafeTx and SafeMessage hashes only; new #109 ABI/domain tags are not frozen.',
        'fixturePrivateKey': KEY,
        'types': {'domain': DOMAIN_TYPE, 'safeTx': TX_TYPE, 'safeMessage': MSG_TYPE},
        'typeHashes': {'domain': DOMAIN_TYPEHASH, 'safeTx': TX_TYPEHASH, 'safeMessage': MSG_TYPEHASH},
        'cryptoVectors': vectors,
        'finiteRepeatedSafeProof': {
            'status': 'Encoded proof fixture; native Safe integration still required.',
            'rootSafe': SAFE, 'rootDigest': vectors[0]['digest'],
            'rootSignatures': root_blob,
            'records': [
                {'safe': SAFE, 'threshold': 1, 'owners': [CHILD, vectors[0]['expectedSigner']]},
                {'safe': CHILD, 'threshold': 1, 'owners': [SAFE]},
            ],
            'steps': [
                {'safe': SAFE, 'digest': vectors[0]['digest'], 'owner': CHILD},
                {'safe': CHILD, 'digest': vectors[-2]['digest'], 'owner': SAFE},
                {'safe': SAFE, 'digest': vectors[-1]['digest'], 'owner': vectors[-1]['expectedSigner']},
            ],
            'expected': 'Finite leaf-backed proof; repeated Safe address alone must not reject it.',
        },
        'semanticCases': [
            {'id': 'initialize-once', 'readyBefore': False, 'readyAfter': True,
             'requires': 'validated native guard activation; repeat cannot reset'},
            {'id': 'source-mutation', 'sourceHashBefore': 'B-old', 'sourceHashAfter': 'B-new',
             'requires': 'atomic registered mutation and matching actual post-state; no authority counter'},
            {'id': 'provider-shared-selection', 'key': ['sourceChainId', 'A'],
             'providers': ['LayerZero', 'CCIP'],
             'result': 'same selected full graph hash and management replay enforcement'},
            {'id': 'independent-child-selection', 'selectedA': 'A-with-B-old', 'selectedB': 'B-new',
             'result': 'B own entry does not change A embedded B snapshot'},
            {'id': 'stricter-child-parent-responsibility',
             'selectedBThreshold': 1, 'sourceBThreshold': 2,
             'result': 'selected threshold 1 remains eligible; A must explicitly adopt stricter B before further A work; no automatic update or child counter'},
            {'id': 'stricter-child-adopted', 'selectedBThreshold': 2,
             'result': 'fresh B approvals need threshold 2; already accepted commitments survive under D92'},
            {'id': 'stricter-root-receiver-freshness',
             'selectedRootThreshold': 1, 'sourceRootThreshold': 2,
             'result': 'stored threshold 1 remains eligible until update installation; A must update relevant receivers before further signing; accepted operational risk'},
            {'id': 'root-ordering-policy-retained',
             'result': 'linked predecessor ordering supersedes D93; no numeric authority counter or source freshness check introduced'},
            {'id': 'explicit-parent-replacement', 'selectedA': 'A-with-B-old',
             'authorization': 'current A quorum signs exact predecessor update/authority hashes and replacement graph in a recognized source guard call',
             'result': 'install A-with-B-new only after independent descendant authentication'},
            {'id': 'implicit-adoption-rejected', 'selectedA': 'A-with-B-old',
             'evidence': 'signed B transition and successor approval attached to ordinary A execution',
             'result': 'cannot install successor implicitly; approval must match selected authority'},
            {'id': 'new-quorum-self-install-rejected',
             'evidence': 'proposed replacement owners alone sign graph replacement',
             'result': 'reject; management authorization must verify under current A graph'},
            {'id': 'unexecuted-child-state',
             'evidence': 'authentic child transition and explicit current A quorum replacement',
             'sourceExecuted': False,
             'result': 'selection allowed; source execution proof not required'},
            {'id': 'management-replay', 'deliveries': ['direct', 'LayerZero', 'CCIP'],
             'result': 'shared linked head and exact acceptance receipt prevent replay'},
            {'id': 'out-of-order-linked-update', 'currentHead': 'H0', 'submittedPreviousHead': 'H1',
             'result': 'reject without consuming or advancing state, regardless of nonce magnitude'},
            {'id': 'huge-nonce-then-lower-linked-update', 'safeNonces': ['uint256.max', 11],
             'result': 'both may apply with valid successive heads/current quorums; no numeric watermark'},
            {'id': 'universal-evidence', 'destinations': ['current chain', 'future chain'],
             'result': 'same signed source evidence reused after independent genesis and predecessor verification'},
            {'id': 'registration-sentinel', 'authorityHash': 'bytes32(0)',
             'result': 'unregistered; reject zero initial/replacement graph hashes'},
            {'id': 'mutation-batch', 'innerOperation': 'CALL', 'outerOperation': 'DELEGATECALL',
             'result': 'pinned MultiSendCallOnly executes ordered zero-value supported self-calls; pair completion mandatory'},
            {'id': 'returning-authority', 'selections': ['X', 'Y', 'X'],
             'result': 'old unexecuted approval may qualify under X; normal nonce/window checks still apply'},
            {'id': 'execution-replay', 'selections': ['X', 'Y', 'X'],
             'result': 'consumed execution stays blocked; graph replacement cannot reset consumption'},
            {'id': 'no-extra-resource-caps',
             'immediateOwnerCap': 16, 'aggregateEntryCap': None,
             'depthCap': None, 'evidenceByteCap': None, 'verificationStepCap': None,
             'result': 'finite valid proofs and terminating enumeration required; only VM/chain/provider resource limits apply beyond per-Safe owner cap'},
            {'id': 'shared-node', 'edges': [['A', 'B'], ['A', 'C'], ['B', 'C']],
             'result': 'graph allowed; shared C enumerated once; retain per-node thresholds'},
            {'id': 'cyclic-graph', 'edges': [['A', 'B'], ['B', 'C'], ['C', 'B']],
             'result': 'stored graph allowed; every accepted proof must be finite and valid'},
            {'id': 'unresolved-approval-loop', 'dependencies': [['claim1', 'claim2'], ['claim2', 'claim1']],
             'result': 'reject; no in-progress claim is an authenticated approval'},
            {'id': 'no-post-execution-refresh',
             'result': 'ordinary execution leaves selected graph unchanged; shared context frozen through calls'},
            {'id': 'commitment-child-authorization',
             'result': 'accepted child authorization is not rechecked or refreshed at finalize'},
            {'id': 'commitment-root-replacement',
             'result': 'accepted commitment remains executable after root replacement; no signature recheck or authority-hash/counter equality; cancellation/consumption checks remain'},
        ],
    }


def verify(data):
    assert len({v['digest'] for v in data['cryptoVectors']}) == len(data['cryptoVectors'])
    for vector in data['cryptoVectors']:
        assert digest_hex(vector['domainPreimage']) == vector['domainSeparator']
        assert digest_hex(vector['structPreimage']) == vector['structHash']
        assert typed_digest(vector['domainSeparator'], vector['structHash']) == vector['digest']
        result = cast('wallet', 'verify', '--address', vector['expectedSigner'],
                      '--no-hash', vector['digest'], vector['rawSafeSignature'])
        assert 'succeeded' in result.lower(), result
        eth_sig = vector['ethSignSafeSignature']
        original_eth_sig = eth_sig[:-2] + f'{int(eth_sig[-2:], 16) - 4:02x}'
        result = cast('wallet', 'verify', '--address', vector['expectedSigner'],
                      vector['digest'], original_eth_sig)
        assert 'succeeded' in result.lower(), result
    assert len({c['id'] for c in data['semanticCases']}) == len(data['semanticCases'])
    blob = bytes.fromhex(data['finiteRepeatedSafeProof']['rootSignatures'][2:])
    for owner in (CHILD, SAFE):
        assert blob[:32][-20:].hex() == owner[2:].lower()
        assert blob[64] == 0
        offset = int.from_bytes(blob[32:64], 'big')
        assert offset == 65
        length = int.from_bytes(blob[offset:offset + 32], 'big')
        assert len(blob) == offset + 32 + length
        blob = blob[offset + 32:]
    assert blob.hex() == data['cryptoVectors'][-1]['rawSafeSignature'][2:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Regenerate the reviewed corpus')
    args = parser.parse_args()
    expected = generate()
    verify(expected)
    if args.write:
        TARGET.write_text(json.dumps(expected, indent=2) + '\n')
    else:
        actual = json.loads(TARGET.read_text())
        assert actual == expected, 'Corpus differs from regenerated offline vectors'
        verify(actual)
    print(f"Verified {len(expected['cryptoVectors'])} hash vectors, "
          f"{2 * len(expected['cryptoVectors'])} signatures; "
          f"{len(expected['semanticCases'])} semantic case definitions (not executed).")


if __name__ == '__main__':
    main()
