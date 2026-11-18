import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from archive import Archive, GRAPH, graph_literal

VECTORS = Path(__file__).resolve().parents[2] / 'docs/vectors/safe-authority-updates-109.json'


class ArchiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vectors = json.loads(VECTORS.read_text())['receiverVectors']
        spec = importlib.util.spec_from_file_location(
            'authority_vectors', VECTORS.with_name('check-safe-authority-updates-109.py'))
        cls.encoder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.encoder)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.vector = self.vectors[0]
        self.archive = self.scoped()

    def scoped(self, **overrides):
        v = self.vector
        values = dict(directory=self.directory.name, chain=v['sourceChainId'], guard=v['guard'], safe=v['sourceSafe'])
        values.update(overrides)
        return Archive(**values)

    def put(self, vector, archive=None):
        archive = archive or self.archive
        publication = archive.cast.hash(vector['submission'])
        archive.put_submission(vector['submission'], vector['update']['safeTxHash'], publication)
        return publication

    def test_accepted_shared_vectors_recover_graph_and_exact_submission(self):
        for vector in self.vectors:
            if vector['expect']['result'] != 'accept':
                continue
            with self.subTest(vector=vector['id']):
                archive = self.scoped(safe=vector['sourceSafe'])
                self.put(vector, archive)
                update = vector['update']
                self.assertEqual(archive.chain_to(update['previousUpdateHash'], update['safeTxHash']),
                                 [vector['submission']])
                graph = archive.get_graph(update['newAuthorityHash'])
                self.assertEqual(archive.graph_info(graph), vector['newGraph']['graphHash'])
                self.put(vector, archive)

    def test_activation_graph_import_and_restore(self):
        vector = self.vector
        # The selected bootstrap graph is an independent source for an activation witness.
        nodes = vector['bootstrap']['graph']['nodes']
        graph = ([[[n['record']['safe'], n['record']['threshold'],
                    [[o['owner'], o['kind']] for o in n['record']['owners']]], n['position']]
                  for n in nodes],)
        encoded = self.archive.cast.abi(GRAPH, graph_literal(graph))
        expected = vector['bootstrap']['graph']['graphHash']
        self.archive.put_graph(encoded, expected)
        self.put(vector)
        restored = Path(self.directory.name) / 'restored'
        shutil.copytree(self.archive.root, restored / str(vector['sourceChainId']) / vector['guard'].lower()
                        / vector['sourceSafe'].lower())
        recovery = self.scoped(directory=restored)
        self.assertEqual(recovery.get_graph(expected), encoded)
        self.assertEqual(recovery.chain_to(vector['update']['previousUpdateHash'], vector['update']['safeTxHash']),
                         [vector['submission']])

    def test_missing_evidence_fails_then_restored_evidence_recovers(self):
        self.put(self.vector)
        head = self.vector['update']['safeTxHash']
        previous = self.vector['update']['previousUpdateHash']
        path = self.archive.path('updates', head)
        saved = path.read_text()
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'missing updates'):
            self.archive.chain_to(previous, head)
        path.write_text(saved)
        self.assertEqual(self.archive.chain_to(previous, head), [self.vector['submission']])
        with self.assertRaisesRegex(ValueError, 'missing updates'):
            self.archive.chain_to('0x' + '11' * 32, head)

    def test_ordered_catchup_requires_every_link_and_survives_interruption(self):
        vectors = self.encoder
        first = self.vector
        second = vectors.receiver_vector(
            'archive-successor', 'eoa', 'Successor signed by the existing quorum',
            first['sourceSafe'], first['newGraph']['nodes'], first['update']['safeTxHash'],
            first['newGraph']['nodes'], [vectors.eoa(1), vectors.eoa(2)], 'accept', 1)
        # Publishing the later object first models an interrupted ingestion with a missing prefix.
        self.put(second)
        start, end = first['update']['previousUpdateHash'], second['update']['safeTxHash']
        with self.assertRaisesRegex(ValueError, 'missing updates'):
            self.archive.chain_to(start, end)
        self.put(first)
        self.assertEqual(self.archive.chain_to(start, end), [first['submission'], second['submission']])
        self.assertEqual(self.archive.chain_to(first['update']['safeTxHash'], end), [second['submission']])

    def test_hash_domain_and_head_mismatches_reject(self):
        v = self.vector
        publication = self.archive.cast.hash(v['submission'])
        with self.assertRaisesRegex(ValueError, 'publication hash'):
            self.archive.put_submission(v['submission'][:-2] + '01', v['update']['safeTxHash'], publication)
        with self.assertRaisesRegex(ValueError, 'SafeTx hash'):
            self.archive.put_submission(v['submission'], '0x' + '11' * 32, publication)
        wrong_chain = self.scoped(chain=1)
        with self.assertRaisesRegex(ValueError, 'signed authority hash'):
            self.put(v, wrong_chain)
        with self.assertRaisesRegex(ValueError, 'archive Safe'):
            self.put(v, self.scoped(safe='0x' + '22' * 20))
        with self.assertRaisesRegex(ValueError, 'not an authority successor'):
            self.put(v, self.scoped(guard='0x' + '22' * 20))

    def test_corruption_is_detected_on_read(self):
        self.put(self.vector)
        head = self.vector['update']['safeTxHash']
        path = self.archive.path('updates', head)
        obj = json.loads(path.read_text())
        obj['submission'] = obj['submission'][:-2] + '01'
        path.write_text(json.dumps(obj))
        with self.assertRaisesRegex(ValueError, 'corrupt submission'):
            self.archive.chain_to(self.vector['update']['previousUpdateHash'], head)
        graph_hash = self.vector['update']['newAuthorityHash']
        self.archive.path('graphs', graph_hash).write_text(json.dumps({'graph': '0x'}))
        with self.assertRaises(ValueError):
            self.archive.get_graph(graph_hash)

    def test_conflicting_evidence_cannot_replace_an_archived_publication(self):
        self.put(self.vector)
        v, enc = self.vector, self.encoder
        alternative = enc.receiver_vector(
            'archive-other-quorum', 'eoa', 'Another valid quorum for the same transaction',
            v['sourceSafe'], v['newGraph']['nodes'], v['update']['previousUpdateHash'],
            v['newGraph']['nodes'], [enc.eoa(1), enc.eoa(2)], 'accept', 0)
        self.assertEqual(alternative['update']['safeTxHash'], self.vector['update']['safeTxHash'])
        # A head does not commit to the signature bytes. Even a caller supplying another
        # digest cannot replace the already archived exact publication for that head.
        with self.assertRaisesRegex(ValueError, 'conflicting archive object'):
            self.put(alternative)
        self.assertEqual(self.archive.chain_to(self.vector['update']['previousUpdateHash'],
                                              self.vector['update']['safeTxHash']),
                         [self.vector['submission']])

    def test_cli_missing_evidence_returns_no_partial_json(self):
        v = self.vector
        result = subprocess.run(
            [sys.executable, '-B', str(Path(__file__).with_name('archive.py')),
             '--archive', self.directory.name, '--chain', str(v['sourceChainId']),
             '--guard', v['guard'], '--safe', v['sourceSafe'], 'get-chain',
             '--start', v['update']['previousUpdateHash'], '--target', v['update']['safeTxHash']],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('missing updates', result.stderr)

    def test_empty_catchup_needs_no_archive_and_never_moves_backwards(self):
        self.put(self.vector)
        head = self.vector['update']['safeTxHash']
        previous = self.vector['update']['previousUpdateHash']
        self.assertEqual(self.archive.chain_to(head, head), [])
        with self.assertRaisesRegex(ValueError, 'missing updates'):
            self.archive.chain_to(head, previous)


if __name__ == '__main__':
    unittest.main()
