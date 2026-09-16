"""Run an isolated environment check; engine errors fail even after quit(0)."""
import argparse
from pathlib import Path
import subprocess
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--godot', required=True)
p.add_argument('--project', type=Path, required=True)
p.add_argument('--script', required=True)
p.add_argument('--log', type=Path, required=True)
p.add_argument('--gpu', action='store_true')
p.add_argument('--level')
p.add_argument('--production', action='store_true')
p.add_argument('--timeout', type=int, default=240)
a = p.parse_args()
a.log.parent.mkdir(parents=True, exist_ok=True)
command = [a.godot, '--path', str(a.project), '--script', a.script]
command += ['--rendering-method', 'forward_plus', '--rendering-driver', 'vulkan', '--resolution', '960x540'] if a.gpu else ['--headless']
user_args = []
if a.level: user_args.append('--level=' + a.level)
if a.production: user_args.append('--production')
if user_args: command += ['--'] + user_args
with a.log.open('w', encoding='utf-8') as output:
    try:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=a.timeout)
        code = result.returncode
    except subprocess.TimeoutExpired:
        code = 124
log = a.log.read_text(encoding='utf-8', errors='replace')
errors = [line for line in log.splitlines() if 'ERROR:' in line or line.startswith('FAIL ')]
print(log[-18000:])
if errors:
    print('Engine/test errors detected:', len(errors))
    code = code or 1
raise SystemExit(code)
