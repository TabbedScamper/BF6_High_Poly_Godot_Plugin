"""Deploy high-poly preview assets for a Portal level scene.

Scans a level .tscn for every placed prop, resolves each proxy to its extracted
game mesh (matches.tsv — including hand-pinned corrections), extracts any that
are missing straight from the game dump, and writes ready-to-use GLBs (vertex
normals + full PBR textures) into the Godot project's res://highpoly/ folder
for the Low/High-Poly Interchange plugin.

Usage:
  python deploy_scene.py <level.tscn> [godot_project_dir]

Defaults to the Portal SDK GodotProject next to this pipeline if omitted.
Re-running is safe: existing up-to-date GLBs are kept, pins are respected.
"""
import os, re, sys, io, glob, json, contextlib
import numpy as np
import trimesh
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rebuild_one_noshadow import DUMP, OUT, main as rebuild
from build_site import fix_normal_z

PIPE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(PIPE, "data")
DEFAULT_GP = os.environ.get("PORTAL_GODOT_PROJECT", "")

# multi-part assemblies that need several game meshes merged into one GLB
ASSEMBLIES = {
    "WreckTank_Abra01": ["mil_wrecktank_abrams_01_chassis", "mil_wrecktank_abrams_01_turret",
                         "mil_wrecktank_abrams_01_barrel"] + [f"mil_wrecktank_abrams_01_debris0{i}" for i in range(1, 7)],
}

def scene_props(tscn):
    txt = open(tscn, encoding="utf-8", errors="ignore").read()
    return sorted(set(re.findall(r'objects/[a-z]+/([A-Za-z0-9_]+)\.tscn', txt)))

def load_matches():
    m = {}
    for ln in open(os.path.join(DATA, "matches.tsv"), encoding="utf-8"):
        p = ln.rstrip("\n").split("\t")
        if len(p) >= 4 and p[0] != "godot_proxy":
            m[p[0]] = (p[1], p[3])
    return m

def meshset_index():
    idx = {}
    for ms in glob.glob(os.path.join(DUMP, "bundles", "**", "*.MeshSet"), recursive=True):
        b = os.path.basename(ms)[:-8]
        nm = b[:-5] if b.endswith("_mesh") else b
        idx.setdefault(nm, ms)
    return idx

def ensure_extracted(game, msidx):
    if os.path.exists(os.path.join(OUT, game, game + ".obj")):
        return True
    ms = msidx.get(game)
    if not ms:
        return False
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rebuild(game, ms)
        return os.path.exists(os.path.join(OUT, game, game + ".obj"))
    except Exception:
        return False

def build_mesh(game, texcap=1024):
    """textured trimesh with vertex normals (Godot needs them for tangents)"""
    pd = os.path.join(OUT, game)
    m = trimesh.load(os.path.join(pd, game + ".obj"), process=False)
    m.faces = m.faces[:, ::-1]                 # DX winding -> glTF CCW
    m.vertex_normals = m.vertex_normals       # force + persist smooth normals
    kw = {"metallicFactor": 0.0, "roughnessFactor": 0.9, "doubleSided": True}
    bc = os.path.join(pd, "basecolor.png")
    if os.path.exists(bc):
        img = Image.open(bc).convert("RGBA"); img.thumbnail((texcap, texcap))
        kw["baseColorTexture"] = img
    nm = os.path.join(pd, "normal.png")
    if os.path.exists(nm):
        nimg = Image.open(nm).convert("RGB"); nimg.thumbnail((texcap, texcap))
        kw["normalTexture"] = fix_normal_z(nimg)
    mr = os.path.join(pd, "mr.png")
    if os.path.exists(mr):
        kw["metallicRoughnessTexture"] = Image.open(mr).convert("RGB")
        kw.pop("roughnessFactor", None)
    m.visual = trimesh.visual.TextureVisuals(
        uv=getattr(m.visual, "uv", None),
        material=trimesh.visual.material.PBRMaterial(**kw))
    return m

def deploy_one(prox, game, hpdir, msidx):
    d = os.path.join(hpdir, prox)
    dest = os.path.join(d, prox + ".glb")
    if prox in ASSEMBLIES:
        sc = trimesh.Scene()
        for part in ASSEMBLIES[prox]:
            if ensure_extracted(part, msidx):
                sc.add_geometry(build_mesh(part), node_name=part)
        if not sc.geometry: return "assembly empty"
        os.makedirs(d, exist_ok=True)
        sc.export(dest)
        return None
    if not ensure_extracted(game, msidx):
        return "not extractable"
    src_obj = os.path.join(OUT, game, game + ".obj")
    if os.path.exists(dest) and os.path.getmtime(dest) > os.path.getmtime(src_obj):
        return None                            # up to date
    os.makedirs(d, exist_ok=True)
    build_mesh(game).export(dest)
    build_mesh(game, texcap=256).export(os.path.join(d, prox + "_med.glb"))
    return None

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    tscn = sys.argv[1]
    gp = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_GP
    hpdir = os.path.join(gp, "highpoly")
    props = scene_props(tscn)
    match = load_matches()
    print(f"{len(props)} distinct props in {os.path.basename(tscn)}", flush=True)
    print("indexing meshsets...", flush=True)
    msidx = meshset_index()
    ok = skip = fail = 0
    problems = []
    for prox in props:
        m = match.get(prox)
        if m is None and prox not in ASSEMBLIES:
            skip += 1; problems.append(f"{prox}: no match entry")
            continue
        game = m[0] if m else ""
        err = deploy_one(prox, game, hpdir, msidx)
        if err is None: ok += 1
        else:
            fail += 1; problems.append(f"{prox}: {err}")
    print(f"deployed/current {ok} | unmatched {skip} | failed {fail}")
    for p in problems: print("  -", p)
    print(f"assets in {hpdir} — open the project and use the High-Poly dock.")

if __name__ == "__main__":
    main()
