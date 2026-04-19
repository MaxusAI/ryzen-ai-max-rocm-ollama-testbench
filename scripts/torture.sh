#!/usr/bin/env bash
# scripts/torture.sh - escalating VRAM/scheduler torture ladder.
#
# Why this exists separately from stress-test.sh: stress-test.sh runs ONE
# configuration. To answer "where does Ollama break?" we need a series of
# progressively harder configs, with health checks between them, and a
# clean stop at the first failure. That is this script.
#
# Each stage:
#   1. Confirms Ollama is healthy (/api/version, no MES wedge in dmesg).
#   2. Runs scripts/stress-test.sh with the stage's args, wrapped by
#      scripts/log-run.sh so the result lands in logs/run-history.jsonl
#      (timestamped, with full snapshot, including the new ollama_runtime
#      block so we capture the live FA/KV/seqs/buffers per stage).
#   3. Captures dmesg delta (MES timeouts, ring-full, queue evictions,
#      VM faults, OOM killer hits).
#   4. Decides PASS / FAIL / WEDGED.
#
# The ladder STOPS at the first hard failure (FAIL or WEDGED). The
# point is to find the breakage, not to keep slamming a wedged GPU.
#
# Usage:
#   ./scripts/torture.sh                          # run the full ladder
#   ./scripts/torture.sh --list                   # show stages and exit
#   ./scripts/torture.sh --start 3                # start from stage 3
#   ./scripts/torture.sh --only 4                 # run just stage 4
#   ./scripts/torture.sh --model qwen3.5:122b-a10b-q4_K_M --big-only
#   ./scripts/torture.sh --dry-run                # print plan, no requests
#   ./scripts/torture.sh --keep-going             # do not stop on FAIL
#   ./scripts/torture.sh --label="post-fa-fix"    # tag in run-history.jsonl
#
# Exit codes:
#   0   ladder finished, no stage broke Ollama
#   1   at least one stage failed (Ollama returned an error or new MES events)
#   2   bad invocation
#   3   GPU was already wedged before we started (MES ring full)

# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/snapshot.sh
. "${REPO_ROOT}/scripts/lib/snapshot.sh"
# shellcheck source=lib/dmesg.sh
. "${REPO_ROOT}/scripts/lib/dmesg.sh"
# shellcheck source=lib/api.sh
. "${REPO_ROOT}/scripts/lib/api.sh"

# ---------------------------------------------------------------------------
# pretty (colors + info/ok/warn/header from scripts/lib/pretty.sh;
# torture-specific fail/dim are defined locally below)
# ---------------------------------------------------------------------------

# shellcheck source=lib/pretty.sh
. "${REPO_ROOT}/scripts/lib/pretty.sh"

# fail: like err() but on stdout (torture report stays in one stream).
fail()   { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"; }
# dim: torture-only; suppressed/secondary info inside stage output.
dim()    { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------

OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-http://localhost:11434}"
MODEL=""
START_STAGE=1
ONLY_STAGE=""
BIG_ONLY=0
DRY_RUN=0
KEEP_GOING=0
LIST=0
LABEL=""
SHOW_HELP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host)        OLLAMA_HOST_URL="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --start)       START_STAGE="$2"; shift 2 ;;
        --only)        ONLY_STAGE="$2"; shift 2 ;;
        --big-only)    BIG_ONLY=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --keep-going)  KEEP_GOING=1; shift ;;
        --list|--ls)   LIST=1; shift ;;
        --label)       LABEL="$2"; shift 2 ;;
        --label=*)     LABEL="${1#--label=}"; shift ;;
        -h|--help)     SHOW_HELP=1; shift ;;
        *)
            echo "unknown arg: $1" >&2
            echo "see --help" >&2
            exit 2
            ;;
    esac
done

if [ "$SHOW_HELP" -eq 1 ]; then
    sed -n '2,40p' "$0" | sed 's/^# \?//'
    exit 0
fi

# ---------------------------------------------------------------------------
# pick the model: largest installed by default
# ---------------------------------------------------------------------------

choose_model() {
    if [ -n "$MODEL" ]; then return; fi
    if ! api_alive 5; then
        echo "ERROR: cannot reach ${OLLAMA_HOST_URL}/api/version - is Ollama running?" >&2
        exit 2
    fi
    MODEL=$(api_largest_model)
    if [ -z "$MODEL" ]; then
        echo "ERROR: no models installed - pull one first (e.g. ollama pull llama3.2:latest)" >&2
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# stage definitions
#
# Each stage is a function that prints a one-line description, and the
# args it would pass to stress-test.sh. The runner below does the
# actual invocation + diff + verdict.
#
# Naming convention:  <model-class>-<ctx>-<num_parallel>x<concurrency>-<note>
#
# We intentionally do NOT mutate OLLAMA_KV_CACHE_TYPE or
# OLLAMA_FLASH_ATTENTION here - those are set in the systemd override
# and changing them would require a daemon restart. We DO use --num-ctx,
# --concurrency, --requests, --num-predict, --prompt-frac to dial the
# pressure that Ollama actually accepts at request time.
# ---------------------------------------------------------------------------

# Format:  STAGES[n]="<id>|<description>|<stress-test args>"
declare -a STAGES

stage_register() {
    STAGES+=("$1|$2|$3")
}

# IMPORTANT design note about prompt size: llama.cpp preallocates the
# KV cache for the FULL num_ctx at model load (per sequence). The
# actual prompt size only affects how much of that KV gets populated
# during prompt eval, NOT the peak VRAM. So we use very small prompts
# (--prompt-frac 0.01) to keep prompt-eval time short while still
# exercising the full VRAM allocation. A 256K-ctx test with a 2k-token
# prompt finishes in seconds and burns the same memory as a 131k-token
# prompt that takes 15+ minutes - the latter is wasted wall time.

# Stage 1: confirm Ollama can serve 2 concurrent requests at 256K with
# the current FA+q8_0 KV config. With the user's run history showing
# 94.5 GiB VRAM peak we expect this to work but sit at the edge.
stage_register \
    "256k-2par-2conc-decode" \
    "256K ctx, NUM_PARALLEL=2, concurrency=2, prompt_frac=0.01, num_predict=128 (fast decode test)" \
    "--num-ctx 262144 --concurrency 2 --requests 2 --num-predict 128 --prompt-frac 0.01"

# Stage 2: same VRAM, but request 4 concurrent against NUM_PARALLEL=2.
# Tests whether the queue scheduler stays stable when the queue is
# always non-empty (2 served, 2 always waiting). Watches for: leaked
# KV slots between batches, scheduler deadlock, slot accounting bugs.
stage_register \
    "256k-2par-4conc-queue" \
    "256K ctx, NP=2, concurrency=4 (2 always queued)" \
    "--num-ctx 262144 --concurrency 4 --requests 4 --num-predict 64 --prompt-frac 0.005"

# Stage 3: drop ctx so per-seq KV is small enough for higher
# concurrency to fit. 64K ctx q8_0 ~ 1.9 GiB KV per seq. With weights
# 75 GiB and NP=2, we have ~17 GiB of headroom for KV+scratch, easily
# enough for 8 sequences if NP allowed it - but NP is capped at 2 by
# the env, so 8 concurrent will queue 6 continuously.
stage_register \
    "64k-2par-8conc-saturate" \
    "64K ctx, NP=2, concurrency=8 (6 always queued)" \
    "--num-ctx 65536 --concurrency 8 --requests 8 --num-predict 64 --prompt-frac 0.01"

# Stage 4: long sustained decode at the edge. Same shape as stage 1
# but actually generates 2048 tokens per request, which keeps the GPU
# saturated for several minutes. Watches for thermal throttling, KV
# eviction bugs, and slow VRAM leaks between decode steps.
stage_register \
    "256k-2par-2conc-sustained" \
    "256K ctx, NP=2, concurrency=2, num_predict=2048 (sustained decode at VRAM edge)" \
    "--num-ctx 262144 --concurrency 2 --requests 2 --num-predict 2048 --prompt-frac 0.01"

# Stage 5: try to allocate more KV than we have headroom for, by
# forcing num_ctx to model max with concurrency that exceeds NP, so
# Ollama queues. The KV alloc itself is per-seq so this should NOT
# fail - it tests whether queueing past saturation produces clean
# 503s rather than HTTP 500s or runner crashes.
stage_register \
    "256k-overcommit-queue" \
    "256K ctx, NP=2, concurrency=16, requests=16 (heavy queue: 14 always waiting)" \
    "--num-ctx 262144 --concurrency 16 --requests 16 --num-predict 32 --prompt-frac 0.005"

# ---------------------------------------------------------------------------
# health checks (api_alive + gpu_wedged + per-mode MES counters live in
# scripts/lib/api.sh and scripts/lib/dmesg.sh respectively)
# ---------------------------------------------------------------------------

# gpu_wedged + per-mode MES counters live in scripts/lib/dmesg.sh.
# `mes_counters` here keeps its 4-tuple shape because it's the format
# torture.sh's stage diff loop expects (cheap to keep, no other caller
# wants the same shape).
mes_counters() {
    printf '%s %s %s %s' \
        "$(mes_count_timeouts)" \
        "$(mes_count_ring_full)" \
        "$(mes_count_evictions)" \
        "$(mes_count_vm_faults)"
}

# VRAM usage in GiB (from amdgpu sysfs - the only iGPU-accurate source).
vram_used_gib() {
    local f
    for f in /sys/class/drm/card*/device/mem_info_vram_used; do
        if [ -r "$f" ]; then
            awk '{printf "%.2f", $1/1024/1024/1024}' "$f"
            return
        fi
    done
    printf 'NA'
}

# ---------------------------------------------------------------------------
# stage runner
# ---------------------------------------------------------------------------

run_stage() {
    local idx="$1" id="$2" desc="$3" args="$4"

    header "Stage $idx: $id"
    info "$desc"
    info "stress-test args: $args"

    if [ "$DRY_RUN" -eq 1 ]; then
        dim "(dry run - skipping)"
        echo "DRY"
        return 0
    fi

    if ! api_alive; then
        fail "Ollama API is not responding before this stage"
        echo "FAIL"
        return 0
    fi

    local pre_counters post_counters pre_vram post_vram start_time end_time
    pre_counters=$(mes_counters)
    pre_vram=$(vram_used_gib)
    info "pre-stage: VRAM used=${pre_vram} GiB  MES counters (timeouts ring-full evictions vm-faults)=${pre_counters}"
    start_time=$(date +%s)

    # Run via log-run.sh so the result lands in run-history.jsonl with
    # full snapshot. We deliberately do NOT propagate set -e through
    # the wrapped command - we want to capture the failure here.
    local rc=0
    local label_arg=()
    if [ -n "$LABEL" ]; then
        label_arg=(--label="${LABEL}/${id}")
    else
        label_arg=(--label="torture/${id}")
    fi
    set +o errexit
    "${REPO_ROOT}/scripts/log-run.sh" "${label_arg[@]}" -- \
        "${REPO_ROOT}/scripts/stress-test.sh" \
        --model "$MODEL" \
        --host "$OLLAMA_HOST_URL" \
        $args
    rc=$?
    set -o errexit

    end_time=$(date +%s)
    post_counters=$(mes_counters)
    post_vram=$(vram_used_gib)

    info "post-stage: VRAM used=${post_vram} GiB  MES counters=${post_counters}  duration=$((end_time - start_time))s  rc=$rc"

    # Diff the counters.
    read -r pt pr pe pv <<<"$pre_counters"
    read -r qt qr qe qv <<<"$post_counters"
    local d_to=$((qt - pt)) d_rf=$((qr - pr)) d_ev=$((qe - pe)) d_vf=$((qv - pv))
    if [ "$d_to" -gt 0 ] || [ "$d_rf" -gt 0 ] || [ "$d_vf" -gt 0 ]; then
        warn "MES delta: +${d_to} timeouts, +${d_rf} ring-full, +${d_ev} evictions, +${d_vf} vm-faults"
    fi

    if gpu_wedged; then
        fail "GPU appears WEDGED after this stage (MES ring full / failed / reset)"
        echo "WEDGED"
        return 0
    fi

    if ! api_alive; then
        fail "Ollama API stopped responding after this stage"
        echo "FAIL"
        return 0
    fi

    if [ "$rc" -ne 0 ]; then
        fail "stress-test.sh exit code = $rc (some requests failed or new MES events)"
        echo "FAIL"
        return 0
    fi

    if [ "$d_rf" -gt 0 ]; then
        fail "new MES ring-full events (+${d_rf}) - GPU is degraded but still alive"
        echo "FAIL"
        return 0
    fi

    ok "stage passed"
    echo "PASS"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

choose_model

if [ "$LIST" -eq 1 ]; then
    header "Torture ladder stages"
    info "Default model: $MODEL"
    info "Use --start N to begin at stage N, or --only N to run just one."
    echo
    n=1
    for s in "${STAGES[@]}"; do
        IFS='|' read -r id desc args <<<"$s"
        printf '  %d. %-22s  %s\n' "$n" "$id" "$desc"
        printf '     args: %s\n' "$args"
        n=$((n + 1))
    done
    exit 0
fi

# Sanity: do not start if the GPU is already wedged.
if gpu_wedged; then
    fail "GPU is already wedged (MES ring full / failed in dmesg). Reboot first."
    exit 3
fi

if ! api_alive; then
    fail "Ollama API at ${OLLAMA_HOST_URL} is not responding. Start ollama first."
    exit 2
fi

header "Torture ladder starting"
info "host:           $OLLAMA_HOST_URL"
info "model:          $MODEL"
info "start stage:    $START_STAGE"
info "only stage:     ${ONLY_STAGE:-(all)}"
info "dry run:        $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)"
info "stop on fail:   $([ "$KEEP_GOING" -eq 1 ] && echo no || echo yes)"
info "label:          ${LABEL:-(none)}"
info "log:            ${RUN_HISTORY_LOG:-${REPO_ROOT}/logs/run-history.jsonl}"

declare -a RESULTS
i=0
for s in "${STAGES[@]}"; do
    i=$((i + 1))
    IFS='|' read -r id desc args <<<"$s"
    if [ -n "$ONLY_STAGE" ] && [ "$ONLY_STAGE" != "$i" ] && [ "$ONLY_STAGE" != "$id" ]; then
        continue
    fi
    if [ -z "$ONLY_STAGE" ] && [ "$i" -lt "$START_STAGE" ]; then
        continue
    fi
    # The verdict (PASS/FAIL/WEDGED/DRY) is run_stage's stdout last
    # line. We capture it via process substitution while still showing
    # the live output to the user.
    verdict=$(run_stage "$i" "$id" "$desc" "$args" | tee /dev/stderr | tail -n 1)
    RESULTS+=("$i|$id|$verdict")
    if [ "$KEEP_GOING" -eq 0 ] && { [ "$verdict" = "FAIL" ] || [ "$verdict" = "WEDGED" ]; }; then
        fail "stopping after first failure (use --keep-going to continue)"
        break
    fi
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

header "Torture summary"
declare -i pass=0 failed=0 wedged=0 dry=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r idx id verdict <<<"$r"
    case "$verdict" in
        PASS)   ok   "stage $idx ($id): PASS";   pass=$((pass + 1)) ;;
        FAIL)   fail "stage $idx ($id): FAIL";   failed=$((failed + 1)) ;;
        WEDGED) fail "stage $idx ($id): WEDGED"; wedged=$((wedged + 1)) ;;
        DRY)    dim  "stage $idx ($id): (dry)";  dry=$((dry + 1)) ;;
        *)      warn "stage $idx ($id): $verdict (unknown)" ;;
    esac
done
echo
info "$pass passed, $failed failed, $wedged wedged, $dry dry"
info "history log: ${RUN_HISTORY_LOG:-${REPO_ROOT}/logs/run-history.jsonl}"
info "  -> ./scripts/log-run.sh show --last $((${#RESULTS[@]} + 1))"

if [ "$failed" -gt 0 ] || [ "$wedged" -gt 0 ]; then
    exit 1
fi
exit 0
