import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cp, mkdir, mkdtemp, rm, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

const project = fileURLToPath(new URL('../../', import.meta.url));

test('git commit checks staged prose, UI and rule changes; unrelated commits can run without packages', async t => {
    const repo = await mkdtemp(path.join(tmpdir(), 'ridecom-commit-test-'));
    t.after(() => rm(repo, {recursive: true, force: true}));
    const git = (...args) => spawnSync('git', args, {cwd: repo, encoding: 'utf8'});
    function success(...args) {
        const result = git(...args);
        assert.equal(result.status, 0, result.stderr);
    }
    success('init', '--quiet', '--template=');
    success('config', 'user.name', 'Test');
    success('config', 'user.email', 'test@example.invalid');
    success('config', 'commit.gpgsign', 'false');
    success('config', 'core.hooksPath', '.githooks');
    for (const name of ['.githooks', 'scripts/lint_staged_text.py', 'tools/doc-lint']) {
        await cp(path.join(project, name), path.join(repo, name), {
            recursive: true, filter: source => path.basename(source) !== 'node_modules'
        });
    }
    await writeFile(path.join(repo, '.gitignore'), 'node_modules\n');
    await symlink(path.join(project, 'tools/doc-lint/node_modules'), path.join(repo, 'tools/doc-lint/node_modules'), 'dir');
    success('add', '.');
    success('commit', '-qm', 'initial');
    const document = path.join(repo, 'README.md');
    const bad = '設定を変更することができます。\n';
    const good = '設定を変更できます。\n';
    await writeFile(document, bad);
    success('add', 'README.md');
    await writeFile(document, good);
    const failure = git('commit', '-qm', 'staged error');
    assert.notEqual(failure.status, 0);
    assert.match(failure.stderr, /ja-no-redundant-expression/);
    success('add', 'README.md');
    await writeFile(document, bad);
    success('commit', '-qm', 'only staged content');
    assert.equal(git('show', 'HEAD:README.md').stdout, good);
    await mkdir(path.join(repo, 'RideIntercom'));
    await writeFile(path.join(repo, 'RideIntercom/Fixture.swift'), 'let label = "仕様の正本を確認する"\n');
    success('add', 'RideIntercom/Fixture.swift');
    assert.match(git('commit', '-qm', 'bad UI').stderr, /ridecom-ja\/document-authority/);
    success('reset', '--quiet', 'HEAD', '--', 'RideIntercom/Fixture.swift');
    // Seed a pre-existing problem to check a policy-only change against the whole index.
    success('add', 'README.md');
    success('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'historical example');
    await writeFile(path.join(repo, 'tools/doc-lint/lint.test.mjs'), '// changed test\n');
    success('add', 'tools/doc-lint/lint.test.mjs');
    assert.match(git('commit', '-qm', 'rule change').stderr, /ja-no-redundant-expression/);
    success('reset', '--quiet', 'HEAD', '--', 'tools/doc-lint/lint.test.mjs');
    await rm(path.join(repo, 'tools/doc-lint/node_modules'));
    await writeFile(path.join(repo, 'example.py'), 'pass\n');
    success('add', 'example.py');
    success('commit', '-qm', 'no wording changes');
    await writeFile(document, good);
    success('add', 'README.md');
    assert.match(git('commit', '-qm', 'missing packages').stderr, /npm ci/);
});
