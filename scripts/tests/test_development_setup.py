"""Keep synchronized editing folders visible without recursive self-project discovery."""
import copy
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import check_development_setup as setup

ROOT = Path(__file__).resolve().parents[2]


class DevelopmentSetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = setup.load_project(ROOT)

    def test_repository_and_editor_configuration(self) -> None:
        self.assertEqual(setup.check(ROOT), [])

    def test_worker_root_does_not_synchronize_generated_directories(self) -> None:
        objects = self.project['objects']
        main = objects[objects[self.project['rootObject']]['mainGroup']]
        worker = next(objects[key] for key in main['children'] if objects[key].get('path') == 'server')
        self.assertEqual(worker['isa'], 'PBXGroup')
        self.assertEqual({objects[key]['path'] for key in worker['children']
                          if objects[key]['isa'] == 'PBXFileSystemSynchronizedRootGroup'}, {'src', 'test'})

    def test_generated_worker_and_build_membership_refs_are_rejected(self) -> None:
        for unwanted in ('node_modules', 'dist', '.wrangler', 'src'):
            with self.subTest(path=unwanted):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                main = objects[objects[project['rootObject']]['mainGroup']]
                worker = next(objects[key] for key in main['children'] if objects[key].get('path') == 'server')
                if unwanted == 'src':
                    child = next(key for key in worker.get('children', []) if objects[key].get('path') == 'src')
                    target = next(obj for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget')
                    target.setdefault('fileSystemSynchronizedGroups', []).append(child)
                    expected = 'server/src is editing-only and must not be a build input.'
                else:
                    objects['GENERATED_WORKER'] = {'isa': 'PBXFileSystemSynchronizedRootGroup',
                                                  'path': unwanted, 'sourceTree': '<group>'}
                    worker.setdefault('children', []).append('GENERATED_WORKER')
                    expected = f'Do not add generated Worker paths to Xcode: server/{unwanted}.'
                with patch.object(setup, 'load_project', return_value=project):
                    self.assertIn(expected, setup.check(ROOT))


    def test_duplicate_root_path_is_rejected_even_with_a_different_spelling(self) -> None:
        project = copy.deepcopy(self.project)
        objects = project['objects']
        main = objects[objects[project['rootObject']]['mainGroup']]
        docs = next(objects[key] for key in main['children'] if objects[key].get('path') == 'docs')
        objects['DUPLICATE_DOCS'] = {**docs, 'path': './docs', 'sourceTree': 'SOURCE_ROOT'}
        main['children'].append('DUPLICATE_DOCS')
        with patch.object(setup, 'load_project', return_value=project):
            self.assertIn('Duplicate Xcode navigator reference: docs.', setup.check(ROOT))

    def test_root_navigator_references_must_resolve_to_existing_paths(self) -> None:
        for kind, path in [('PBXFileReference', 'retired-notes.md'),
                           ('PBXFileSystemSynchronizedRootGroup', 'retired-scripts')]:
            with self.subTest(kind=kind):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                main = objects[objects[project['rootObject']]['mainGroup']]
                objects['RETIRED_ENTRY'] = {'isa': kind, 'path': path, 'sourceTree': '<group>'}
                main['children'].append('RETIRED_ENTRY')
                with patch.object(setup, 'load_project', return_value=project):
                    self.assertIn(f'Missing Xcode navigator reference: {path}.', setup.check(ROOT))

    def test_watch_ui_sources_must_be_visible(self) -> None:
        project = copy.deepcopy(self.project)
        objects = project['objects']
        main = objects[objects[project['rootObject']]['mainGroup']]
        group_id = next(key for key in main['children'] if objects[key].get('path') == 'RideIntercomWatchUITests')
        main['children'].remove(group_id)
        with patch.object(setup, 'load_project', return_value=project):
            self.assertTrue(any('RideIntercomWatchUITests must remain visible' in error for error in setup.check(ROOT)))

    def test_source_folders_must_belong_only_to_their_target(self) -> None:
        for folder in ('RideIntercom', 'RideIntercomWatchUITests'):
            for failure in ('missing', 'additional-target'):
                with self.subTest(folder=folder, failure=failure):
                    project = copy.deepcopy(self.project)
                    objects = project['objects']
                    owner = next(obj for obj in objects.values()
                                 if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == folder)
                    group_id = owner['fileSystemSynchronizedGroups'][0]
                    if failure == 'missing':
                        owner['fileSystemSynchronizedGroups'].remove(group_id)
                    else:
                        other = next(obj for obj in objects.values()
                                     if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercomTests')
                        other['fileSystemSynchronizedGroups'].append(group_id)
                    with patch.object(setup, 'load_project', return_value=project):
                        group_path = Path(objects[group_id]['path']).name
                        expected = (f'{group_path} must be visible and synchronized only by the {folder} target.'
                                    if folder == 'RideIntercom' else
                                    f'{folder} must be synchronized only by the {folder} target.')
                        self.assertIn(expected, setup.check(ROOT))

    def test_package_folder_override_is_rejected(self) -> None:
        project = copy.deepcopy(self.project)
        group = next(obj for obj in project['objects'].values()
                     if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup'
                     and obj.get('path') == 'RideIntercom/packages')
        group['explicitFolders'] = ['CallControl']
        with patch.object(setup, 'load_project', return_value=project):
            self.assertTrue(any('force' in error and 'package' in error for error in setup.check(ROOT)))

    def test_self_project_reference_is_rejected(self) -> None:
        project = copy.deepcopy(self.project)
        project['objects']['SELF_PROJECT'] = {
            'isa': 'PBXFileReference', 'path': './RideIntercom.xcodeproj',
            'sourceTree': '<group>', 'lastKnownFileType': 'wrapper.pb-project',
        }
        project['objects'][project['rootObject']]['projectReferences'] = [
            {'ProjectRef': 'SELF_PROJECT'},
        ]
        with patch.object(setup, 'load_project', return_value=project):
            self.assertTrue(any('itself' in error for error in setup.check(ROOT)))


    def test_app_build_root_rejects_a_package_ancestor_even_with_membership_exceptions(self) -> None:
        project = copy.deepcopy(self.project)
        objects = project['objects']
        app_id = next(key for key, obj in objects.items()
                      if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
        objects['APP_PARENT'] = {'isa': 'PBXFileSystemSynchronizedRootGroup', 'path': 'RideIntercom',
                                 'sourceTree': 'SOURCE_ROOT', 'exceptions': ['APP_EXCEPTIONS']}
        objects['APP_EXCEPTIONS'] = {'isa': 'PBXFileSystemSynchronizedBuildFileExceptionSet', 'target': app_id,
                                     'membershipExceptions': ['packages/CallControl']}
        objects[app_id]['fileSystemSynchronizedGroups'].append('APP_PARENT')
        with patch.object(setup, 'load_project', return_value=project):
            self.assertIn('App synchronized groups must not overlap the local Swift package root RideIntercom/packages/CallControl.',
                          setup.check(ROOT))

    def test_package_editing_group_cannot_become_an_app_build_input(self) -> None:
        project = copy.deepcopy(self.project)
        objects = project['objects']
        package_group = next(k for k, v in objects.items() if v.get('path') == 'RideIntercom/packages')
        app = next(obj for obj in objects.values()
                   if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
        app['fileSystemSynchronizedGroups'].append(package_group)
        with patch.object(setup, 'load_project', return_value=project):
            self.assertIn('Keep RideIntercom/packages visible for editing only.', setup.check(ROOT))

    def test_app_build_root_rejects_a_folder_inside_a_package(self) -> None:
        project = copy.deepcopy(self.project)
        objects = project['objects']
        app = next(obj for obj in objects.values()
                   if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
        objects['GENERATED'] = {'isa': 'PBXFileSystemSynchronizedRootGroup', 'sourceTree': 'SOURCE_ROOT',
                                'path': 'RideIntercom/packages/CallControl/.build'}
        app['fileSystemSynchronizedGroups'].append('GENERATED')
        with patch.object(setup, 'load_project', return_value=project):
            self.assertIn('App synchronized groups must not overlap the local Swift package root RideIntercom/packages/CallControl.',
                          setup.check(ROOT))

    def test_synchronized_ancestor_is_rejected_even_with_folder_type_override(self) -> None:
        for path in ['.', '..', str(ROOT.resolve())]:
            with self.subTest(path=path):
                project = copy.deepcopy(self.project)
                project['objects']['RECURSIVE_ROOT'] = {
                    'isa': 'PBXFileSystemSynchronizedRootGroup', 'path': path,
                    'sourceTree': '<group>', 'explicitFileTypes': {'RideIntercom.xcodeproj': 'folder'},
                }
                with patch.object(setup, 'load_project', return_value=project):
                    self.assertTrue(any('containing the project' in error for error in setup.check(ROOT)))

    def test_editing_folder_must_stay_visible_and_synchronized(self) -> None:
        for folder in ['docs', '.agents']:
            for failure in ['detached', 'static-group']:
                with self.subTest(folder=folder, failure=failure):
                    project = copy.deepcopy(self.project)
                    objects = project['objects']
                    group_id = next(k for k,v in objects.items() if v.get('path') == folder)
                    if failure == 'detached':
                        main = objects[objects[project['rootObject']]['mainGroup']]
                        main['children'].remove(group_id)
                    else:
                        objects[group_id]['isa'] = 'PBXGroup'
                    with patch.object(setup, 'load_project', return_value=project):
                        self.assertTrue(any(f'{folder} must remain visible' in error for error in setup.check(ROOT)))

    def test_editing_only_folder_must_not_become_a_build_input(self) -> None:
        for folder in ['docs', '.agents']:
            for failure in ['target-group', 'build-file']:
                with self.subTest(folder=folder, failure=failure):
                    project = copy.deepcopy(self.project)
                    objects = project['objects']
                    group_id = next(k for k,v in objects.items() if v.get('path') == folder)
                    if failure == 'target-group':
                        target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget')
                        target.setdefault('fileSystemSynchronizedGroups', []).append(group_id)
                    else:
                        objects['EDITING_BUILD_FILE'] = {'isa': 'PBXBuildFile', 'fileRef': group_id}
                    with patch.object(setup, 'load_project', return_value=project):
                        self.assertTrue(any(f'{folder} is editing-only' in error for error in setup.check(ROOT)))

    def test_self_project_folder_reference_is_also_rejected(self) -> None:
        project = copy.deepcopy(self.project)
        project['objects']['SELF_FOLDER'] = {
            'isa': 'PBXFileReference', 'path': 'RideIntercom.xcodeproj',
            'sourceTree': '<group>', 'explicitFileType': 'folder',
        }
        project['objects'][project['rootObject']]['projectReferences'] = [{'ProjectRef': 'SELF_FOLDER'}]
        with patch.object(setup, 'load_project', return_value=project):
            self.assertTrue(any('itself' in error for error in setup.check(ROOT)))


if __name__ == '__main__':
    unittest.main()
