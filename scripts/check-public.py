#!/usr/bin/env python3
"""Bounded static checks for a source publication; no network or device access."""
from pathlib import Path
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ALLOWED_ROOTS = {'Sources', 'Tests', 'scripts', 'Resources', 'docs'}
ALLOWED_FILES = {'.gitignore', 'README.md', 'README.de.md', 'LICENSE', 'CHANGELOG.md'}
SKIP_ROOTS = {'.git', 'dist', '.build', '.ui-test-artifacts'}
PATTERNS = {
    'private signing key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub token': re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'access key': re.compile(rb'AKIA[0-9A-Z]{16}'),
    'private IPv4': re.compile(rb'\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b'),
    'absolute home path': re.compile(('/' + r'Users/(?!example(?:-user)?/)[A-Za-z0-9_.-]+/').encode()),
    'machine volume path': re.compile(('(?<!System)/' + r'Volumes/(?!Example|M5-Tests-Absent-)[A-Za-z0-9_ -]+/').encode()),
}

def findings(data):
    return [name for name, pattern in PATTERNS.items() if pattern.search(data)]

def main():
    issues = []
    scanned = 0
    for file in sorted(ROOT.rglob('*')):
        relative = file.relative_to(ROOT)
        if relative.parts[0] in SKIP_ROOTS or '__pycache__' in relative.parts:
            continue
        if file.is_symlink():
            issues.append((str(relative), 'unexpected symbolic link')); continue
        if not file.is_file():
            continue
        if relative.parts[0] not in ALLOWED_ROOTS and str(relative) not in ALLOWED_FILES:
            issues.append((str(relative), 'unexpected publication file')); continue
        if file.suffix in {'.p12', '.p8', '.key', '.mobileprovision', '.zip', '.log'}:
            issues.append((str(relative), 'private or generated artifact in source')); continue
        if file.stat().st_size > 2 * 1024 * 1024:
            issues.append((str(relative), 'unexpected large source file')); continue
        for rule in findings(file.read_bytes()):
            issues.append((str(relative), rule))
        scanned += 1
    catalog = json.loads((ROOT / 'Resources/Localizations.json').read_text())
    for key, translations in catalog.items():
        if set(translations) != {'de', 'en'}:
            issues.append(('Resources/Localizations.json', 'missing language'))
        for value in translations.values():
            if sorted(re.findall(r'\{\d+\}', value)) != sorted(re.findall(r'\{\d+\}', key)):
                issues.append(('Resources/Localizations.json', 'placeholder mismatch'))
    # If initialized, inspect all reachable blobs, not just the checkout.
    git_dir = ROOT / '.git'
    if git_dir.exists():
        history = subprocess.run(['git', '-C', str(ROOT), 'rev-list', '--objects', '--all'], check=True, capture_output=True, text=True)
        for record in history.stdout.splitlines():
            oid, _, name = record.partition(' ')
            kind = subprocess.check_output(['git', '-C', str(ROOT), 'cat-file', '-t', oid], text=True).strip()
            if kind == 'blob':
                data = subprocess.check_output(['git', '-C', str(ROOT), 'cat-file', 'blob', oid])
                for rule in findings(data): issues.append(('history:' + name, rule))
        remotes = subprocess.check_output(['git', '-C', str(ROOT), 'remote', '-v'])
        for rule in findings(remotes): issues.append(('Git remotes', rule))
    if issues:
        for file, rule in issues: print(f'FAIL {file}: {rule}', file=sys.stderr)
        return 1
    print(f'PASS: {scanned} publication files, {len(catalog)} bilingual messages; no static findings')
    print('Static checks complement human review; they do not prove that arbitrary content is public.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
