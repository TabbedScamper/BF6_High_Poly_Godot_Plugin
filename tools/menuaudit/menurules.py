"""Rules over the extracted panel graph, aimed at the person who will not read
the source to find out why a checkbox did nothing.

Each rule states the user-visible symptom, not the code smell.
"""
import os, re, json, sys

D = (r"C:\PortalSDK\GodotProject\User_Created\tools"
     r"\bf6-portal-highpoly-preview\addons\highpoly_toggle")
SRC = open(os.path.join(D, "highpoly_toggle.gd"), encoding="utf-8").read()
L = SRC.split("\n")
G = json.load(open(sys.argv[1], encoding="utf-8"))

def ctx(i, n=3):
    return "\n".join("      %s" % x.strip() for x in L[max(0, i - n):i + n])

print("=" * 78)
print("1. DISABLED WITH NO REASON GIVEN")
print("   Greying a control out without saying what to switch on is the single")
print("   most common way a panel wastes somebody's afternoon.")
print("=" * 78)
DIS = re.compile(r"\b(\w+)\.disabled\s*=\s*(.+)")
seen = set()
for i, ln in enumerate(L):
    if ln.strip().startswith("#"):
        continue
    m = DIS.search(ln)
    if not m or m.group(1) not in G:
        continue
    name, cond = m.group(1), m.group(2).strip()
    if cond in ("false",):
        continue
    # is a reason set anywhere near it? (a tooltip or label rewrite)
    near = "\n".join(L[max(0, i - 6):i + 7])
    told = ("%s.tooltip_text" % name) in near or ("%s.text" % name) in near
    key = (name, cond)
    if key in seen:
        continue
    seen.add(key)
    print("  %-20s line %-5d disabled when: %s" % (name, i + 1, cond[:46]))
    print("      label %-28s reason shown to the user: %s"
          % (G[name]["label"][:28] or "(none)", "yes" if told else "NO"))

print()
print("=" * 78)
print("2. CHILDREN LEFT BEHIND")
print("   A sub-option that stays ticked after its parent is switched off reads")
print("   as 'this is on' when nothing is happening.")
print("=" * 78)
PARENTS = {
    "mapctx_light": ["mapctx_gi", "mapctx_shadows", "mapctx_maplights",
                     "mapctx_fill"],
    "col_chk": ["iso_chk", "col_alpha"],
    "mapctx_on": ["mapctx_maptile"],
    "mapctx_objects": ["mapctx_variant"],
}
for p, kids in PARENTS.items():
    if p not in G:
        continue
    # Use the graph, which already inlined the functions the handler delegates
    # to. Re-parsing just the handler body reported four of these as broken
    # when every one was handled inside a callee.
    touched = {a for a, _b in G[p]["writes"]}
    for k in kids:
        # A control is often gated by hiding the ROW it sits in, so the control
        # itself is never named. That is still handled.
        ok = k in touched or ("%s_row" % k) in SRC and re.search(
            r"\b%s_row\.visible" % k, SRC)
        print("  %-16s -> %-18s %s" % (p, k,
              "handled" if ok else "NOT TOUCHED when the parent flips"))

print()
print("=" * 78)
print("3. THINGS THAT VANISH INSTEAD OF GREYING OUT")
print("   Controls appearing and disappearing move everything below them, so a")
print("   click can land on the wrong row.")
print("=" * 78)
for n, c in G.items():
    vis = [a for a, b in c["writes"] if b == "visible"]
    if vis:
        print("  %-18s (%s) shows/hides: %s"
              % (n, c["label"][:22] or "?", ", ".join(sorted(set(vis)))))

print()
print("=" * 78)
print("4. SILENT CHANGES TO SOMETHING THE USER SET")
print("=" * 78)
for n, c in G.items():
    sil = [a for a, b in c["writes"] if b == "moved silently"]
    if sil:
        print("  %-18s (%s) also un/re-ticks: %s"
              % (n, c["label"][:22] or "?", ", ".join(sorted(set(sil)))))
