"""Synthetic negative controls for the publication scanner."""
from pathlib import Path
import importlib.util

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('publication_check', root / 'scripts/check-public.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

tests = [
    (b'gh' + b'p_' + b'A' * 30, 'GitHub token'),
    (b'github' + b'_pat_' + b'A' * 30, 'GitHub token'),
    (b'AK' + b'IA' + b'A' * 16, 'access key'),
    (b'-----BEGIN OPENSSH ' + b'PRIVATE KEY-----', 'private signing key'),
    (b'192.' + b'168.5.9', 'private IPv4'),
    (b'10.' + b'5.9.2', 'private IPv4'),
    (b'172.' + b'16.0.1', 'private IPv4'),
    (b'/' + b'Users/synthetic-person/file.txt', 'absolute home path'),
    (b'/' + b'Volumes/SecretVolume/project/', 'machine volume path'),
]
for data, rule in tests:
    assert rule in check.findings(data), rule
for data in [b'/sd/data.csv', b'/tmp/test.txt', b'/Volumes/ExampleBackup/M5', b'/System/Volumes/Data/Volumes/']:
    assert not check.findings(data), data
print(f'SUCCESS: {len(tests) + 4} publication-scanner controls; synthetic inputs only')
