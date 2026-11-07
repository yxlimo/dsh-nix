#!/usr/bin/env python3
"""Regenerate npm/package-lock.json for a published dsh version.

The lockfile is what Nix's `importNpmLock` turns into `npmDeps`, so it has to
cover the whole dependency tree of `@deepseek-ai/dsh`, including the optional
per-platform bindings of `node-addon-require-builtin` on every platform we
build for. `npm install --package-lock-only` records all of them regardless of
the host, which is exactly what we want.

Usage:
    python3 scripts/gen-lock.py                # newest published version
    python3 scripts/gen-lock.py 0.2.2-rc.1     # a specific one
"""

import json
import os
import subprocess
import sys
import tempfile
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(REPO, "npm")
PACKAGE = "@deepseek-ai/dsh"


def latest_version(registry: str) -> str:
    url = f"{registry}/{PACKAGE}".replace("/", "%2F", 1) if "npmjs.org" in registry else f"{registry}/{PACKAGE}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        data = json.load(resp)
    tags = data["dist-tags"]
    # `next` is the newer candidate, `latest` the staged one; prefer whichever
    # is actually newer so the lockfile matches what we package.
    return max(tags.get("latest", ""), tags.get("next", ""), key=_semver_key)


def _semver_key(v: str):
    # Good enough for ordering rc/alpha prereleases of a 0.x package.
    core, _, pre = v.partition("-")
    nums = [int(p) for p in core.split(".") if p.isdigit()]
    while len(nums) < 3:
        nums.append(0)
    return (nums, pre == "", pre)


def main() -> int:
    registry = os.environ.get("DSH_NPM_REGISTRY", "https://registry.npmjs.org")
    version = sys.argv[1] if len(sys.argv) > 1 else latest_version(registry)
    print(f"generating lockfile for {PACKAGE}@{version} from {registry}")

    os.makedirs(OUTDIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "package.json"), "w") as fh:
            json.dump({"name": "dsh-npm-root", "private": True}, fh)
        subprocess.run(
            [
                "npm",
                "install",
                "--package-lock-only",
                "--no-audit",
                "--no-fund",
                "--registry",
                registry,
                f"{PACKAGE}@{version}",
            ],
            cwd=tmp,
            check=True,
        )
        for name in ("package.json", "package-lock.json"):
            with open(os.path.join(tmp, name)) as src, open(
                os.path.join(OUTDIR, name), "w"
            ) as dst:
                dst.write(src.read())

    print(f"wrote {OUTDIR}/package.json and npm/package-lock.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
