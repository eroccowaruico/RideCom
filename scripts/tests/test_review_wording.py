import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.review_wording import candidates


class WordingReviewTests(unittest.TestCase):
    def test_reviews_only_added_or_edited_passages_including_new_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args: str) -> None:
                subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)

            git('init')
            (root / 'docs').mkdir()
            doc = root / 'docs/操作 手順.md'
            doc.write_text('以前に確認済み\n削除する文は適宜直す\n')
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                'commit', '-m', 'baseline')
            doc.write_text('以前に確認済み\n送信を再試行\n')
            git('add', '--', str(doc))
            doc.write_text(doc.read_text() + 'as needed\n')
            skill = root / '.agents/skills/example/SKILL.md'
            skill.parent.mkdir(parents=True)
            skill.write_text('適宜進める\n')
            app = root / 'RideIntercom/UI/Example.swift'
            app.parent.mkdir(parents=True)
            app.write_text('func retry() {}\nButton("Retry") {}\n')
            (root / 'RideIntercom/Localizable.xcstrings').write_text(
                '{"strings":{"Retry":{"localizations":{"ja":{"stringUnit":{"value":"再試行"}}}}}}')
            design = root / 'docs/design/画面.html'
            design.parent.mkdir()
            design.write_text('<button>Retry</button>')
            findings = list(candidates(root, 'HEAD'))
            self.assertEqual([line.split('  ')[0] for line in findings], [
                '.agents/skills/example/SKILL.md:1', 'RideIntercom/Localizable.xcstrings:1',
                'RideIntercom/UI/Example.swift:2', 'docs/design/画面.html:1',
                'docs/操作 手順.md:2', 'docs/操作 手順.md:3',
            ])

    def test_unregistered_japanese_is_included_in_the_readers_review(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git','init','-q'], cwd=root, check=True)
            (root / 'README.md').write_text('通話の音量を上げる。\n')
            subprocess.run(['git','add','README.md'], cwd=root, check=True)
            subprocess.run(['git','-c','user.name=Test','-c','user.email=test@example.invalid',
                            'commit','-qm','base'], cwd=root, check=True)
            (root / 'README.md').write_text('通話の音量を上げる。\nその判断は水に流す。\n')
            self.assertEqual(list(candidates(root, 'HEAD')), [])
            review = list(candidates(root, 'HEAD', all_passages=True))
            self.assertEqual(len(review), 1)
            self.assertTrue(review[0].startswith('README.md:2 '))

            (root / 'README.md').write_text('通話の音量を上げる。\n次に飛び石を蹴った。\n')
            for all_passages in (False, True):
                review = list(candidates(root, 'HEAD', all_passages=all_passages))
                self.assertEqual(len(review), 1)
                self.assertIn('動詞が表す操作', review[0])
