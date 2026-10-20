#!/usr/bin/env python3
"""Run production indexed-click paths against in-memory AX and mouse boundaries.

Usage: python3 scripts/test-native-input.py --scratch /absolute/private/scratch
No helper, GUI, AX service, socket, or real CGEvent is launched. The generated
source and extraction map remain in scratch for inspection. This proves source
routing/validation, not macOS event recipient behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--group', choices=['all', 'geometry', 'buttons'], default='all')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
args.scratch.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='native-input-', dir=args.scratch.resolve()))
env = dict(os.environ, CUA_RUN_DIR=str(out / 'run'), CUA_CONFIG=str(out / 'config.json'))
(out / 'run').mkdir()
(out / 'config.json').write_text('{}\n')
source = root / 'agent/CuaAgent.swift'
text = source.read_text()
segments = []


def extract(start, end):
    assert text.count(start) == 1, f'ambiguous/missing source boundary: {start}'
    a = text.index(start)
    b = text.index(end, a + len(start))
    segments.append({'start': start, 'firstLine': text[:a].count('\n') + 1,
                     'lastLine': text[:b].count('\n')})
    return text[a:b]


parts = [
    extract('struct AgentError: Error {', '\nfunc requireScreenRecording'),
    extract('func ax(_ el:', '\nlet ROLE_NAMES:'),
    extract('let ROLE_NAMES:', '\nlet SKIP_ROLES:'),
    extract('final class Table {', '\nvar tables:'),
    extract('func windowID(of el:', '\n// Mouse events'),
    extract('func postMouse(pid:', '\nfunc eventScroll('),
    extract('func checkProcess(', '\nfunc windows('),
    extract('func selectedWindow(', '\nfunc snapshot('),
    extract('func element(_ pid:', '\n// MARK: - passive exact lookup'),
    extract('struct LookupFailure: Error {', '\nstruct LookupQuery'),
    extract('func lookupRole(', '\nstruct LookupCandidate'),
    extract('func lookupPositiveRect(', '\nfunc lookupOcclusionMessage'),
    extract('final class LookupReader {', '\nfunc lookupOverlayWindowIDs'),
    extract('func click(_ el:', '\n/// Scroll the nearest'),
]
handler = extract('func handle(_ req:', '\n    case "status":')
handler += '\n' + extract('    case "press":', '    case "locate":')
handler += '\n' + extract('    case "action":', '    case "scroll":')
handler += '\n    default: fatalError("Unexpected fixture command: \\(cmd)")\n    }\n}\n'
parts.append(handler)
production = '\n'.join(parts)
# Imports and OS boundaries are supplied only by the local doubles, never by the
# original helper's imports or top-level socket/run-loop initialization.
for forbidden in ['import ', 'CGEventPost(', 'NSRunningApplication', 'NSWorkspace',
                  'SCShareableContent', 'CGWarpMouseCursorPosition', 'AXUIElementCreate']:
    assert forbidden not in production, f'unexpected live boundary: {forbidden}'
combined = ((root / 'scripts/test-native-input-stubs.swift').read_text() + '\n'
            + production + '\n' + (root / 'scripts/test-native-input.swift').read_text())
(out / 'main.swift').write_text(combined)
(out / 'extraction-map.json').write_text(json.dumps({
    'source': str(source), 'sha256': hashlib.sha256(text.encode()).hexdigest(),
    'segments': segments,
}, indent=2) + '\n')
print(f'Extracted production paths: {out / "extraction-map.json"}', flush=True)
subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'module-cache'),
                str(out / 'main.swift'), '-o', str(out / 'input-checks')], env=env, check=True)
result = subprocess.run([str(out / 'input-checks'), args.group], env=env, timeout=30)
raise SystemExit(result.returncode)
