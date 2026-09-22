#!/usr/bin/env python3
"""Consistency checks for the addon package: run before zipping in CI."""
import json
import os
import re
import sys

errors = []

addon = json.load(open("addon.json"))
lang = json.load(open("lang/en-US.json"))
readme = open("README.md", encoding="utf-8").read()

# Every packaged file exists, and every shipped file is packaged.
file_list = addon["file-list"]
for f in file_list:
    if not os.path.exists(f):
        errors.append(f"file-list entry missing on disk: {f}")
for f in ["addon.json", "effect.fx", "effect.wgsl", "icon.svg", "lang/en-US.json"]:
    if f not in file_list:
        errors.append(f"shipped file not in file-list: {f}")

# Version in addon.json matches the newest README changelog heading.
version = re.sub(r"\.0$", "", addon["version"])
m = re.search(r"^## Changes in (\S+)", readme, re.M)
if not m:
    errors.append("README has no '## Changes in X' heading")
elif m.group(1) != version:
    errors.append(f"addon.json version {version} != README newest changelog {m.group(1)}")

# A release tag must match the addon version.
tag = os.environ.get("GITHUB_REF_NAME", "")
if os.environ.get("GITHUB_REF_TYPE") == "tag" and re.sub(r"^v", "", tag) != version:
    errors.append(f"tag {tag} does not match addon.json version {version}")

# Parameter ids agree between addon.json and the language file, in order.
ids = [p["id"] for p in addon["parameters"]]
lang_ids = list(lang["text"]["effects"][addon["id"]]["parameters"].keys())
if ids != lang_ids:
    errors.append(f"parameter ids differ: addon.json {ids} vs lang {lang_ids}")

# Every uniform is declared in the WebGL shader, and the WGSL struct has one
# member per parameter (Construct maps the struct by position).
fx = open("effect.fx", encoding="utf-8").read()
for p in addon["parameters"]:
    if not re.search(r"^uniform\s+(float|vec3)\s+%s\s*;" % re.escape(p["uniform"]), fx, re.M):
        errors.append(f"uniform {p['uniform']} not declared in effect.fx")
wgsl = open("effect.wgsl", encoding="utf-8").read()
m = re.search(r"struct ShaderParams \{(.*?)\};", wgsl, re.S)
members = re.findall(r"^\s*(\w+)\s*:\s*(f32|vec3<f32>)", m.group(1), re.M) if m else []
member_names = [name for name, _ in members]
if member_names != ids:
    errors.append(f"ShaderParams members {member_names} do not match parameter ids {ids}")

if errors:
    print("\n".join("error: " + e for e in errors))
    sys.exit(1)
print(f"ok: version {version}, {len(ids)} parameters, {len(file_list)} files")
