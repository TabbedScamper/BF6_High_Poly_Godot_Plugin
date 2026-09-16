"""Regenerate field serialization from the canonical reader header."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
header=re.sub(r'/\*.*?\*/','', (root/'core/include/bf6_core.h').read_text(encoding='utf-8'),flags=re.S)
out=['// Native API field serialization; names follow bf6_core.h. No game data tables.\n']
for name in ['bf6_water_sim_v2','bf6_water_render','bf6_water_mask','bf6_ground_material']:
    match=next(m for m in re.finditer(r'typedef struct(?:\s+\w+)?\s*\{([^{}]*)\}\s*(\w+)\s*;',header,re.S) if m[2]==name)
    out.append(f'static Object describe(const {name}& v) {{\n    Object o;\n')
    for decl in match[1].split(';'):
        decl=decl.strip()
        if not decl: continue
        m=re.match(r'(?:const\s+)?(float|int32_t|uint32_t|uint64_t|uint8_t|char)\s*(\*)?\s*(.*)',decl,re.S)
        if not m: raise ValueError(decl)
        if m[2] and m[1]!='char': continue
        for field in m[3].split(','):
            field=re.sub(r'\[.*?\]','',field).strip()
            value=f'(const char*)v.{field}' if m[1]=='char' else f'v.{field}'
            out.append(f'    o.put("{field}", {value});\n')
    out.append('    return o;\n}\n')
(root/'native/src/bf6_environment_fields.inc').write_text(''.join(out),encoding='utf-8')
print('generated serializer fields')
