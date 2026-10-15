#!/usr/bin/env python3
"""Wraps an effect .metal file into a C++ raw string literal (.inc) that
jet_fx_object.h includes. usage: embed_fx.py <in.metal> <out.inc>"""
import sys
src = open(sys.argv[1]).read()
assert ')JETFX"' not in src
open(sys.argv[2], "w").write('R"JETFX(' + src + ')JETFX"\n')
