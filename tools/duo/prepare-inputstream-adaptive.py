#!/usr/bin/env python3
"""Reconstruct the companion add-on source used by the Duo build."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def output(*args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def main():
    directory = Path(__file__).resolve().parent
    manifest = json.loads((directory / "source-manifest.json").read_text())
    addon = manifest["inputstream_adaptive"]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new checkout directory (must not exist)")
    parser.add_argument("--repository", default=addon["repository"],
                        help="upstream URL or a local Git clone for offline reconstruction")
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists():
        parser.error("destination already exists; choose a new directory")

    patches = []
    for entry in addon["patches"]:
        patch = directory / entry["file"]
        if hashlib.sha256(patch.read_bytes()).hexdigest() != entry["sha256"]:
            raise SystemExit(f"Patch checksum mismatch: {patch.name}")
        patches.append(str(patch))

    # Require a Git identity for git am, without storing or changing the user's config.
    output("git", "var", "GIT_COMMITTER_IDENT", cwd=directory)
    run("git", "clone", "--no-checkout", "--", args.repository, str(destination))
    run("git", "checkout", "--detach", addon["base_commit"], cwd=destination)
    run("git", "am", *patches, cwd=destination)
    tree = output("git", "rev-parse", "HEAD^{tree}", cwd=destination)
    if tree != addon["source_tree"]:
        raise SystemExit(f"Source tree mismatch: expected {addon['source_tree']}, got {tree}")
    if output("git", "status", "--porcelain", cwd=destination):
        raise SystemExit("Reconstructed source tree is not clean")
    print(f"Verified InputStream Adaptive source: {destination}\nTree: {tree}")


if __name__ == "__main__":
    main()
