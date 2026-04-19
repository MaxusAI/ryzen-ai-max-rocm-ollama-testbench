#!/usr/bin/env bash
# scripts/lib/snapshot.sh - sourceable helpers to capture host / GPU /
# Ollama version info as a single-line JSON object. Used by:
#   - scripts/log-run.sh   (wraps validate.sh + stress-test.sh runs)
#   - scripts/stress-test.sh
#
# Design notes:
#   - This file is meant to be sourced, not executed. It registers
#     functions in the caller's shell.
#   - All output is single-line JSON with double-quoted strings; no
#     dependency on jq. We escape only the characters that JSON requires
#     (backslash, double-quote) plus newline / tab / control. That's
#     enough for what we capture (versions and short paths).
#   - All discovery functions are best-effort: failures degrade to the
#     literal string "unknown", never crash the caller.
#   - Honors HOST_PORT, DRI_INDEX, COMPOSE_FILE env vars if the caller
#     has set them; falls back to sensible defaults otherwise.

# shellcheck shell=bash

# ---------------------------------------------------------------------------
# json helpers
# ---------------------------------------------------------------------------

# json_escape <string> - print the input with the JSON string-escape rules
# applied (backslash, double-quote, control characters, newline, tab).
# Does NOT add surrounding quotes - caller wraps as needed.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# json_string <value> - emit "<escaped>" (quoted), or null if empty/unknown.
# Lets us use the same call site for "real value" and "no value found".
json_string() {
    local v="$1"
    if [ -z "$v" ] || [ "$v" = "unknown" ]; then
        printf 'null'
    else
        printf '"%s"' "$(json_escape "$v")"
    fi
}

# json_number <value> - emit a JSON number, or null if not numeric.
json_number() {
    local v="$1"
    case "$v" in
        ''|unknown) printf 'null' ;;
        *[!0-9.\-]*) printf 'null' ;;
        *) printf '%s' "$v" ;;
    esac
}

# ---------------------------------------------------------------------------
# discovery helpers (each prints a single value; "unknown" on failure)
# ---------------------------------------------------------------------------

snapshot_kernel() { uname --kernel-release 2>/dev/null || echo "unknown"; }

snapshot_host()   { hostname --short 2>/dev/null || hostname 2>/dev/null || echo "unknown"; }

snapshot_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s %s' "${NAME:-?}" "${VERSION:-?}" )
    else
        echo "unknown"
    fi
}

snapshot_linux_firmware_pkg() {
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query --showformat='${Version}' --show linux-firmware 2>/dev/null \
            || echo "unknown"
    else
        echo "unknown"
    fi
}

# Read the full amdgpu_firmware_info dump from debugfs. Returns the raw
# multi-line text or "" on failure. Needs root or sudo with cached
# creds. Internal helper used by the snapshot_*_fw functions below.
_snapshot_fw_dump() {
    local idx="${DRI_INDEX:-1}"
    local path="/sys/kernel/debug/dri/${idx}/amdgpu_firmware_info"
    if [ -r "$path" ]; then
        cat "$path" 2>/dev/null
    elif command -v sudo >/dev/null 2>&1; then
        sudo --non-interactive cat "$path" 2>/dev/null || true
    fi
}

# Pull the firmware-version field from one named line of the dump.
# $1 = exact prefix ("MES feature", "MES_KIQ feature", "SMC feature", ...).
_snapshot_fw_field() {
    local prefix="$1" raw="$2"
    printf '%s\n' "$raw" \
        | grep --max-count=1 "^${prefix}" \
        | grep --extended-regexp --only-matching '0x[0-9a-fA-F]+' \
        | tail -n 1 \
        || true
}

# Read the running MES feature firmware version from debugfs. Returns
# e.g. "0x00000080" or "unknown".
snapshot_mes_fw() {
    local raw v
    raw=$(_snapshot_fw_dump)
    if [ -z "$raw" ]; then
        echo "unknown"; return
    fi
    v=$(_snapshot_fw_field 'MES feature' "$raw")
    [ -n "$v" ] && printf '%s' "$v" || echo "unknown"
}

# snapshot_firmware_extras_json - emit a JSON object with the firmware
# fields most worth tracking for drift over time. Keeps the JSONL
# record compact (only the fields we ever cite in bug reports) but
# captures enough to detect a silent BIOS / linux-firmware shift.
snapshot_firmware_extras_json() {
    local raw
    raw=$(_snapshot_fw_dump)
    if [ -z "$raw" ]; then
        printf 'null'; return
    fi
    # Each "extra" is a (label, line-prefix) pair.
    local mes_kiq smc sdma0 vcn rlc imu me pfp mec vpe vbios
    mes_kiq=$(_snapshot_fw_field 'MES_KIQ feature' "$raw")
    smc=$(_snapshot_fw_field    'SMC feature'      "$raw")
    sdma0=$(_snapshot_fw_field  'SDMA0 feature'    "$raw")
    vcn=$(_snapshot_fw_field    'VCN feature'      "$raw")
    rlc=$(_snapshot_fw_field    'RLC feature'      "$raw")
    imu=$(_snapshot_fw_field    'IMU feature'      "$raw")
    me=$(_snapshot_fw_field     'ME feature'       "$raw")
    pfp=$(_snapshot_fw_field    'PFP feature'      "$raw")
    mec=$(_snapshot_fw_field    'MEC feature'      "$raw")
    vpe=$(_snapshot_fw_field    'VPE feature'      "$raw")
    # VBIOS line is "VBIOS version: 113-STRXLGEN-001" - no 0x prefix.
    vbios=$(printf '%s\n' "$raw" \
        | grep --max-count=1 '^VBIOS version:' \
        | sed 's/^VBIOS version:[[:space:]]*//' || true)
    printf '{'
    printf '"mes_kiq":%s,' "$(json_string "$mes_kiq")"
    printf '"smc":%s,'     "$(json_string "$smc")"
    printf '"sdma0":%s,'   "$(json_string "$sdma0")"
    printf '"vcn":%s,'     "$(json_string "$vcn")"
    printf '"rlc":%s,'     "$(json_string "$rlc")"
    printf '"imu":%s,'     "$(json_string "$imu")"
    printf '"me":%s,'      "$(json_string "$me")"
    printf '"pfp":%s,'     "$(json_string "$pfp")"
    printf '"mec":%s,'     "$(json_string "$mec")"
    printf '"vpe":%s,'     "$(json_string "$vpe")"
    printf '"vbios":%s'    "$(json_string "$vbios")"
    printf '}'
}

# ROCm release string from /opt/rocm/.info/version (canonical), or
# 'rocminfo' as a fallback.
#
# Implementation note: piped commands (cmd|awk) run in a subshell, so a
# trailing `&& return` inside the pipe only exits the subshell, NOT the
# function. We capture into a variable first, then return based on that.
snapshot_rocm() {
    local v=""
    if [ -r /opt/rocm/.info/version ]; then
        v=$(head --lines=1 /opt/rocm/.info/version 2>/dev/null | tr --delete '[:space:]')
    fi
    if [ -z "$v" ] && command -v rocminfo >/dev/null 2>&1; then
        v=$(rocminfo 2>/dev/null | awk '/Runtime Version:/{print $3; exit}')
    fi
    [ -n "$v" ] && printf '%s' "$v" || echo "unknown"
}

# AMDGPU kernel-driver version as reported by Ollama (e.g. "70253.21").
# Only meaningful if Ollama is running and has logged at least one
# inference-compute line.
snapshot_amdgpu_driver_from_ollama_logs() {
    local raw=""
    if command -v journalctl >/dev/null 2>&1; then
        raw=$(journalctl --unit=ollama --since="-10min" --no-pager 2>/dev/null \
            | grep --extended-regexp --only-matching 'driver=[0-9.]+' \
            | tail -n 1 \
            | cut --delimiter='=' --fields=2 || true)
    fi
    [ -n "$raw" ] && printf '%s' "$raw" || echo "unknown"
}

snapshot_ollama_version() {
    local port="${HOST_PORT:-11434}"
    local raw=""
    if command -v curl >/dev/null 2>&1; then
        raw=$(curl --silent --max-time 2 "http://localhost:${port}/api/version" 2>/dev/null \
            | grep --extended-regexp --only-matching '"version":"[^"]+"' \
            | sed 's/.*:"//;s/"$//' || true)
    fi
    [ -n "$raw" ] && printf '%s' "$raw" || echo "unknown"
}

# snapshot_ollama_config_json - capture Ollama's effective runtime
# config (NUM_PARALLEL, MAX_QUEUE, KEEP_ALIVE, FLASH_ATTENTION, etc.).
#
# Why it's worth the parsing pain: Ollama has NO API endpoint that
# exposes its own config (verified: /api/config, /api/info, /api/server,
# /api/runtime, /api/env all 404 on 0.21.0). And /proc/<pid>/environ
# only has explicitly-set vars - everything that fell back to a default
# (NUM_PARALLEL=1, MAX_QUEUE=512, KEEP_ALIVE=5m0s, ...) is invisible
# there. The only place these surface is the structured startup line:
#
#   msg="server config" env="map[KEY1:VAL1 KEY2:VAL2 ...]"
#
# logged once per `ollama serve` boot. We grep journalctl (host) or
# `docker compose logs` (container) for the most recent occurrence and
# parse the Go fmt.Print syntax with a small bracket-balancing parser.
#
# Returns a JSON object of OLLAMA_* keys, or `null` if no config line
# could be found (e.g. journalctl unreadable, recent restart purged
# logs, or running in container mode with no compose context).
snapshot_ollama_config_json() {
    local svc="${COMPOSE_SERVICE:-${SERVICE:-ollama}}"
    local compose_file="${COMPOSE_FILE:-docker-compose.yml}"
    local raw="" inv="" cache=""

    # Cache strategy: journalctl on a long-running OLLAMA_DEBUG=2 host
    # produces a massive journal, so even scoped queries can take 30s+.
    # Tie the cache file to the systemd InvocationID so it's auto-
    # invalidated on every Ollama restart (which is also the only event
    # that can change the config). $XDG_RUNTIME_DIR is tmpfs (cleared
    # on boot) so we don't need explicit cleanup.
    inv=$(systemctl show ollama.service --property=InvocationID --value 2>/dev/null || true)
    if [ -n "$inv" ]; then
        cache="${XDG_RUNTIME_DIR:-/tmp}/ollama-cfg-${inv}.json"
        if [ -s "$cache" ]; then
            cat "$cache"
            return
        fi
    fi

    # Host: scope by InvocationID (only this Ollama boot's logs).
    # Wrap in `timeout` because journalctl can be very slow on systems
    # with a large journal; we'd rather return "unknown" than hang
    # validate.sh / stress-test.sh for half a minute.
    if command -v journalctl >/dev/null 2>&1 && [ -n "$inv" ]; then
        if command -v sudo >/dev/null 2>&1; then
            raw=$(timeout 45 sudo --non-interactive journalctl \
                    _SYSTEMD_INVOCATION_ID="$inv" --no-pager 2>/dev/null \
                | grep --extended-regexp --max-count=1 'msg="server config"' || true)
        fi
        if [ -z "$raw" ]; then
            raw=$(timeout 45 journalctl _SYSTEMD_INVOCATION_ID="$inv" --no-pager 2>/dev/null \
                | grep --extended-regexp --max-count=1 'msg="server config"' || true)
        fi
    fi

    # Container fallback: scan docker compose logs.
    if [ -z "$raw" ] && [ -f "$compose_file" ] && command -v docker >/dev/null 2>&1; then
        raw=$(timeout 30 docker compose --file "$compose_file" logs --no-color "$svc" 2>/dev/null \
            | grep --extended-regexp --max-count=1 'msg="server config"' || true)
    fi

    if [ -z "$raw" ]; then
        printf 'null'
        return
    fi

    # Hand the line to python for parsing. We use a bracket-balancing
    # walker because OLLAMA_ORIGINS contains spaces and itself nested
    # in [...] - naive split-on-space would mangle it.
    local parsed
    parsed=$(printf '%s\n' "$raw" | _snapshot_parse_server_config)
    if [ -z "$parsed" ] || [ "$parsed" = "null" ]; then
        printf 'null'
        return
    fi
    if [ -n "$cache" ]; then
        printf '%s' "$parsed" > "$cache" 2>/dev/null || true
    fi
    printf '%s' "$parsed"
}

# Internal: parse one journalctl/docker-logs line into a flat JSON
# object of OLLAMA_* keys. Splits to a separate function so the parser
# can be tested in isolation and also reused by callers that already
# have the line cached.
_snapshot_parse_server_config() {
    python3 -c '
import sys, re, json
line = sys.stdin.read()
m = re.search(r"env=\"map\[(.+)\]\"", line)
if not m:
    print("null"); sys.exit(0)
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
            if body[k] == "[": depth += 1
            elif body[k] == "]": depth -= 1
            k += 1
        value = body[j+1:k-1]
        i = k
    else:
        k = j
        while k < n and body[k] != " ":
            k += 1
        value = body[j:k]
        i = k
    # Keep only OLLAMA_* keys; drop the noisy default origins list
    # (15+ URLs, never useful for debugging) and the proxy vars.
    if key.startswith("OLLAMA_") and key != "OLLAMA_ORIGINS":
        out[key] = value
print(json.dumps(out, separators=(",",":")))
'
}

# Marketing name of the (first) discovered GPU. Strips leading whitespace.
snapshot_gpu_name() {
    local v=""
    if command -v rocminfo >/dev/null 2>&1; then
        v=$(rocminfo 2>/dev/null \
            | awk --field-separator=: '/Marketing Name:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}')
    fi
    [ -n "$v" ] && printf '%s' "$v" || echo "unknown"
}

snapshot_gpu_arch() {
    local v=""
    if command -v rocminfo >/dev/null 2>&1; then
        v=$(rocminfo 2>/dev/null \
            | awk '/Name:[[:space:]]+gfx/ {print $2; exit}')
    fi
    [ -n "$v" ] && printf '%s' "$v" || echo "unknown"
}

# Total VRAM in GiB as a decimal number (e.g. "96.0"), or "unknown".
# rocm-smi --showmeminfo vram exposes "VRAM Total Memory (B)" in bytes.
snapshot_vram_total_gib() {
    if ! command -v rocm-smi >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    local bytes
    bytes=$(rocm-smi --showmeminfo vram --csv 2>/dev/null \
        | awk -F, '/^card/ {print $2; exit}' \
        | tr -d '"[:space:]')
    if [ -z "$bytes" ]; then
        # csv output not available on all rocm-smi versions; fall back to text
        bytes=$(rocm-smi --showmeminfo vram 2>/dev/null \
            | awk '/VRAM Total Memory \(B\):/ {print $NF; exit}')
    fi
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
        # bytes -> GiB, one decimal
        awk --assign=b="$bytes" 'BEGIN { printf "%.1f", b/1024/1024/1024 }'
    else
        echo "unknown"
    fi
}

# Detect runtime mode: "container" if the docker-compose service named
# COMPOSE_SERVICE has a running container, otherwise "host" if a host
# Ollama is responding on HOST_PORT, otherwise "unknown".
snapshot_runtime_mode() {
    local svc="${COMPOSE_SERVICE:-${SERVICE:-ollama}}"
    local compose_file="${COMPOSE_FILE:-docker-compose.yml}"
    local port="${HOST_PORT:-11434}"
    if [ -f "$compose_file" ] && command -v docker >/dev/null 2>&1; then
        local cid
        cid=$(docker compose --file "$compose_file" ps --quiet "$svc" 2>/dev/null || true)
        if [ -n "$cid" ]; then
            printf 'container'
            return
        fi
    fi
    if curl --silent --max-time 1 "http://localhost:${port}/api/version" >/dev/null 2>&1; then
        printf 'host'
        return
    fi
    printf 'unknown'
}

# ---------------------------------------------------------------------------
# top-level: snapshot_versions_json
# ---------------------------------------------------------------------------

# snapshot_ollama_runtime_state_json - capture Ollama's RUNTIME state
# (what the runner actually decided to do for the most recently loaded
# model) - distinct from snapshot_ollama_config_json which only shows
# the daemon-level env-var defaults at startup.
#
# This matters because the env var OLLAMA_FLASH_ATTENTION:false does
# NOT mean flash attention is off. It means Ollama isn't *forcing* it,
# leaving the inner llama.cpp runner to decide. The runner's default
# is `flash_attn = auto`, which auto-resolves to "enabled" for almost
# any modern model on a ROCm/CUDA backend - so the actual behaviour is
# the opposite of what the env var suggests at first glance.
#
# Markers we extract from journalctl (or docker compose logs):
#   - "starting runner ... cmd=\"... --model PATH ... --port N\""
#   - "llama_context: flash_attn    = auto|on|off"          (requested)
#   - "Flash Attention was auto, set to enabled|disabled"   (resolved)
#   - "llama_kv_cache: size = X MiB (Y cells, Z layers, ...), K (T): A MiB, V (T): B MiB"
#   - "llama_context:      ROCm0 compute buffer size = X MiB"
#   - "llama_context:  ROCm_Host compute buffer size = X MiB"
#   - "msg=\"inference compute\" ... library=L compute=ARCH ..."
#
# Returns a JSON object, or `null` if no runner has emitted a model-
# load in the current Ollama InvocationID yet (i.e. nothing's been
# inferred against since the daemon last restarted).
snapshot_ollama_runtime_state_json() {
    local svc="${COMPOSE_SERVICE:-${SERVICE:-ollama}}"
    local compose_file="${COMPOSE_FILE:-docker-compose.yml}"
    local raw="" inv=""

    inv=$(systemctl show ollama.service --property=InvocationID --value 2>/dev/null || true)

    # We deliberately DON'T cache this one - the data changes per model
    # load (different models -> different KV size, FA decision can vary)
    # so caching by InvocationID alone would silently go stale. Scope to
    # current InvocationID + 15s timeout to bound the worst case.
    # The grep pattern is shared between host and container paths. We
    # match on:
    #   - "starting runner ... --model PATH"          - which model
    #   - "llama_context: flash_attn = ..."           - what was requested
    #   - "Flash Attention was auto, set to ..."      - llama.cpp resolution (auto path only)
    #   - "msg=\"enabling flash attention\""          - Ollama daemon explicit FA enable
    #   - "msg=load request=\"{...FlashAttention:..." - canonical FA decision in load req
    #   - "llama_kv_cache: size = ..."                - K/V quant + total
    #   - "compute buffer size"                       - device + host scratch
    #   - "msg=\"inference compute\""                 - daemon library/arch line
    local pat='starting runner.*--model|llama_context: flash_attn|Flash Attention was|enabling flash attention|FlashAttention:|llama_kv_cache: size|compute buffer size|"inference compute"'

    if command -v journalctl >/dev/null 2>&1 && [ -n "$inv" ]; then
        if command -v sudo >/dev/null 2>&1; then
            raw=$(timeout 15 sudo --non-interactive journalctl \
                    _SYSTEMD_INVOCATION_ID="$inv" --no-pager 2>/dev/null \
                | grep --extended-regexp "$pat" || true)
        fi
        if [ -z "$raw" ]; then
            raw=$(timeout 15 journalctl _SYSTEMD_INVOCATION_ID="$inv" --no-pager 2>/dev/null \
                | grep --extended-regexp "$pat" || true)
        fi
    fi

    # Container fallback: scan docker compose logs.
    if [ -z "$raw" ] && [ -f "$compose_file" ] && command -v docker >/dev/null 2>&1; then
        raw=$(timeout 15 docker compose --file "$compose_file" logs --no-color "$svc" 2>/dev/null \
            | grep --extended-regexp "$pat" || true)
    fi

    if [ -z "$raw" ]; then
        printf 'null'
        return
    fi

    # Hand to python for the actual extraction. We use the LAST
    # occurrence of each marker (most recent model load wins). The KV
    # cache line's regex captures K/V quant types (f16, q8_0, q4_0, ...)
    # and total size in MiB; the runner cmd line yields the model
    # blob/path; the inference-compute line gives the library + arch.
    printf '%s\n' "$raw" | python3 -c '
import sys, re, json
lines = [l.strip() for l in sys.stdin if l.strip()]
out = {}

def last(pattern, line=None):
    rx = re.compile(pattern)
    for l in reversed(lines):
        m = rx.search(l)
        if m:
            return m
    return None

# library / compute (daemon-level inference-compute line).
m = last(r"library=(\S+)\s+compute=(\S+)")
if m:
    out["library"] = m.group(1)
    out["compute"] = m.group(2)

# Most recent model load: extract path/digest from the runner cmd line.
m = last(r"--model\s+(\S+)")
if m:
    p = m.group(1)
    out["model_path"] = p
    # Short form: "sha256-abcd..." -> "sha256-abcd1234"
    short = p.rsplit("/", 1)[-1]
    if short.startswith("sha256-"):
        short = short[:14]
    out["model_short"] = short

# Flash-attn: requested vs resolved. There are THREE log shapes we
# care about, in priority order for the resolved value:
#  1. Auto path (most common): "Flash Attention was auto, set to enabled"
#  2. Explicit-on path:        "msg=\"enabling flash attention\""    (Ollama daemon)
#  3. Load-request canonical:  "FlashAttention:Enabled" / "Disabled" (in load request struct)
# The 2nd and 3rd shapes appear when the user sets OLLAMA_FLASH_ATTENTION=1
# explicitly - in that case llama.cpp does not print the "was auto"
# message because no auto-resolution happened.
m = last(r"llama_context: flash_attn\s*=\s*(\S+)")
if m:
    out["flash_attn_requested"] = m.group(1)
m = last(r"Flash Attention was \S+, set to (\S+)")
if m:
    out["flash_attn_resolved"] = m.group(1)
else:
    # Fallback 1: Ollama daemon-level explicit-enable log.
    if last(r"msg=\"enabling flash attention\""):
        out["flash_attn_resolved"] = "enabled"
    else:
        # Fallback 2: load-request struct exposes the final decision.
        m = last(r"FlashAttention:(\S+?)[\s}]")
        if m:
            out["flash_attn_resolved"] = m.group(1).lower()

# KV cache: total + K/V quant types and sizes + sequence count. The
# total can look "bigger than expected" when OLLAMA_NUM_PARALLEL > 1
# because Ollama allocates one KV slot per concurrent sequence; we
# capture the seq count so the printer can show per-seq size too.
#   "llama_kv_cache: size = 15232.00 MiB (131072 cells,  28 layers,  2/2 seqs),
#       K (q8_0): 7616.00 MiB, V (q8_0): 7616.00 MiB"
m = last(r"llama_kv_cache: size = ([\d.]+) MiB \((\d+) cells,\s*(\d+) layers,\s*(\d+)/(\d+) seqs.*K \((\S+)\): ([\d.]+) MiB, V \((\S+)\): ([\d.]+) MiB")
if m:
    out["kv_cache_total_mib"] = float(m.group(1))
    out["kv_cache_cells"]     = int(m.group(2))
    out["kv_cache_layers"]    = int(m.group(3))
    out["kv_cache_seqs"]      = int(m.group(5))
    out["kv_cache_k_type"]    = m.group(6)
    out["kv_cache_k_mib"]     = float(m.group(7))
    out["kv_cache_v_type"]    = m.group(8)
    out["kv_cache_v_mib"]     = float(m.group(9))

# Compute scratch buffers (device + host pinned). The two log lines
# look like:
#   "llama_context:      ROCm0      compute buffer size =   408.01 MiB"
#   "llama_context:  ROCm_Host      compute buffer size =   262.01 MiB"
# We want them in the right slots: device buffer is NOT *_Host, host
# buffer IS *_Host. Negative lookahead keeps `_Host` lines out of the
# device match.
m = last(r"llama_context:\s+(?!\S+_Host)\S+\s+compute buffer size =\s*([\d.]+) MiB")
if m:
    out["compute_buffer_mib"] = float(m.group(1))
m = last(r"llama_context:\s+\S+_Host\s+compute buffer size =\s*([\d.]+) MiB")
if m:
    out["host_compute_buffer_mib"] = float(m.group(1))

print(json.dumps(out, separators=(",",":")) if out else "null")
'
}

# snapshot_versions_json - print one JSON object capturing the current
# system + Ollama state. Single line, no trailing newline.
snapshot_versions_json() {
    local ts host kernel distro lf mes rocm ollama drv gpu_name gpu_arch vram mode fw_extras ollama_cfg ollama_rt
    ts=$(date --iso-8601=seconds)
    host=$(snapshot_host)
    kernel=$(snapshot_kernel)
    distro=$(snapshot_distro)
    lf=$(snapshot_linux_firmware_pkg)
    mes=$(snapshot_mes_fw)
    rocm=$(snapshot_rocm)
    ollama=$(snapshot_ollama_version)
    drv=$(snapshot_amdgpu_driver_from_ollama_logs)
    gpu_name=$(snapshot_gpu_name)
    gpu_arch=$(snapshot_gpu_arch)
    vram=$(snapshot_vram_total_gib)
    mode=$(snapshot_runtime_mode)
    fw_extras=$(snapshot_firmware_extras_json)
    ollama_cfg=$(snapshot_ollama_config_json)
    ollama_rt=$(snapshot_ollama_runtime_state_json)

    printf '{'
    printf '"timestamp":%s,'        "$(json_string "$ts")"
    printf '"host":%s,'             "$(json_string "$host")"
    printf '"distro":%s,'           "$(json_string "$distro")"
    printf '"kernel":%s,'           "$(json_string "$kernel")"
    printf '"linux_firmware":%s,'   "$(json_string "$lf")"
    printf '"mes_fw":%s,'           "$(json_string "$mes")"
    printf '"firmware":%s,'         "$fw_extras"
    printf '"rocm":%s,'             "$(json_string "$rocm")"
    printf '"ollama":%s,'           "$(json_string "$ollama")"
    printf '"ollama_config":%s,'    "$ollama_cfg"
    printf '"ollama_runtime":%s,'   "$ollama_rt"
    printf '"amdgpu_driver":%s,'    "$(json_string "$drv")"
    printf '"gpu":%s,'              "$(json_string "$gpu_name")"
    printf '"gpu_arch":%s,'         "$(json_string "$gpu_arch")"
    printf '"vram_total_gib":%s,'   "$(json_number "$vram")"
    printf '"runtime_mode":%s'      "$(json_string "$mode")"
    printf '}'
}
