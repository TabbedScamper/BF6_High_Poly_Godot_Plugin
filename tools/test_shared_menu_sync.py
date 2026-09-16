"""Parent-to-both-engines ownership checks in isolated filesystem fixtures."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import sync_shared_menu as sync


class SharedMenuOwnership(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.product = self.root/'godot'
        self.parent = self.root/'unreal'
        self.snapshot = self.product/'shared/menu'
        self.canonical = self.parent/'Shared/menu'
        self.addon = self.product/'addons/highpoly_toggle'
        self.installed = self.root/'installed'
        shutil.copytree(sync.PRODUCT/'shared/menu', self.snapshot)
        shutil.copytree(self.snapshot, self.canonical)
        self.addon.mkdir(parents=True)
        self.installed.mkdir()
        for name in sync.RUNTIME_DEFINITIONS:
            shutil.copy2(self.snapshot/name, self.addon/name)
            shutil.copy2(self.snapshot/name, self.installed/name)
        shutil.copy2(sync.PRODUCT/'addons/highpoly_toggle/highpoly_toggle.gd', self.addon/'highpoly_toggle.gd')
        (self.installed/'highpoly_toggle.gd').write_text('# Installed adapter fixture')
        (self.parent/'BF6HighPoly.uplugin').write_text('{}')
        cpp = self.parent/'Source/BF6HighPoly/Private/BF6HighPoly.cpp'
        cpp.parent.mkdir(parents=True)
        caps = sync.read_json(self.canonical/'adapters.json')
        cpp.write_text('const TMap<FString, FString> Ids = {\n' + '\n'.join('{TEXT("native_' + key + '"), TEXT("' + key + '")},' for key in caps['unreal']) + '\n};\nfor (auto& Pair : Bindings) {}')
        self.environment = patch.object(sync, 'PRODUCT', self.product)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def run_sync(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return sync.main(list(args))

    def parent_args(self, mode='--write'):
        return [mode, '--unreal-plugin', str(self.parent)]

    def test_parent_edit_flows_to_both_without_touching_installed(self):
        menu = sync.read_json(self.canonical/'menu.json')
        menu['controls']['detail_mode']['label'] = 'Parent-owned updated label'
        (self.canonical/'menu.json').write_text(json.dumps(menu))
        installed_theme = b'{"custom_installation_theme":"preserve"}'
        (self.installed/'theme.json').write_bytes(installed_theme)
        self.assertEqual(self.run_sync(*self.parent_args('--check')), 1)
        self.assertEqual(self.run_sync(*self.parent_args()), 0)
        for name in sync.DEFINITIONS:
            self.assertEqual((self.snapshot/name).read_bytes(), (self.canonical/name).read_bytes())
        for name in sync.RUNTIME_DEFINITIONS:
            for destination in (self.addon, self.parent/'Resources/theme'):
                self.assertEqual((destination/name).read_bytes(), (self.canonical/name).read_bytes())
        self.assertEqual((self.installed/'theme.json').read_bytes(), installed_theme)
        self.assertEqual(self.run_sync(*self.parent_args('--check')), 0)

    def test_stale_godot_cannot_override_parent(self):
        old = (self.canonical/'menu.json').read_bytes()
        stale = sync.read_json(self.snapshot/'menu.json')
        stale['controls']['detail_mode']['label'] = 'Stale local edit'
        (self.snapshot/'menu.json').write_text(json.dumps(stale))
        self.assertEqual(self.run_sync(*self.parent_args()), 0)
        self.assertEqual((self.canonical/'menu.json').read_bytes(), old)
        self.assertEqual((self.snapshot/'menu.json').read_bytes(), old)

    def test_invalid_parent_capability_stops_all_writes(self):
        before = (self.addon/'menu.json').read_bytes()
        menu = sync.read_json(self.canonical/'menu.json')
        menu['controls']['performance']['kind'] = 'action'
        (self.canonical/'menu.json').write_text(json.dumps(menu))
        self.assertEqual(self.run_sync(*self.parent_args()), 2)
        self.assertEqual((self.addon/'menu.json').read_bytes(), before)
        self.assertFalse((self.parent/'Resources/theme').exists())

    def test_standalone_is_read_only_and_snapshot_labelled(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(sync.main(['--check']), 0)
        self.assertEqual(json.loads(output.getvalue())['authority'], 'standalone_snapshot_freshness_unverified')
        with self.assertRaises(SystemExit):
            self.run_sync('--write')

    def test_missing_parent_requires_explicit_empty_promotion(self):
        for path in self.canonical.iterdir():
            path.unlink()
        self.assertEqual(self.run_sync(*self.parent_args()), 2)
        self.assertEqual(list(self.canonical.iterdir()), [])
        self.assertEqual(self.run_sync(*self.parent_args(), '--promote-snapshot'), 0)
        with self.assertRaises(SystemExit):
            self.run_sync(*self.parent_args(), '--promote-snapshot')

    def test_installed_is_updated_only_when_explicit(self):
        (self.installed/'theme.json').write_bytes(b'custom')
        self.assertEqual(self.run_sync(*self.parent_args(), '--installed-addon', str(self.installed)), 0)
        self.assertEqual((self.installed/'theme.json').read_bytes(), (self.canonical/'theme.json').read_bytes())


if __name__ == '__main__':
    unittest.main()
