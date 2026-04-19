#!/usr/bin/env python3
"""Parse one Ollama 'server config' journalctl/docker-logs line on stdin
into a flat JSON object of OLLAMA_* keys (printed on stdout).

Used by scripts/lib/snapshot.sh's snapshot_ollama_config_json. Lives as
a standalone file because the bracket-balancing parser is awkward to
maintain inside a bash heredoc and has its own test surface (missing
brackets, OLLAMA_ORIGINS containing nested [], etc.).

Why not just key=value split: the line is Go fmt.Print map syntax:

    msg="server config" env="map[KEY1:VAL1 KEY2:[a b c] KEY3:VAL3 ...]"

Spaces inside [...] (notably OLLAMA_ORIGINS, which has 15+ URLs with
embedded slashes and colons) make split-on-space mangle the values, so
we walk the buffer and balance brackets.

Output: single-line JSON object on stdout, or the literal "null" if no
server-config envelope was found in the input. Always exits 0; callers
guard on the literal "null".

OLLAMA_ORIGINS is intentionally dropped because the daemon defaults
include 15+ URLs that crowd out the actually-useful keys in any
debugging output. Re-add by removing the `key != "OLLAMA_ORIGINS"`
clause if you need it.
"""

import json
import re
import sys


def parse(line: str):
    m = re.search(r'env="map\[(.+)\]"', line)
    if not m:
        return None
    body = m.group(1)
    out = {}
    i, n = 0, len(body)
    while i < n:
        while i < n and body[i] == " ":
            i += 1
        if i >= n:
            break
        j = i
        while j < n and body[j] != ":":
            j += 1
        if j >= n:
            break
        key = body[i:j]
        j += 1
        if j < n and body[j] == "[":
            depth, k = 1, j + 1
            while k < n and depth > 0:
                if body[k] == "[":
                    depth += 1
                elif body[k] == "]":
                    depth -= 1
                k += 1
            value = body[j + 1 : k - 1]
            i = k
        else:
            k = j
            while k < n and body[k] != " ":
                k += 1
            value = body[j:k]
            i = k
        if key.startswith("OLLAMA_") and key != "OLLAMA_ORIGINS":
            out[key] = value
    return out


def main() -> int:
    line = sys.stdin.read()
    parsed = parse(line)
    if parsed is None:
        print("null")
    else:
        print(json.dumps(parsed, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
