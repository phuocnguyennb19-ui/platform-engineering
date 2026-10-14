#!/usr/bin/env python3
"""Keep only key/value lines in a values file: drop prose comments and trailing `# notes`;
keep commented-out options (`# key: value`, `#   - item`), block headers (`# ── Name ──`)
and the content of block scalars (`key: |`) untouched.
usage: strip-notes.py <file>...   (in place)   |   strip-notes.py -   (stdin → stdout)"""
import re, sys

KEYLINE = re.compile(r"^\s*#\s?\s*(- )?([A-Za-z_][\w./-]*|\"[^\"]+\"|'[^']+'):(\s|$)")
LISTLINE = re.compile(r"^\s*#\s+- ")
HEADER = re.compile(r"^\s*# ── ")
TRAIL = re.compile(r"^(.*?\S)\s{2,}#(\s.*)?$")          # value  # note
BLOCK = re.compile(r"^(\s*)(- )?[\w./\"'-]+:\s*[|>][+-]?\d*\s*$")

def is_option(ln):
    """`# key: value` / `#   - item` that is YAML, not a sentence that happens to contain a colon."""
    if LISTLINE.match(ln): return True
    m = KEYLINE.match(ln)
    if not m: return False
    key = m.group(2).strip("\"'")
    if key[0].isupper() and not re.fullmatch(r"[A-Z0-9_]+", key): return False      # "Image: …", "Note: …"
    val = re.sub(r"(^|\s)#.*$", "", ln.split(":", 1)[1]).strip()
    if val and val[0] not in "{[\"'|>&*" and len(val.split()) >= 4: return False   # a sentence
    return True

def drop_trail(s):
    if re.match(r"^\s*\S+:\s+#", s):                    # `key:   # note` → `key:`
        return re.sub(r"\s+#.*$", "", s)
    t = TRAIL.match(s)
    if not t: return s
    head = t.group(1)
    if head.count('"') % 2 or head.count("'") % 2:      # the # sits inside a quoted string
        return s
    return head

def strip(text):
    out, in_block, block_indent = [], False, 0
    for ln in text.split("\n"):
        if in_block:
            ind = len(ln) - len(ln.lstrip())
            if ln.strip() == "" or ind > block_indent:
                out.append(ln); continue
            in_block = False
        s = ln.strip()
        if s.startswith("#"):
            if HEADER.match(ln):
                out.append(ln.rstrip()); continue
            if is_option(ln):
                m = re.match(r"^(\s*#\s?)(.*)$", ln)
                out.append(m.group(1) + drop_trail(m.group(2))); continue
            continue                                     # prose: drop
        if s == "":
            out.append(""); continue
        ln = drop_trail(ln)
        out.append(ln)
        b = BLOCK.match(ln)
        if b:
            in_block, block_indent = True, len(b.group(1))
    txt = "\n".join(out)
    txt = re.sub(r"\n{3,}", "\n\n", txt).strip("\n") + "\n"
    return txt

if sys.argv[1:] == ["-"]:
    sys.stdout.write(strip(sys.stdin.read()))
else:
    for p in sys.argv[1:]:
        with open(p, encoding="utf-8") as f:
            new = strip(f.read())          # read fully BEFORE opening for write
        with open(p, "w", encoding="utf-8") as f:
            f.write(new)
