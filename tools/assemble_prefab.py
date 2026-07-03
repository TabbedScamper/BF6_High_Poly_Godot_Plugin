"""Assemble a composite SDK prefab (props dressing sets etc.) into one
high-poly GLB by reading the game's own prefab blueprint: member object
references + transforms from the pf_*.ebx, member meshes from the extraction
(extracted on demand).

Usage: assemble_prefab.py <ProxyName> [--deploy]
       assemble_prefab.py HouseRuralSpareRoomAddon_01_PropsD --deploy
"""
import os, re, sys, io, glob, contextlib
import numpy as np
import trimesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typesdk, ebx_deser
from rebuild_one_noshadow import DUMP, OUT, main as rebuild
from deploy_scene import build_mesh, meshset_index

DATA = os.environ.get("PIPELINE_DATA", "")
GP = os.environ.get("PORTAL_GODOT_PROJECT", "")

# field name-hashes discovered from the type SDK (member instance layout)
K_TRANSFORM = 2069188341
K_MEMBER = 1803754376
K_VEC = {"x": 956422932, "y": 1123815262, "z": 849976220}
T_RIGHT, T_UP, T_FRONT, T_TRANS = 3296250939, 3205832441, 1767707300, 3159033780

def norm(s):
    s = re.sub(r'^(pf_|pfw_)', '', s.lower())
    return re.sub(r'[^a-z0-9]', '', s)

def find_prefab_ebx(proxy):
    want = norm(re.sub(r'_01_', '_', proxy))  # tolerate dropped _01_ etc.
    want_full = norm(proxy)
    hits = []
    for p in glob.glob(os.path.join(DUMP, "bundles", "**", "pf_*.ebx"), recursive=True):
        b = norm(os.path.basename(p)[:-4])
        if b == want_full or b == want or want_full in b or want in b or b in want_full:
            hits.append(p)
    hits.sort(key=lambda p: (0 if (os.sep + "environment" + os.sep) in p else 1, len(p)))
    return hits[0] if hits else None

def vec(d):
    return np.array([float(d[K_VEC["x"]]), float(d[K_VEC["y"]]), float(d[K_VEC["z"]])])

def member_mesh_name(path, have):
    """object ebx path -> extracted mesh name (handles ov_ variation wrappers)"""
    base = os.path.basename(path)[:-4]
    if base.startswith("decal") or "_nocollision_" in base or base.startswith("ov_de_"):
        return None
    if base in have: return base
    if base.startswith("ov_"):
        # variation wrapper: find the longest extracted prop name inside it
        cand = [n for n in have if n in base]
        if cand: return max(cand, key=len)
        return None
    return base   # not extracted yet; caller will try extraction

def assemble(proxy, deploy=False):
    ebx_path = find_prefab_ebx(proxy)
    if not ebx_path:
        print("no prefab ebx found for", proxy); return False
    print("blueprint:", ebx_path.replace(DUMP, ""))
    pe = typesdk.PE(typesdk.EXE)
    gi = {}
    for ln in open(os.path.join(DATA, "guid_index.tsv"), encoding="utf-8"):
        a, b = ln.rstrip("\n").split("\t", 1); gi[a] = b
    dz = ebx_deser.Deser(pe, ebx_path, gi)
    msidx = meshset_index()
    have = set(os.listdir(OUT))
    sc = trimesh.Scene()
    placed = skipped = 0
    for i in range(len(dz.f.instance_offsets)):
        inst = dz.read_instance(i)
        if not isinstance(inst, dict): continue
        if K_TRANSFORM not in inst or K_MEMBER not in inst: continue
        mem = inst[K_MEMBER]
        if not isinstance(mem, dict) or "path" not in mem: continue
        name = member_mesh_name(str(mem["path"]), have)
        if name is None:
            skipped += 1; continue
        if name not in have:
            ms = msidx.get(name)
            if ms:
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        rebuild(name, ms)
                    have.add(name)
                except Exception:
                    pass
        if not os.path.exists(os.path.join(OUT, name, name + ".obj")):
            skipped += 1; print("  missing mesh:", name); continue
        t = inst[K_TRANSFORM]
        M = np.eye(4)
        M[:3, 0] = vec(t[T_RIGHT])
        M[:3, 1] = vec(t[T_UP])
        M[:3, 2] = vec(t[T_FRONT])
        M[:3, 3] = vec(t[T_TRANS])
        try:
            sc.add_geometry(build_mesh(name), node_name=f"{name}_{i}", transform=M)
            placed += 1
        except Exception as e:
            skipped += 1; print("  mesh fail:", name, e)
    if placed == 0:
        print("nothing placed"); return False
    b = sc.bounds
    print(f"placed {placed} members (skipped {skipped}); extents {(b[1]-b[0]).round(2)}")
    out_dir = os.path.join(GP, "highpoly", proxy)
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, proxy + ".glb")
    sc.export(dest)
    print("wrote", dest, round(os.path.getsize(dest)/1024), "KB")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    assemble(sys.argv[1], "--deploy" in sys.argv)
