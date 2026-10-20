#!/usr/bin/env python3
"""Stage and verify native apps before replacing an installed bundle. No MCP/config edits."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def build(destination, identity, names, isolated=False, runtime_dir=None):
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    runtime = Path.home() / 'Library/Application Support/cua/isolated' / hashlib.sha256(str(destination).encode()).hexdigest()[:12]
    if runtime_dir is not None:
        runtime = runtime_dir.expanduser().resolve()
    if isolated:
        runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        config = runtime / 'config.json'
        if not config.exists():
            config.write_text(json.dumps({'hud': {'enabled': False}, 'web': {'port': 0}}, indent=2) + '\n')
            config.chmod(0o600)
    for name, source, identifier in names:
        app = destination / f'{name}.app'
        if app.exists():
            raise ValueError(f'Refusing to overwrite build output: {app}')
        binary = app / 'Contents/MacOS' / name
        binary.parent.mkdir(parents=True)
        sources = [REPO / source]
        if source == 'hud/CuaPreview.swift':
            sources += [REPO / 'hud/PointerGeometry.swift', REPO / 'hud/Companion.swift', REPO / 'hud/CompanionComposer.swift', REPO / 'hud/CompanionDrafts.swift', REPO / 'hud/CompanionHub.swift', REPO / 'hud/CompanionVoice.swift']
        run('swiftc', '-O', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macos14.0', '-o', binary, *sources)
        info = dict(CFBundleName=name, CFBundleIdentifier=identifier, CFBundleExecutable=name,
                    CFBundlePackageType='APPL', CFBundleShortVersionString='2.3.0',
                    CFBundleVersion='230', LSUIElement=True, LSMinimumSystemVersion='14.0',
                    CuaSourceHash=hashlib.sha256(b''.join(p.read_bytes() for p in sources)).hexdigest())
        if source == 'hud/CuaPreview.swift':
            info.update(NSMicrophoneUsageDescription='Record a command while you hold Talk, or dictation after you start it.',
                        NSSpeechRecognitionUsageDescription='Transcribe your voice input on this Mac.')
        if name == 'AndyBarista':
            resources = app / 'Contents/Resources/runtime'
            dependency = REPO / 'node_modules/playwright-core'
            if not dependency.is_dir():
                raise ValueError('Run npm ci before building the standalone companion')
            shutil.copytree(REPO / 'server', resources / 'server')
            shutil.copytree(dependency, resources / 'node_modules/playwright-core')
            shutil.copy2(REPO / 'LICENSE', resources / 'LICENSE')
            for helper in ['CuaAgent', 'CuaPreview']:
                shutil.copytree(destination / f'{helper}.app', app / 'Contents/Helpers' / f'{helper}.app')
            info.update(CFBundleDisplayName='Andy Barista', CuaCLIPath='Contents/Resources/runtime/server/cli.mjs',
                        CuaNodePath=shutil.which('node') or '/usr/bin/node',
                        CuaPreviewPath='Contents/Helpers/CuaPreview.app', CuaAgentPath='Contents/Helpers/CuaAgent.app')
        if isolated and name != 'CuaAgent':
            info.update(CuaRunDir=str(runtime), CuaConfigPath=str(runtime / 'config.json'))
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
    parser.add_argument('--isolated', action='store_true', help='with --build-only: use a separate local run directory and config')
    parser.add_argument('--runtime-dir', type=Path, help='with --isolated: keep an existing companion runtime and history')
    args = parser.parse_args()
    if args.runtime_dir and not args.isolated:
        parser.error('--runtime-dir needs --isolated')
    if args.isolated and not args.build_only:
        parser.error('--isolated needs --build-only')
    names = [('CuaAgent', 'agent/CuaAgent.swift', 'com.andymsun.cua.agent')]
    if not args.agent_only:
        names.append(('CuaPreview', 'hud/CuaPreview.swift', 'com.andymsun.cua.preview'))
        names.append(('AndyBarista', 'hud/CuaPreview.swift', 'com.andymsun.cua.barista'))
    if args.build_only:
        build(args.build_only, args.identity, names, args.isolated, args.runtime_dir)
        return
    args.apps_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cua-stage-', dir=args.apps_dir) as temporary:
        staging = Path(temporary)
        build(staging, args.identity, names)
        install(staging, args.apps_dir, names)
    run('open', '-g', '-j', args.apps_dir / 'CuaAgent.app')


if __name__ == '__main__':
    main()
