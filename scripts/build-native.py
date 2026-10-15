#!/usr/bin/env python3
"""Stage and verify native apps before replacing an installed bundle. No MCP/config edits."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import platform
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def build(destination, identity, names):
    destination.mkdir(parents=True, exist_ok=True)
    for name, source, identifier in names:
        app = destination / f'{name}.app'
        if app.exists():
            raise ValueError(f'Refusing to overwrite build output: {app}')
        binary = app / 'Contents/MacOS' / name
        binary.parent.mkdir(parents=True)
        run('swiftc', '-O', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macos14.0', '-o', binary, REPO / source)
        info = dict(CFBundleName=name, CFBundleIdentifier=identifier, CFBundleExecutable=name,
                    CFBundlePackageType='APPL', CFBundleShortVersionString='2.3.0',
                    CFBundleVersion='230', LSUIElement=True, LSMinimumSystemVersion='14.0',
                    CuaSourceHash=hashlib.sha256((REPO / source).read_bytes()).hexdigest())
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--timestamp=none', '--sign', identity, app)
        run('codesign', '--verify', '--strict', '--verbose=2', app)
        result = run('codesign', '-dr', '-', app, capture_output=True, text=True)
        requirement = result.stdout + result.stderr
        if 'certificate' not in requirement or 'cdhash H' in requirement:
            raise ValueError(f'{name} must have a certificate-bound designated requirement, not ad-hoc signing')
        print(f'{name}: {requirement.strip()}')


def install(staging, destination, names):
    # Keep a rollback bundle; never remove an app until every replacement is signed.
    for name, _, identifier in names:
        current = destination / f'{name}.app'
        backup = destination / f'{name}.app.previous'
        if current.is_symlink() or backup.exists():
            raise ValueError(f'Inspect existing symlink/rollback before installing: {current}, {backup}')
        if current.exists():
            info = plistlib.loads((current / 'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') != identifier:
                raise ValueError(f'Refusing to replace an unrelated app: {current}')
    for name, _, _ in names:
        current = destination / f'{name}.app'
        backup = destination / f'{name}.app.previous'
        # Target only this installed executable, not helpers belonging to other installations.
        result = subprocess.run(['pgrep', '-f', f'^{re.escape(str(current / "Contents/MacOS" / name))}$'], capture_output=True, text=True)
        for pid in result.stdout.split():
            run('kill', '-TERM', pid)
        moved = current.exists()
        if moved:
            current.rename(backup)
        try:
            (staging / f'{name}.app').rename(current)
        except Exception:
            if moved:
                backup.rename(current)
            raise
        print(f'Installed {current}; previous bundle retained at {backup}' if moved else f'Installed {current}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', default=os.environ.get('CUA_SIGNING_IDENTITY', 'CUA Local Development'))
    parser.add_argument('--build-only', type=Path, help='empty output directory; do not install or restart')
    parser.add_argument('--apps-dir', type=Path, default=Path.home() / 'Applications')
    parser.add_argument('--agent-only', action='store_true')
    args = parser.parse_args()
    names = [('CuaAgent', 'agent/CuaAgent.swift', 'com.andymsun.cua.agent')]
    if not args.agent_only:
        names.append(('CuaPreview', 'hud/CuaPreview.swift', 'com.andymsun.cua.preview'))
    if args.build_only:
        build(args.build_only, args.identity, names)
        return
    args.apps_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cua-stage-', dir=args.apps_dir) as temporary:
        staging = Path(temporary)
        build(staging, args.identity, names)
        install(staging, args.apps_dir, names)
    run('open', '-g', '-j', args.apps_dir / 'CuaAgent.app')


if __name__ == '__main__':
    main()
