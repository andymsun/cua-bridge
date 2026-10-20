#!/usr/bin/env python3
"""Compile the real native helper and run lookup checks without launching any GUI app.

Usage: python3 scripts/test-lookup.py --scratch /absolute/scratch/directory
The generated main.swift excludes only the helper's socket/run-loop entry point.
"""
import argparse
import pathlib
import platform
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
args.scratch.mkdir(parents=True, exist_ok=True)
out = pathlib.Path(tempfile.mkdtemp(prefix='native-lookup-', dir=args.scratch))
source = (root / 'agent/CuaAgent.swift').read_text()
assert source.count('// MARK: - main') == 1, 'native entry-point boundary changed'
(out / 'main.swift').write_text(source.split('// MARK: - main')[0] + '\n' + (root / 'scripts/test-lookup.swift').read_text())
flags = ['-swift-version', '5', '-target', f'{platform.machine()}-apple-macos14.0']
subprocess.run(['swiftc', *flags, str(out / 'main.swift'), '-o', str(out / 'lookup-checks')], check=True)
subprocess.run([str(out / 'lookup-checks')], check=True)
subprocess.run(['swiftc', '-O', *flags, str(root / 'agent/CuaAgent.swift'), '-o', str(out / 'CuaAgent')], check=True)
print(f'PASS real native helper compiled: {out / "CuaAgent"}', flush=True)
bundle = out / 'LookupFixture.app'
(bundle / 'Contents/MacOS').mkdir(parents=True)
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.cua.NativeLookupFixture', 'CFBundleExecutable': 'LookupFixture',
    'CFBundleName': 'Native Lookup Fixture', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
}))
subprocess.run(['swiftc', *flags, str(root / 'scripts/fixtures/LookupFixture.swift'),
                '-o', str(bundle / 'Contents/MacOS/LookupFixture')], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)], check=True)
print(f'PASS LaunchServices fixture prepared, NOT launched: {bundle}', flush=True)
