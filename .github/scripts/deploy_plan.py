#!/usr/bin/env python3
"""Decide which stacks .github/workflows/deploy.yml deploys.

A stack is deployable when komodo/komodo.toml declares it git-backed (`repo`
set) with `run_directory = "stacks/<name>"`, so the Komodo stack name, the
stacks/ folder, the apps/ folder and the deploy:<name> task all agree.
Stacks Ansible copies to the host (files_on_host) are never deployed from here.

  deploy_plan.py changed <base> <head>   stacks touched between two commits
  deploy_plan.py stack <name>            just <name>, failing if not deployable
  deploy_plan.py list                    every deployable stack

Prints a JSON list of stack names.
"""
import json
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
        if cfg.get("run_directory") != f"stacks/{s['name']}":
            print(f"::warning::git-backed stack {s['name']} has run_directory "
                  f"{cfg.get('run_directory')!r}, expected 'stacks/{s['name']}'; "
                  "not deployable by CI", file=sys.stderr)
            continue
        names.add(s["name"])
    return names


def changed(base, head):
    # A new branch or a force push can leave `before` unknown or unreachable;
    # fall back to the head commit's own changes.
    if not base or set(base) == {"0"} or subprocess.run(
            ["git", "cat-file", "-e", f"{base}^{{commit}}"]).returncode != 0:
        base = f"{head}~1"
    out = subprocess.run(["git", "diff", "--name-only", base, head],
                         check=True, capture_output=True, text=True).stdout
    touched = set()
    for path in out.splitlines():
        parts = path.split("/")
        if len(parts) > 2 and parts[0] in ("stacks", "apps"):
            touched.add(parts[1])
    ok = deployable()
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
