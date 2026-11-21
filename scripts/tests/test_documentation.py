import tempfile
import unittest
from pathlib import Path

from scripts.check_documentation import check, check_backlog


class DocumentationTests(unittest.TestCase):
    def fixture(self, root: Path) -> None:
        (root / 'docs').mkdir()
        (root / 'README.md').write_text('[guide](docs/guide.md)\n')
        (root / 'docs/guide.md').write_text('# Guide\n')

    def test_design_html_rejects_svg_and_section_with_the_same_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            designs = root / 'docs/design'
            designs.mkdir()
            (designs / 'sample.html').write_text(
                '<svg><symbol id="watch"></symbol></svg><a href="#watch">Watch</a><h2 id="watch">Watch</h2>')
            self.assertTrue(any('duplicate HTML id watch' in error for error in check(root)))

    def test_design_html_ids_are_scoped_to_each_document(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            designs = root / 'docs/design'
            designs.mkdir()
            for name in ('standard', 'advanced'):
                (designs / (name + '.html')).write_text('<svg><symbol id="watch-icon"/></svg><h2 id="watch">Watch</h2>')
            self.assertEqual(check(root), [])

    def test_broken_relative_link_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / 'docs/guide.md').write_text('[lost](lost.md)')
            self.assertTrue(any('missing link' in error for error in check(root)))

    def test_current_links_must_reach_a_backlog_heading(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            backlog = root / 'docs/backlog'
            backlog.mkdir()
            (backlog / '改善候補.md').write_text('# 候補\n\n## 通話（Wi-Fi）\n')
            history = root / 'docs/history'
            history.mkdir()
            (history / 'old.md').write_text('[当時の候補](../backlog/改善候補.md#旧見出し)')
            guide = root / 'docs/guide.md'
            guide.write_text('[今の候補](backlog/改善候補.md#通話wi-fi)\n[履歴](history/old.md)\n')
            self.assertEqual(check(root), [])

            guide.write_text(guide.read_text().replace('#通話wi-fi', '#旧見出し'))
            self.assertEqual(check(root), [
                'docs/guide.md: missing backlog heading backlog/改善候補.md#旧見出し',
            ])

    def test_audio_evidence_table_requires_decisions_and_resolvable_sources(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            folder = root / 'docs/validation'
            folder.mkdir()
            index = folder / 'README.md'
            (root / 'docs/guide.md').write_text('# Guide\n[検証](validation/README.md)\n## 測定値\n')
            heading = '## 音声の設定切替で守る動作と現在の品質'
            columns = '| 判断すること | 現在の判断 | 根拠 |'
            header = f'# 検証状況と証跡\n\n{heading}\n\n{columns}\n|---|---|---|\n'
            row = '| 現在の結果 | 上限を超えた | [証拠](../guide.md#測定値) |\n'
            source = '[証拠](#検証状況と証跡)'
            rows = ''.join(f'| {name} | 記録あり | {source} |\n' for name in (
                '維持する実装と理由', '壊れた条件', '測った限界と未確認の範囲', '利用者に保証する目標', '次に試す改善',
            ))
            index.write_text(header.replace(columns, '対象は設定の切替。\n\n' + columns) + rows + row)
            self.assertEqual(check(root), [])

            for broken, message in [
                ('# 検証結果を読む\n', 'この見出しが1つ必要'),
                (header.replace(heading, '## 参考例') + rows + row, 'この見出しが1つ必要'),
                (header + rows + row + heading, 'この見出しが1つ必要'),
                (header.replace(columns, '| 現在の判断 | 判断すること | 根拠 |') + rows + row, '3列の表'),
                (header.replace('|---|---|---|', '|---|---|') + rows + row, '3列の表'),
                (header.replace(columns, '後の節に記録する。\n\n## 別の節\n' + columns) + rows + row, '3列の表'),
                (header + rows + row + row, '現在2件'),
                (header + rows + '\n## 別の節\n' + row, '「現在の結果」の行が1つ必要'),
                (header + rows + row.replace('上限を超えた', ' '), '3列すべてに内容が必要'),
                (header + rows + row.replace('[証拠](../guide.md#測定値)', ''), '3列すべてに内容が必要'),
                (header + rows + row.replace('[証拠](../guide.md#測定値)', '調査記録'), '見出しへのリンクが必要'),
                (header + rows + row.replace('../guide.md#測定値', '../guide.md'), '見出しへのリンクが必要'),
                (header + rows + row.replace('guide.md', 'missing.md'), '根拠の文書が見つかりません'),
                (header + rows + row.replace('測定値', '過去の値'), '根拠の見出しが見つかりません'),
                (header + rows + row.replace('測定値)', '測定値) [古い出典](#欠落)'), '根拠の見出しが見つかりません'),
            ]:
                with self.subTest(message=message, broken=broken):
                    index.write_text(broken)
                    self.assertTrue(any(message in error for error in check(root)))

    def test_unindexed_document_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / 'docs/orphan.md').write_text('Still useful information')
            self.assertTrue(any('not reachable' in error for error in check(root)))

    def test_settings_controls_in_each_file_require_specification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            settings = root / 'RideIntercom/UI/Settings'
            for mode in ('Common', 'Standard'): (settings / mode).mkdir(parents=True)
            (settings / 'Common/SettingsView.swift').write_text('.accessibilityIdentifier("rootSetting")')
            (settings / 'Common/SettingsPanels.swift').write_text('.accessibilityIdentifier("panelSetting")')
            (settings / 'Standard/StandardSettingsView.swift').write_text('.accessibilityIdentifier("standardSetting")')
            other = root / 'RideIntercom/UI/Call'
            other.mkdir(parents=True)
            (other / 'CallView.swift').write_text('.accessibilityIdentifier("otherFeature")')
            spec = root / 'docs/spec/App/UI/Settings.md'
            spec.parent.mkdir(parents=True)
            spec.write_text('# Settings\n`rootSetting`')
            (root / 'docs/guide.md').write_text('[settings](spec/App/UI/Settings.md)')
            errors = check(root)
            self.assertTrue(any('panelSetting' in error for error in errors))
            self.assertTrue(any('standardSetting' in error for error in errors))
            self.assertFalse(any('otherFeature' in error for error in errors))
            spec.write_text('# Settings\n`rootSetting` `panelSetting` `standardSetting`')
            self.assertEqual(check(root), [])

    def test_empty_document_directory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / 'docs/obsolete/nested').mkdir(parents=True)
            self.assertTrue(any('empty directory' in error for error in check(root)))

    def test_backlog_requires_one_index_link_per_issue_heading(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            backlog = root / 'docs/backlog'
            backlog.mkdir()
            with (root / 'README.md').open('a') as entry:
                entry.write('[backlog](docs/backlog/README.md)\n')
            (backlog / '未実装課題.md').write_text(
                '## 通話（Wi-Fi）\n\n### 再接続\n\n## 再開待ち\n')
            index = backlog / 'README.md'
            active = '| [通話](未実装課題.md#通話wi-fi) | 改善 | 調査中 | 発話を測る |\n'
            paused = '| [再開待ち](未実装課題.md#再開待ち) | 機能 | 中断 | 指示待ち |\n'
            index.write_text(f'## 着手順\n\n{active}\n## 判断や再開を待つもの\n\n{paused}')
            self.assertEqual(check(root), [])

            for broken, message in [
                (active + active, 'duplicate index link #通話wi-fi'),
                (active.replace('通話wi-fi', '通話'), 'unknown detail heading #通話'),
                (active.replace('通話wi-fi', '再接続'), 'unknown detail heading #再接続'),
                (active.replace('改善', '運用'), 'invalid backlog classification 運用'),
            ]:
                with self.subTest(message=message):
                    index.write_text(f'## 着手順\n\n{broken}\n## 判断や再開を待つもの\n\n{paused}')
                    self.assertTrue(any(message in error for error in check(root)))

            index.write_text(f'## 着手順\n\n{active}\n')
            self.assertTrue(any('unindexed detail heading #再開待ち' in error for error in check(root)))

    def test_backlog_requires_each_design_item_and_complete_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            backlog = Path(tmp)
            (backlog / '未実装課題.md').write_text('# 未実装課題\n')
            (backlog / '画面実装とデザイン見本の差分.md').write_text(
                '## 通話\n\n### 操作列\n\n### 接続の表示\n')
            (backlog / '改善候補.md').write_text('## 長押しを検討する\n')
            index = backlog / 'README.md'
            active = '| [操作列](画面実装とデザイン見本の差分.md#操作列) | デザイン | 未着手 | 実画面で照合する |\n'
            paused = '| [接続の表示](画面実装とデザイン見本の差分.md#接続の表示) | デザイン | 機能待ち | 接続の実装と同時に直す |\n'
            for current, waiting, message in [
                (active, paused, None),
                (active, '', 'unindexed detail heading #接続の表示'),
                (active, active + paused, 'duplicate index link #操作列'),
                (active.replace('#操作列', '#通話'), paused, 'unknown detail heading #通話'),
                (active, paused.replace(' | デザイン | ', ' | 改善 | '), 'invalid design classification 改善'),
                (active, paused.replace('機能待ち', ''), 'incomplete backlog row'),
                (active + '| 実機だけの確認 | 改善 | 実機待ち | 計測する |\n', paused, 'missing backlog detail link'),
                (active, paused + '| [長押し](改善候補.md#長押しを検討する) | デザイン | 採用前 | 点検する |\n',
                 'invalid backlog detail link'),
            ]:
                with self.subTest(message=message):
                    index.write_text(f'## 着手順\n\n{current}\n## 判断や再開を待つもの\n\n{waiting}')
                    if message:
                        self.assertTrue(any(message in error for error in check_backlog(backlog)))
                    else:
                        self.assertEqual(check_backlog(backlog), [])

    def test_agent_entrypoint_links_are_checked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / 'AGENTS.md').write_text('[rules](docs/missing-rules.md)')
            with (root / 'README.md').open('a') as entry:
                entry.write('[agents](AGENTS.md)')
            self.assertTrue(any('missing link' in error for error in check(root)))

    def test_archived_source_fence_preserves_obsolete_links(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / 'docs/guide.md').write_text(
                '# Historical plan\n~~~~markdown\n[old](deleted.md)\n'
                '```swift\nlet example = 1\n```\n`docs/deleted.md`\n~~~~\n')
            self.assertEqual(check(root), [])

    def test_space_paths_and_examples_are_supported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fixture(root)
            (root / 'docs/two words.md').write_text('details')
            (root / 'docs/guide.md').write_text('[details](<two words.md>)\n```markdown\n[example](does-not-exist.md)\n```\n')
            self.assertEqual(check(root), [])


if __name__ == '__main__': unittest.main()
