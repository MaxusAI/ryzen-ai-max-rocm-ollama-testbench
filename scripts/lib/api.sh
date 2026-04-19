#!/usr/bin/env bash
# scripts/lib/api.sh - Ollama HTTP API helpers shared by validate.sh,
# stress-test.sh, torture.sh, and parts of snapshot.sh.
#
# All helpers respect the same URL-discovery precedence so each caller
# script can keep its own preferred env-var name:
#   1. $OLLAMA_HOST_URL  (torture.sh convention; full URL)
#   2. $HOST             (stress-test.sh convention; full URL)
#   3. http://localhost:${HOST_PORT:-11434}  (validate.sh / snapshot.sh)
#
# Discovery is done lazily at call time, not at source time, so a script
# that re-points $HOST mid-run still gets routed correctly.

# shellcheck shell=bash

# Resolve the Ollama base URL. Used internally by every helper below.
# Trailing slashes are tolerated by Ollama, so we don't bother stripping.
_api_url() {
    printf '%s' "${OLLAMA_HOST_URL:-${HOST:-http://localhost:${HOST_PORT:-11434}}}"
}

# api_alive [timeout=3] - returns 0 if Ollama responds to /api/version.
# Hides curl noise. Used as a pre-flight gate before issuing real calls
# so a dead daemon produces a clean error message instead of stack of
# curl warnings.
api_alive() {
    local timeout="${1:-3}"
    curl --silent --max-time "$timeout" --fail --output /dev/null \
        "$(_api_url)/api/version"
}

# api_largest_model - print the name of the largest installed model
# (by on-disk size from /api/tags), or "" if no models / API down.
# Used by stress-test.sh and torture.sh to default the test model when
# the user didn't pass --model.
api_largest_model() {
    curl --silent --max-time 5 "$(_api_url)/api/tags" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(""); sys.exit(0)
ms = sorted(d.get("models",[]), key=lambda m: -m.get("size", 0))
print(ms[0]["name"] if ms else "")'
}

# api_smallest_model - mirror of api_largest_model. Used by validate.sh
# Layer 5 to load "literally any model" for a GPU sanity check without
# blowing past VRAM limits on small machines.
api_smallest_model() {
    curl --silent --max-time 5 "$(_api_url)/api/tags" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(""); sys.exit(0)
ms = sorted(d.get("models",[]), key=lambda m: m.get("size", 1<<62))
print(ms[0]["name"] if ms else "")'
}

# api_model_size_bytes <name> - on-disk size of a specific model from
# /api/tags. Returns "0" if the model is not installed.
api_model_size_bytes() {
    local name="$1"
    curl --silent --max-time 5 "$(_api_url)/api/tags" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(0); sys.exit(0)
for m in d.get('models', []):
    if m.get('name') == '$name':
        print(m.get('size', 0)); break
else:
    print(0)"
}

# api_model_max_context <name> - max context length the model itself
# declares (via /api/show -> model_info[*context_length*]). Returns "0"
# if unknown / API down. Used by stress-test.sh to clamp --num-ctx.
api_model_max_context() {
    local name="$1"
    curl --silent --max-time 5 \
            --request POST \
            --header 'content-type: application/json' \
            --data "{\"model\":\"$name\"}" \
            "$(_api_url)/api/show" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(0); sys.exit(0)
mi = d.get("model_info", {})
for k, v in mi.items():
    if "context_length" in k and isinstance(v, int):
        print(v); break
else:
    print(0)'
}

# api_bytes_to_gib <bytes> - format bytes as a GiB string with 2 decimals.
# (Tiny utility, but kept here so callers don't have to remember the awk.)
api_bytes_to_gib() {
    awk --assign=b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}
