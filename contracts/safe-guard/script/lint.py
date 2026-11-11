#!/usr/bin/env python3
"""Run Forge lint with canonical import paths across the two Foundry projects.

Forge 1.8.1's Solar frontend can load an external dependency under both a relative
and an absolute path, reporting duplicate declarations. Canonicalizing remappings
for lint avoids that aliasing without changing either project's compiler settings.
"""
import os
from pathlib import Path
import subprocess
import sys

os.chdir(Path(__file__).resolve().parent.parent)
remappings = subprocess.check_output(["forge", "remappings"], text=True).splitlines()
canonical = []
for mapping in remappings:
    prefix, target = mapping.split("=", 1)
    if ":" in prefix:
        context, name = prefix.split(":", 1)
        prefix = str(Path(context).resolve()) + "/:" + name
    canonical.append(prefix + "=" + str(Path(target).resolve()) + "/")
env = os.environ.copy()
env["FOUNDRY_REMAPPINGS"] = "\n".join(canonical)
os.execvpe("forge", ["forge", "lint", *sys.argv[1:]], env)
