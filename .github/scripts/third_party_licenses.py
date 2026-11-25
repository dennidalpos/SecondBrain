"""Write the license texts of the crates linked into `sb` for one target.

Usage: python third_party_licenses.py <target triple> <output file>
Reads `cargo metadata` for cli/Cargo.toml, follows the normal (non-dev,
non-build) dependencies from the root package, and copies each crate's
LICENSE, COPYING, UNLICENSE and NOTICE files into one text file.
"""

import json
import pathlib
import subprocess
import sys

NAMES = ("LICENSE", "LICENCE", "COPYING", "UNLICENSE", "NOTICE")


def main() -> int:
    target, out = sys.argv[1], pathlib.Path(sys.argv[2])
    meta = json.loads(
        subprocess.check_output(
            [
                "cargo", "metadata", "--locked", "--format-version", "1",
                "--filter-platform", target, "--manifest-path", "cli/Cargo.toml",
            ]
        )
    )
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    seen, stack = set(), [meta["resolve"]["root"]]
    while stack:
        for dep in nodes[stack.pop()]["deps"]:
            normal = any(k["kind"] is None for k in dep["dep_kinds"])
            if normal and dep["pkg"] not in seen:
                seen.add(dep["pkg"])
                stack.append(dep["pkg"])

    parts = [
        "Third-party licenses for sb (" + target + ")\n",
        "sb itself is MIT licensed (see LICENSE). It links the crates below.\n",
    ]
    missing = []
    for pkg in sorted((packages[i] for i in seen), key=lambda p: (p["name"], p["version"])):
        folder = pathlib.Path(pkg["manifest_path"]).parent
        files = sorted(
            f for f in folder.iterdir()
            if f.is_file() and f.name.upper().startswith(NAMES)
        )
        parts.append("=" * 72)
        parts.append(f"{pkg['name']} {pkg['version']}  ({pkg.get('license') or 'no SPDX expression'})")
        if pkg.get("repository"):
            parts.append(pkg["repository"])
        if not files:
            missing.append(pkg["name"])
            parts.append("(no license file in the published crate; see the SPDX expression above)")
        for f in files:
            parts.append("-" * 72 + "\n" + f.name + "\n")
            parts.append(f.read_text(encoding="utf-8", errors="replace").rstrip() + "\n")
    out.write_text("\n".join(parts) + "\n", encoding="utf-8", newline="\n")
    print(f"{len(seen)} crates, {len(missing)} without a license file: {', '.join(missing) or '-'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
