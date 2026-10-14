#!/usr/bin/env python3
"""Write an app values file that shows EVERY option of k8s/charts/application.

The keys the app sets stay as they are; every other key of the chart is added in its place,
commented out with the chart default, grouped in one block per component (`# ── Image ──` …).
Pipe through strip-notes.py to keep key/value lines only.

usage: gen-app-values.py <app-values.yaml> [> out]
       reads the chart at k8s/charts/application/values.yaml; needs yq v4 (mikefarah)

Run it on a file that has not been through it before (it does not strip its own output).
The EKS template is regenerated from docs/tools/eks-app-values.base.yaml by `make docs-reference`.
"""
import json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHART = os.path.join(ROOT, "k8s/charts/application/values.yaml")
APP = sys.argv[1]

def yq_json(expr, path):
    r = subprocess.run(["yq", "-o=json", expr, path], capture_output=True, text=True, check=True)
    return json.loads(r.stdout)

rows = yq_json('[ .. | select((tag == "!!map" and length > 0) | not) | select(path | length > 0)'
               ' | select(path | map(tag == "!!int") | any | not)'
               ' | {"path": path, "value": ., "comment": (line_comment | sub("^# ?"; ""))} ]', CHART)
heads = yq_json('to_entries | map({"key": .key, "head": (.key | head_comment)})', CHART)
app = yq_json(".", APP) or {}
text = open(APP, encoding="utf-8").read().rstrip("\n").split("\n")

# ── sections of the chart (the `# ── Title ──` headers above top-level keys) ──
section, cur = {}, "General"
for h in heads:
    t = [l for l in h["head"].split("\n") if re.search(r"── .+ ─", l)]
    if t:
        cur = re.sub(r"^#?\s*── *", "", t[-1]); cur = re.sub(r" *─+ *$", "", cur)
        cur = re.sub(r"\s*\(.*\)\s*$", "", cur)             # "Global (shared …)" → "Global"
    section[h["key"]] = cur
order = [h["key"] for h in heads]

# ── split the app file into its header and one block per top-level key ──
KEY = re.compile(r"^([A-Za-z_][\w-]*):(\s|$)")
CKEY = re.compile(r"^#\s?([A-Za-z_][\w-]*):(\s|$)")          # a key the author left commented
starts = []
for i, l in enumerate(text):
    m = KEY.match(l) or (CKEY.match(l) if CKEY.match(l) and CKEY.match(l).group(1) in order else None)
    if m: starts.append((i, m.group(1)))
def owned(i):
    # the comment paragraph right above a key is its own; a blank line ends it
    return text[i].startswith("#")
blocks, header_end = {}, len(text)
for n, (i, k) in enumerate(starts):
    s = i
    prev_end = starts[n - 1][0] if n else -1
    while s - 1 > prev_end and owned(s - 1):
        s -= 1
    if n == 0:
        # file header = everything above the first key's own paragraph; a paragraph that
        # starts the file is the header, not the key's comment
        if s == 0:
            blanks = [x for x in range(0, i) if text[x].strip() == "" or text[x].strip() == "#"]
            s = (blanks[-1] + 1) if blanks else i
        header_end = s
    blocks.setdefault(k, []).append([s, None])
# block end = start of the next block
spans = sorted((v[0][0], k) for k, v in blocks.items())
for n, (s, k) in enumerate(spans):
    blocks[k][0][1] = spans[n + 1][0] if n + 1 < len(spans) else len(text)
header = text[:header_end]

# ── formatting ──
def scalar(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return str(v)
    if v == "": return '""'
    if re.match(r"^[A-Za-z0-9_./@%+-][A-Za-z0-9_./@%+ =,-]*$", v) and v.lower() not in ("true", "false", "null", "yes", "no", "on", "off") \
       and not re.match(r"^[0-9.+-]+$", v) and not v.endswith(" "):
        return v
    return json.dumps(v, ensure_ascii=False)
def flow(v):
    if isinstance(v, dict):
        return "{}" if not v else "{ " + ", ".join(f"{k}: {flow(x)}" for k, x in v.items()) + " }"
    if isinstance(v, list):
        return "[]" if not v else "[ " + ", ".join(flow(x) for x in v) + " ]"
    return scalar(v)
COL = 46
def line(indent, depth, key, val=None, comment=""):
    body = "  " * depth + (f"{key}: {flow(val)}" if val is not ... else f"{key}:")
    s = " " * indent + "# " + body
    if comment: s = s.ljust(COL) + "  # " + comment
    return s

def commented_tree(prefix_len, sub_rows, indent):
    """sub_rows: rows whose path starts with a common prefix of length prefix_len."""
    out, opened = [], []
    for r in sub_rows:
        rel = [str(x) for x in r["path"][prefix_len:]]
        common = 0
        while common < min(len(opened), len(rel) - 1) and opened[common] == rel[common]: common += 1
        opened = opened[:common]
        for d in range(common, len(rel) - 1):
            out.append(line(indent, d, rel[d], ...)); opened.append(rel[d])
        out.append(line(indent, len(rel) - 1, rel[-1], r["value"], r["comment"]))
    return out

# ── assemble ──
out = list(header)
last_sec = None
emitted = set()
for k in order:
    sec = section.get(k, "General")
    if sec != last_sec:
        out += ["", f"# ── {sec} ──"]; last_sec = sec
    krows = [r for r in rows if r["path"][0] == k]
    if k in blocks:
        s, e = blocks[k][0]
        blk = [l for l in text[s:e] if not re.match(r"^\s*# ── ", l)]   # the chart's blocks are the headers
        while blk and blk[-1].strip() == "": blk.pop()
        if out and out[-1].strip() != "" and not out[-1].startswith("# ──"): out.append("")
        out += blk
        v = app.get(k, None) if isinstance(app, dict) else None
        if isinstance(v, dict) and KEY.match(text[[i for i, kk in starts if kk == k][0]]):
            # add the chart's other first-level options of this key, as new commented siblings
            missing = [r for r in krows if len(r["path"]) > 1 and r["path"][1] not in v]
            if missing:
                # right after the key's last indented line, before any trailing top-level comments
                body_end = len(out)
                while body_end > 0 and not out[body_end - 1].startswith(" "): body_end -= 1
                out[body_end:body_end] = commented_tree(1, missing, 2)
        out.append("")
    else:
        if len(krows) == 1 and len(krows[0]["path"]) == 1:
            out.append(line(0, 0, k, krows[0]["value"], krows[0]["comment"]))
        else:
            out += commented_tree(0, krows, 0)
    emitted.add(k)
extra = [k for k in blocks if k not in emitted]
if extra:
    out += ["", "# ── Khác (không có trong chart values.yaml) ─────────────────────────"]
    for k in extra:
        s, e = blocks[k][0]; out += text[s:e]
txt = "\n".join(out)
txt = re.sub(r"\n{3,}", "\n\n", txt).strip("\n") + "\n"
sys.stdout.write(txt)
