"""The November 9 approval must not admit modified source or new findings."""
import contextlib
import io
import subprocess
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_speaker_label_interpolation as speaker
import check_product_file_line_count_ratchet as size


def blob(source):
    raw = source.encode()
    return hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()


class ApprovedSnapshotTests(unittest.TestCase):
    def test_speaker_acceptance_is_exact_and_still_reported(self):
        path = 'backend/utils/example.py'
        source = 'label = f"{speaker_id}"\n'
        entry = {'blob': blob(source), 'expressions': ['f"{speaker_id}"']}
        with patch('fork_sync_acceptance.ACCEPTANCE', {'speaker': {path: entry}}):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(speaker.regressions(path, '', source), [])
            self.assertIn('remains unresolved', output.getvalue())
            for changed in [source + '\n', source + 'other = f"{speaker_id}"\n', source.replace('label', 'other')]:
                self.assertTrue(speaker.regressions(path, '', changed))
            self.assertTrue(speaker.regressions('backend/utils/unlisted.py', '', source))
        with patch('fork_sync_acceptance.ACCEPTANCE', {'speaker': {path: dict(entry, expressions=[])}}):
            self.assertTrue(speaker.regressions(path, '', source))

    def test_line_count_acceptance_does_not_admit_mutations(self):
        path = 'backend/utils/example.py'
        source = '# line\n' * 1501
        entry = {'blob': blob(source), 'base_lines': 1500, 'candidate_lines': 1501}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / path
            file.parent.mkdir(parents=True)
            with patch('fork_sync_acceptance.ACCEPTANCE', {'line_count': {path: entry}}), patch.object(size, 'source_count_at_ref', return_value=1500):
                file.write_text(source)
                self.assertEqual(size.evaluate_changes(root, 'base', {path}, {}), [])
                for changed in [source + '# extra\n', source.replace('# line', '# other', 1)]:
                    file.write_text(changed)
                    self.assertTrue(size.evaluate_changes(root, 'base', {path}, {}))
                file.write_text(source)
                with patch.object(size, 'source_count_at_ref', return_value=1499):
                    self.assertTrue(size.evaluate_changes(root, 'base', {path}, {}))


    def test_line_count_uses_candidate_tree_bytes_not_working_copy(self):
        path = 'backend/utils/example.py'
        source = '# line\n' * 1501
        entry = {'blob': blob(source), 'base_lines': 1500, 'candidate_lines': 1501}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(
                    ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
                     '-c', 'user.email=fixture@example.com', *args], cwd=root,
                    env=size.clean_git_env(), text=True, stderr=subprocess.DEVNULL,
                ).strip()
            git('init', '-q')
            file = root / path
            file.parent.mkdir(parents=True)
            file.write_text('# line\n' * 1500)
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            file.write_text(source)
            git('add', '.')
            git('commit', '-qm', 'candidate')
            candidate = git('rev-parse', 'HEAD')
            with patch('fork_sync_acceptance.ACCEPTANCE', {'line_count': {path: entry}}):
                file.write_text(source + '# extra\n')
                self.assertEqual(size.evaluate_changes(root, base, {path}, {}, candidate_ref=candidate), [])
                git('add', '.')
                git('commit', '-qm', 'changed candidate')
                file.write_text(source)
                self.assertTrue(size.evaluate_changes(root, base, {path}, {}, candidate_ref='HEAD'))
                unlisted = 'backend/utils/unlisted.py'
                (root / unlisted).write_text(source)
                self.assertTrue(size.evaluate_changes(root, base, {unlisted}, {}))


if __name__ == '__main__':
    unittest.main()
