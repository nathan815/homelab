#!/usr/bin/env python3
"""Fail if a compose healthcheck runs a binary its image doesn't contain.

Image bumps can silently drop tools (Loki 3.6+ went distroless: no `wget`, no
`sh`), leaving the container permanently "unhealthy". For every service with a
`healthcheck.test`, this resolves the compose file (so ${VAR} images and pinned
digests are real), lists the image's filesystem without running it, and checks
that the healthcheck's executable(s) exist on the image's PATH.

  CMD [...]        -> test[1] must exist
  CMD-SHELL / str  -> /bin/sh must exist, and so must the first word of every
                      `a && b || c ; d | e` segment (shell builtins skipped)

Services without an `image:`, or whose image isn't pinned by digest (built in
this repo, e.g. lanindex; see check_pinned_images.py), are skipped.
Usage: check_healthchecks.py [compose-file ...]   (default: stacks/*/ compose files)
"""
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor

DEFAULT_FILES = ["stacks/*/docker-compose.yml", "stacks/*/compose.yaml", "stacks/*/compose.yml"]
BUILTINS = {"exit", "test", "[", "[[", "true", "false", "echo", "cd", ":", "command", "set", "exec", "if", "then", "fi"}
DEFAULT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SEGMENT = re.compile(r"\|\||&&|;|\||\n")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def compose_cmd():
    """`docker compose` (CI) or the standalone `docker-compose` (some dev machines)."""
    if run(["docker", "compose", "version"]).returncode == 0:
        return ["docker", "compose"]
    return ["docker-compose"]


def compose_config(path):
    cmd = compose_cmd() + ["--profile", "*"]
    env_file = os.path.join(os.path.dirname(path), ".env.defaults")
    if os.path.exists(env_file):
        cmd += ["--env-file", env_file]
    r = run(cmd + ["-f", path, "config", "--format", "json"])
    if r.returncode:
        raise RuntimeError(f"{path}: compose config failed: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout).get("services", {})


def image_files(image):
    """Return (set of file paths in the image, PATH dirs). Pulls if needed."""
    if run(["docker", "image", "inspect", image]).returncode:
        r = run(["docker", "pull", "--quiet", image])
        if r.returncode:
            raise RuntimeError(f"cannot pull {image}: {r.stderr.strip()}")
    info = json.loads(run(["docker", "image", "inspect", image]).stdout)[0]
    env = dict(e.split("=", 1) for e in info["Config"].get("Env") or [] if "=" in e)
    cid = run(["docker", "create", "--entrypoint", "/nonexistent", image]).stdout.strip()
    try:
        proc = subprocess.Popen(["docker", "export", cid], stdout=subprocess.PIPE)
        files = set()
        with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
            for m in tar:
                files.add("/" + m.name.lstrip("./").rstrip("/"))
        proc.wait()
    finally:
        run(["docker", "rm", "-f", cid])
    return files, env.get("PATH", DEFAULT_PATH).split(":")


def required_executables(test):
    """Return (executables, needs_shell) for a normalized healthcheck test list."""
    if not test or test[0] == "NONE":
        return [], False
    if test[0] == "CMD":
        return [test[1]], False
    cmd = test[1] if test[0] == "CMD-SHELL" else " ".join(test)
    exes = []
    for seg in SEGMENT.split(cmd):
        try:
            words = shlex.split(seg)
        except ValueError:
            words = seg.split()
        while words and "=" in words[0] and not words[0].startswith("-"):
            words.pop(0)  # VAR=value prefix
        if words and words[0] not in BUILTINS:
            exes.append(words[0])
    return exes, True


def has(files, path_dirs, exe):
    if "/" in exe:
        return exe in files
    return any(f"{d}/{exe}" in files for d in path_dirs)


def main():
    paths = sys.argv[1:] or sorted(p for pat in DEFAULT_FILES for p in glob.glob(pat))
    bad, checks = [], []  # checks: (path, service, image, executables, needs_shell)
    for path in paths:
        try:
            services = compose_config(path)
        except RuntimeError as e:
            bad.append(str(e))  # fail closed: a skipped file would hide a broken healthcheck
            continue
        for name, svc in services.items():
            test = (svc.get("healthcheck") or {}).get("test")
            image = svc.get("image")
            if not test or not image or svc.get("build") or "@sha256:" not in image:
                continue
            exes, needs_shell = required_executables(test)
            checks.append((path, name, image, exes, needs_shell))

    def load(image):
        try:
            return image_files(image)
        except RuntimeError as e:
            return e

    images = sorted({c[2] for c in checks})
    with ThreadPoolExecutor(max_workers=4) as pool:
        cache = dict(zip(images, pool.map(load, images)))

    for path, name, image, exes, needs_shell in checks:
        if isinstance(cache[image], RuntimeError):
            bad.append(f"{path}: service {name}: {cache[image]}")
            continue
        files, path_dirs = cache[image]
        missing = [e for e in exes if not has(files, path_dirs, e)]
        if needs_shell and not has(files, path_dirs, "sh"):
            missing.insert(0, "sh")
        print(f"{'FAIL' if missing else 'ok':4} {path}: {name} ({image.split('@')[0]}): {' '.join(exes) or '-'}")
        if missing:
            bad.append(f"{path}: service {name}: healthcheck needs {', '.join(missing)}, "
                       f"not found in {image.split('@')[0]}")
    if bad:
        print("\nHealthcheck problems (container would stay unhealthy):")
        print("\n".join(bad))
        sys.exit(1)


main()
