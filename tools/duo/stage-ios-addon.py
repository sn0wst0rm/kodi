#!/usr/bin/env python3
"""Stage a compiled iOS add-on, including its generated settings resources."""

import argparse
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("addon_id")
    parser.add_argument("source", type=Path)
    parser.add_argument("build", type=Path)
    parser.add_argument("destination", type=Path, help="new add-on directory")
    args = parser.parse_args()
    source = args.source / args.addon_id
    generated = args.build / args.addon_id
    if args.destination.exists():
        parser.error("destination must not exist")

    # CMake configures settings.xml.in as well as addon.xml.in.
    for template in source.rglob("*.in"):
        configured = generated / template.relative_to(source).with_suffix("")
        if not configured.is_file():
            parser.error(f"missing generated resource: {configured}")
        if configured.suffix == ".xml":
            ET.parse(configured)

    addon = ET.parse(generated / "addon.xml").getroot()
    if addon.get("id") != args.addon_id:
        parser.error("generated add-on ID does not match")
    libraries = [extension.get(key) for extension in addon.findall("extension")
                 for key in ("library_darwin_embedded", "library_ios") if extension.get(key)]
    if not libraries or not all((args.build / name).is_file() for name in libraries):
        parser.error("compiled iOS add-on library is missing")

    shutil.copytree(source, args.destination, ignore=shutil.ignore_patterns("*.in"))
    shutil.copytree(generated, args.destination, dirs_exist_ok=True)
    for name in libraries:
        shutil.copy2(args.build / name, args.destination / name)
    print(f"Staged {args.addon_id} {addon.get('version')} with generated resources")


if __name__ == "__main__":
    main()
