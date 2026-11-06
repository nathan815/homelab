#!/usr/bin/env python3
"""Decide which stacks .github/workflows/deploy.yml deploys.

A stack is deployable when komodo/komodo.toml declares it git-backed (`repo`
set) with `run_directory = "stacks/<folder>"` and is named `<folder>` or, for a
folder deployed to several Komodo servers (one stack per server),
`<folder>_<server>`. Changing stacks/<folder>/ or apps/<folder>/ deploys every
such stack, and the deploy:<stack> task uses the Komodo stack name.
Stacks in MANUAL_ONLY (woodpecker) are skipped too.
Stacks Ansible copies to the host (files_on_host) are never deployed from here.
Names must match [a-z0-9_-]+ and folders [a-z0-9-]+ (what ci/komodo-deploy.sh
accepts); a git-backed stack that doesn't is an error, so validate.yml fails
before any deploy.

  deploy_plan.py changed <base> <head>   stacks touched between two commits
  deploy_plan.py stack <name|folder>     that stack (or every stack of the
                                         folder), failing if not deployable
  deploy_plan.py list                    every deployable stack

Prints a JSON list of stack names.
"""
import json
import re
import subprocess
import sys
import tomllib


# Git-backed stacks CI must never deploy: Woodpecker runs the deploy pipeline,
# so redeploying it from that pipeline would kill the deploy that triggered it.
# Deploy these by hand from the Komodo UI (komodo/README.md).
MANUAL_ONLY = {"woodpecker"}


def deployable():
    """Map each CI-deployable Komodo stack name to its stacks/ folder."""
    with open("komodo/komodo.toml", "rb") as f:
        stacks = tomllib.load(f).get("stack", [])
    folders = {}
    for s in stacks:
        cfg = s.get("config", {})
        if not cfg.get("repo"):
            continue
        name = s["name"]
        if name in MANUAL_ONLY:
            continue
        if not re.fullmatch(r"[a-z0-9_-]+", name):
            sys.exit(f"::error::git-backed stack {name!r}: name must match "
                     "[a-z0-9_-]+ (ci/komodo-deploy.sh rejects anything else)")
        run_dir = cfg.get("run_directory", "")
        folder = run_dir.removeprefix("stacks/")
        if (not run_dir.startswith("stacks/") or not re.fullmatch(r"[a-z0-9-]+", folder)
                or not (name == folder or name.startswith(folder + "_"))):
            print(f"::warning::git-backed stack {name} has run_directory "
                  f"{run_dir!r}, expected 'stacks/{name}' (or 'stacks/<folder>' "
                  "with the stack named '<folder>_<server>'); not deployable by CI",
                  file=sys.stderr)
            continue
        folders[name] = folder
    return folders


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
    for folder in sorted(touched - set(ok.values())):
        print(f"skipping {folder}: not a git-backed stack in komodo/komodo.toml",
              file=sys.stderr)
    return sorted(name for name, folder in ok.items() if folder in touched)


def main(argv):
    if argv[:1] == ["changed"] and len(argv) == 3:
        result = changed(argv[1], argv[2])
    elif argv[:1] == ["stack"] and len(argv) == 2:
        ok = deployable()
        result = ([argv[1]] if argv[1] in ok
                  else sorted(n for n, f in ok.items() if f == argv[1]))
        if not result:
            sys.exit(f"::error::{argv[1]!r} is not a git-backed stack in "
                     "komodo/komodo.toml (run_directory = \"stacks/<folder>\")")
    elif argv == ["list"]:
        result = sorted(deployable())
    else:
        sys.exit(__doc__)
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
