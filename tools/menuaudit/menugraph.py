"""What actually happens when you click each thing in the panel.

Reading the dock and imagining the click paths is how the two bugs fixed today
survived: a comment asserted behaviour the code did not have. So this does not
reason about the panel, it reads what each handler WRITES and builds the graph
from that.

For every control it finds the signal handler and records, inside that handler:

  enables/disables   X.disabled = ...
  shows/hides        X.visible = ...
  moves silently     X.set_pressed_no_signal(...) / X.select(...)
  relabels           X.text = ...
  rebuilds           _mapctx_changed / _mapctx_rebuild / mapctx.apply

Then it applies the rules that matter to somebody who is not going to read the
source to work out why a checkbox did nothing.
"""
import os, re, json, sys

D = (r"C:\PortalSDK\GodotProject\User_Created\tools"
     r"\bf6-portal-highpoly-preview\addons\highpoly_toggle")
SRC = open(os.path.join(D, "highpoly_toggle.gd"), encoding="utf-8").read()
LINES = SRC.split("\n")

# --- the controls themselves ------------------------------------------------
DECL = re.compile(r"^\s*(\w+)\s*=\s*(?:Theme_\.(chip|button|slider)"
                  r"|(CheckBox|CheckButton|Button|OptionButton|HSlider"
                  r"|MenuButton|LineEdit)\.new)")
LABEL = re.compile(r'Theme_\.\w+\("([^"]+)"')
controls = {}
for i, ln in enumerate(LINES):
    m = DECL.match(ln)
    if not m:
        continue
    name = m.group(1)
    lab = LABEL.search(ln)
    controls[name] = {"line": i + 1, "label": lab.group(1) if lab else "",
                      "kind": m.group(2) or m.group(3) or "?",
                      "tooltip": "", "writes": [], "rebuilds": False,
                      "gated_by": []}

# tooltip that follows the declaration
for name, c in controls.items():
    for j in range(c["line"] - 1, min(c["line"] + 6, len(LINES))):
        if "%s.tooltip_text" % name in LINES[j]:
            t = re.search(r'=\s*"(.*)', LINES[j])
            if t:
                c["tooltip"] = t.group(1)
            elif "MAPTILE_TIP" in LINES[j]:
                c["tooltip"] = "(MAPTILE_TIP)"
            break

# --- what each handler does -------------------------------------------------
SIGNAL = re.compile(r"^\s*(\w+)\.(toggled|pressed|item_selected|value_changed"
                    r"|text_submitted)\.connect\(")
WRITE = re.compile(r"\b(\w+)\.(disabled|visible)\s*=")
SILENT = re.compile(r"\b(\w+)\.(set_pressed_no_signal|select)\s*\(")
REBUILD = re.compile(r"_mapctx_changed\(|_mapctx_rebuild\(|mapctx\.apply\(")

def handler_body(start):
    """Lines of the lambda/handler that begins on `start` (0-based)."""
    base = len(LINES[start]) - len(LINES[start].lstrip("\t"))
    out = [LINES[start]]
    j = start + 1
    while j < len(LINES):
        ln = LINES[j]
        if ln.strip() == "":
            j += 1; continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if ind <= base and not ln.lstrip().startswith(")"):
            break
        out.append(ln)
        j += 1
    return out

def func_body(name):
    """The body of `func name(...)`, or '' if there isn't one."""
    for i, ln in enumerate(LINES):
        if re.match(r"^\s*(static\s+)?func\s+%s\s*\(" % re.escape(name), ln):
            out = [ln]
            j = i + 1
            while j < len(LINES):
                cur = LINES[j]
                if cur.strip() and not cur.startswith(("\t", " ")):
                    break
                out.append(cur)
                j += 1
            return "\n".join(out)
    return ""

CALL = re.compile(r"\b(_[a-z]\w*)\s*\(")

def expand(body, depth=1):
    """Inline the functions a handler calls.

    WITHOUT THIS THE REPORT IS MOSTLY NOISE. Almost every handler here is one
    line that delegates — col_chk.toggled just calls _collision_changed(), and
    THAT is where iso_chk gets disabled. A first run flagged four "children left
    behind" and every one of them was handled inside a callee.
    """
    if depth <= 0:
        return body
    seen, out = set(), [body]
    for m in CALL.finditer(body):
        n = m.group(1)
        if n in seen:
            continue
        seen.add(n)
        fb = func_body(n)
        if fb:
            out.append(expand(fb, depth - 1))
    return "\n".join(out)

for i, ln in enumerate(LINES):
    m = SIGNAL.match(ln)
    if not m or m.group(1) not in controls:
        continue
    c = controls[m.group(1)]
    body = expand("\n".join(handler_body(i)), depth=2)
    if REBUILD.search(body):
        c["rebuilds"] = True
    for w in WRITE.finditer(body):
        if w.group(1) in controls and w.group(1) != m.group(1):
            c["writes"].append((w.group(1), w.group(2)))
    for w in SILENT.finditer(body):
        if w.group(1) in controls and w.group(1) != m.group(1):
            c["writes"].append((w.group(1), "moved silently"))

# --- who gates whom, anywhere in the file -----------------------------------
for i, ln in enumerate(LINES):
    if ln.strip().startswith("#"):
        continue
    for w in WRITE.finditer(ln):
        tgt = w.group(1)
        if tgt in controls and w.group(2) == "disabled":
            controls[tgt]["gated_by"].append(i + 1)

json.dump(controls, open(sys.argv[1], "w", encoding="utf-8"), indent=1)
print("%d control(s)" % len(controls))
for n, c in sorted(controls.items(), key=lambda kv: kv[1]["line"]):
    eff = ", ".join("%s:%s" % (a, b) for a, b in c["writes"][:6])
    print("  %-22s %-28s %-11s rebuild=%-5s %s"
          % (n, c["label"][:28], c["kind"], c["rebuilds"], eff[:70]))
