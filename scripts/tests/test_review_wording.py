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
