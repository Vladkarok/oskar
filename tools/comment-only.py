#!/usr/bin/env python3
"""Prove a diff touches comments only.

usage: tools/comment-only.py <base-rev> [paths...]

Run it after any comment-only edit (a comment sweep, a doc pass that
touches code files): a rewrite that swallows a code line fails here.
Strips comments from each changed file at <base-rev> and in the working tree
and requires the remaining code to be identical (whitespace-normalised per line,
blank lines dropped). Exit 1 and print the offending file on any code change.
"""
import subprocess, sys, re

def strip(text, ext):
    out, i, n = [], 0, len(text)
    hash_style = ext in ('.py', '.sh', '')
    buf = []
    in_str = None
    while i < n:
        c = text[i]
        if in_str:
            buf.append(c)
            if c == '\\' and i + 1 < n:
                buf.append(text[i + 1]); i += 2; continue
            if text.startswith(in_str, i):
                buf.extend(in_str[1:]); i += len(in_str); in_str = None; continue
            i += 1; continue
        if hash_style:
            if c == '#' and (i == 0 or text[i-1] in ' \t\n'):
                while i < n and text[i] != '\n': i += 1
                continue
            if text.startswith('"""', i) or text.startswith("'''", i):
                in_str = text[i:i+3]; buf.append(in_str); i += 3; continue
        else:
            if text.startswith('//', i):
                while i < n and text[i] != '\n': i += 1
                continue
            if text.startswith('/*', i):
                j = text.find('*/', i + 2)
                j = n if j < 0 else j + 2
                buf.append('\n' * text.count('\n', i, j)); i = j; continue
        if c in '"\'`' and not (ext == '.rs' and c == "'"):
            in_str = c; buf.append(c); i += 1; continue
        buf.append(c); i += 1
    lines = [re.sub(r'\s+', ' ', l).strip() for l in ''.join(buf).split('\n')]
    return [l for l in lines if l]

def main():
    base = sys.argv[1]
    paths = sys.argv[2:] or subprocess.run(
        ['git', 'diff', '--name-only', base, '--'], capture_output=True, text=True, check=True
    ).stdout.split()
    bad = 0
    for p in paths:
        ext = '.' + p.rsplit('.', 1)[1] if '.' in p.rsplit('/', 1)[-1] else ''
        if ext not in ('.qml', '.js', '.rs', '.py', '.sh', '.c', '.h', ''):
            print(f'SKIP (not code): {p}'); continue
        old = subprocess.run(['git', 'show', f'{base}:{p}'], capture_output=True, text=True).stdout
        try: new = open(p).read()
        except FileNotFoundError: print(f'DELETED: {p}'); bad = 1; continue
        a, b = strip(old, ext), strip(new, ext)
        if a != b:
            bad = 1
            import difflib
            print(f'CODE CHANGED: {p}')
            for d in list(difflib.unified_diff(a, b, lineterm='', n=0))[2:20]: print('   ', d)
        else:
            print(f'ok (comments only): {p}')
    sys.exit(bad)

main()
