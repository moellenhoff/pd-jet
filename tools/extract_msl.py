#!/usr/bin/env python3
"""Pulls the Metal Shading Language sources embedded as C string literals
out of src/*.mm into one .metal file per object, so tools/msltest.mm can
compile them with Metal's runtime compiler - the same path Pd takes
(newLibraryWithSource:), no Metal toolchain install needed.

usage: extract_msl.py <src_dir> <out_dir>
Exits non-zero if it finds no shader at all (almost certainly a broken
extraction rather than a project without shaders).
"""
import ast
import glob
import os
import re
import sys

src_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
for stale in glob.glob(os.path.join(out_dir, "*.metal")):
    os.remove(stale)

LITERAL = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*;?\s*$')
found = 0

for path in sorted(glob.glob(os.path.join(src_dir, "*.mm"))):
    lines = open(path).read().split("\n")
    n = 0
    for i, line in enumerate(lines):
        # a shader source starts with a string literal that begins with
        # "#include <" - deliberately NOT matching "<metal_stdlib>"
        # itself, or a mangled include would make the file silently
        # drop out of the test instead of failing it
        if not re.match(r'^\s*"#include <', line):
            continue
        parts = []
        for l in lines[i:]:
            s = l.strip()
            if s.startswith("//"):
                continue  # comment lines between concatenated literals
            m = LITERAL.match(s)
            if not m:
                break
            parts.append(ast.literal_eval('"' + m.group(1) + '"'))
        name = os.path.basename(path)[:-3] + (".metal" if n == 0 else ".%d.metal" % n)
        open(os.path.join(out_dir, name), "w").write("".join(parts))
        n += 1
        found += 1

if found == 0:
    sys.exit("extract_msl: no embedded shader found in " + src_dir)
print("extract_msl: %d shader source(s) extracted" % found)
