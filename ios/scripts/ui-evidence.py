#!/usr/bin/env python3
"""Turns the result of a real UI-test run into a record, and checks whether a record exists for the current source.

  python3 ios/scripts/ui-evidence.py record <result.xcresult> <device-name>     # after scripts/test-ui.sh; writes ios/test-evidence/ui-run.json
  python3 ios/scripts/ui-evidence.py check                                       # exit 0 only if a recorded run passed on THIS source

A run is evidence only if it is recorded from a real result bundle, with its test counts, the device it ran on and the source revision. The counts include
SKIPPED tests, listed by name: a test that skipped itself (for example one that needs the VPN permission) did not pass and is never counted as having passed.
`check` fails (exit 2, "not run") when there is no record, when the record is for different source, or when the run had failures. It never passes on a
compile alone."""
import json, subprocess, sys, hashlib
from datetime import datetime, timezone
from pathlib import Path

ios = Path(__file__).resolve().parents[1]
repo = ios.parent
import os
record_path = Path(os.environ['VAYU_UI_EVIDENCE_PATH']) if os.environ.get('VAYU_UI_EVIDENCE_PATH') else ios / 'test-evidence/ui-run.json'   # the override exists so the recorder can be tested without writing real evidence

def git(*args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True).stdout.strip()

def source_fingerprint():
    """The revision plus a hash of any uncommitted change under ios/ and the core package, so a run on edited source does not vouch for different edits."""
    head = git('rev-parse', 'HEAD')
    diff = subprocess.run(['git', '-C', str(repo), 'diff', 'HEAD', '--', 'ios/Sources', 'ios/Tunnel', 'ios/UITests', 'Packages/VayuSetuCore/Sources'], capture_output=True).stdout
    untracked = git('ls-files', '--others', '--exclude-standard', '--', 'ios/Sources', 'ios/Tunnel', 'ios/UITests', 'Packages/VayuSetuCore/Sources')
    # The committed content of these directories is part of the fingerprint too: on a clean tree the diff is empty, and without this a run recorded at one commit
    # would vouch for any other clean commit.
    committed = git('rev-parse', 'HEAD:ios/Sources', 'HEAD:ios/Tunnel', 'HEAD:ios/UITests', 'HEAD:Packages/VayuSetuCore/Sources')
    blob = hashlib.sha256(committed.encode() + diff + untracked.encode())
    for name in sorted(untracked.splitlines()):
        p = repo / name
        if p.is_file(): blob.update(p.read_bytes())
    return head, blob.hexdigest()[:16]

def xcrun(*args):
    """xcresulttool ships with full Xcode only, so the developer directory is set here and the result does not depend on the system's xcode-select setting."""
    env = dict(os.environ); env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    return subprocess.check_output(['xcrun', *args], text=True, env=env)

def summary(bundle: Path):
    out = xcrun('xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle), '--compact')
    return json.loads(out)

def tests(bundle: Path):
    out = xcrun('xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle), '--compact')
    return json.loads(out)

def walk(node, found):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case': found.append(node)
        for child in node.get('children', []) or []: walk(child, found)
    elif isinstance(node, list):
        for n in node: walk(n, found)

def record(bundle: Path, device: str):
    s = summary(bundle)
    cases = []; walk(tests(bundle).get('testNodes', []), cases)
    if not cases: sys.exit('Could not find any test cases in the result bundle; nothing was recorded.')
    result = lambda c: str(c.get('result', '')).lower()
    passed = [c['name'] for c in cases if result(c) == 'passed']
    failed = [c['name'] for c in cases if result(c) == 'failed']
    skipped = [c['name'] for c in cases if result(c) == 'skipped']
    other = [c['name'] for c in cases if result(c) not in ('passed', 'failed', 'skipped')]
    head, fingerprint = source_fingerprint()
    data = {'recorded': datetime.now(timezone.utc).isoformat(timespec='seconds'), 'device': device, 'os': s.get('devicesAndConfigurations', [{}])[0].get('device', {}).get('osVersion', 'unknown') if s.get('devicesAndConfigurations') else 'unknown',
            'revision': head, 'source': fingerprint, 'total': len(cases), 'passed': passed, 'failed': failed, 'skipped': skipped, 'unknown': other,
            'result': 'passed' if not failed and not other and passed else 'failed', 'bundle': bundle.name}
    record_path.parent.mkdir(exist_ok=True); record_path.write_text(json.dumps(data, indent=2) + '\n')
    print(f"Recorded: {len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped, {len(other)} unclassified, on {device}.")
    if skipped: print('Skipped (these did not run and are not counted as passed): ' + ', '.join(skipped))
    sys.exit(0 if data['result'] == 'passed' else 1)

def check():
    if not record_path.exists():
        print('NOT RUN  no UI test run has been recorded (ios/test-evidence/ui-run.json is missing). Run scripts/test-ui.sh on a connected iPhone, then record it.'); sys.exit(2)
    d = json.loads(record_path.read_text())
    head, fingerprint = source_fingerprint()
    if d.get('source') != fingerprint:
        print(f"NOT RUN  the recorded UI run ({d.get('recorded')}, {d.get('device')}) was on different source than this one; run it again."); sys.exit(2)
    if d.get('result') != 'passed':
        print(f"FAIL     the recorded UI run failed: {', '.join(d.get('failed', [])) or 'unclassified results'}"); sys.exit(1)
    skipped = d.get('skipped', [])
    print(f"PASS     UI run on {d['device']} ({d['os']}), {d['recorded']}: {len(d['passed'])} passed, {len(skipped)} skipped" + (' (' + ', '.join(skipped) + ' did not run)' if skipped else ''))
    sys.exit(0)

if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'check': check()
    elif len(sys.argv) == 4 and sys.argv[1] == 'record': record(Path(sys.argv[2]), sys.argv[3])
    else: sys.exit(__doc__)
