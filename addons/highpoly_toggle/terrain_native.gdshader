// Port of the active Unreal ground functions. Source SHA256 e9ac596ca7cad112538ab5bdee41961be49f66152cac20d4923cb66f8a608d4d
shader_type spatial;
uniform sampler2D CovIdx : filter_nearest, repeat_disable;
uniform sampler2D CovW : filter_nearest, repeat_disable;
uniform sampler2D CovIdx2 : filter_nearest, repeat_disable;
uniform sampler2D CovW2 : filter_nearest, repeat_disable;
uniform sampler2D Params : filter_nearest, repeat_disable;
uniform sampler2D Aerial : filter_linear, repeat_disable;
uniform sampler2D Reference : filter_linear, repeat_disable;
uniform sampler2D ExactMaterialPage : filter_linear, repeat_disable;
uniform sampler2D ExactNormalPage : filter_linear, repeat_disable;
uniform sampler2D GroundNormal : filter_linear, repeat_disable;
uniform sampler2D Bake : source_color, filter_linear, repeat_disable;
uniform sampler2D FarBake : source_color, filter_linear, repeat_disable;
uniform sampler2D ExactPage : source_color, filter_linear, repeat_disable;
uniform sampler2DArray Sheets : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray Heights : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray Masks : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 Lo = vec3(1.0);
uniform vec3 Span = vec3(1.0);
uniform vec3 FarLo = vec3(1.0);
uniform vec3 FarSpan = vec3(1.0);
uniform vec3 BoxCentre = vec3(1.0);
uniform vec3 BoxHalf = vec3(1.0);
uniform vec3 ExactPageLo = vec3(1.0);
uniform vec3 ExactPageSpan = vec3(1.0);
uniform vec3 GroundLo = vec3(1.0);
uniform vec3 GroundSpan = vec3(1.0);
uniform float CovSize = 2048.0;
uniform float MatCount = 1.0;
uniform float NearM = 120.0;
uniform float FarM = 500.0;
uniform float DebugMode = 0.0;
uniform float PhotoMix = 1.0;
uniform float ReferenceMix = 0.0;
uniform float StochasticTiling = 1.0;
uniform float SlopeProjection = 1.0;
uniform float CoverageUnion = 1.0;
uniform float MapDetailStrength = 1.0;
uniform float GroundGrassMode = 1.0;
uniform float GroundGrassStrength = 1.0;
uniform float ExactPageEnabled = 0.0;
uniform float ExactBaseColorEnabled = 0.0;
uniform float GroundNormalEnabled = 0.0;
uniform float GroundRoughness = 0.9;
float saturate(float v) { return clamp(v, float(0.0), float(1.0)); }
vec2 saturate(vec2 v) { return clamp(v, vec2(0.0), vec2(1.0)); }
vec3 saturate(vec3 v) { return clamp(v, vec3(0.0), vec3(1.0)); }
vec4 saturate(vec4 v) { return clamp(v, vec4(0.0), vec4(1.0)); }
float bf6_pow(float v, float e) { return pow(v,e); }
vec3 bf6_pow(vec3 v, float e) { return pow(v,vec3(e)); }

vec3 terrain_colour(vec3 WPos, vec3 GeoNormal, vec3 CamPos) {

vec2 pm  = WPos.xy * 0.01;
vec2 cuv = saturate((pm - Lo.xy) / max(Span.xy, 1.0));
vec2 tc  = cuv * CovSize - 0.5;
vec2 fr  = fract(tc);
float  inv = 1.0 / CovSize;
vec2 b0  = (floor(tc) + 0.5) * inv;
vec4 IDS[4], WS[4], IDS2[4], WS2[4];
vec2 CTO[4] = vec2[4]( b0, b0 + vec2(inv, 0), b0 + vec2(0, inv), b0 + vec2(inv, inv) );
for (int c0 = 0; c0 < 4; c0++)
{
    IDS[c0]  = textureLod(CovIdx,  CTO[c0], 0) * 255.0;
    WS[c0]   = textureLod(CovW,    CTO[c0], 0);
    IDS2[c0] = textureLod(CovIdx2, CTO[c0], 0) * 255.0;
    WS2[c0]  = textureLod(CovW2,   CTO[c0], 0);
}
float BW[4];
BW[0] = (1.0 - fr.x) * (1.0 - fr.y);
BW[1] = fr.x * (1.0 - fr.y);
BW[2] = (1.0 - fr.x) * fr.y;
BW[3] = fr.x * fr.y;
float rid[8];
float acc[8];
int evalN = 0;
int baseN = 0;
if (CoverageUnion > 0.5)
{
	for (int c0 = 0; c0 < 4; c0++)
	{
		float candidate = IDS[c0].x;
		if (WS[c0].x < (254.5 / 255.0) || candidate >= 254.5) continue;
		bool already = false;
		for (int j = 0; j < evalN; j++) already = already || abs(rid[j] - candidate) < 0.5;
		if (already) continue;
		float mw = 0.0;
		for (int c = 0; c < 4; c++)
		{
			float ic[8] = float[8]( IDS[c].x, IDS[c].y, IDS[c].z, IDS[c].w,
			                IDS2[c].x, IDS2[c].y, IDS2[c].z, IDS2[c].w );
			float wc[8] = float[8]( WS[c].x, WS[c].y, WS[c].z, WS[c].w,
			                WS2[c].x, WS2[c].y, WS2[c].z, WS2[c].w );
			for (int k2 = 0; k2 < 8; k2++)
				if (wc[k2] > 0.0 && abs(ic[k2] - candidate) < 0.5)
					mw += BW[c] * wc[k2];
		}
		if (mw > 0.0 && evalN < 8)
		{
			rid[evalN] = candidate; acc[evalN] = mw; evalN++;
		}
	}
	baseN = evalN;
	for (int c0 = 0; c0 < 4; c0++)
	{
		float srcId[8] = float[8]( IDS[c0].x, IDS[c0].y, IDS[c0].z, IDS[c0].w,
		                   IDS2[c0].x, IDS2[c0].y, IDS2[c0].z, IDS2[c0].w );
		float srcW[8] = float[8]( WS[c0].x, WS[c0].y, WS[c0].z, WS[c0].w,
		                  WS2[c0].x, WS2[c0].y, WS2[c0].z, WS2[c0].w );
		for (int k0 = 0; k0 < 8; k0++)
		{
			float candidate = srcId[k0];
			if (srcW[k0] <= 0.0 || candidate >= 254.5) continue;
			bool already = false;
			for (int j = 0; j < evalN; j++) already = already || abs(rid[j] - candidate) < 0.5;
			if (already) continue;
			float mw = 0.0;
			for (int c = 0; c < 4; c++)
			{
				float ic[8] = float[8]( IDS[c].x, IDS[c].y, IDS[c].z, IDS[c].w,
				                IDS2[c].x, IDS2[c].y, IDS2[c].z, IDS2[c].w );
				float wc[8] = float[8]( WS[c].x, WS[c].y, WS[c].z, WS[c].w,
				                WS2[c].x, WS2[c].y, WS2[c].z, WS2[c].w );
				for (int k2 = 0; k2 < 8; k2++)
					if (wc[k2] > 0.0 && abs(ic[k2] - candidate) < 0.5)
						mw += BW[c] * wc[k2];
			}
			if (mw <= 0.0) continue;
			if (evalN < 8)
			{
				rid[evalN] = candidate; acc[evalN] = mw; evalN++;
			}
			else if (baseN < 8)
			{
				int weak = baseN;
				for (int j = baseN + 1; j < 8; j++) if (acc[j] < acc[weak]) weak = j;
				if (mw > acc[weak]) { rid[weak] = candidate; acc[weak] = mw; }
			}
		}
	}
	for (int a = baseN; a < 8; a++)
	{
		if (a >= evalN) break;
		for (int b = a + 1; b < 8; b++)
		{
			if (b >= evalN) break;
			if (rid[b] < rid[a])
			{
				float ti = rid[a]; rid[a] = rid[b]; rid[b] = ti;
				float tw = acc[a]; acc[a] = acc[b]; acc[b] = tw;
			}
		}
	}
}
else
{
	int refc = (fr.x < 0.5 ? 0 : 1) + (fr.y < 0.5 ? 0 : 2);
	float oldId[8] = float[8]( IDS[refc].x, IDS[refc].y, IDS[refc].z, IDS[refc].w,
	                   IDS2[refc].x, IDS2[refc].y, IDS2[refc].z, IDS2[refc].w );
	float oldW[8] = float[8]( WS[refc].x, WS[refc].y, WS[refc].z, WS[refc].w,
	                  WS2[refc].x, WS2[refc].y, WS2[refc].z, WS2[refc].w );
	for (int k2 = 0; k2 < 8; k2++) if (oldW[k2] > 0.0 && oldId[k2] < 254.5)
	{
		rid[evalN] = oldId[k2]; acc[evalN] = 0.0; evalN++;
	}
	baseN = evalN > 0 && oldW[0] >= (254.5 / 255.0) ? 1 : 0;
}
if (CoverageUnion <= 0.5) for (int c = 0; c < 4; c++)
{
	float ic[8] = float[8]( IDS[c].x, IDS[c].y, IDS[c].z, IDS[c].w,
	                IDS2[c].x, IDS2[c].y, IDS2[c].z, IDS2[c].w );
	float wc[8] = float[8]( WS[c].x, WS[c].y, WS[c].z, WS[c].w,
	                WS2[c].x, WS2[c].y, WS2[c].z, WS2[c].w );
	for (int s = 0; s < evalN; s++) for (int k2 = 0; k2 < 8; k2++)
		if (wc[k2] > 0.0 && abs(ic[k2] - rid[s]) < 0.5)
			acc[s] += BW[c] * wc[k2];
}
vec3 col = vec3(0.0, 0.0, 0.0);
vec3 detail = vec3(1.0, 1.0, 1.0);
vec3 grassPremul = vec3(0.0, 0.0, 0.0);
float  grassAlpha = 0.0;
float  du  = 1.0 / max(MatCount, 1.0);
vec3 aerial = texture(Aerial, cuv).rgb;
vec2 dpx = dFdx(pm);
vec2 dpy = dFdy(pm);
float accH = 0.0, accLoMax = 0.0, accHiMax = 0.0;
bool  touched = false;
int   dbg = int(DebugMode + 0.5);
for (int s2 = 0; s2 < evalN; s2++)
{
	if (dbg == 6 && s2 < baseN) continue;
	float slice = clamp(rid[s2], 0.0, max(MatCount - 1.0, 0.0));
	vec2 pu = vec2((slice + 0.5) * du, 0.0);
	vec4 P0 = textureLod(Params, vec2(pu.x, 0.125), 0);
	vec4 P1 = textureLod(Params, vec2(pu.x, 0.375), 0);
	vec4 P2 = textureLod(Params, vec2(pu.x, 0.625), 0);
	vec4 P3 = textureLod(Params, vec2(pu.x, 0.875), 0);
	float  rep = max(P0.r, 0.05);
	vec2 uv  = (pm / rep) * P2.zw + P3.xy;
	vec2 ddu = (dpx / rep) * P2.zw;
	vec2 ddv = (dpy / rep) * P2.zw;
	float  rot = P0.g;
	if (abs(rot) > 0.001)
	{
		float cs = cos(rot), sn = sin(rot);
		uv  = vec2(uv.x  * cs - uv.y  * sn, uv.x  * sn + uv.y  * cs);
		ddu = vec2(ddu.x * cs - ddu.y * sn, ddu.x * sn + ddu.y * cs);
		ddv = vec2(ddv.x * cs - ddv.y * sn, ddv.x * sn + ddv.y * cs);
	}
	vec4 sh4 = textureGrad(Sheets,
	                                      vec3(uv, slice), ddu, ddv);
	vec4 shLow4 = textureLod(Sheets,
	                                          vec3(uv, slice), 6);
	vec4 nh4 = textureGrad(Heights,
	                                      vec3(uv, slice), ddu, ddv);
	vec4 mk4 = textureGrad(Masks,
	                                      vec3(uv, slice), ddu, ddv);
	if (SlopeProjection > 0.5 || dbg == 7)
	{
		vec3 posm = WPos * 0.01;
		vec3 nx = dFdx(posm);
		vec3 ny = dFdy(posm);
		vec2 uvX = (posm.yz / rep) * P2.zw + P3.xy;
		vec2 uvY = (posm.xz / rep) * P2.zw + P3.xy;
		vec2 dxX = (nx.yz / rep) * P2.zw;
		vec2 dyX = (ny.yz / rep) * P2.zw;
		vec2 dxY = (nx.xz / rep) * P2.zw;
		vec2 dyY = (ny.xz / rep) * P2.zw;
		if (abs(rot) > 0.001)
		{
			float cs = cos(rot), sn = sin(rot);
			uvX = vec2(uvX.x * cs - uvX.y * sn, uvX.x * sn + uvX.y * cs);
			uvY = vec2(uvY.x * cs - uvY.y * sn, uvY.x * sn + uvY.y * cs);
			dxX = vec2(dxX.x * cs - dxX.y * sn, dxX.x * sn + dxX.y * cs);
			dyX = vec2(dyX.x * cs - dyX.y * sn, dyX.x * sn + dyX.y * cs);
			dxY = vec2(dxY.x * cs - dxY.y * sn, dxY.x * sn + dxY.y * cs);
			dyY = vec2(dyY.x * cs - dyY.y * sn, dyY.x * sn + dyY.y * cs);
		}
		vec3 triW = bf6_pow(abs(normalize(GeoNormal)), 8.0);
		triW /= max(triW.x + triW.y + triW.z, 1e-5);
		vec4 shX = textureGrad(Sheets,
		                                      vec3(uvX, slice), dxX, dyX);
		vec4 shY = textureGrad(Sheets,
		                                      vec3(uvY, slice), dxY, dyY);
		vec4 shLowX = textureLod(Sheets,
		                                           vec3(uvX, slice), 6);
		vec4 shLowY = textureLod(Sheets,
		                                           vec3(uvY, slice), 6);
		vec4 nhX = textureGrad(Heights,
		                                      vec3(uvX, slice), dxX, dyX);
		vec4 nhY = textureGrad(Heights,
		                                      vec3(uvY, slice), dxY, dyY);
		sh4 = shX * triW.x + shY * triW.y + sh4 * triW.z;
		shLow4 = shLowX * triW.x + shLowY * triW.y + shLow4 * triW.z;
		nh4 = nhX * triW.x + nhY * triW.y + nh4 * triW.z;
	}
	if (StochasticTiling > 0.5)
	{
		vec2 cf = fract(uv);
		vec2 cb = floor(uv);
		vec2 v0, v1, v2;
		vec3 sw;
		if (cf.x + cf.y <= 1.0)
		{
			v0 = cb;                       v1 = cb + vec2(1.0, 0.0);
			v2 = cb + vec2(0.0, 1.0);   sw = vec3(1.0-cf.x-cf.y, cf.x, cf.y);
		}
		else
		{
			v0 = cb + vec2(1.0, 1.0);   v1 = cb + vec2(0.0, 1.0);
			v2 = cb + vec2(1.0, 0.0);   sw = vec3(cf.x+cf.y-1.0, 1.0-cf.x, 1.0-cf.y);
		}
		vec3 h0 = fract(sin(vec3(dot(v0,vec2(127.11,311.80)),
		                            dot(v0,vec2(269.52,183.38)),
		                            dot(v0,vec2(419.27,371.93)))) * 43758.5);
		vec3 h1 = fract(sin(vec3(dot(v1,vec2(127.11,311.80)),
		                            dot(v1,vec2(269.52,183.38)),
		                            dot(v1,vec2(419.27,371.93)))) * 43758.5);
		vec3 h2 = fract(sin(vec3(dot(v2,vec2(127.11,311.80)),
		                            dot(v2,vec2(269.52,183.38)),
		                            dot(v2,vec2(419.27,371.93)))) * 43758.5);
		float a0=(h0.x-0.5)*6.2831855, a1=(h1.x-0.5)*6.2831855, a2=(h2.x-0.5)*6.2831855;
		vec2 cs0=vec2(cos(a0),sin(a0)), cs1=vec2(cos(a1),sin(a1)), cs2=vec2(cos(a2),sin(a2));
		vec2 u0=vec2(uv.x*cs0.x-uv.y*cs0.y,uv.x*cs0.y+uv.y*cs0.x)+h0.yz;
		vec2 u1=vec2(uv.x*cs1.x-uv.y*cs1.y,uv.x*cs1.y+uv.y*cs1.x)+h1.yz;
		vec2 u2=vec2(uv.x*cs2.x-uv.y*cs2.y,uv.x*cs2.y+uv.y*cs2.x)+h2.yz;
		vec2 dx0=vec2(ddu.x*cs0.x-ddu.y*cs0.y,ddu.x*cs0.y+ddu.y*cs0.x);
		vec2 dy0=vec2(ddv.x*cs0.x-ddv.y*cs0.y,ddv.x*cs0.y+ddv.y*cs0.x);
		vec2 dx1=vec2(ddu.x*cs1.x-ddu.y*cs1.y,ddu.x*cs1.y+ddu.y*cs1.x);
		vec2 dy1=vec2(ddv.x*cs1.x-ddv.y*cs1.y,ddv.x*cs1.y+ddv.y*cs1.x);
		vec2 dx2=vec2(ddu.x*cs2.x-ddu.y*cs2.y,ddu.x*cs2.y+ddu.y*cs2.x);
		vec2 dy2=vec2(ddv.x*cs2.x-ddv.y*cs2.y,ddv.x*cs2.y+ddv.y*cs2.x);
		sh4 = textureGrad(Sheets,vec3(u0,slice),dx0,dy0)*sw.x
		    + textureGrad(Sheets,vec3(u1,slice),dx1,dy1)*sw.y
		    + textureGrad(Sheets,vec3(u2,slice),dx2,dy2)*sw.z;
		shLow4 = textureLod(Sheets,vec3(u0,slice),6)*sw.x
		       + textureLod(Sheets,vec3(u1,slice),6)*sw.y
		       + textureLod(Sheets,vec3(u2,slice),6)*sw.z;
		nh4 = textureGrad(Heights,vec3(u0,slice),dx0,dy0)*sw.x
		    + textureGrad(Heights,vec3(u1,slice),dx1,dy1)*sw.y
		    + textureGrad(Heights,vec3(u2,slice),dx2,dy2)*sw.z;
		mk4 = textureGrad(Masks,vec3(u0,slice),dx0,dy0)*sw.x
		    + textureGrad(Masks,vec3(u1,slice),dx1,dy1)*sw.y
		    + textureGrad(Masks,vec3(u2,slice),dx2,dy2)*sw.z;
	}
	float ht      = saturate(nh4.b);
	float baseH   = P2.r;
	float disp    = P2.g;
	float hLayer  = baseH + (ht - 0.5) * disp;
	float hMax    = baseH + 0.5 * disp;
	float hMin    = baseH - 0.5 * disp;
	float m       = saturate(acc[s2] * mk4.r);
	float rampExp = max(P0.a, 0.01);
	float hb      = P1.a;
	float wHi     = bf6_pow(saturate((m - 0.9) / -0.85), rampExp);
	float wLo     = bf6_pow(saturate((m - 0.05) / 0.95), rampExp);
	float hiRef   = hLayer + (accHiMax - hMax) * wHi;
	float loRef   = accH + (hMin - accLoMax) * wLo;
	float rawc    = m + (hiRef - loRef) * hb;
	float c = (m >= 1.0) ? 1.0 : ((m <= 0.0) ? 0.0 : saturate(rawc));
	vec3 lc = sh4.rgb * P1.rgb;
	if (P0.b > 0.001)
	{
		vec3 loB = 2.0 * lc * aerial;
		vec3 hiB = 1.0 - 2.0 * (1.0 - lc) * (1.0 - aerial);
		vec3 useLo = step(lc, vec3(0.5));        
		lc = mix(lc, mix(hiB, loB, useLo), P0.b);
	}
	float cc = (!touched && c > 0.0) ? 1.0 : c;
	col = mix(col, lc, cc);
	float grassFlag = GroundGrassMode < 0.5 ? 0.0
		: (GroundGrassMode < 1.5 ? P3.z : P3.w);
	float grassC = saturate(c * grassFlag);
	grassPremul = mix(grassPremul, lc, grassC);
	grassAlpha = mix(grassAlpha, 1.0, grassC);
	vec3 hiDetail = clamp(sh4.rgb / max(shLow4.rgb, 0.04), 0.78, 1.22);
	detail = mix(detail, hiDetail, cc);
	if (c > 0.0)
	{
		accH     = clamp(mix(loRef, hiRef, c), -1.0, 10.0);
		accLoMax = mix(accLoMax, hMin, c);
		accHiMax = mix(accHiMax, hMax, c);
		touched  = true;
	}
}
if (!touched) col = bf6_pow(max(aerial, 0.0), 2.2);
{
    vec3 photo = bf6_pow(max(aerial, 0.0), 2.2);
    col = mix(col, photo, saturate(PhotoMix));
}
vec3 reference = texture(Reference, cuv).rgb;
vec3 referencedDetail = saturate(reference * detail);
col = mix(col, referencedDetail, saturate(ReferenceMix));
float dist = length(WPos.xy - CamPos.xy) * 0.01;
float k = saturate((dist - NearM) / max(FarM - NearM, 1.0));
vec3 baked = texture(Bake, cuv).rgb;
vec2 bx = abs((pm - BoxCentre.xy) / max(BoxHalf.xy, 1.0));
float outside = saturate((max(bx.x, bx.y) - 0.92) / 0.08);
if (outside > 0.0)
{
    vec2 fuv = saturate((pm - FarLo.xy) / max(FarSpan.xy, 1.0));
    vec3 farCol = texture(FarBake, fuv).rgb;
    col   = mix(col, farCol, outside);
    baked = mix(baked, farCol, outside);
}
if (dbg >= 100)
{
    float want = float(dbg - 100);
    return abs(rid[0] - want) < 0.5 ? vec3(1.0, 1.0, 1.0) : vec3(0.02, 0.02, 0.02);
}
if (dbg == 1)
{
    float h = fract(rid[0] * 0.6180339887);
    return saturate(vec3(abs(h * 6.0 - 3.0) - 1.0,
                           2.0 - abs(h * 6.0 - 2.0),
                           2.0 - abs(h * 6.0 - 4.0)));
}
if (dbg == 2) return aerial;
if (dbg == 3) return col;
if (dbg == 4) return baked;
if (dbg == 6) return col;
if (dbg == 7) return col;
if (dbg == 5)
{
    float used = 0.0;
    for (int d = 0; d < evalN; d++) if (acc[d] > 0.0) used += 1.0;
    return vec3(used * 0.125, used * 0.125, used * 0.125);
}
vec3 mapRaw =
    texture(Aerial, cuv + inv * vec2(-1,-1)).rgb * 1.0 +
    texture(Aerial, cuv + inv * vec2( 0,-1)).rgb * 2.0 +
    texture(Aerial, cuv + inv * vec2( 1,-1)).rgb * 1.0 +
    texture(Aerial, cuv + inv * vec2(-1, 0)).rgb * 2.0 +
    texture(Aerial, cuv                         ).rgb * 4.0 +
    texture(Aerial, cuv + inv * vec2( 1, 0)).rgb * 2.0 +
    texture(Aerial, cuv + inv * vec2(-1, 1)).rgb * 1.0 +
    texture(Aerial, cuv + inv * vec2( 0, 1)).rgb * 2.0 +
    texture(Aerial, cuv + inv * vec2( 1, 1)).rgb * 1.0;
vec3 mapBase = bf6_pow(max(mapRaw * (1.0 / 16.0), 0.0), 2.2);
vec3 detailRatio = clamp(detail, 0.82, 1.18);
float detailAmount = saturate(MapDetailStrength) * (1.0 - outside);
vec3 distantCol = saturate(mapBase * mix(vec3(1.0, 1.0, 1.0), detailRatio, detailAmount));
vec3 grassCol = grassPremul / max(grassAlpha, 1.0e-4);
float grassBlend = saturate(grassAlpha * GroundGrassStrength) * (1.0 - outside);
distantCol = mix(distantCol, saturate(grassCol), grassBlend);
vec3 playableCol = distantCol;
vec3 finalCol = mix(playableCol, baked, outside);
vec2 exactUV = (pm - ExactPageLo.xy) / max(ExactPageSpan.xy, 0.001);
float exactEdge = min(min(exactUV.x, exactUV.y),
                      min(1.0 - exactUV.x, 1.0 - exactUV.y));
vec4 exactSample = textureLod(ExactPage, saturate(exactUV), 0);
float exactUnhandled = step(0.70, exactSample.r)
                     * step(exactSample.g, 0.30)
                     * step(0.70, exactSample.b);
float exactMask = saturate(exactEdge * 64.0)
                * saturate(ExactPageEnabled)
				* saturate(ExactBaseColorEnabled)
                * (1.0 - exactUnhandled);
vec3 exactCol = exactSample.rgb;
return mix(finalCol, exactCol, exactMask);

}

vec3 terrain_normal(vec3 WPos, vec3 GeoNormal) {

vec3 geometricWorld = normalize(GeoNormal);
vec2 groundUV = (WPos.xy * 0.01 - GroundLo.xy) / max(GroundSpan.xy, 1.0);
float insideGround = step(0.0, groundUV.x) * step(groundUV.x, 1.0)
                   * step(0.0, groundUV.y) * step(groundUV.y, 1.0)
                   * saturate(GroundNormalEnabled);
vec3 tangentNormal = textureLod(GroundNormal, saturate(groundUV), 0).rgb * 2.0 - 1.0;
vec3 tangentX = vec3(1.0, 0.0, 0.0)
                - geometricWorld * geometricWorld.x;
float tangentLength2 = dot(tangentX, tangentX);
tangentX = tangentLength2 > 1.0e-6
    ? tangentX * inversesqrt(tangentLength2)
    : vec3(0.0, 1.0, 0.0);
vec3 tangentY = normalize(cross(geometricWorld, tangentX));
vec3 bakedWorld = normalize(tangentX * tangentNormal.x
                            + tangentY * tangentNormal.y
                            + geometricWorld * max(tangentNormal.z, 0.05));
float bakedValid = step(0.05, dot(bakedWorld, geometricWorld));
vec3 fallbackWorld = normalize(mix(
    geometricWorld, bakedWorld, insideGround * bakedValid));
vec2 uv = (WPos.xy * 0.01 - ExactPageLo.xy) / max(ExactPageSpan.xy, 0.001);
float edge = min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y));
float mask = saturate(edge * 64.0) * saturate(ExactPageEnabled);
vec3 basePage = textureLod(ExactPage, saturate(uv), 0).rgb;
float unhandled = step(0.70, basePage.r)
                * step(basePage.g, 0.30)
                * step(0.70, basePage.b);
mask *= 1.0 - unhandled;
vec2 horizontal = textureLod(ExactNormalPage, saturate(uv), 0).rg * 2.0 - 1.0;
float vertical = textureLod(ExactMaterialPage, saturate(uv), 0).g * 2.0 - 1.0;
vec3 packedWorld = vec3(horizontal.x, horizontal.y, vertical);
float packedLength2 = dot(packedWorld, packedWorld);
vec3 unrealWorld = packedLength2 > 1.0e-6
    ? packedWorld * inversesqrt(packedLength2)
    : fallbackWorld;
float validNormal = step(0.05, dot(unrealWorld, geometricWorld));
return normalize(mix(fallbackWorld, unrealWorld, mask * validNormal));

}

float terrain_roughness(vec3 WPos) {

vec2 uv = (WPos.xy * 0.01 - ExactPageLo.xy) / max(ExactPageSpan.xy, 0.001);
float edge = min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y));
float mask = saturate(edge * 64.0) * saturate(ExactPageEnabled);
vec3 basePage = textureLod(ExactPage, saturate(uv), 0).rgb;
float unhandled = step(0.70, basePage.r)
                * step(basePage.g, 0.30)
                * step(0.70, basePage.b);
mask *= 1.0 - unhandled;
float smoothness = textureLod(ExactMaterialPage, saturate(uv), 0).a;
return mix(saturate(GroundRoughness), saturate(1.0 - smoothness), mask);

}

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
