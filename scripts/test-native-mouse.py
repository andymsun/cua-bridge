#!/usr/bin/env python3
"""Check real AppKit mouse metadata without posting any event."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root / 'agent/CuaAgent.swift').read_text()
start, end = '// Mouse events', '\nfunc eventClick(pid:'
assert source.count(start) == 1 and source.count(end) == 1
section = source[source.index(start):source.index(end)]
assert section.count('e.postToPid(pid)') == 1
section = section.replace('e.postToPid(pid)', 'captured.append(e)')
scroll = source[source.index('func eventScroll('):source.index('\nfunc processIdentity(')]
assert scroll.count('e.postToPid(pid)') == 1
section += '\n' + scroll.replace('e.postToPid(pid)', 'captured.append(e)')
assert 'postToPid' not in section and '.post(' not in section
out = Path(tempfile.mkdtemp(prefix='native-mouse-', dir=args.scratch.resolve()))
script = 'import AppKit\nvar captured: [CGEvent] = []\n'
script += 'struct AgentError: Error { let message: String; let code: String; init(_ message: String, code: String = "native_error") { self.message = message; self.code = code } }\n'
script += section + '\n' + (root / 'scripts/test-native-mouse.swift').read_text()
(out / 'main.swift').write_text(script)
subprocess.run(['swiftc', '-swift-version', '5', str(out / 'main.swift'), '-o', str(out / 'checks')], check=True)
subprocess.run([str(out / 'checks')], check=True)
lookup = 'dlsym(library, "CGEventSetWindowLocation")'
assert script.count(lookup) == 1
(out / 'main.swift').write_text(script.replace(lookup, 'dlsym(library, "CuaTestMissingWindowLocation")'))
subprocess.run(['swiftc', '-swift-version', '5', str(out / 'main.swift'), '-o', str(out / 'missing-checks')], check=True)
subprocess.run([str(out / 'missing-checks'), '--missing-spi'], check=True)
print('PASS real mouse-event metadata and missing-SPI refusal; no event posting; evidence:', out)
