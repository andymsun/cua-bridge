#!/usr/bin/env python3
"""Opt-in LaunchServices fixture checks; never starts or modifies CuaAgent or requests TCC.

Prepare the bundle with test-lookup.py, then run against the coordinator's tested helper:
  python3 scripts/test-lookup-live.py --socket /path/to/agent.sock \
    --fixture-app /path/to/LookupFixture.app --scratch /path/to/scratch \
    --launch-fixture --mode basic
Modes: basic, multi-window, occluded, sibling, long-name, large-tree, deep-tree, slow.
Each invocation opens one disposable fixture app through /usr/bin/open, then asks it to exit.
Optional --overlay-app starts a dedicated guide overlay in an otherwise unused pointer runtime.
The native helper must use that selected CUA_HUD_APP or the matching sibling preview bundle.
Do not touch the pointer or keyboard during checks. This deliberately tests the real AX tree.
"""
import argparse
import json
import pathlib
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--socket', required=True)
parser.add_argument('--fixture-app', required=True, type=pathlib.Path)
parser.add_argument('--scratch', required=True, type=pathlib.Path)
parser.add_argument('--overlay-app', type=pathlib.Path)
parser.add_argument('--overlay-populated', action='store_true')
parser.add_argument('--launch-fixture', action='store_true', help='explicitly allow opening the fixture GUI through LaunchServices')
parser.add_argument('--mode', default='basic', choices=['basic', 'accessory', 'multi-window', 'occluded', 'sibling', 'long-name', 'large-tree', 'deep-tree', 'slow'])
args = parser.parse_args()
if not args.launch_fixture:
    parser.error('--launch-fixture is required: these checks open a disposable GUI fixture')
if not args.fixture_app.is_dir() or args.fixture_app.suffix != '.app':
    parser.error('--fixture-app must be the generated LaunchServices .app bundle, not a bare executable')
args.scratch.mkdir(parents=True, exist_ok=True)
directory = pathlib.Path(tempfile.mkdtemp(prefix='lookup-live-', dir=args.scratch))
state_file = directory / 'state.json'
serial = 0

def request(payload):
    global serial
    serial += 1
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(4)
        client.connect(args.socket)
        client.sendall((json.dumps({'id': serial, **payload}) + '\n').encode())
        data = bytearray()
        while b'\n' not in data:
            chunk = client.recv(8192)
            assert chunk, 'helper disconnected'
            data.extend(chunk)
            assert len(data) <= 65536, 'unbounded native lookup response'
    reply = json.loads(data.split(b'\n', 1)[0])
    assert reply.get('id') == serial and reply.get('ok'), reply
    return reply['result']

def read_state():
    try:
        return json.loads(state_file.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None

status = request({'cmd': 'status'})
assert status.get('accessibility') is True, 'BLOCKED: tested helper lacks Accessibility; no permission was requested'
overlay_feed = None
overlay_manifest = pathlib.Path(args.socket).parent / 'pointer-windows.json'
try:
    if args.overlay_app:
        feed = pathlib.Path(args.socket).parent / 'pointers.json'
        assert not feed.exists() and not overlay_manifest.exists(), 'Overlay checks need an unused pointer runtime'
        assert args.overlay_app.is_dir() and args.overlay_app.suffix == '.app', 'Select a built CuaPreview.app'
        cursors = {'lookup-fixture': {'name': 'Lookup fixture', 'color': '#ad794c', 'target': {'screen': [1000, 350]},
                    'kind': 'point', 'state': 'waiting', 'label': 'Owned guide overlay', 'persistent': True,
                    't': int(time.time() * 1000)}} if args.overlay_populated else {}
        with feed.open('x') as output:
            output.write(json.dumps({'cursors': cursors}))
        feed.chmod(0o600)
        overlay_feed = feed
        subprocess.run(['/usr/bin/open', '-n', '-g', '--env', f'CUA_RUN_DIR={feed.parent}',
                        '--env', f'CUA_CONFIG={feed.parent / "config.json"}', str(args.overlay_app.resolve()), '--args', '--pointer'], check=True)
        deadline = time.monotonic() + 10
        while not overlay_manifest.exists():
            assert time.monotonic() < deadline, 'Overlay did not publish its LaunchServices identity'
            time.sleep(0.05)
        record = json.loads(overlay_manifest.read_text())
        assert record['process'].startswith(str(record['pid']) + ':') and record['windows'], record
        assert overlay_manifest.stat().st_mode & 0o777 == 0o600
    subprocess.run(['/usr/bin/open', '-n', '-a', str(args.fixture_app.resolve()), '--args',
                    '--state-file', str(state_file), '--mode', args.mode], check=True)
    deadline = time.monotonic() + 15
    before = None
    while time.monotonic() < deadline:
        before = read_state()
        if before and before.get('ready'):
            break
        time.sleep(0.05)
    assert before and before.get('ready'), f'Fixture identity unavailable; launch the .app through LaunchServices. State: {before}'
    time.sleep(0.3)
    before = read_state()
    pid, identity, window = before['pid'], before['process'], before['windows']['primary']
    assert identity.startswith(f'{pid}:'), before
    checks = []

    def check(name, expected, *, role='button', window_id=window, process=identity):
        payload = {'cmd': 'lookup', 'pid': pid, 'process': process, 'name': name}
        if role is not None:
            payload['role'] = role
        if window_id is not None:
            payload['windowId'] = window_id
        start = time.monotonic()
        result = request(payload)
        elapsed = time.monotonic() - start
        assert elapsed < 3, f'lookup exceeded bounded read time: {elapsed:.3f}s'
        assert result.get('status') == expected, (name, expected, result)
        assert len(result.get('message', '')) <= 240 and len(result.get('candidates', [])) <= 8, result
        if expected == 'matched':
            assert result['name'] == name and result['windowId'] == window, result
            if role is not None:
                assert result['role'] == role, result
            target = result['target']; rect = target['rect']
            assert target['windowId'] == window, result
            assert 0 <= rect['x'] < 1 and 0 <= rect['y'] < 1 and 0 < rect['w'] <= 1 and 0 < rect['h'] <= 1, result
            assert rect['x'] + rect['w'] <= 1.000001 and rect['y'] + rect['h'] <= 1.000001, result
        else:
            assert 'target' not in result, result
        checks.append({'request': payload, 'result': result, 'elapsedMs': round(elapsed * 1000, 3)})
        print(f'PASS {args.mode}: {name!r} -> {expected} ({elapsed * 1000:.1f} ms)', flush=True)

    if args.mode == 'accessory':
        assert all(app['pid'] != pid for app in request({'cmd': 'apps'})), 'Default app list stays compatible'
        assert any(app['pid'] == pid and app['process'] == identity for app in request({'cmd': 'apps', 'includeAccessories': True})), 'Explicit running discovery includes menu-bar apps'
    if args.mode in ['basic', 'accessory']:
        check('Save', 'matched')
        check('Save', 'matched', role=None, window_id=None)
        check('save', 'not_found')
        check('Sav', 'not_found')
        check('Repeat', 'ambiguous')
        check('Shared', 'ambiguous', role=None)
        check('Shared', 'matched')
        check('Disabled', 'not_found')
        check('Hidden', 'not_found')
        check('Secret', 'not_found', role=None)
        check('Offscreen', 'not_found')
        check('Clipped', 'not_found')
        check('Save', 'unavailable', process=f'{pid}:1')
        check('Save', 'unavailable', window_id=4294967295)
        if args.overlay_app:
            record = overlay_manifest.read_text()
            for value in ['not json', json.dumps({**json.loads(record), 'process': f'{json.loads(record)["pid"]}:1'}),
                          json.dumps({**json.loads(record), 'windows': [4294967295]})]:
                overlay_manifest.write_text(value)
                check('Save', 'incomplete')
            overlay_manifest.write_text(record)
            overlay_manifest.chmod(0o644)
            check('Save', 'incomplete')
            overlay_manifest.chmod(0o600)
            check('Save', 'matched')
    elif args.mode == 'multi-window':
        check('Save', 'ambiguous', window_id=None)
    elif args.mode == 'occluded':
        check('Save', 'incomplete')
    else:
        check('Save', 'incomplete')
    time.sleep(0.3)
    after = read_state()
    for key in ['actions', 'inputEvents', 'secureValueReads', 'frontmostPid', 'pointer']:
        assert after[key] == before[key], f'State changed during the passive check; result is inconclusive for {key}: {before[key]} -> {after[key]}'
    (directory / 'results.json').write_text(json.dumps({'mode': args.mode, 'checks': checks, 'before': before, 'after': after}, indent=2))
    print(f'PASS passive-state checks; evidence: {directory / "results.json"}')
finally:
    pathlib.Path(str(state_file) + '.stop').write_text('stop fixture\n')
    if overlay_feed is not None:
        overlay_feed.unlink(missing_ok=True)
        deadline = time.monotonic() + 5
        while overlay_manifest.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not overlay_manifest.exists(), 'Owned overlay did not remove its manifest on exit'
