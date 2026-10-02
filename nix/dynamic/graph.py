"""Turn the configured objdir's compile tier into a graph of build groups.

The recursive-make backend lists the compile tier's targets in root.mk and
their edges in root-deps.mk, and config/recurse.mk hard-codes a few more.
Asking make for its rule database picks all of them up at once.

Targets with the same dependency set are chunked into groups, each of which
becomes one derivation. Grouping on identical dependency sets cannot create a
cycle: two groups depending on each other would need two targets depending on
each other.

Usage: graph.py OBJDIR CHUNK_SIZE > graph.json
"""

import json
import re
import subprocess
import sys
from collections import defaultdict
from graphlib import TopologicalSorter

objdir, chunk_size = sys.argv[1], int(sys.argv[2])


def root_mk_list(variable):
    with open(f"{objdir}/root.mk") as f:
        for line in f:
            if line.startswith(f"{variable} :="):
                return line.split(":=", 1)[1].split()
    raise SystemExit(f"{variable} not found in root.mk")


targets = set(root_mk_list("compile_targets")) | set(root_mk_list("pre_compile_targets"))

# The goal names nothing: make still reads every makefile and prints the
# database, but has no recipe to run. A real goal such as recurse_compile
# would build, because make runs recipe lines that invoke $(MAKE) even under
# -q or -n, and the compile tier recurses through exactly those.
database = subprocess.run(
    ["make", "-C", objdir, "-pq", ".zen-print-database"],
    capture_output=True,
    text=True,
).stdout

rule = re.compile(r"^([^\s#:=][^:=]*?)::?(?!=)\s*(.*)$")
deps = defaultdict(set)
for line in database.splitlines():
    match = rule.match(line)
    if not match:
        continue
    prerequisites = set(match.group(2).replace("|", " ").split()) & targets
    for target in match.group(1).split():
        if target in targets:
            deps[target] |= prerequisites - {target}

# Link steps, host tools and gkrust are long or unique; give each its own
# derivation instead of chunking them with unrelated targets.
def alone(target):
    return target.endswith(("/target", "/host")) or target.startswith("toolkit/library/rust/")


classes = defaultdict(list)
for target in sorted(targets):
    key = target if alone(target) else frozenset(deps[target])
    classes[key].append(target)

group_of = {}
members = {}
for key in sorted(classes, key=lambda k: classes[k][0]):
    chunk = classes[key]
    for start in range(0, len(chunk), chunk_size):
        part = chunk[start : start + chunk_size]
        name = re.sub(r"[^A-Za-z0-9+._-]", "-", part[0])
        if len(part) > 1:
            name += f"-and-{len(part) - 1}"
        members[name] = part
        for target in part:
            group_of[target] = name

groups = {
    name: {
        "targets": part,
        "deps": sorted({group_of[d] for t in part for d in deps[t]} - {name}),
    }
    for name, part in members.items()
}
order = list(TopologicalSorter({n: g["deps"] for n, g in groups.items()}).static_order())

json.dump({"groups": groups, "order": order}, sys.stdout, indent=1, sort_keys=True)
