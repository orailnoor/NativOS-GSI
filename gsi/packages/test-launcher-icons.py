import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('manager', Path(__file__).with_name('nativos-packages.py'))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)

class LauncherTests(unittest.TestCase):
    def test_packaged_icon_and_original_app_id(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root, home = base / 'root', base / 'home'
            apps = root / 'usr/share/applications'
            apps.mkdir(parents=True)
            icon = root / 'usr/share/icons/hicolor/scalable/apps/demo.svg'
            icon.parent.mkdir(parents=True)
            icon.write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
            (apps / 'org.example.Demo.desktop').write_text('[Desktop Entry]\nType=Application\nName=Demo\nIcon=demo\nExec=demo\n')
            with patch.object(Path, 'home', return_value=home):
                manager.export_launchers(root)
                alias = home / '.local/share/applications/org.example.Demo.desktop'
                self.assertIn('Exec=/usr/local/bin/nativos-packages run "/usr/bin/demo"', alias.read_text())
                self.assertIn(str(home / '.local/share/icons/nativos-packages'), alias.read_text())
                self.assertIn('Hidden=true', next(alias.parent.glob('nativos-pkg-*.desktop')).read_text())
                alias.write_text('[Desktop Entry]\nExec=/usr/bin/other\n')
                manager.export_launchers(root)
                self.assertEqual(alias.read_text(), '[Desktop Entry]\nExec=/usr/bin/other\n')

    def test_escape_and_control_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / 'root'
            root.mkdir()
            outside = base / 'outside.png'
            outside.write_bytes(b'dummy')
            (root / 'evil.png').symlink_to(outside)
            with patch.object(Path, 'home', return_value=base / 'home'):
                self.assertEqual(manager.exported_icon(root, '/evil.png'), 'application-x-executable')
                self.assertEqual(manager.exported_icon(root, 'icon\nExec=oops'), 'application-x-executable')
            with self.assertRaises(ValueError):
                manager.desktop_arguments('/usr/bin/../bad')

if __name__ == '__main__':
    unittest.main()
