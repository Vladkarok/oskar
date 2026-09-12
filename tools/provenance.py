#!/usr/bin/env python3
"""Measure how much of the shell layer is still shared with upstream.

Answers "how much of the panel is still shared with
abdxdev/omarchy-onscreen-keyboard" as a number, so the answer stops being
an argument (spec-v1.md §13, decisions.md §14). It compares the shell-layer
sources against upstream `e3771b6` — the last commit before our own PR
merged into it — and prints shared substantive lines per file and a total.

A line is **substantive** when, trimmed, it is none of:

- blank,
- lone braces (nothing but `{}()[]`),
- a comment (a `//` line, or inside a `/* ... */` block),
- twelve characters or fewer.

Independently written QML still coincides on imports, property
declarations and anchor boilerplate; a small structural residue is
expected and the length floor keeps most of it out. The count is a
multiset intersection: a line shared three times counts three times,
and never more times than the upstream file contains it.

The upstream checkout is verified, never assumed: the script either uses
`--upstream DIR` after checking that DIR is exactly at `e3771b6` and
clean, or fetches upstream into a cache under `$XDG_CACHE_HOME` and
checks out that commit there. A different revision, a dirty checkout or
a failed fetch is a hard error — the measurement is never taken against
anything else.

Exit codes:

- `0` — the total is zero: the licence may become a sole copyright.
- `1` — the total is above zero: the attribution stays.
- `2` — the measurement could not be taken (no network, wrong or dirty
  upstream checkout, no git).

Examples:

    tools/provenance.py                          # fetch or reuse the cache
    tools/provenance.py --upstream ~/src/osk     # use an existing checkout
    tools/provenance.py --verbose                # list the shared lines
"""

import argparse
import collections
import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

UPSTREAM_URL = "https://github.com/abdxdev/omarchy-onscreen-keyboard"
UPSTREAM_COMMIT = "e3771b6a4a15f872ba12dc8fe506140c777ea897"
UPSTREAM_SHORT = "e3771b6"

BRACES = set("{}()[]")


def run_git(*argv, cwd=None):
    """Run git, returning stdout; raise RuntimeError with stderr on failure."""
    proc = subprocess.run(
        ["git", *argv], cwd=cwd, capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"git {argv[0]} failed")
    return proc.stdout.strip()


def substantive_lines(text):
    """The lines of `text` that survive the substantive definition."""
    out = []
    in_block = False
    for raw in text.splitlines():
        s = raw.strip()
        # Unwind block comments; keep any code wrapped around them.
        while True:
            if in_block:
                end = s.find("*/")
                if end == -1:
                    s = ""
                    break
                s = s[end + 2 :].strip()
                in_block = False
            start = s.find("/*")
            if start == -1:
                break
            head, rest = s[:start].strip(), s[start + 2 :]
            if "*/" not in rest:
                in_block = True
                s = head
                break
            s = (head + " " + rest.split("*/", 1)[1]).strip()
        if not s or s.startswith("//"):
            continue
        if all(c in BRACES for c in s):
            continue
        if len(s) <= 12:
            continue
        out.append(s)
    return out


def shared_counts(ours, upstream):
    """Multiset intersection: how many times each shared line is shared."""
    return collections.Counter(ours) & collections.Counter(upstream)


def shell_files(root):
    """The shell-layer sources of a tree: QML and JS at the repo root."""
    paths = glob.glob(os.path.join(root, "*.qml")) + glob.glob(
        os.path.join(root, "*.js")
    )
    return sorted(os.path.basename(p) for p in paths)


def die(message):
    print(f"provenance: {message}", file=sys.stderr)
    print(
        "provenance: refusing to measure against anything but upstream "
        f"{UPSTREAM_SHORT}",
        file=sys.stderr,
    )
    sys.exit(2)


def resolve_upstream(args):
    """Return a verified, clean upstream checkout at the expected commit."""
    if args.upstream:
        path = os.path.abspath(args.upstream)
        if not os.path.exists(os.path.join(path, ".git")):
            die(f"{path} is not a git checkout")
        try:
            head = run_git("rev-parse", "HEAD", cwd=path)
        except RuntimeError as err:
            die(f"cannot read HEAD of {path}: {err}")
        if head != UPSTREAM_COMMIT:
            die(
                f"{path} is at {head[:7]}, not upstream {UPSTREAM_SHORT} "
                "(pass --upstream at the exact revision, or let the script "
                "fetch one)"
            )
        try:
            dirty = run_git("status", "--porcelain", cwd=path)
        except RuntimeError as err:
            die(f"cannot read status of {path}: {err}")
        if dirty:
            die(f"{path} has uncommitted changes; a clean checkout is required")
        return path

    cache = os.environ.get(
        "XDG_CACHE_HOME", os.path.join(os.path.expanduser("~"), ".cache")
    )
    cache = os.path.join(cache, "omarchy-osk", "provenance-upstream")
    if not shutil.which("git"):
        die("git is required to fetch upstream")
    try:
        if os.path.exists(os.path.join(cache, ".git")):
            run_git("fetch", "origin", cwd=cache)
        else:
            os.makedirs(cache, exist_ok=True)
            run_git("clone", UPSTREAM_URL, cache)
        run_git("checkout", "--quiet", "--detach", UPSTREAM_COMMIT, cwd=cache)
    except RuntimeError as err:
        die(f"cannot fetch {UPSTREAM_URL} into {cache}: {err}")
    return cache


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare the shell layer against upstream "
        f"{UPSTREAM_SHORT} and print shared substantive lines."
    )
    parser.add_argument(
        "--upstream",
        metavar="DIR",
        help="use this upstream checkout instead of fetching; it must be "
        "exactly at e3771b6 and clean",
    )
    parser.add_argument(
        "--root",
        metavar="DIR",
        help="the tree to measure (default: the checkout this script lives in)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="also list the shared lines per file, with their counts",
    )
    args = parser.parse_args(argv)

    root = (
        os.path.abspath(args.root)
        if args.root
        else str(Path(__file__).resolve().parent.parent)
    )

    upstream_dir = resolve_upstream(args)

    ours_files = shell_files(root)
    upstream_files = set(shell_files(upstream_dir))
    compared = [f for f in ours_files if f in upstream_files]
    ours_only = [f for f in ours_files if f not in upstream_files]
    if not compared:
        die(f"no comparable shell-layer files under {root}")

    print(
        f"upstream: {UPSTREAM_URL} at {UPSTREAM_SHORT} "
        f"(verified {UPSTREAM_COMMIT})"
    )

    total_shared = 0
    total_lines = 0
    rows = []
    for name in compared:
        ours = substantive_lines(Path(root, name).read_text(encoding="utf-8"))
        upstream = substantive_lines(
            Path(upstream_dir, name).read_text(encoding="utf-8")
        )
        shared = sum(shared_counts(ours, upstream).values())
        total_shared += shared
        total_lines += len(ours)
        rows.append((name, shared, len(ours), shared_counts(ours, upstream)))

    width = max(len(name) for name, *_ in rows)
    for name, shared, lines, counts in rows:
        print(f"{name:<{width}}  {shared:>4} / {lines}")
        if args.verbose:
            for line, count in sorted(
                counts.items(), key=lambda kv: (-kv[1], kv[0])
            ):
                print(f"    {count}x {line}")
    print(f"{'total':<{width}}  {total_shared:>4} / {total_lines}")
    if ours_only:
        print(
            "not present upstream, so sharing nothing by definition: "
            + ", ".join(ours_only)
        )

    if total_shared > 0:
        print(
            "provenance: the shell layer still shares "
            f"{total_shared} substantive lines with upstream; "
            "the attribution stays"
        )
        return 1
    print("provenance: zero shared substantive lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
