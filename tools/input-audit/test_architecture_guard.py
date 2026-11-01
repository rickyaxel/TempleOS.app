#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path
from check_input_architecture import inspect


class GuardTests(unittest.TestCase):
    def check(self, platform, name, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / ('temple_os_swift' if platform == 'ios' else 'temple_os_kotlin')
            folder.mkdir()
            (folder / name).write_text(source)
            return inspect(platform, root)

    def test_ios_text_clients_and_requests_rejected(self):
        for source in ['extension Surface: UIKeyInput {}', 'let field = UITextField()', 'TextEditor(text: $x)', 'view.addTextField {}']:
            self.assertTrue(self.check('ios', 'Future.swift', source), source)
        self.assertTrue(self.check('ios', 'Future.m', '@interface Hidden : UIView <UIKeyInput> @end'))

    def test_plain_hardware_responder_and_diagnostics_allowed(self):
        self.assertFalse(self.check('ios', 'Keys.swift', 'class Keys: UIResponder { func pressesBegan() {} }; let event = UIResponder.keyboardWillShowNotification'))
        self.assertFalse(self.check('android', 'Keys.kt', 'view.requestFocus(); override fun onKeyDown(code: Int) = true'))

    def test_android_clients_and_ime_requests_rejected(self):
        for source in ['EditText(context)', 'BasicTextField(value)', 'manager.showSoftInput(view, 0)', 'controller.show(WindowInsets.Type.ime())', 'controller.show(WindowInsetsCompat.Type.ime())', 'manager.startStylusHandwriting(view)', 'class Client: BaseInputConnection(view, false)', 'override fun onCheckIsTextEditor() = true']:
            self.assertTrue(self.check('android', 'Future.kt', source), source)

    def test_only_non_editor_null_connection_is_permitted(self):
        self.assertFalse(self.check('android', 'TempleView.kt', 'override fun onCreateInputConnection(attrs: EditorInfo): InputConnection? { return null }'))
        self.assertTrue(self.check('android', 'Future.kt', 'override fun onCreateInputConnection(attrs: EditorInfo): InputConnection? { return null }'))
        self.assertTrue(self.check('android', 'TempleView.kt', 'override fun onCreateInputConnection(attrs: EditorInfo): InputConnection? { if (enabled) return factory(); return null }'))
        self.assertTrue(self.check('android', 'Future.kt', 'class HiddenClient : InputConnection {}'))

    def test_comments_do_not_create_false_alarms(self):
        self.assertFalse(self.check('ios', 'Keys.swift', '// UITextField was removed\nclass Keys: UIResponder {}'))


if __name__ == '__main__':
    unittest.main()
