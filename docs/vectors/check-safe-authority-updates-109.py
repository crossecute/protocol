#!/usr/bin/env python3
"""Generate/check offline Safe hash vectors, #109 receiver vectors and semantic cases.

Requires Foundry cast on PATH or CODEX_SAFE_VECTOR_CAST. No RPC is used. Every hash,
encoding and signature here comes from cast, independently of the Solidity encoders;
contracts/evm/test/authority/AuthorityVectors.t.sol replays the file. Fixture private
keys 1 to 4 are public test material.
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


def safe_tx_hash(fields, safe, chain_id):
    """(struct preimage, struct hash, digest) of a Safe 1.5.0 SafeTx."""
    preimage = abi('bytes32,address,uint256,bytes32,uint8,uint256,uint256,'
                   'uint256,address,address,uint256', TX_TYPEHASH,
                   fields['to'], fields['value'], digest_hex(fields['data']),
                   fields['operation'], fields['safeTxGas'], fields['baseGas'],
                   fields['gasPrice'], fields['gasToken'],
                   fields['refundReceiver'], fields['nonce'])
    struct_hash = digest_hex(preimage)
    return preimage, struct_hash, typed_digest(domain(chain_id, safe)[1], struct_hash)


def safe_message_hash(parent_hash, safe, chain_id):
    """(struct preimage, struct hash, digest) of the handler's SafeMessage over abi.encode(parent)."""
    preimage = abi('bytes32,bytes32', MSG_TYPEHASH, digest_hex(parent_hash))
    struct_hash = digest_hex(preimage)
    return preimage, struct_hash, typed_digest(domain(chain_id, safe)[1], struct_hash)


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


# #109 receiver vectors. Addresses below are fixture values with no deployed code; the
# Solidity replay pins the receiver to VECTOR_GUARD and VECTOR_MULTISEND.
GRAPH_DOMAIN = typehash('Crossecute.AuthorityGraph.v1')
SOURCE_CHAIN = 10
VECTOR_GUARD = '0x4444444444444444444444444444444444444444'
VECTOR_MULTISEND = '0x6666666666666666666666666666666666666666'
EOA_ROOT = SAFE
NESTED_ROOT = '0x7777777777777777777777777777777777777777'
SHARED_ROOT = '0x8888888888888888888888888888888888888888'
CHILD_B = CHILD
CHILD_C = '0x3333333333333333333333333333333333333333'
CHILD_D = '0x5555555555555555555555555555555555555555'
SENTINEL = '0x0000000000000000000000000000000000000001'
ZERO32 = '0x' + '00' * 32
OWNER_EOA, OWNER_SAFE = 0, 1

RECORD_T = '(address,uint256,(address,uint8)[])'
NODE_T = f'({RECORD_T},bytes32)'
GRAPH_T = f'({NODE_T}[])'
ENTRY_T = '(bytes32,bytes32)'
TX_T = '(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)'
SIGNED_T = f'({TX_T},bytes)'
APPROVAL_T = f'(address,bytes32,{SIGNED_T})'
EVIDENCE_T = f'({SIGNED_T},{APPROVAL_T}[])'
CHILD_T = f'(address,{EVIDENCE_T},{RECORD_T},{ENTRY_T}[])'
BOOTSTRAP_T = '(address,bytes32,bytes,bytes)'
CALL_T = '(address,uint256,bytes)'

_ADDRESSES = {}


def key(n):
    return '0x' + f'{n:064x}'


def owner_of(n):
    if n not in _ADDRESSES:
        _ADDRESSES[n] = cast('wallet', 'address', '--private-key', key(n))
    return _ADDRESSES[n]


def label(text):
    return typehash(text)


def record(safe, threshold, owners):
    return {'safe': safe, 'threshold': threshold,
            'owners': [{'owner': o, 'kind': k} for o, k in owners]}


def record_tuple(r):
    owners = ','.join(f"({o['owner']},{o['kind']})" for o in r['owners'])
    return f"({r['safe']},{r['threshold']},[{owners}])"


def record_hash(r):
    return digest_hex(abi(RECORD_T, record_tuple(r)))


def graph_tuple(nodes):
    return '([' + ','.join(f"({record_tuple(n['record'])},{n['position']})" for n in nodes) + '])'


def graph_entries(nodes):
    return [{'recordHash': record_hash(n['record']), 'position': n['position']} for n in nodes]


def entries_tuple(entries):
    return '[' + ','.join(f"({e['recordHash']},{e['position']})" for e in entries) + ']'


def graph_hash(entries):
    return digest_hex(abi(f'bytes32,uint256,{ENTRY_T}[]', GRAPH_DOMAIN, SOURCE_CHAIN,
                          entries_tuple(entries)))


def graph_json(nodes):
    entries = graph_entries(nodes)
    return {'nodes': nodes, 'entries': entries, 'graphHash': graph_hash(entries)}


def safe_tx(to, data, operation, nonce):
    return {'to': to, 'value': 0, 'data': data, 'operation': operation,
            'safeTxGas': 0, 'baseGas': 0, 'gasPrice': 0,
            'gasToken': ZERO, 'refundReceiver': ZERO, 'nonce': nonce}


def safe_tx_tuple(t):
    return (f"({t['to']},{t['value']},{t['data']},{t['operation']},{t['safeTxGas']},"
            f"{t['baseGas']},{t['gasPrice']},{t['gasToken']},{t['refundReceiver']},{t['nonce']})")


def mutation(safe, signature, *args):
    return {'target': safe, 'value': 0, 'call': signature,
            'data': cast('calldata', signature, *args)}


def multisend_entry(to, data):
    return '00' + to[2:].lower() + '00' * 32 + f'{(len(data) - 2) // 2:064x}' + data[2:]


def ownership_batch(safe, previous, new, mutations):
    registration = cast('calldata', 'registerOwnershipChange((bytes32,bytes32))',
                        f'({previous},{new})')
    packed = multisend_entry(VECTOR_GUARD, registration)
    packed += ''.join(multisend_entry(safe, m['data']) for m in mutations)
    return cast('calldata', 'multiSend(bytes)', '0x' + packed)


def eoa(n, signed_hash=None):
    return {'kind': 'eoa', 'key': n, 'signedHash': signed_hash}


def nested(safe, signers, domain_chain=SOURCE_CHAIN, domain_safe=None):
    return {'kind': 'safe', 'safe': safe, 'signers': signers,
            'domainChain': domain_chain, 'domainSafe': domain_safe or safe}


def contract_entry_for(owner, payload):
    return {'kind': 'contract', 'owner': owner, 'payload': payload}


def approved(owner):
    return {'kind': 'approved', 'owner': owner}


def signature_blob(signers, digest, reverse_payloads=False, offset_shift=0, keep_order=False):
    """Safe 1.5.0 blob: 65-byte static entries by ascending owner, then length-prefixed
    contract payloads, each at the offset its entry's `s` names."""
    items = []
    for signer in signers:
        if signer['kind'] == 'eoa':
            sig = cast('wallet', 'sign', '--private-key', key(signer['key']), '--no-hash',
                       signer['signedHash'] or digest)
            items.append((owner_of(signer['key']), sig[2:], None))
        elif signer['kind'] == 'safe':
            child_digest = safe_message_hash(digest, signer['domainSafe'], signer['domainChain'])[2]
            items.append((signer['safe'], None, signature_blob(signer['signers'], child_digest)[2:]))
        elif signer['kind'] == 'contract':
            items.append((signer['owner'], None, signer['payload'][2:]))
        else:
            items.append((signer['owner'], signer['owner'][2:].lower().rjust(64, '0')
                          + '00' * 32 + '01', None))
    if not keep_order:
        items.sort(key=lambda item: int(item[0], 16))
    payloads = [item for item in items if item[2] is not None]
    if reverse_payloads:
        payloads.reverse()
    offsets, dynamic, at = {}, '', len(items) * 65
    for item in payloads:
        offsets[id(item)] = at
        dynamic += f'{len(item[2]) // 2:064x}' + item[2]
        at += 32 + len(item[2]) // 2
    static = ''
    for item in items:
        if item[2] is None:
            static += item[1]
        else:
            static += (item[0][2:].lower().rjust(64, '0')
                       + f'{offsets[id(item)] + offset_shift:064x}' + '00')
    return '0x' + static + dynamic


def error_data(signature, *args):
    return cast('calldata', signature, *args)


def reject(signature, *args):
    """Expected revert. With args, the exact revert data; without, the selector only."""
    expect = {'result': 'reject', 'error': signature,
              'errorSelector': cast('sig', signature)}
    if args:
        expect['revertData'] = error_data(signature, *args)
    return expect


def child_update(child, previous, signers, new_record, mutations, nonce):
    nodes = [{'record': new_record, 'position': ZERO32}]
    graph = graph_json(nodes)
    t = safe_tx(VECTOR_MULTISEND, ownership_batch(child, previous, graph['graphHash'], mutations), 1, nonce)
    digest = safe_tx_hash(t, child, SOURCE_CHAIN)[2]
    signatures = signature_blob(signers, digest)
    encoded = (f"({child},(({safe_tx_tuple(t)},{signatures}),[]),"
               f"{record_tuple(new_record)},{entries_tuple(graph['entries'])})")
    return {
        'sourceSafe': child, 'previousUpdateHash': previous,
        'newAuthorityHash': graph['graphHash'], 'mutations': mutations,
        'safeTx': t, 'safeTxHash': digest, 'signatures': signatures,
        'newRecord': new_record, 'newGraphEntries': graph['entries'],
    }, encoded


def receiver_vector(vid, family, description, safe, boot_nodes, boot_head, new_nodes,
                    signers, expect, nonce, mutations=None, children=(), blob=None,
                    signed_chain=SOURCE_CHAIN):
    boot = graph_json(boot_nodes)
    new = graph_json(new_nodes)
    bootstrap = abi(BOOTSTRAP_T, f"({VECTOR_GUARD},{boot_head},{abi(GRAPH_T, graph_tuple(boot_nodes))},"
                                 f"{abi(CALL_T + '[]', '[]')})")
    if mutations is None:
        kind = 'selectAuthority'
        data = cast('calldata', 'selectAuthority((bytes32,bytes32))', f"({boot_head},{new['graphHash']})")
        t = safe_tx(VECTOR_GUARD, data, 0, nonce)
    else:
        kind = 'ownershipChange'
        t = safe_tx(VECTOR_MULTISEND, ownership_batch(safe, boot_head, new['graphHash'], mutations), 1, nonce)
    digest = safe_tx_hash(t, safe, SOURCE_CHAIN)[2]
    signed = digest if signed_chain == SOURCE_CHAIN else safe_tx_hash(t, safe, signed_chain)[2]
    signatures = blob(signed) if blob else signature_blob(signers, signed)
    child_json = [c[0] for c in children]
    submission = abi(f'{EVIDENCE_T},{GRAPH_T},{CHILD_T}[]',
                     f"(({safe_tx_tuple(t)},{signatures}),[])", graph_tuple(new_nodes),
                     '[' + ','.join(c[1] for c in children) + ']')
    if expect == 'accept':
        expect = {'result': 'accept', 'updateHead': digest, 'authorityHash': new['graphHash']}
    return {
        'id': vid, 'family': family, 'description': description,
        'sourceChainId': SOURCE_CHAIN, 'sourceSafe': safe,
        'guard': VECTOR_GUARD, 'multiSendCallOnly': VECTOR_MULTISEND,
        'bootstrap': {'updateHead': boot_head, 'graph': boot, 'encoded': bootstrap},
        'update': {'kind': kind, 'previousUpdateHash': boot_head,
                   'newAuthorityHash': new['graphHash'], 'mutations': mutations or [],
                   'safeTx': t, 'safeTxHash': digest, 'signatures': signatures},
        'newGraph': new, 'childUpdates': child_json,
        'submission': submission, 'expect': expect,
    }


def receiver_vectors():
    k1, k2, k3, k4 = (owner_of(n) for n in (1, 2, 3, 4))
    vectors = []

    # One Safe, three EOA owners, threshold 2.
    eoa_root = record(EOA_ROOT, 2, [(k1, OWNER_EOA), (k2, OWNER_EOA), (k3, OWNER_EOA)])
    eoa_nodes = [{'record': eoa_root, 'position': ZERO32}]
    eoa_head = label('vector:eoa-root:head-0')

    def eoa_vector(vid, family, description, signers, expect, **kw):
        new_nodes = kw.pop('new_nodes', eoa_nodes)
        vectors.append(receiver_vector(vid, family, description, EOA_ROOT, eoa_nodes, eoa_head,
                                       new_nodes, signers, expect, nonce=len(vectors), **kw))

    eoa_vector('eoa-select', 'eoa', 'Two of three EOA owners sign a selectAuthority.',
               [eoa(1), eoa(3)], 'accept')
    eoa_vector('eoa-below-threshold', 'threshold', 'One signature for a threshold of two.',
               [eoa(1)], reject('SignaturesTooShort(address)', EOA_ROOT))
    eoa_vector('eoa-descending-signers', 'eoa', 'Signers out of ascending owner order.',
               [eoa(1), eoa(3)], reject('SignersNotAscending(address)', EOA_ROOT),
               blob=lambda d: signature_blob(
                   sorted([eoa(1), eoa(3)], key=lambda e: -int(owner_of(e['key']), 16)), d,
                   keep_order=True))
    eoa_vector('eoa-approved-hash', 'eoa', 'A v=1 approved-hash entry, which portable checks refuse.',
               [approved(k1), eoa(3)], reject('ApprovedHashUnsupported(address)', EOA_ROOT))
    eoa_vector('eoa-contract-signature', 'mixed',
               'A v=0 contract entry naming an EOA-kind owner.',
               [contract_entry_for(k1, '0x' + '11' * 65), eoa(3)],
               reject('NotAnOwner(address,address)', EOA_ROOT, k1))
    eoa_vector('eoa-wrong-chain', 'wrong-domain', 'Owners sign the SafeTx digest for chain 1.',
               [eoa(1), eoa(3)], reject('NotAnOwner(address,address)'), signed_chain=1)

    swapped = record(EOA_ROOT, 2, [(k4, OWNER_EOA), (k2, OWNER_EOA), (k3, OWNER_EOA)])
    swap = [mutation(EOA_ROOT, 'swapOwner(address,address,address)', SENTINEL, k1, k4)]
    eoa_vector('eoa-swap-owner', 'eoa', 'The stored quorum swaps owner 1 for owner 4.',
               [eoa(1), eoa(3)], 'accept', mutations=swap,
               new_nodes=[{'record': swapped, 'position': ZERO32}])
    eoa_vector('eoa-new-owner-self-install', 'stale-snapshot',
               'The proposed owner 4 signs its own installation.',
               [eoa(4), eoa(3)], reject('NotAnOwner(address,address)', EOA_ROOT, k4), mutations=swap,
               new_nodes=[{'record': swapped, 'position': ZERO32}])
    raised = record(EOA_ROOT, 3, [(k1, OWNER_EOA), (k2, OWNER_EOA), (k3, OWNER_EOA)])
    eoa_vector('threshold-raise', 'threshold', 'The stored threshold-2 quorum raises it to 3.',
               [eoa(1), eoa(3)], 'accept',
               mutations=[mutation(EOA_ROOT, 'changeThreshold(uint256)', 3)],
               new_nodes=[{'record': raised, 'position': ZERO32}])

    # Root with an EOA owner and Safe owner B (one EOA owner), threshold 2.
    b0 = record(CHILD_B, 1, [(k2, OWNER_EOA)])
    nested_root = record(NESTED_ROOT, 2, [(k1, OWNER_EOA), (CHILD_B, OWNER_SAFE)])
    b_head = label('vector:child-b:head-0')
    nested_nodes = [{'record': nested_root, 'position': ZERO32}, {'record': b0, 'position': b_head}]
    nested_head = label('vector:nested-root:head-0')

    def nested_vector(vid, family, description, signers, expect, **kw):
        new_nodes = kw.pop('new_nodes', nested_nodes)
        vectors.append(receiver_vector(vid, family, description, NESTED_ROOT, nested_nodes,
                                       nested_head, new_nodes, signers, expect,
                                       nonce=len(vectors), **kw))

    nested_vector('mixed-inline-nested', 'mixed',
                  'An EOA owner and Safe owner B, whose own owner signs inline.',
                  [eoa(1), nested(CHILD_B, [eoa(2)])], 'accept')
    nested_vector('nested-wrong-chain', 'wrong-domain',
                  "B's owner signs B's SafeMessage for chain 11.",
                  [eoa(1), nested(CHILD_B, [eoa(2)], domain_chain=11)],
                  reject('NotAnOwner(address,address)'))
    nested_vector('nested-wrong-safe', 'wrong-domain',
                  "B's owner signs the SafeMessage of the root instead of B's.",
                  [eoa(1), nested(CHILD_B, [eoa(2)], domain_safe=NESTED_ROOT)],
                  reject('NotAnOwner(address,address)'))
    nested_vector('nested-stale-owner', 'stale-snapshot',
                  "Owner 4 signs for B, but the stored B record still names owner 2.",
                  [eoa(1), nested(CHILD_B, [eoa(4)])],
                  reject('NotAnOwner(address,address)', CHILD_B, k4))

    b1 = record(CHILD_B, 1, [(k4, OWNER_EOA)])
    b_swap = [mutation(CHILD_B, 'swapOwner(address,address,address)', SENTINEL, k2, k4)]
    adopted = child_update(CHILD_B, b_head, [eoa(2)], b1, b_swap, 0)
    adopted_nodes = [{'record': nested_root, 'position': ZERO32},
                     {'record': b1, 'position': adopted[0]['safeTxHash']}]
    nested_vector('nested-adopt-child-update', 'nested',
                  "The root adopts B's rotation from owner 2 to 4; B votes under its new position.",
                  [eoa(1), nested(CHILD_B, [eoa(4)])], 'accept',
                  new_nodes=adopted_nodes, children=[adopted])
    nested_vector('nested-adopt-old-owner-votes', 'stale-snapshot',
                  "The same adoption, but B's vote comes from its replaced owner 2.",
                  [eoa(1), nested(CHILD_B, [eoa(2)])],
                  reject('NotAnOwner(address,address)', CHILD_B, k2),
                  new_nodes=adopted_nodes, children=[adopted])

    # Root owners: EOA 1, Safe C, Safe D; C owns D as well, so D is shared.
    d0 = record(CHILD_D, 1, [(k3, OWNER_EOA)])
    c0 = record(CHILD_C, 1, [(CHILD_D, OWNER_SAFE), (k2, OWNER_EOA)])
    shared_root = record(SHARED_ROOT, 2, [(k1, OWNER_EOA), (CHILD_C, OWNER_SAFE), (CHILD_D, OWNER_SAFE)])
    shared_nodes = [{'record': shared_root, 'position': ZERO32},
                    {'record': c0, 'position': label('vector:child-c:head-0')},
                    {'record': d0, 'position': label('vector:child-d:head-0')}]
    shared_head = label('vector:shared-root:head-0')
    two_level = [nested(CHILD_C, [nested(CHILD_D, [eoa(3)])]), nested(CHILD_D, [eoa(3)])]

    def shared_vector(vid, family, description, expect, **kw):
        vectors.append(receiver_vector(vid, family, description, SHARED_ROOT, shared_nodes,
                                       shared_head, shared_nodes, two_level, expect,
                                       nonce=len(vectors), **kw))

    shared_vector('multilevel-shared', 'multilevel-shared',
                  'C signs through D two levels down, and D signs directly; D is enumerated once.',
                  'accept')
    shared_vector('dynamic-offsets-reordered', 'dynamic-offset',
                  'The same signatures with the contract payloads stored in reverse order.',
                  'accept', blob=lambda d: signature_blob(two_level, d, reverse_payloads=True))
    shared_vector('dynamic-offset-into-static', 'dynamic-offset',
                  'A contract entry whose offset points inside the static part.',
                  reject('MalformedContractSignature(address)', SHARED_ROOT),
                  blob=lambda d: signature_blob(two_level, d, offset_shift=-(2 * 65)))
    return vectors


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
        vector = signed_vector(name, safe, chain_id, *safe_tx_hash(fields, safe, chain_id))
        vector['safeTx'] = dict(fields)
        vectors.append(vector)
    parent_hash = vectors[0]['digest']
    for name, child in [('nested-child', CHILD), ('nested-root-revisited', SAFE)]:
        vector = signed_vector(name, child, 1, *safe_message_hash(parent_hash, child, 1))
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
        'status': ('cryptoVectors and receiverVectors are replayed by '
                   'contracts/evm/test/authority/AuthorityVectors.t.sol; semanticCases are '
                   'prose expectations covered by the acceptance matrix, not executed here.'),
        'abiCoverage': ('SafeTx and SafeMessage hashes; #109 record and graph hashes, '
                        'ownership batches, child updates, bootstraps and full receiver submissions.'),
        'fixturePrivateKey': KEY,
        'types': {'domain': DOMAIN_TYPE, 'safeTx': TX_TYPE, 'safeMessage': MSG_TYPE},
        'typeHashes': {'domain': DOMAIN_TYPEHASH, 'safeTx': TX_TYPEHASH, 'safeMessage': MSG_TYPEHASH},
        'cryptoVectors': vectors,
        'receiverVectors': receiver_vectors(),
        'finiteRepeatedSafeProof': {
            'status': 'Encoded nested-signature bytes only: these records form a cycle, which #109 rejects as a stored graph.',
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
            'expected': 'Signature bytes decode as a finite leaf-backed proof; the graph itself is rejected as cyclic.',
        },
        'semanticCases': [
            {'id': 'initialize-once', 'readyBefore': False, 'readyAfter': True,
             'requires': 'guard set, then activate signed by the quorum at live state; a receiver is seeded once from its bootstrap head and graph; repeat cannot reset'},
            {'id': 'source-mutation', 'sourceHashBefore': 'B-old', 'sourceHashAfter': 'B-new',
             'requires': 'one SafeTx batch: guard call then owner mutations, matching actual post-state; no authority counter'},
            {'id': 'per-receiver-selection', 'key': ['receiver'],
             'providers': ['LayerZero', 'CCIP'],
             'result': 'each provider receiver holds its own selection from its own bootstrap; the same updates apply to each independently'},
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
             'result': 'destinations order updates by signed predecessor hash; source freshness is an operator responsibility'},
            {'id': 'explicit-parent-replacement', 'selectedA': 'A-with-B-old',
             'authorization': 'current A quorum signs exact predecessor update/authority hashes and replacement graph in a recognized source guard call',
             'result': 'install A-with-B-new only after B updates from the stored B position verify'},
            {'id': 'implicit-adoption-rejected', 'selectedA': 'A-with-B-old',
             'evidence': 'signed B transition and successor approval attached to ordinary A execution',
             'result': 'cannot install successor implicitly; approval must match selected authority'},
            {'id': 'new-quorum-self-install-rejected',
             'evidence': 'proposed replacement owners alone sign graph replacement',
             'result': 'reject; the root votes under its stored record'},
            {'id': 'unexecuted-child-state',
             'evidence': 'child update signed but not executed on source, named by an A adoption',
             'sourceExecuted': False,
             'result': 'source guard rejects: not a head the child executed; a destination cannot check execution and relies on A signers not to sign it'},
            {'id': 'child-position-forward', 'storedB': 'p', 'namedB': 'p+2',
             'evidence': 'B updates p->p+1->p+2, each signed under the B record before it',
             'result': 'accept in one A update; B record is the result of the signed mutations'},
            {'id': 'child-position-not-forward', 'storedB': 'p+1', 'namedB': 'p',
             'result': 'reject; a position is kept or reached from the stored one through child updates'},
            {'id': 'child-vote-under-named-position', 'storedB': 'p owners X', 'namedB': 'p+1 owners Y',
             'result': 'B vote on the adoption counts under Y; X signatures do not count for B; root still votes under its stored record'},
            {'id': 'child-rotates-before-root-quorum', 'storedB': 'p owners X', 'liveB': 'p+1 owners Y',
             'evidence': 'update keeps B at p; X signed before rotating',
             'result': 'Y signs for source execution; guard verifies and emits the X set as portable evidence'},
            {'id': 'child-rotates-after-adoption-signed', 'namedB': 'p+1', 'liveB': 'p+2',
             'result': 'source accepts: p+1 is an executed head at or after the stored position'},
            {'id': 'added-child-named', 'addedSafe': 'D',
             'evidence': 'A new graph names D record and position; no child update',
             'result': 'accept as named on A signers; source requires that position executed and the record D held there, so a D that never activated is rejected there'},
            {'id': 'readded-child-earlier-position', 'removedAt': 'p5', 'namedOnReadd': 'p2',
             'result': 'accept as named when p2 executed; any executed position leads to later ones'},
            {'id': 'nested-voter-flat-proof', 'voterInChildUpdate': 'C at q', 'storedC': 'q',
             'result': 'accept; C counts under q as on source, proven once in the flat child-update pass'},
            {'id': 'nested-voter-behind-stored', 'voterInChildUpdate': 'C at q', 'storedC': 'later than q',
             'result': 'reject; no child update proves a position before the stored one'},
            {'id': 'child-own-entry-ignored', 'selectedB': 'abandoned branch on this destination',
             'result': 'A adoption verifies links against the B record in A graph; B own entry is not read'},
            {'id': 'management-replay', 'deliveries': ['direct', 'LayerZero', 'CCIP'],
             'result': 'shared linked head prevents replay: each update names its predecessor and heads never repeat'},
            {'id': 'out-of-order-linked-update', 'currentHead': 'H0', 'submittedPreviousHead': 'H1',
             'result': 'reject without consuming or advancing state, regardless of nonce magnitude'},
            {'id': 'huge-nonce-then-lower-linked-update', 'safeNonces': ['uint256.max', 11],
             'result': 'both may apply with valid successive heads/current quorums; no numeric watermark'},
            {'id': 'universal-evidence', 'destinations': ['current chain', 'future chain'],
             'result': 'same signed source evidence reused after independent seeding and predecessor verification'},
            {'id': 'unseeded-sentinel', 'authorityHash': 'bytes32(0)',
             'result': 'unseeded; activation signs no previous hash and destinations reject it; reject zero initial/replacement graph hashes'},
            {'id': 'mutation-batch', 'innerOperation': 'CALL', 'outerOperation': 'DELEGATECALL',
             'result': 'pinned MultiSendCallOnly runs the guard call, then ordered zero-value supported self-calls, in one SafeTx'},
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
             'result': 'stored graph rejected on source and destination; a live cycle only blocks the adoption that would store it'},
            {'id': 'undeployed-owner-later-deployed', 'ownerAtAddition': 'no code', 'ownerLater': 'Safe',
             'result': 'stays EOA-kind until swapped; its contract signature does not count on source or destination'},
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
    vectors = {v['id']: v for v in data['receiverVectors']}
    assert len(vectors) == len(data['receiverVectors'])
    families = {'eoa', 'nested', 'mixed', 'multilevel-shared', 'dynamic-offset',
                'stale-snapshot', 'wrong-domain', 'threshold'}
    assert {v['family'] for v in vectors.values()} == families
    for v in vectors.values():
        assert v['newGraph']['graphHash'] == graph_hash(v['newGraph']['entries'])
        assert v['update']['safeTxHash'] == safe_tx_hash(v['update']['safeTx'], v['sourceSafe'], v['sourceChainId'])[2]
        if v['expect']['result'] == 'accept':
            assert v['expect']['updateHead'] == v['update']['safeTxHash']
            assert v['expect']['authorityHash'] == v['newGraph']['graphHash']
    assert (vectors['dynamic-offsets-reordered']['update']['signatures']
            != vectors['multilevel-shared']['update']['signatures'])


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
          f"{2 * len(expected['cryptoVectors'])} signatures, "
          f"{len(expected['receiverVectors'])} receiver vectors; "
          f"{len(expected['semanticCases'])} semantic case definitions (not executed).")


if __name__ == '__main__':
    main()
