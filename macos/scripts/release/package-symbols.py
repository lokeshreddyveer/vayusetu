"""Merge genuine compiler-generated symbols for the universal release binaries."""
from pathlib import Path
import shutil
import subprocess

output = Path('build/symbols')
output.mkdir(parents=True, exist_ok=True)
for executable, bundle in [('VayuSetuVPN', 'VayuSetu.app'), ('VayuSetuTunnel', 'app.vayusetu.macos.tunnel.systemextension')]:
    sources = [Path(f'build/vpn-{arch}/{executable}.dSYM') for arch in ('arm64', 'x86_64')]
    destination = output / (bundle + '.dSYM')
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(sources[0], destination)
    dwarf = Path('Contents/Resources/DWARF') / executable
    subprocess.run(['xcrun', 'lipo', '-create', *(str(source / dwarf) for source in sources), '-output', str(destination / dwarf)], check=True)
    subprocess.run(['xcrun', 'dwarfdump', '--uuid', str(destination)], check=True)
