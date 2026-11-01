"""Hardware automation guards; mocks ensure these tests never contact a device."""
import unittest
import io
from unittest.mock import patch
import android_target as target


class AndroidTargetTests(unittest.TestCase):
    def setUp(self):
        self.device = target.HardwareDevice('test-only')

    def test_global_settings_data_and_other_apps_are_rejected(self):
        for command in ['settings put system user_rotation 1', 'settings delete system user_rotation',
                        'wm size 720x1604', 'wm density reset', 'pm clear ' + target.BENCH,
                        'pm uninstall ' + target.BENCH, 'am force-stop com.digitalcircuitstudios.templeosapp']:
            with self.subTest(command=command), self.assertRaises(RuntimeError):
                self.device.shell(command)
        with self.assertRaises(RuntimeError):
            self.device.launch(clear=True)
        with self.assertRaises(RuntimeError):
            self.device.logcat_clear()

    def test_read_only_queries_and_app_rotation_use_expected_commands(self):
        with patch.object(target.ui.Device, 'shell', return_value='ok') as shell, \
             patch.object(target.time, 'sleep'), \
             patch.object(target.ui, 'ACT', target.BENCH + '/MainActivity'):
            self.assertEqual(self.device.shell('wm size'), 'ok')
            self.assertEqual(self.device.shell('settings get system user_rotation'), 'ok')
            self.device.rotate(True)
            self.assertEqual(shell.call_args.args[0], 'am start -W -f 0x20000000 -n ' + target.BENCH + '/MainActivity --es inputOrientation landscape')

    def test_install_rejects_production_package(self):
        with patch.object(target.Path, 'glob', return_value=[target.Path('/test/aapt2')]), \
             patch.object(target.subprocess, 'check_output', return_value="package: name='com.digitalcircuitstudios.templeosapp'"), \
             patch.object(target.ui.Device, 'install') as install:
            with self.assertRaises(RuntimeError):
                self.device.install('/test/app.apk')
            install.assert_not_called()

    def test_install_accepts_only_verified_bench_package(self):
        with patch.object(target.Path, 'glob', return_value=[target.Path('/test/aapt2')]), \
             patch.object(target.subprocess, 'check_output', return_value="package: name='" + target.BENCH + "' versionCode='1'"), \
             patch.object(target.ui.Device, 'install') as install:
            self.device.install('/test/app.apk')
            install.assert_called_once_with('/test/app.apk')

    def test_launch_is_app_local_and_does_not_clear_data(self):
        with patch.object(target.ui.Device, 'launch') as launch:
            self.device.launch(extras='--es engine native')
            launch.assert_called_once_with(clear=False, extras='--es engine native --es inputOrientation portrait --es inputLanguage en-US')

    def test_hardware_requires_explicit_opt_in(self):
        with patch.object(target.sys, 'argv', ['test', 'hardware-serial', '/test/output']), \
             patch.object(target.sys, 'stderr', io.StringIO()), \
             self.assertRaises(SystemExit):
            target.configure('test')

    def test_emulator_cannot_be_labeled_physical(self):
        with patch.object(target.sys, 'argv', ['test', 'emulator-5556', '/test/output', '--physical']), \
             patch.object(target.sys, 'stderr', io.StringIO()), \
             self.assertRaises(SystemExit):
            target.configure('test')

    def test_explicit_hardware_selects_bench_artifacts(self):
        with patch.object(target.sys, 'argv', ['test', 'hardware-serial', '/test/output', '--physical', '--cycles', '3']), \
             patch.object(target.Path, 'mkdir'), \
             patch.object(target.HardwareDevice, 'shell', return_value='0'):
            args, device, _, apk = target.configure('test')
            self.assertTrue(args.physical)
            self.assertEqual(args.cycles, 3)
            self.assertIsInstance(device, target.HardwareDevice)
            self.assertEqual(target.ui.PKG, target.BENCH)
            self.assertEqual(apk.name, 'app-bench.apk')


if __name__ == '__main__':
    unittest.main()
