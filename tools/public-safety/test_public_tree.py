"""Regression checks for signing identifiers and local configuration in public commits."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('public_tree', Path(__file__).with_name('check_public_tree.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class SigningPrivacyTests(unittest.TestCase):
    # Build synthetic identifiers at runtime so test fixtures do not resemble published account IDs.
    team = b'ABCD' + b'123456'

    def test_identifiers_in_project_generator_docs_and_export_plist_are_rejected(self):
        cases = [
            ('project.pbxproj', b'DEVELOPMENT_TEAM = ' + self.team + b';'),
            ('project.pbxproj', b'DEVELOPMENT_TEAM = "' + self.team + b'";'),
            ('project.pbxproj', b'"DEVELOPMENT_TEAM[sdk=iphoneos*]" = ' + self.team + b';'),
            ('settings.json', b'{"teamID": "' + self.team + b'"}'),
            ('generator.py', b"STORE_TEAM = '" + self.team + b"'"),
            ('releasing.md', b'Apple team | `' + self.team + b'` |'),
            ('releasing.md', b'team `' + self.team + b'`'),
            ('export.plist', b'<key>teamID</key>\n<string>' + self.team + b'</string>'),
            ('entitlements.plist', b'<key>com.apple.developer.team-identifier</key><string>' + self.team + b'</string>'),
        ]
        for path, data in cases:
            with self.subTest(path=path):
                problems = checker.inspect(path, lambda: data)
                self.assertTrue(any('Apple signing team identifier' in p for p in problems))
                self.assertTrue(all(self.team.decode() not in p for p in problems))

    def test_signed_application_prefix_is_rejected(self):
        data = b'<key>application-identifier</key><string>' + self.team + b'.com.example.app</string>'
        problems = checker.inspect('entitlements.plist', lambda: data)
        self.assertTrue(any('Apple signing application prefix' in p for p in problems))

    def test_force_added_local_configuration_is_rejected(self):
        problems = checker.inspect('Config/Signing.local.xcconfig', lambda: b'// local')
        self.assertTrue(any('local Apple signing configuration' in p for p in problems))

    def test_shared_include_and_variable_references_are_allowed(self):
        data = b'#include? "Signing.local.xcconfig"\nDEVELOPMENT_TEAM = $(LOCAL_TEAM)\n'
        self.assertEqual(checker.inspect('Config/Signing.xcconfig', lambda: data), [])


if __name__ == '__main__':
    unittest.main()
