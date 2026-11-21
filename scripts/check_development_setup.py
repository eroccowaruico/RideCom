#!/usr/bin/env python3
"""Read-only check of the shared Xcode / VS Code development contract."""
import json
from pathlib import Path
import subprocess
import sys


def load_project(root):
    return json.loads(subprocess.check_output([
        '/usr/bin/plutil', '-convert', 'json', '-o', '-',
        str(root / 'RideIntercom.xcodeproj/project.pbxproj'),
    ]))


def check_worker_editing_references(root, objects, worker_key, build_inputs):
    worker = objects.get(worker_key, {})
    if worker.get('isa') != 'PBXGroup':
        return ['Keep server as an Xcode group so its dependency and build directories are not synchronized.']

    errors = []
    required = {
        'src': 'PBXFileSystemSynchronizedRootGroup',
        'test': 'PBXFileSystemSynchronizedRootGroup',
        '.dev.vars.example': 'PBXFileReference',
        'package-lock.json': 'PBXFileReference',
        'package.json': 'PBXFileReference',
        'tsconfig.json': 'PBXFileReference',
        'wrangler.toml': 'PBXFileReference',
    }
    generated = {'.wrangler', 'node_modules', 'dist'}
    children = {}
    for key in worker.get('children', []):
        reference = objects[key]
        path = Path(reference.get('path', ''))
        if reference.get('sourceTree') != '<group>' or path.is_absolute() or not path.parts or '..' in path.parts:
            errors.append('Worker editing references must point to paths inside server.')
            continue
        name = path.as_posix()
        if path.parts[0] in generated:
            errors.append(f'Do not add generated Worker paths to Xcode: server/{name}.')
            continue
        if name in children:
            errors.append(f'Duplicate Xcode navigator reference: server/{name}.')
        children[name] = reference.get('isa')
        if not (root / 'server' / path).exists():
            errors.append(f'Missing Xcode navigator reference: server/{name}.')
        if key in build_inputs:
            errors.append(f'server/{name} is editing-only and must not be a build input.')
    for name, reference_type in required.items():
        if children.get(name) != reference_type:
            errors.append(f'Keep the Xcode editing reference for server/{name} as {reference_type}.')
    return errors


def check(root):
    errors = []
    project = load_project(root)
    objects = project['objects']
    package_paths = {obj['relativePath'] for obj in objects.values()
                     if obj.get('isa') == 'XCLocalSwiftPackageReference'}
    for obj in objects.values():
        if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup':
            directory = (root / obj.get('path', '')).resolve()
            if (root / 'RideIntercom.xcodeproj').resolve().is_relative_to(directory):
                errors.append('Do not synchronize a folder containing the project itself; add its editing subfolders separately.')
            for folder in obj.get('explicitFolders', []):
                forced = (root / obj.get('path', '') / folder).resolve()
                if any((root / path).resolve().is_relative_to(forced) for path in package_paths):
                    errors.append('Do not force a local Swift package or its parent to a folder; Xcode must resolve the package container.')
    project_object = objects[project['rootObject']]
    for reference in project_object.get('projectReferences', []):
        obj = objects[reference['ProjectRef']]
        if obj.get('sourceTree') in ('<group>', 'SOURCE_ROOT', '<absolute>') and (root / obj.get('path', '')).resolve() == (root / 'RideIntercom.xcodeproj').resolve():
            errors.append('RideIntercom must not reference itself as a child project.')
    main = objects[project_object['mainGroup']]
    repository = root.resolve()
    visible = {}
    for key in main['children']:
        reference = objects[key]
        path = reference.get('path')
        if not path or reference.get('sourceTree') not in ('<group>', 'SOURCE_ROOT', '<absolute>'):
            continue
        resolved_path = (repository / path).resolve()
        in_repository = resolved_path.is_relative_to(repository)
        name = resolved_path.relative_to(repository).as_posix() if in_repository else str(resolved_path)
        if in_repository and not resolved_path.exists():
            errors.append(f'Missing Xcode navigator reference: {name}.')
        if name in visible:
            errors.append(f'Duplicate Xcode navigator reference: {name}.')
        else:
            visible[name] = key

    build_groups = {}
    for target in objects.values():
        if target.get('isa') == 'PBXNativeTarget':
            for key in target.get('fileSystemSynchronizedGroups', []):
                build_groups.setdefault(key, []).append(target['name'])

    editing_folders = ['docs', 'scripts', 'Configuration', '.vscode', '.codex', '.github', '.claude', '.agents']
    source_folders = ['RideIntercomTests', 'RideIntercomUITests', 'RideIntercomAudioE2ETests',
                      'RideIntercomWidgets', 'RideIntercomWatch', 'RideIntercomWatchUITests']
    for folder in source_folders + editing_folders:
        key = visible.get(folder)
        group = objects.get(key, {})
        if group.get('isa') != 'PBXFileSystemSynchronizedRootGroup':
            errors.append(f'{folder} must remain visible as a filesystem-synchronized folder.')
        elif folder in source_folders and build_groups.get(key) != [folder]:
            errors.append(f'{folder} must be synchronized only by the {folder} target.')
    build_files = {obj.get('fileRef') for obj in objects.values() if obj.get('isa') == 'PBXBuildFile'}
    for folder in editing_folders + ['server', '.gitignore', 'README.md', 'RideIntercom.code-workspace', 'AGENTS.md', 'CLAUDE.md']:
        key = visible.get(folder)
        if key is None:
            errors.append(f'Keep the explicit Xcode editing entry for {folder}.')
        elif key in build_groups or key in build_files:
            errors.append(f'{folder} is editing-only and must not be a build input.')
    errors.extend(check_worker_editing_references(root, objects, visible.get('server'), build_files | set(build_groups)))
    app_id = next(key for key,obj in objects.items() if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
    app = objects.get(visible.get('RideIntercom'), {})
    if app.get('isa') != 'PBXGroup':
        errors.append('Keep RideIntercom as an Xcode group so package build outputs are outside target synchronization.')
    app_directory = repository / 'RideIntercom'
    package_directory = app_directory / 'packages'
    synchronized_paths = {}
    for group_id in app.get('children', []):
        group = objects[group_id]
        if group.get('isa') != 'PBXFileSystemSynchronizedRootGroup':
            continue
        path = repository if group.get('sourceTree') == 'SOURCE_ROOT' else app_directory
        synchronized_paths[(path / group['path']).resolve()] = group_id
    for directory in sorted(p for p in app_directory.iterdir() if p.is_dir() and not p.name.startswith('.')
                            and p.suffix not in ('.icon', '.lproj') and p != package_directory):
        if build_groups.get(synchronized_paths.get(directory)) != ['RideIntercom']:
            errors.append(f'{directory.name} must be visible and synchronized only by the RideIntercom target.')
    package_group_id = synchronized_paths.get(package_directory)
    if package_group_id is None or package_group_id in build_groups or package_group_id in build_files:
        errors.append('Keep RideIntercom/packages visible for editing only.')
    for group_id in objects[app_id].get('fileSystemSynchronizedGroups', []):
        group = objects[group_id]
        path = repository if group.get('sourceTree') == 'SOURCE_ROOT' else app_directory
        directory = (path / group['path']).resolve()
        for package in sorted(package_paths):
            package_root = (repository / package).resolve()
            if package_root.is_relative_to(directory) or directory.is_relative_to(package_root):
                errors.append(f'App synchronized groups must not overlap the local Swift package root {package}.')
    settings = json.loads((root / '.vscode/settings.json').read_text())
    if settings.get('explorer.excludeGitIgnore') is not False or settings.get('explorer.fileNesting.enabled') is not False:
        errors.append('VS Code must show ignored files and disable file nesting.')
    if any(value is not False for value in settings.get('files.exclude', {}).values()):
        errors.append('VS Code files.exclude must not hide repository contents.')
    workspace = json.loads((root / 'RideIntercom.code-workspace').read_text())
    if not any(folder['path'] == '.' for folder in workspace['folders']):
        errors.append('VS Code workspace must include the entire repository root.')
    if workspace.get('settings') != settings:
        errors.append('Workspace settings must match .vscode/settings.json, including package roots.')
    if {folder['path'] for folder in workspace['folders']} != package_paths | {'.'}:
        errors.append('VS Code workspace must include the repository and every local Swift package.')
    tasks = json.loads((root / '.vscode/tasks.json').read_text())['tasks']
    for task in tasks:
        if task.get('type') != 'process' or task.get('options', {}).get('cwd') != '${workspaceFolder}':
            errors.append(f"Task {task['label']} must use a process in the repository root.")
        command = task['command']
        if command.startswith('${workspaceFolder}/') and not (root / command.removeprefix('${workspaceFolder}/')).is_file():
            errors.append(f'Missing task command: {command}')
    return errors


if __name__ == '__main__':
    try:
        errors = check(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        errors = [str(error)]
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        sys.exit(1)
    subprocess.run([sys.executable, str(Path(__file__).with_name('check_platform_configuration.py'))], check=True)
    print('Xcode / VS Code development setup: OK')
