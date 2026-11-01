#!/usr/bin/env python3
"""Fail builds when a new application-owned platform text client or software-keyboard request appears.

Physical responder/focus handling and diagnostic visibility observation are permitted. This is a focused
source guard, supplemented by runtime counters and real UI tests, not a proof against arbitrary reflection.
"""
from pathlib import Path
import argparse
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def inspect(platform, root=ROOT):
    folder = root / ('temple_os_swift' if platform == 'ios' else 'temple_os_kotlin')
    errors = []
    for path in folder.rglob('*'):
        if any(p in {'.build', 'build', '.gradle'} for p in path.parts):
            continue
        if '/Tests/' in str(path) or '/src/test/' in str(path) or 'UITests' in str(path) or '/src/androidTest/' in str(path):
            continue
        if path.suffix not in {'.swift', '.kt', '.java', '.xml', '.h', '.m', '.mm', '.c', '.cc', '.cpp'}:
            continue
        source = re.sub(r'/\*.*?\*/|//[^\n]*|<!--.*?-->', '', path.read_text(), flags=re.S)
        patterns = ([r'\b(?:UIKeyInput|UITextInput|UITextField|UITextView|UISearchBar|UISearchController|WKWebView|UIInputViewController)\b',
                     r'\b(?:TextField|SecureField|TextEditor|UIViewRepresentable)\b', r'\.searchable\s*\(', r'\b(?:inputView|inputAccessoryView)\s*[:={]',
                     r'\b(?:insertText|setMarkedText)\s*\(', r'\baddTextField\b']
                    if platform == 'ios' else
                    [r'\b(?:EditText|AutoCompleteTextView|MultiAutoCompleteTextView|SearchView|WebView|InputMethodManager|BaseInputConnection)\b',
                     r'\b(?:BasicTextField2?|OutlinedTextField|TextField|LocalSoftwareKeyboardController|LocalTextInputService|KeyboardOptions|startInputSession|establishTextInputSession|startStylusHandwriting)\b',
                     r'\b(?:showSoftInput|hideSoftInputFromWindow|toggleSoftInput|setInputType|setRawInputType|commitText|setComposingText)\s*\(',
                     r'\.show\s*\(\s*(?:WindowInsets(?:Compat)?\.)?Type\.ime\s*\(',
                     r'onCheckIsTextEditor\s*\(\s*\)\s*=\s*true', r'adjustResize|adjustPan', r'key\.use_device_keyboard'])
        for pattern in patterns:
            match = re.search(pattern, source)
            if match:
                errors.append(f'{path.relative_to(root)}: forbidden native text-entry construct: {match.group()}')
        if platform == 'android' and ('onCreateInputConnection' in source or re.search(r'\bInputConnection\b', source)):
            # The sole permitted override only counts a probe and returns null. An unreachable
            # `return null` elsewhere must not whitelist a real factory/connection branch.
            permitted = r'override\s+fun\s+onCreateInputConnection\([^)]*\)\s*:\s*InputConnection\?\s*\{\s*(?:imeDiagnostics\.connectionProbe\(\);?\s*)?return\s+null\s*\}'
            remaining, count = re.subn(permitted, '', source)
            remaining = re.sub(r'import\s+android\.view\.inputmethod\.InputConnection\b', '', remaining)
            if path.name != 'TempleView.kt' or count != 1 or re.search(r'\b(?:InputConnection|onCreateInputConnection)\b', remaining):
                errors.append(f'{path.relative_to(root)}: input connections must be the non-editor null override')
        if platform == 'android' and re.search(r'\bTextView\s*\(', source) and path.name != 'BenchMode.kt':
            errors.append(f'{path.relative_to(root)}: new TextView requires explicit non-editable review')
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['ios', 'android', 'all'], default='all')
    args = parser.parse_args()
    errors = [error for platform in (['ios', 'android'] if args.platform == 'all' else [args.platform]) for error in inspect(platform)]
    print('\n'.join(errors) if errors else f'{args.platform}: native software input architecture check passed')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
