"""Translate active Unreal ground functions; --check detects port drift."""
from pathlib import Path
import re,hashlib
import argparse
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--unreal-source',type=Path,required=True)
p.add_argument('--check',action='store_true')
a=p.parse_args()
src=a.unreal_source
root=Path(__file__).resolve().parents[1]
s=src.read_text(encoding='utf-8')
start=s.index('Blend->Description = TEXT("BF6 ground layer blend")')
s=s[start:]
def convert(code):
    code=re.sub(r'//[^\n]*','',code)
    code=re.sub(r'\[(?:unroll|loop)(?:\([^]]*\))?\]','',code)
    names={'Texture2DSample':'texture','Texture2DArraySample':'texture',
           'Texture2DSampleLevel':'textureLod','Texture2DArraySampleLevel':'textureLod',
           'Texture2DSampleGrad':'textureGrad','Texture2DArraySampleGrad':'textureGrad'}
    for old,new in sorted(names.items(),key=lambda x:-len(x[0])):
        code=re.sub(r'\b'+old+r'\(\s*(\w+)\s*,\s*\w+Sampler\s*,',new+r'(\1,',code)
    for old,new in {'float2':'vec2','float3':'vec3','float4':'vec4','lerp':'mix','frac':'fract','rsqrt':'inversesqrt','ddx':'dFdx','ddy':'dFdy','pow':'bf6_pow'}.items():
        code=re.sub(r'\b'+old+r'\b',new,code)
    code=re.sub(r'(float|vec[234]|int)\s+(\w+)\[(\d+)\]\s*=\s*\{(.*?)\};',lambda m:f'{m[1]} {m[2]}[{m[3]}] = {m[1]}[{m[3]}]({m[4]});',code,flags=re.S)
    code=re.sub(r'\(float\)\(([^()]*)\)',r'float(\1)',code)
    code=re.sub(r'\(int\)\(([^()]*)\)',r'int(\1)',code)
    code=re.sub(r'\((float|int)\)(\w+)',r'\1(\2)',code)
    code=code.replace('step(lc, 0.5)','step(lc, vec3(0.5))')
    return re.sub(r'\n\s*\n','\n',code)
functions=[]
for label,ret,name,params in [('Blend','vec3','terrain_colour','vec3 WPos, vec3 GeoNormal, vec3 CamPos'),
                              ('ExactNormal','vec3','terrain_normal','vec3 WPos, vec3 GeoNormal'),
                              ('ExactRoughness','float','terrain_roughness','vec3 WPos')]:
    m=re.search(label+r'->Code = TEXT\(R"HLSL\((.*?)\)HLSL"\);',s,re.S)
    if not m: raise ValueError(label)
    functions.append(f'{ret} {name}({params}) {{\n'+convert(m[1])+'\n}\n')
uniforms=[]
for name in ['CovIdx','CovW','CovIdx2','CovW2','Params']:
    uniforms.append(f'uniform sampler2D {name} : filter_nearest, repeat_disable;')
for name in ['Aerial','Reference','ExactMaterialPage','ExactNormalPage','GroundNormal']:
    uniforms.append(f'uniform sampler2D {name} : filter_linear, repeat_disable;')
for name in ['Bake','FarBake','ExactPage']:
    uniforms.append(f'uniform sampler2D {name} : source_color, filter_linear, repeat_disable;')
for name in ['Sheets','Heights','Masks']:
    hint='source_color, ' if name=='Sheets' else ''
    uniforms.append(f'uniform sampler2DArray {name} : {hint}filter_linear_mipmap_anisotropic, repeat_enable;')
for name in ['Lo','Span','FarLo','FarSpan','BoxCentre','BoxHalf','ExactPageLo','ExactPageSpan','GroundLo','GroundSpan']:
    uniforms.append(f'uniform vec3 {name} = vec3(1.0);')
for name,value in {'CovSize':2048,'MatCount':1,'NearM':120,'FarM':500,'DebugMode':0,'PhotoMix':1,'ReferenceMix':0,
                   'StochasticTiling':1,'SlopeProjection':1,'CoverageUnion':1,'MapDetailStrength':1,
                   'GroundGrassMode':1,'GroundGrassStrength':1,'ExactPageEnabled':0,'ExactBaseColorEnabled':0,
                   'GroundNormalEnabled':0,'GroundRoughness':.9}.items():
    uniforms.append(f'uniform float {name} = {float(value)};')
helpers='\n'.join(f'{t} saturate({t} v) {{ return clamp(v, {t}(0.0), {t}(1.0)); }}' for t in ['float','vec2','vec3','vec4'])
helpers+='\nfloat bf6_pow(float v, float e) { return pow(v,e); }\nvec3 bf6_pow(vec3 v, float e) { return pow(v,vec3(e)); }\n'
body='''
varying vec3 world_position;
varying vec3 world_normal;
void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    // Unreal's ground functions use centimetres and Z-up. Convert once here.
    vec3 wp = world_position.xzy * 100.0;
    vec3 gn = normalize(world_normal.xzy);
    vec3 cp = CAMERA_POSITION_WORLD.xzy * 100.0;
    ALBEDO = terrain_colour(wp, gn, cp);
    vec3 n = terrain_normal(wp, gn).xzy;
    NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
    ROUGHNESS = terrain_roughness(wp);
}
'''
out='// Port of the active Unreal ground functions. Source SHA256 '+hashlib.sha256(src.read_bytes()).hexdigest()+'\nshader_type spatial;\n'+ '\n'.join(uniforms)+'\n'+helpers+'\n'+ '\n'.join(functions)+body
target=root/'addons/highpoly_toggle/terrain_native.gdshader'
if a.check:
    if target.read_text(encoding='utf-8') != out:
        raise SystemExit('Ground shader differs from the active Unreal source. Regenerate and run GPU checks.')
    print('Ground shader matches the source translation.')
else:
    target.write_text(out,encoding='utf-8')
    print('Wrote',target)
