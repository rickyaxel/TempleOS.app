"""Regression fixtures for defects that the former catalog validator could miss."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import validate


class CatalogValidationTests(unittest.TestCase):
    def setUp(self):
        validate.errors.clear()
        validate.warnings.clear()

    def test_duplicate_json_identifiers_are_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'duplicate.json'
            file.write_text('{"button.ok":"OK", "button.ok":"WRONG"}')
            validate.load(file)
            self.assertTrue(any('duplicate identifier button.ok' in e for e in validate.errors))

    def test_english_and_translations_reject_invalid_values(self):
        for value in ['', 42, '\ufffd', '\ud800', '\ue000', '{Count}', '{path', 'path}']:
            with self.subTest(value=repr(value)):
                validate.errors.clear()
                validate.check_values('en', {'test': value}, {})
                self.assertTrue(validate.errors)

    def test_placeholder_multiplicity_is_checked_but_order_is_free(self):
        validate.check_values('test', {'test': '{second} / {first}'}, {'test': '{first} {second}'})
        self.assertEqual([], validate.errors)
        validate.check_values('test', {'test': '{first} {first}'}, {'test': '{first} {second}'})
        self.assertTrue(validate.errors)

    def test_locale_integrity_and_orphaned_files(self):
        original = Path(validate.L10N)
        manifest = json.loads((original / 'locales.json').read_text())
        manifest['locales'][0]['id'] = 'invalid locale!'
        manifest['locales'][1]['parent'] = 'absent'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'locales.json').write_text(json.dumps(manifest))
            for locale in manifest['locales']:
                (root / (locale['catalog'] + '.json')).write_text('{}')
            (root / 'unused.json').write_text('{}')
            with patch.object(validate, 'L10N', directory):
                validate.check_manifest()
            self.assertTrue(any('invalid locale identifier' in e for e in validate.errors))
            self.assertTrue(any('unknown parent' in e for e in validate.errors))
            self.assertTrue(any('orphaned catalog' in e for e in validate.errors))


if __name__ == '__main__':
    unittest.main()
