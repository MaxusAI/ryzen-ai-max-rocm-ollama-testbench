#!/usr/bin/env bash
# scripts/stress-test.sh - VRAM / GTT / MES stress test for Ollama on
# AMD GPUs. Picks the largest installed model, opens N parallel
# /api/generate requests at large num_ctx, and watches rocm-smi +
# dmesg for distress signals while they run.
#
# What this is for:
#   - Exercising the unified VRAM + GTT memory path on Strix Halo
#     (and similar APUs) under heavy concurrent load.
#   - Surfacing latent MES regressions: this is exactly the kind of
#     workload that triggers Mode A "MES failed to respond" and the
#     escalated Mode B "MES ring buffer is full" (see Fix 4 in
#     docs/build-fixes.md). Running this BEFORE deploying anything
#     real is cheaper than discovering the wedge under user load.
#
# What this is NOT:
#   - A throughput benchmark. The numbers are repeatable enough to
#     compare run-to-run on the same box, but not designed for cross-
#     hardware comparison.
#   - A load test for the Ollama runner itself. The model is pinned
#     for the duration; we're testing the GPU / driver / firmware.
#
# Output: real-time stats during the run, a human summary at the end,
# and a single final line "STRESS_RESULT_JSON: { ... }" that
# scripts/log-run.sh consumes for the JSONL history log.
#
# Usage:
#   ./scripts/stress-test.sh                                # auto everything
#   ./scripts/stress-test.sh --model gemma4:31b-it-q4_K_M
#   ./scripts/stress-test.sh --concurrency 8 --requests 16
#   ./scripts/stress-test.sh --num-ctx 131072 --prompt-frac 0.5
#   ./scripts/stress-test.sh --dry-run                      # show plan, exit
#
# Wrapping with the history log (recommended):
#   ./scripts/log-run.sh -- ./scripts/stress-test.sh --concurrency 8
#
# Options:
#   --model NAME           Ollama model tag (default: largest installed)
#   --concurrency N        parallel /api/generate requests (default: 4)
#   --requests N           total requests to issue (default: 2 * concurrency)
#   --num-ctx N            num_ctx per request (default: model's max from /api/show)
#   --prompt-frac F        fill prompt to F * num_ctx tokens (0 < F < 1, default: 0.5)
#   --num-predict N        max tokens to generate per request (default: 16)
#   --request-timeout S    per-request timeout in seconds (default: 1800)
#   --monitor-interval S   poll rocm-smi every S seconds (default: 5)
#   --host URL             Ollama base URL (default: http://localhost:11434)
#   --warmup / --no-warmup  warmup the model with one request first (default: warmup)
#   --dry-run              print the plan and exit without sending requests
#   -h --help              show this help
#
# Exit codes:
#   0   all requests succeeded, no MES errors during run
#   1   at least one request failed OR new MES errors observed in dmesg
#   2   bad invocation
#   3   refused: GPU was already in a wedged state (MES ring full) before start

# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# config + defaults
# ---------------------------------------------------------------------------

HOST="${OLLAMA_HOST_URL:-http://localhost:11434}"
MODEL=""
CONCURRENCY=4
REQUESTS=""
NUM_CTX=""
PROMPT_FRAC="0.5"
NUM_PREDICT=16
REQUEST_TIMEOUT=1800
MONITOR_INTERVAL=5
DO_WARMUP=1
DRY_RUN=0

# Approximation: avg chars-per-token across English text + light markup is
# ~3.2 (slightly model-dependent). We synthesize prompt text by repeating
# a small passage, which keeps tokens-per-character close to that ratio.
CHARS_PER_TOKEN="3.21"

# ---------------------------------------------------------------------------
# pretty (colors + info/ok/warn/err/header from scripts/lib/pretty.sh)
# ---------------------------------------------------------------------------

# shellcheck source=lib/pretty.sh
. "${REPO_ROOT}/scripts/lib/pretty.sh"

usage() {
    sed --quiet '2,/^$/p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --model)              MODEL="$2"; shift 2 ;;
        --model=*)            MODEL="${1#*=}"; shift ;;
        --concurrency)        CONCURRENCY="$2"; shift 2 ;;
        --concurrency=*)      CONCURRENCY="${1#*=}"; shift ;;
        --requests)           REQUESTS="$2"; shift 2 ;;
        --requests=*)         REQUESTS="${1#*=}"; shift ;;
        --num-ctx)            NUM_CTX="$2"; shift 2 ;;
        --num-ctx=*)          NUM_CTX="${1#*=}"; shift ;;
        --prompt-frac)        PROMPT_FRAC="$2"; shift 2 ;;
        --prompt-frac=*)      PROMPT_FRAC="${1#*=}"; shift ;;
        --num-predict)        NUM_PREDICT="$2"; shift 2 ;;
        --num-predict=*)      NUM_PREDICT="${1#*=}"; shift ;;
        --request-timeout)    REQUEST_TIMEOUT="$2"; shift 2 ;;
        --request-timeout=*)  REQUEST_TIMEOUT="${1#*=}"; shift ;;
        --monitor-interval)   MONITOR_INTERVAL="$2"; shift 2 ;;
        --monitor-interval=*) MONITOR_INTERVAL="${1#*=}"; shift ;;
        --host)               HOST="$2"; shift 2 ;;
        --host=*)             HOST="${1#*=}"; shift ;;
        --warmup)             DO_WARMUP=1; shift ;;
        --no-warmup)          DO_WARMUP=0; shift ;;
        --dry-run)            DRY_RUN=1; shift ;;
        -h|--help)            usage 0 ;;
        *)                    err "unknown arg: $1"; usage 2 ;;
    esac
done

[ "$REQUESTS" = "" ] && REQUESTS=$((CONCURRENCY * 2))

# ---------------------------------------------------------------------------
# pre-flight: pick model, pick num_ctx, check GPU sanity
# ---------------------------------------------------------------------------

# API helpers (api_largest_model, api_model_size_bytes, api_bytes_to_gib,
# api_model_max_context, api_alive) live in scripts/lib/api.sh. Sourced
# below so the helpers see the final value of $HOST after argument parse.

# shellcheck source=lib/api.sh
. "${REPO_ROOT}/scripts/lib/api.sh"

# Check Ollama is reachable; bail out fast if not.
if ! api_alive 2; then
    err "cannot reach Ollama at ${HOST} (is the daemon running?)"
    exit 1
fi

if [ -z "$MODEL" ]; then
    MODEL=$(api_largest_model)
    if [ -z "$MODEL" ]; then
        err "no models installed (pull one with: ollama pull <model>)"
        exit 1
    fi
fi

if [ -z "$NUM_CTX" ]; then
    NUM_CTX=$(api_model_max_context "$MODEL")
    if [ -z "$NUM_CTX" ] || [ "$NUM_CTX" -lt 4096 ]; then
        warn "could not determine max context for $MODEL; defaulting to 32768"
        NUM_CTX=32768
    fi
fi

MODEL_SIZE_BYTES=$(api_model_size_bytes "$MODEL")
MODEL_SIZE_GIB=$(api_bytes_to_gib "${MODEL_SIZE_BYTES:-0}")
MODEL_MAX_CTX=$(api_model_max_context "$MODEL")

# Compute prompt size in tokens and chars. awk handles the float.
PROMPT_TOKENS=$(awk --assign=n="$NUM_CTX" --assign=f="$PROMPT_FRAC" \
    'BEGIN { printf "%d", n*f }')
PROMPT_CHARS=$(awk --assign=t="$PROMPT_TOKENS" --assign=c="$CHARS_PER_TOKEN" \
    'BEGIN { printf "%d", t*c }')

# ---------------------------------------------------------------------------
# Pull Ollama's effective server config. Without this, "concurrency=8" in
# the test plan can be misleading: if the daemon is running with the
# default OLLAMA_NUM_PARALLEL=1, those 8 requests will queue inside
# Ollama and we'll be measuring queue throughput, not GPU parallelism.
# Surfacing the value here makes that visible BEFORE the run starts and
# lets the user adjust /etc/systemd/system/ollama.service.d/ overrides
# (or drop --concurrency) instead of staring at confusing latency
# percentiles afterwards.
# ---------------------------------------------------------------------------

# shellcheck source=lib/snapshot.sh
. "${REPO_ROOT}/scripts/lib/snapshot.sh"
OLLAMA_CFG_JSON=$(snapshot_ollama_config_json)

# Pull the keys most relevant to "how much stress will Ollama actually
# accept" - everything else is in the JSONL log via log-run.sh. The
# parser lives in lib/snapshot.sh as snapshot_ollama_cfg_vars (kept
# next to snapshot_ollama_config_json for cohesion).
read -r CFG_NUM_PARALLEL CFG_MAX_QUEUE CFG_MAX_LOADED CFG_KEEP_ALIVE \
        CFG_FLASH_ATTN  CFG_KV_CACHE  CFG_NEW_ENGINE  CFG_CTX_LEN \
        CFG_LOAD_TIMEOUT CFG_GPU_OVERHEAD \
        <<<"$(snapshot_ollama_cfg_vars "$OLLAMA_CFG_JSON")"

header "Stress-test plan"
info  "host:                ${HOST}"
info  "model:               ${MODEL}"
info  "model on-disk size:  ${MODEL_SIZE_GIB} GiB"
info  "model max context:   ${MODEL_MAX_CTX}"
info  "num_ctx:             ${NUM_CTX}"
info  "prompt:              ~${PROMPT_TOKENS} tokens (${PROMPT_CHARS} chars, ${PROMPT_FRAC} of num_ctx)"
info  "num_predict:         ${NUM_PREDICT}"
info  "concurrency:         ${CONCURRENCY}"
info  "requests:            ${REQUESTS}"
info  "request timeout:     ${REQUEST_TIMEOUT}s"
info  "monitor interval:    ${MONITOR_INTERVAL}s"
info  "warmup:              $([ "$DO_WARMUP" = 1 ] && echo "yes" || echo "no")"

header "Ollama runtime config (governs how much stress Ollama will accept)"
if [ "$OLLAMA_CFG_JSON" = "null" ]; then
    warn "could not read Ollama's effective config (no recent 'server config'"
    warn "  line found in journalctl/docker logs). Defaults assumed below."
    warn "  Restart Ollama to refresh the log line:  sudo systemctl restart ollama"
fi
info  "OLLAMA_NUM_PARALLEL:      ${CFG_NUM_PARALLEL}    (concurrent requests per loaded model)"
info  "OLLAMA_MAX_QUEUE:         ${CFG_MAX_QUEUE}    (queued-request cap before HTTP 503)"
info  "OLLAMA_MAX_LOADED_MODELS: ${CFG_MAX_LOADED}    (0 = auto)"
info  "OLLAMA_KEEP_ALIVE:        ${CFG_KEEP_ALIVE}"
info  "OLLAMA_FLASH_ATTENTION:   ${CFG_FLASH_ATTN}"
info  "OLLAMA_KV_CACHE_TYPE:     ${CFG_KV_CACHE}"
info  "OLLAMA_NEW_ENGINE:        ${CFG_NEW_ENGINE}"
info  "OLLAMA_CONTEXT_LENGTH:    ${CFG_CTX_LEN}    (0 = use model default)"
info  "OLLAMA_LOAD_TIMEOUT:      ${CFG_LOAD_TIMEOUT}"
info  "OLLAMA_GPU_OVERHEAD:      ${CFG_GPU_OVERHEAD}"

# Concurrency reality check. If the user asked for more parallel requests
# than Ollama is configured to actually run in parallel, we will measure
# QUEUE behavior, not GPU parallelism. Warn explicitly.
if [ "$CFG_NUM_PARALLEL" != "?" ] && [ "$CFG_NUM_PARALLEL" -gt 0 ] 2>/dev/null; then
    if [ "$CONCURRENCY" -gt "$CFG_NUM_PARALLEL" ]; then
        warn "concurrency=${CONCURRENCY} > OLLAMA_NUM_PARALLEL=${CFG_NUM_PARALLEL}:"
        warn "  Ollama will run ${CFG_NUM_PARALLEL} request(s) in parallel and queue the rest."
        warn "  This test will primarily measure queueing, not GPU parallelism."
        warn "  To raise it:  sudo systemctl edit ollama.service  ->  add"
        warn "      [Service]"
        warn "      Environment=\"OLLAMA_NUM_PARALLEL=${CONCURRENCY}\""
        warn "  Then: sudo systemctl restart ollama"
    fi
fi
if [ "$CFG_MAX_QUEUE" != "?" ] && [ "$CFG_MAX_QUEUE" -gt 0 ] 2>/dev/null; then
    # Account for warmup using a slot too.
    if [ "$REQUESTS" -gt "$CFG_MAX_QUEUE" ]; then
        warn "requests=${REQUESTS} > OLLAMA_MAX_QUEUE=${CFG_MAX_QUEUE}:"
        warn "  some requests will get HTTP 503 'too many requests'."
    fi
fi
if [ "$CFG_FLASH_ATTN" = "false" ]; then
    info "  note: FLASH_ATTENTION is off; KV cache stays in f16. Set"
    info "        OLLAMA_FLASH_ATTENTION=1 + OLLAMA_KV_CACHE_TYPE=q8_0 to halve"
    info "        per-request VRAM at high num_ctx (helps fit 256K context)."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    header "Dry run; exiting without sending requests."
    exit 0
fi

# ---------------------------------------------------------------------------
# pre-flight: refuse to run if MES ring is already full
# ---------------------------------------------------------------------------

# shellcheck source=lib/dmesg.sh
. "${REPO_ROOT}/scripts/lib/dmesg.sh"
PRE_MES_TIMEOUT_COUNT=$(mes_count_timeouts)
PRE_MES_RING_FULL_COUNT=$(mes_count_ring_full)
if [ "$PRE_MES_RING_FULL_COUNT" -gt 0 ]; then
    err "MES ring buffer is already full (per dmesg) - GPU is wedged."
    err "Reboot before running this stress test. See docs/build-fixes.md Fix 4."
    exit 3
fi

# ---------------------------------------------------------------------------
# rocm-smi monitor (background)
# ---------------------------------------------------------------------------

WORK_DIR=$(mktemp --directory --suffix=.stress)
MONITOR_LOG="${WORK_DIR}/monitor.csv"
REQUESTS_DIR="${WORK_DIR}/requests"
mkdir -p "$REQUESTS_DIR"

cleanup() {
    # Kill the monitor if still running.
    if [ -n "${MONITOR_PID:-}" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    rm --recursive --force "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Single rocm-smi sample, parsed into a CSV row.
# Columns: epoch,vram_used_b,vram_total_b,gtt_used_b,gtt_total_b,gpu_use_pct,temp_c
sample_rocm_smi() {
    local out
    out=$(rocm-smi --showmeminfo vram gtt --showuse --showtemp --json 2>/dev/null \
        | python3 -c 'import json,sys
d=json.load(sys.stdin)
c=next(iter(d.values()))
def g(k,default=""):
    return c.get(k,default)
print(",".join([
    g("VRAM Total Used Memory (B)","0"),
    g("VRAM Total Memory (B)","0"),
    g("GTT Total Used Memory (B)","0"),
    g("GTT Total Memory (B)","0"),
    str(g("GPU use (%)","0")).strip(),
    str(g("Temperature (Sensor edge) (C)","0")).strip(),
]))' 2>/dev/null || echo "0,0,0,0,0,0")
    printf '%s,%s\n' "$(date +%s)" "$out"
}

monitor_loop() {
    printf 'epoch,vram_used_b,vram_total_b,gtt_used_b,gtt_total_b,gpu_use_pct,temp_c\n' >"$MONITOR_LOG"
    while true; do
        sample_rocm_smi >>"$MONITOR_LOG"
        sleep "$MONITOR_INTERVAL"
    done
}

if command -v rocm-smi >/dev/null 2>&1; then
    monitor_loop &
    MONITOR_PID=$!
else
    warn "rocm-smi not found; skipping VRAM/GTT monitoring"
    MONITOR_PID=""
fi

# ---------------------------------------------------------------------------
# warmup
# ---------------------------------------------------------------------------

WARMUP_OK=0
if [ "$DO_WARMUP" -eq 1 ]; then
    header "Warmup"
    info "loading model with a tiny request..."
    local_payload="{\"model\":\"$MODEL\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_ctx\":${NUM_CTX},\"num_predict\":1}}"
    if curl --silent --max-time 600 --fail \
            --request POST \
            --header 'content-type: application/json' \
            --data "$local_payload" \
            "${HOST}/api/generate" >/dev/null 2>&1; then
        WARMUP_OK=1
        ok "model loaded"
    else
        warn "warmup request failed (continuing anyway)"
    fi
fi

# ---------------------------------------------------------------------------
# build the prompt (one long synthetic passage; identical for all reqs)
# ---------------------------------------------------------------------------

PROMPT_FILE="${WORK_DIR}/prompt.txt"
python3 -c "
import json, sys
PASSAGE = (
    'The Strix Halo APU integrates a Zen 5 CPU complex with an RDNA 3.5 GPU '
    '(gfx1151) sharing a unified 128 GiB LPDDR5X memory pool. ROCm 7.2.2 '
    'introduces compiler and runtime support for this architecture. '
)
target = ${PROMPT_CHARS}
text = (PASSAGE * (target // len(PASSAGE) + 1))[:target]
prompt = (
    'You are answering a comprehension question. Read the following passage '
    'carefully, then answer the question in ONE short sentence at the end.\n\n'
    'PASSAGE:\n' + text +
    '\n\nQUESTION: What GPU architecture does the passage mention?\nANSWER:'
)
sys.stdout.write(prompt)
" >"$PROMPT_FILE"

ACTUAL_PROMPT_CHARS=$(wc --bytes <"$PROMPT_FILE")
info "prompt built: ${ACTUAL_PROMPT_CHARS} chars"

# ---------------------------------------------------------------------------
# fire requests
# ---------------------------------------------------------------------------

# fire_one <id> - send one request, write JSON response to $REQUESTS_DIR/<id>.json
# and timing info to $REQUESTS_DIR/<id>.meta. Return curl's exit code.
#
# IMPORTANT: each request gets a UNIQUE prefix prepended to the shared
# passage. Without this, identical prompts at temperature=0 would let
# Ollama serve cached results (KV cache prefix-match), making most of
# the requests near-instant and defeating the point of a stress test.
# A short, unique prefix invalidates the cache while keeping ~99% of
# the prompt the same length.
fire_one() {
    local id="$1"
    local payload_file="${REQUESTS_DIR}/${id}.payload.json"
    local out_file="${REQUESTS_DIR}/${id}.json"
    local meta_file="${REQUESTS_DIR}/${id}.meta"
    python3 -c "
import json, time
prompt = open('${PROMPT_FILE}').read()
prefix = f'[stress-request id=${id} ts={time.time_ns()}] '
print(json.dumps({
    'model': '${MODEL}',
    'prompt': prefix + prompt,
    'stream': False,
    'raw': True,
    'options': {'num_ctx': ${NUM_CTX}, 'num_predict': ${NUM_PREDICT}, 'temperature': 0.0},
}))" >"$payload_file"
    local t0
    t0=$(date +%s.%N)
    local rc=0
    curl --silent --max-time "$REQUEST_TIMEOUT" \
        --request POST \
        --header 'content-type: application/json' \
        --data "@${payload_file}" \
        "${HOST}/api/generate" >"$out_file" 2>"${REQUESTS_DIR}/${id}.err" \
        || rc=$?
    local t1
    t1=$(date +%s.%N)
    printf 'rc=%s\nt0=%s\nt1=%s\n' "$rc" "$t0" "$t1" >"$meta_file"
    rm --force "$payload_file"
    return "$rc"
}

# We track request PIDs in this array so the concurrency gate and the
# final wait operate on the SPECIFIC processes we launched - never on
# the monitor_loop background job (which is an infinite loop and would
# make a no-arg `wait` block forever; this exact bug was hit during
# initial bring-up).
#
# Note: a previous version used `jobs --pid --running` inside `$(...)`
# to count running children. That is broken because $(...) creates a
# subshell, and subshells inherit an EMPTY job table from the parent.
# So `jobs` always returned 0 lines and the gate never fired.
# `kill -0 $pid` checks the kernel directly and works regardless.
REQ_PIDS=()

prune_finished_pids() {
    local p alive=()
    for p in "${REQ_PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then
            alive+=("$p")
        fi
    done
    REQ_PIDS=("${alive[@]}")
}

header "Firing ${REQUESTS} requests, concurrency=${CONCURRENCY}"
T_RUN_START=$(date +%s)

NEXT_ID=1
while [ "$NEXT_ID" -le "$REQUESTS" ]; do
    prune_finished_pids
    if [ "${#REQ_PIDS[@]}" -ge "$CONCURRENCY" ]; then
        info "  ... +$((($(date +%s) - T_RUN_START)))s waiting for a slot (in-flight=${#REQ_PIDS[@]}/${CONCURRENCY})"
    fi
    while [ "${#REQ_PIDS[@]}" -ge "$CONCURRENCY" ]; do
        # Block until at least one of OUR request PIDs finishes.
        # `wait -n <pids...>` blocks for any of the listed PIDs only
        # (not the monitor). Falls back to a short sleep on bash<5
        # where `wait -n PID` may not be supported.
        wait -n "${REQ_PIDS[@]}" 2>/dev/null || sleep 1
        prune_finished_pids
    done
    info "  -> +$((($(date +%s) - T_RUN_START)))s launching request #${NEXT_ID} (in-flight=$((${#REQ_PIDS[@]} + 1))/${CONCURRENCY})"
    fire_one "$NEXT_ID" &
    REQ_PIDS+=("$!")
    NEXT_ID=$((NEXT_ID + 1))
done

info "all requests launched; waiting for completion..."
# Wait ONLY for the request PIDs - never bare `wait`, which would also
# wait for the monitor_loop subshell and hang forever.
for pid in "${REQ_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done
T_RUN_END=$(date +%s)
RUN_ELAPSED=$((T_RUN_END - T_RUN_START))
ok "all ${REQUESTS} requests completed in ${RUN_ELAPSED}s"

# Stop the monitor now that all requests are done. Cleanup trap also
# does this on any other exit path (e.g. ctrl-c during the wait loop).
if [ -n "${MONITOR_PID:-}" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
fi

# ---------------------------------------------------------------------------
# aggregate per-request results
# ---------------------------------------------------------------------------

header "Per-request results"
SUCCEEDED=0
FAILED=0
TOTAL_PROMPT_TOK=0
TOTAL_DECODE_TOK=0
TOTAL_PROMPT_S=0
TOTAL_DECODE_S=0
LAT_LIST_FILE="${WORK_DIR}/latencies.txt"
: >"$LAT_LIST_FILE"

for id in $(seq 1 "$REQUESTS"); do
    meta="${REQUESTS_DIR}/${id}.meta"
    out="${REQUESTS_DIR}/${id}.json"
    [ -f "$meta" ] || { err "missing meta for request $id"; FAILED=$((FAILED+1)); continue; }
    rc=$(awk --field-separator='=' '/^rc=/{print $2}' "$meta")
    t0=$(awk --field-separator='=' '/^t0=/{print $2}' "$meta")
    t1=$(awk --field-separator='=' '/^t1=/{print $2}' "$meta")
    wall=$(awk --assign=a="$t1" --assign=b="$t0" 'BEGIN{ printf "%.2f", a-b }')
    if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
        err "request #${id}: rc=${rc} wall=${wall}s (failed)"
        FAILED=$((FAILED+1))
        continue
    fi
    # Extract Ollama's per-request timings.
    parsed=$(python3 -c "
import json
d=json.load(open('${out}'))
ped=(d.get('prompt_eval_duration',0) or 1)/1e9
pec=d.get('prompt_eval_count') or 0
ed =(d.get('eval_duration',0) or 1)/1e9
ec =d.get('eval_count') or 0
print(f'{pec} {ped:.3f} {ec} {ed:.3f}')" 2>/dev/null || echo "0 1 0 1")
    pec=$(printf '%s' "$parsed" | awk '{print $1}')
    ped=$(printf '%s' "$parsed" | awk '{print $2}')
    ec=$(printf  '%s' "$parsed" | awk '{print $3}')
    ed=$(printf  '%s' "$parsed" | awk '{print $4}')
    info "  #${id}: wall=${wall}s  prompt=${pec} tok in ${ped}s  decode=${ec} tok in ${ed}s"
    SUCCEEDED=$((SUCCEEDED+1))
    TOTAL_PROMPT_TOK=$((TOTAL_PROMPT_TOK + pec))
    TOTAL_DECODE_TOK=$((TOTAL_DECODE_TOK + ec))
    TOTAL_PROMPT_S=$(awk --assign=a="$TOTAL_PROMPT_S" --assign=b="$ped" 'BEGIN{printf "%.3f", a+b}')
    TOTAL_DECODE_S=$(awk --assign=a="$TOTAL_DECODE_S" --assign=b="$ed"  'BEGIN{printf "%.3f", a+b}')
    printf '%s\n' "$wall" >>"$LAT_LIST_FILE"
done

# Latency percentiles (sort numerically, then index).
LAT_P50="?"; LAT_P95="?"; LAT_P99="?"; LAT_MAX="?"; LAT_MIN="?"
if [ -s "$LAT_LIST_FILE" ]; then
    LAT_MIN=$(sort --general-numeric-sort "$LAT_LIST_FILE" | head --lines=1)
    LAT_MAX=$(sort --general-numeric-sort "$LAT_LIST_FILE" | tail --lines=1)
    LAT_P50=$(python3 -c "
import sys
xs=sorted(float(l) for l in open('${LAT_LIST_FILE}'))
def pct(p): return xs[min(int(p*len(xs)), len(xs)-1)]
print(f'{pct(0.50):.2f} {pct(0.95):.2f} {pct(0.99):.2f}')")
    LAT_P95=$(printf '%s' "$LAT_P50" | awk '{print $2}')
    LAT_P99=$(printf '%s' "$LAT_P50" | awk '{print $3}')
    LAT_P50=$(printf '%s' "$LAT_P50" | awk '{print $1}')
fi

# rocm-smi peaks
PEAK_VRAM_GIB="?"; PEAK_GTT_GIB="?"; PEAK_GPU_PCT="?"; PEAK_TEMP_C="?"
SAMPLES=0
if [ -s "$MONITOR_LOG" ]; then
    SAMPLES=$(($(wc --lines <"$MONITOR_LOG") - 1))
    [ "$SAMPLES" -lt 0 ] && SAMPLES=0
    peaks=$(python3 -c "
import csv
xs=list(csv.DictReader(open('${MONITOR_LOG}')))
if not xs:
    print('0 0 0 0'); raise SystemExit
def maxf(k): return max(float(r.get(k,0) or 0) for r in xs)
vram=maxf('vram_used_b')/1024/1024/1024
gtt =maxf('gtt_used_b' )/1024/1024/1024
gpu =maxf('gpu_use_pct')
temp=maxf('temp_c')
print(f'{vram:.2f} {gtt:.2f} {gpu:.0f} {temp:.0f}')")
    PEAK_VRAM_GIB=$(printf '%s' "$peaks" | awk '{print $1}')
    PEAK_GTT_GIB=$(printf  '%s' "$peaks" | awk '{print $2}')
    PEAK_GPU_PCT=$(printf  '%s' "$peaks" | awk '{print $3}')
    PEAK_TEMP_C=$(printf   '%s' "$peaks" | awk '{print $4}')
fi

# Post-run dmesg deltas (helpers from lib/dmesg.sh).
POST_MES_TIMEOUT_COUNT=$(mes_count_timeouts)
POST_MES_RING_FULL_COUNT=$(mes_count_ring_full)
NEW_TIMEOUT=$((POST_MES_TIMEOUT_COUNT - PRE_MES_TIMEOUT_COUNT))
NEW_RING_FULL=$((POST_MES_RING_FULL_COUNT - PRE_MES_RING_FULL_COUNT))
[ "$NEW_TIMEOUT" -lt 0 ] && NEW_TIMEOUT=0
[ "$NEW_RING_FULL" -lt 0 ] && NEW_RING_FULL=0

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

# Capture the runtime state AFTER the run - so the snapshot reflects
# what the runner ACTUALLY did for this model load (FA on/off, KV
# cache type+size, compute buffers). The env-var values printed above
# in the plan are intent; this is reality.
RUNTIME_STATE_JSON=$(snapshot_ollama_runtime_state_json)
read -r RT_FA_RES RT_KV_K RT_KV_V RT_KV_TOTAL RT_LIBRARY RT_COMPUTE \
    <<<"$(printf '%s' "$RUNTIME_STATE_JSON" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read()) or {}
except Exception:
    d = {}
def g(k, default="?"):
    v = d.get(k, default)
    return default if v in ("", None) else v
print(g("flash_attn_resolved"), g("kv_cache_k_type"), g("kv_cache_v_type"),
      g("kv_cache_total_mib", 0), g("library"), g("compute"))')"

header "Summary"
info "model:                 ${MODEL}  (${MODEL_SIZE_GIB} GiB on disk)"
info "num_ctx:               ${NUM_CTX}  (model max=${MODEL_MAX_CTX})"
info "concurrency:           ${CONCURRENCY}  (Ollama NUM_PARALLEL=${CFG_NUM_PARALLEL})"
info "requests:              ${REQUESTS}  (succeeded=${SUCCEEDED}  failed=${FAILED})"
info "wall (run only):       ${RUN_ELAPSED}s"
info "throughput total:      $(awk --assign=t="$TOTAL_DECODE_TOK" --assign=s="$RUN_ELAPSED" \
                                  'BEGIN{printf "%.1f", t/s}') decode tok/s aggregate"
info "latency p50/p95/p99:   ${LAT_P50}s / ${LAT_P95}s / ${LAT_P99}s   (min=${LAT_MIN}s max=${LAT_MAX}s)"
info "VRAM peak:             ${PEAK_VRAM_GIB} GiB"
info "GTT  peak:             ${PEAK_GTT_GIB} GiB"
info "GPU peak util / temp:  ${PEAK_GPU_PCT}%  /  ${PEAK_TEMP_C} C"
info "monitor samples:       ${SAMPLES}"
info "MES dmesg pre/post:    timeouts ${PRE_MES_TIMEOUT_COUNT}->${POST_MES_TIMEOUT_COUNT} (+${NEW_TIMEOUT})  ring-full ${PRE_MES_RING_FULL_COUNT}->${POST_MES_RING_FULL_COUNT} (+${NEW_RING_FULL})"
info "ollama env (intent):   FA=${CFG_FLASH_ATTN}  KV=${CFG_KV_CACHE}  engine=${CFG_NEW_ENGINE}"
info "ollama runtime (real): FA=${RT_FA_RES}  KV=K(${RT_KV_K})+V(${RT_KV_V})  ${RT_LIBRARY}/${RT_COMPUTE}"
# Flag the most common config-vs-runtime drift right in the summary.
if [ "$CFG_KV_CACHE" != "?" ] && [ "$CFG_KV_CACHE" != "" ] && [ "$CFG_KV_CACHE" != "f16" ] && [ "$RT_KV_K" = "f16" ]; then
    if [ "$CFG_FLASH_ATTN" != "true" ] && [ "$CFG_FLASH_ATTN" != "1" ]; then
        warn "KV CACHE DRIFT: env says ${CFG_KV_CACHE} but runtime is f16 because OLLAMA_FLASH_ATTENTION=${CFG_FLASH_ATTN}."
        warn "  Ollama only honors OLLAMA_KV_CACHE_TYPE when OLLAMA_FLASH_ATTENTION=1 (the runner auto-enabling FA is NOT enough)."
    else
        warn "KV CACHE DRIFT: env says ${CFG_KV_CACHE} but loaded model has K/V=f16. Reload the model."
    fi
fi

EXIT_CODE=0
if [ "$FAILED" -gt 0 ]; then
    err "${FAILED} request(s) failed"
    EXIT_CODE=1
fi
if [ "$NEW_RING_FULL" -gt 0 ]; then
    err "MES ring buffer FILLED during stress test (Mode B; reboot required)"
    EXIT_CODE=1
elif [ "$NEW_TIMEOUT" -gt 0 ]; then
    warn "${NEW_TIMEOUT} new MES timeout(s) observed (Mode A; see Fix 4)"
    EXIT_CODE=1
elif [ "$FAILED" -eq 0 ]; then
    ok "all ${SUCCEEDED} requests succeeded with no new MES errors"
fi

# ---------------------------------------------------------------------------
# emit STRESS_RESULT_JSON for log-run.sh
# ---------------------------------------------------------------------------

# Note: we emit this even on partial failures so the log captures the
# distress signature. log-run.sh only looks at the last line matching
# this prefix.
# Read the runtime-state JSON we captured pre-summary into a python
# dict here so it lands as a structured object (not a string) in the
# log and downstream graphs can index ollama_runtime.kv_cache_total_mib
# without re-parsing.
python3 -c "
import json
try:
    runtime_state = json.loads('''${RUNTIME_STATE_JSON}''') or {}
except Exception:
    runtime_state = {}
out = {
    'model': '${MODEL}',
    'model_size_bytes': ${MODEL_SIZE_BYTES:-0},
    'model_size_gib': float('${MODEL_SIZE_GIB}'),
    'model_max_ctx': ${MODEL_MAX_CTX:-0},
    'num_ctx': ${NUM_CTX},
    'concurrency': ${CONCURRENCY},
    'requests': ${REQUESTS},
    'succeeded': ${SUCCEEDED},
    'failed': ${FAILED},
    'wall_sec': ${RUN_ELAPSED},
    'prompt_tokens_per_request': ${PROMPT_TOKENS},
    'num_predict': ${NUM_PREDICT},
    'latency_sec': {
        'min': '${LAT_MIN}',
        'p50': '${LAT_P50}',
        'p95': '${LAT_P95}',
        'p99': '${LAT_P99}',
        'max': '${LAT_MAX}',
    },
    'peak': {
        'vram_gib': '${PEAK_VRAM_GIB}',
        'gtt_gib':  '${PEAK_GTT_GIB}',
        'gpu_pct':  '${PEAK_GPU_PCT}',
        'temp_c':   '${PEAK_TEMP_C}',
    },
    'mes_dmesg': {
        'pre':  {'timeouts': ${PRE_MES_TIMEOUT_COUNT},  'ring_full': ${PRE_MES_RING_FULL_COUNT}},
        'post': {'timeouts': ${POST_MES_TIMEOUT_COUNT}, 'ring_full': ${POST_MES_RING_FULL_COUNT}},
        'new':  {'timeouts': ${NEW_TIMEOUT},            'ring_full': ${NEW_RING_FULL}},
    },
    'monitor_samples': ${SAMPLES},
    'ollama_config': {
        'num_parallel':      '${CFG_NUM_PARALLEL}',
        'max_queue':         '${CFG_MAX_QUEUE}',
        'max_loaded_models': '${CFG_MAX_LOADED}',
        'keep_alive':        '${CFG_KEEP_ALIVE}',
        'flash_attention':   '${CFG_FLASH_ATTN}',
        'kv_cache_type':     '${CFG_KV_CACHE}',
        'new_engine':        '${CFG_NEW_ENGINE}',
        'context_length':    '${CFG_CTX_LEN}',
        'load_timeout':      '${CFG_LOAD_TIMEOUT}',
        'gpu_overhead':      '${CFG_GPU_OVERHEAD}',
    },
    'ollama_runtime': runtime_state,
}
def coerce(v):
    if isinstance(v, str):
        try: return float(v)
        except ValueError: return v
    return v
def walk(o):
    if isinstance(o, dict): return {k: walk(v) for k,v in o.items()}
    if isinstance(o, list): return [walk(v) for v in o]
    return coerce(o)
print('STRESS_RESULT_JSON: ' + json.dumps(walk(out), separators=(',',':')))"

exit "$EXIT_CODE"
