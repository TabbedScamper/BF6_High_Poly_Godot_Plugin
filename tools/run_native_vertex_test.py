"""Run the isolated Godot native-vertex harness and retain stdout/stderr."""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--godot', required=True)
p.add_argument('--project', type=Path, required=True)
p.add_argument('--log', type=Path, required=True)
p.add_argument('--script', default='res://test_native_vertex_decode.gd')
a = p.parse_args()
a.log.parent.mkdir(parents=True, exist_ok=True)
command = [a.godot, '--headless', '--path', str(a.project), '--script', a.script]
with a.log.open('w', encoding='utf-8') as output:
    try:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=240)
        code = result.returncode
    except subprocess.TimeoutExpired:
        code = 124
print(a.log.read_text(encoding='utf-8', errors='replace')[-14000:])
raise SystemExit(code)
