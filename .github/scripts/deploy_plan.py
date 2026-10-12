#!/usr/bin/env python3
"""Decide which stacks .github/workflows/deploy.yml deploys.

A stack is deployable when komodo/komodo.toml declares it git-backed (`repo`
set) with `run_directory = "stacks/<name>"`, so the Komodo stack name, the
stacks/ folder, the apps/ folder and the deploy:<name> task all agree.
Stacks Ansible copies to the host (files_on_host) are never deployed from here.
Names must match [a-z0-9-]+ (what ci/komodo-deploy.sh accepts); a git-backed
stack that doesn't is an error, so validate.yml fails before any deploy.

  deploy_plan.py changed <base> <head>   stacks touched between two commits
  deploy_plan.py stack <name>            just <name>, failing if not deployable
  deploy_plan.py list                    every deployable stack

Prints a JSON list of stack names.
"""
import json
import re
import subprocess
import sys
import tomllib


def deployable():
    with open("komodo/komodo.toml", "rb") as f:
        stacks = tomllib.load(f).get("stack", [])
    names = set()
    for s in stacks:
        cfg = s.get("config", {})
        if not cfg.get("repo"):
            continue
        if not re.fullmatch(r"[a-z0-9-]+", s["name"]):
            sys.exit(f"::error::git-backed stack {s['name']!r}: name must match "
                     "[a-z0-9-]+ (ci/komodo-deploy.sh rejects anything else)")
        if cfg.get("run_directory") != f"stacks/{s['name']}":
            print(f"::warning::git-backed stack {s['name']} has run_directory "
                  f"{cfg.get('run_directory')!r}, expected 'stacks/{s['name']}'; "
                  "not deployable by CI", file=sys.stderr)
            continue
        names.add(s["name"])
    return names


def changed(base, head):
    ok = deployable()
    # A new branch or a force push can leave `before` unknown or unreachable,
    # so the change set can't be known: deploy every stack.
    if not base or set(base) == {"0"} or subprocess.run(
            ["git", "cat-file", "-e", f"{base}^{{commit}}"],
            capture_output=True).returncode != 0:
        print(f"previous commit {base!r} unavailable, deploying all stacks",
              file=sys.stderr)
        return sorted(ok)
    out = subprocess.run(["git", "diff", "--name-only", base, head],
                         check=True, capture_output=True, text=True).stdout
    touched = set()
    for path in out.splitlines():
        parts = path.split("/")
        if len(parts) > 2 and parts[0] in ("stacks", "apps"):
            touched.add(parts[1])
    for name in sorted(touched - ok):
        print(f"skipping {name}: not a git-backed stack in komodo/komodo.toml",
              file=sys.stderr)
    return sorted(touched & ok)


def main(argv):
    if argv[:1] == ["changed"] and len(argv) == 3:
        result = changed(argv[1], argv[2])
    elif argv[:1] == ["stack"] and len(argv) == 2:
        if argv[1] not in deployable():
            sys.exit(f"::error::{argv[1]!r} is not a git-backed stack in "
                     "komodo/komodo.toml (run_directory = \"stacks/<name>\")")
        result = [argv[1]]
    elif argv == ["list"]:
        result = sorted(deployable())
    else:
        sys.exit(__doc__)
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
