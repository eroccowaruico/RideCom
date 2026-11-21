"""List changed wording that needs a reader to check its meaning in context."""
import argparse
import re
import subprocess
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATHS = [
    'docs/*.md', 'docs/design/*.html', '.agents/skills/*.md', '*.xcstrings', '*/ja*.lproj/*.strings',
    'RideIntercom/*.swift', 'RideIntercomWatch/*.swift', 'RideIntercomWidgets/*.swift',
    'AGENTS.md', 'CLAUDE.md', 'README.md', '.github/copilot-instructions.md',
]
# These expressions identify passages to read. They do not prescribe replacements.
# A predicate without a known technical noun still deserves a contextual reading.
VERB_CUE = re.compile(r'走らせ|走って|走った|走る|叩[かきくけこい]|たた[かきくけこい]|投げ|吐[かきくけこい]|'
                      r'握り(?:つぶ|潰)|飲み込|流し込|蹴[らりるれろっ]|火を[吹噴]|(?:を|は)回[さしすせそ]')
VERB_QUESTION = '誰が何をすると、相手や画面にどんな変化がありますか。動詞が表す操作を確かめてください。'
QUESTIONS = [
    (VERB_CUE, VERB_QUESTION),
    (re.compile(r'再?試行|(?<![a-z])(?:retry|attempt)(?![a-z])', re.IGNORECASE),
     '何を始める、またはやり直す操作ですか。相手や結果は読み取れますか。'),
    (re.compile(r'適宜|必要に応じて|よしなに|差分を閉じる|\bas (?:needed|appropriate)\b', re.IGNORECASE),
     '誰が、どの条件で、何をするか分かりますか。'),
    (re.compile(r'対応済み?|確認済み?|検証済み?|改善済み?|\b(?:handled|verified|resolved)\b', re.IGNORECASE),
     'どの条件で何を観測しましたか。どこまで確認できましたか。'),
    (re.compile(r'(?<![A-Za-z0-9_])(?:TX|RX|JIT|E2E|SLO)(?![A-Za-z0-9_])'),
     'この読者に略語は通じますか。誰のどの動作か説明が必要ですか。'),
]
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', re.MULTILINE)


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(['git', *args], cwd=root).decode('utf-8')


def paths(root: Path, *args: str, all_passages: bool) -> set[str]:
    selected = PATHS if all_passages else [*PATHS, ':(exclude)RideIntercom/packages/**']
    return set(git(root, *args, '--', *selected).rstrip('\0').split('\0')) - {''}


def candidates(root: Path, base: str, *, all_passages: bool = False) -> Iterator[str]:
    changed = paths(root, 'diff', '--name-only', '-z', base, all_passages=all_passages)
    new = paths(root, 'ls-files', '--others', '--exclude-standard', '-z', all_passages=all_passages)
    for name in sorted(changed | new):
        path = root / name
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8'
        lines = data.decode(encoding).split('\n')
        if name in new or encoding == 'utf-16':
            spans = [(1, len(lines))]
        else:
            patch = git(root, 'diff', '--no-ext-diff', '--no-color', '-U0', base, '--', name)
            spans = [(int(start), int(count or '1')) for start, count in HUNK.findall(patch)]
        for start, count in spans:
            for number in range(start, start + count):
                line = lines[number - 1]
                if all_passages:
                    # Include every edited line with Japanese script, even when no
                    # registered expression (or opening Swift quote) is on this line.
                    if re.search(r'[ぁ-ヿ一-龯々]', line):
                        question = VERB_QUESTION if VERB_CUE.search(line) else '読み手に具体的な操作と結果が伝わるかを読む。'
                        yield f'{name}:{number}  {question}'
                    continue
                if path.suffix == '.swift' and '"' not in line:
                    continue
                for pattern, question in QUESTIONS:
                    words = list(dict.fromkeys(pattern.findall(line)))
                    if words:
                        yield f'{name}:{number}  {" / ".join(words)}  {question}'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='HEAD', help='commit to compare with the working tree')
    parser.add_argument('--all-passages', action='store_true',
                        help='list all changed Japanese passages, including unregistered expressions')
    args = parser.parse_args()
    for finding in candidates(ROOT, args.base, all_passages=args.all_passages):
        print(finding)
    print('候補の抽出が終わりました。変更した文章は元の指示・操作と照合してください。')
