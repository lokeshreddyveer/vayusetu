#!/usr/bin/env python3
"""Download the exact verified compiler into the project; no system installation."""
import hashlib
import json
import tarfile
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent.parent
metadata = json.loads((root / 'Configuration/BuildTools.json').read_text())
compiler = root / 'Tools/go/bin/go'
if compiler.exists():
    print('Local Go compiler is already present.')
    raise SystemExit(0)
tools = root / 'Tools'
tools.mkdir(exist_ok=True)
archive = tools / metadata['filename']
urllib.request.urlretrieve('https://go.dev/dl/' + metadata['filename'], archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != metadata['sha256']:
    archive.unlink()
    raise SystemExit('Go archive checksum mismatch.')
with tarfile.open(archive) as bundle:
    for item in bundle.getmembers():
        if item.name.startswith('/') or '..' in Path(item.name).parts or item.issym() or item.islnk():
            raise SystemExit('Unexpected Go archive member.')
    bundle.extractall(tools)
archive.unlink()
(tools / 'go-version.json').write_text(json.dumps(metadata, indent=2))
print('Downloaded and verified ' + metadata['version'])
