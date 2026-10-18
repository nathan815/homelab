#!/usr/bin/env python3
"""Fail if an image reference isn't <name>:<non-latest tag>@sha256:<64 hex>.

Checks compose `image:` values and Dockerfile `FROM`s. Refs containing ${...}
(built in-repo, e.g. lanindex) are exempt, as is `FROM scratch` and stage names.
"""
import re
import subprocess
import sys

FILES = ["stacks/*/*.yml", "stacks/*/*.yaml", "ansible/roles/*/templates/docker-compose.yml.j2",
         ".woodpecker/*.yaml", "ansible/Dockerfile", "apps/*/Dockerfile"]
IMAGE = re.compile(r"^\s*(?:-\s*)?image:\s*(?P<q>[\"']?)(?P<ref>[^\s\"'#]+)(?P=q)\s*(?:#.*)?$")
FROM = re.compile(r"^FROM\s+(?:--platform=\S+\s+)?(?P<ref>\S+)(?:\s+AS\s+(?P<as>\S+))?\s*(?:#.*)?$", re.I)
GOOD = re.compile(r"^[^@:\s]+(?::\d+)?[^@:\s]*:(?P<tag>[^@:\s]+)@sha256:[0-9a-f]{64}$")


def main():
    files = subprocess.check_output(["git", "ls-files", *FILES], text=True).split()
    stages, bad = set(), []
    for f in files:
        for n, line in enumerate(open(f).read().splitlines(), 1):
            m = IMAGE.match(line) or FROM.match(line)
            if not m:
                continue
            ref = m.group("ref")
            if f.endswith("Dockerfile"):
                if ref == "scratch" or ref in stages:
                    stages.add(m.group("as") or "")
                    continue
                if m.group("as"):
                    stages.add(m.group("as"))
            if "${" in ref:
                continue
            g = GOOD.match(ref)
            if not g or g.group("tag") == "latest":
                bad.append(f"{f}:{n}: {ref}")
    if bad:
        print("Images must be <name>:<version tag>@sha256:<digest> (no :latest):")
        print("\n".join(bad))
        sys.exit(1)


main()
