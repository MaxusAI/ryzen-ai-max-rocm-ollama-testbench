#!/usr/bin/env bash
# scripts/log-run.sh - run validate.sh or stress-test.sh and append a
# timestamped JSONL record of the result + system snapshot to a
# persistent history log. Designed to be a no-touch wrapper so we can
# add timestamped tracking without modifying validate.sh itself.
#
# Default log path: ./logs/run-history.jsonl  (override via --log <path>
# or the RUN_HISTORY_LOG env var). Each line is a self-contained JSON
# object - safe to grep, jq, or import into anything that speaks JSONL.
#
# Usage:
#   ./scripts/log-run.sh [options] -- <command> [command-args...]
#   ./scripts/log-run.sh show [--last N] [--kind KIND]   # tail recent entries
#   ./scripts/log-run.sh diff <id1> <id2>                # version diff between runs
#   ./scripts/log-run.sh --help
#
# Wrapper options (before the '--'):
#   --kind KIND        validate | stress | other (default: auto-detect from cmd)
#   --label TEXT       free-text label attached to this run (e.g. "after-reboot")
#   --log PATH         override the JSONL log path
#   --no-tee           do not echo the wrapped command's output to stdout
#                      (useful in CI; output is still captured and parsed)
#
# Examples:
#   sudo ./scripts/log-run.sh -- ./scripts/validate.sh --skip-long-ctx
#   sudo ./scripts/log-run.sh --label="post-mes-fix" -- ./scripts/validate.sh
#   ./scripts/log-run.sh -- ./scripts/stress-test.sh --concurrency=8
#   ./scripts/log-run.sh show --last 3
#   ./scripts/log-run.sh diff 0 1     # newest vs second-newest

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

LOG_PATH="${RUN_HISTORY_LOG:-${REPO_ROOT}/logs/run-history.jsonl}"
KIND=""
LABEL=""
DO_TEE=1

# ---------------------------------------------------------------------------
# pretty (colors only - we use raw printf below; pretty.sh's helpers
# would shadow our custom show/diff/wrap formatters if invoked).
# ---------------------------------------------------------------------------

# shellcheck source=lib/pretty.sh
. "${REPO_ROOT}/scripts/lib/pretty.sh"

# ---------------------------------------------------------------------------
# subcommand: show
# ---------------------------------------------------------------------------

cmd_show() {
    local last=10 kind_filter=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --last)     last="$2"; shift 2 ;;
            --last=*)   last="${1#*=}"; shift ;;
            --kind)     kind_filter="$2"; shift 2 ;;
            --kind=*)   kind_filter="${1#*=}"; shift ;;
            *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    if [ ! -f "$LOG_PATH" ]; then
        printf '(no log yet at %s)\n' "$LOG_PATH"
        exit 0
    fi
    local rows
    if [ -n "$kind_filter" ]; then
        rows=$(grep --extended-regexp "\"kind\":\"${kind_filter}\"" "$LOG_PATH" | tail --lines="$last")
    else
        rows=$(tail --lines="$last" "$LOG_PATH")
    fi
    if [ -z "$rows" ]; then
        printf '(no matching entries)\n'
        exit 0
    fi
    printf '%s%s%s\n' "${C_BOLD}" "Run history (newest last):" "${C_RESET}"
    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$rows" | jq --raw-output '
            (.snapshot.timestamp // "?") + "  " +
            (.kind // "?") + "  " +
            ((.summary.exit_code // -1) | tostring) + "  " +
            "kernel=" + (.snapshot.kernel // "?") + "  " +
            "mes=" + (.snapshot.mes_fw // "?") + "  " +
            "ollama=" + (.snapshot.ollama // "?") + "  " +
            (.label // "")'
    else
        printf '  (install jq for pretty output)\n'
        printf '%s\n' "$rows"
    fi
}

# ---------------------------------------------------------------------------
# subcommand: diff
# ---------------------------------------------------------------------------

cmd_diff() {
    if [ "$#" -ne 2 ]; then
        printf 'usage: log-run.sh diff <newer-index> <older-index>\n' >&2
        printf '       indices count back from the end (0 = newest)\n' >&2
        exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf 'jq is required for the diff subcommand (apt install jq)\n' >&2
        exit 1
    fi
    if [ ! -f "$LOG_PATH" ]; then
        printf 'no log at %s\n' "$LOG_PATH" >&2
        exit 1
    fi
    local n1="$1" n2="$2" total
    total=$(wc --lines <"$LOG_PATH")
    if [ "$total" -le "$n1" ] || [ "$total" -le "$n2" ]; then
        printf 'log only has %d entries; index out of range\n' "$total" >&2
        exit 1
    fi
    local row1 row2
    row1=$(tail --lines=$((n1 + 1)) "$LOG_PATH" | head --lines=1)
    row2=$(tail --lines=$((n2 + 1)) "$LOG_PATH" | head --lines=1)
    printf '%s===== run A (index %s) vs run B (index %s) =====%s\n' \
        "${C_BOLD}" "$n1" "$n2" "${C_RESET}"
    printf 'kind / time:\n'
    printf '  A: %s\n' "$(printf '%s' "$row1" | jq --raw-output '.kind + " @ " + .snapshot.timestamp + "  " + (.label // "")')"
    printf '  B: %s\n' "$(printf '%s' "$row2" | jq --raw-output '.kind + " @ " + .snapshot.timestamp + "  " + (.label // "")')"
    printf '\nversion deltas:\n'
    diff \
        <(printf '%s' "$row1" | jq --sort-keys '.snapshot' | grep --extended-regexp -v '"timestamp"|"host"') \
        <(printf '%s' "$row2" | jq --sort-keys '.snapshot' | grep --extended-regexp -v '"timestamp"|"host"') \
        | sed 's/^/  /' || true
    printf '\nsummary deltas:\n'
    diff \
        <(printf '%s' "$row1" | jq --sort-keys '.summary') \
        <(printf '%s' "$row2" | jq --sort-keys '.summary') \
        | sed 's/^/  /' || true
}

# ---------------------------------------------------------------------------
# subcommand: wrap (default)
# ---------------------------------------------------------------------------

# Parse validate.sh stdout for layer-result lines and a final tally.
# Returns JSON {"layers":[...], "summary":{...}}.
parse_validate_output() {
    local file="$1" exit_code="$2"
    # Layer lines from the summary section: "  Layer N: STATUS  msg"
    # We ignore color codes.
    local layers
    layers=$(sed --regexp-extended 's/\x1b\[[0-9;]*m//g' "$file" \
        | grep --extended-regexp '^  Layer [0-9]+: (PASS|FAIL|SKIP)' \
        | awk '{
            num=$2; sub(":","",num);
            status=$3;
            msg=$0; sub(/^  Layer [0-9]+: (PASS|FAIL|SKIP)  +/, "", msg);
            gsub(/\\/, "\\\\", msg); gsub(/"/, "\\\"", msg);
            printf "%s{\"layer\":%s,\"status\":\"%s\",\"msg\":\"%s\"}", (NR>1?",":""), num, status, msg
          }')
    local tally
    tally=$(sed --regexp-extended 's/\x1b\[[0-9;]*m//g' "$file" \
        | grep --extended-regexp '^  [0-9]+ passed  [0-9]+ failed  [0-9]+ skipped' \
        | tail --lines=1)
    local p f s
    p=$(printf '%s\n' "$tally" | awk '{print $1+0}')
    f=$(printf '%s\n' "$tally" | awk '{print $3+0}')
    s=$(printf '%s\n' "$tally" | awk '{print $5+0}')
    printf '"layers":[%s],"summary":{"passed":%s,"failed":%s,"skipped":%s,"exit_code":%s}' \
        "$layers" "${p:-0}" "${f:-0}" "${s:-0}" "$exit_code"
}

# Parse stress-test.sh stdout. The stress test emits a single line
# "STRESS_RESULT_JSON: { ... }" near the end which we lift verbatim.
parse_stress_output() {
    local file="$1" exit_code="$2"
    local json
    json=$(sed --regexp-extended 's/\x1b\[[0-9;]*m//g' "$file" \
        | grep --extended-regexp '^STRESS_RESULT_JSON: ' \
        | tail --lines=1 \
        | sed 's/^STRESS_RESULT_JSON: //')
    if [ -z "$json" ]; then
        json='{}'
    fi
    printf '"stress":%s,"summary":{"exit_code":%s}' "$json" "$exit_code"
}

cmd_wrap() {
    if [ "$#" -eq 0 ]; then
        printf 'no command to wrap (use -- before the command)\n' >&2
        exit 2
    fi
    local cmd_basename
    cmd_basename=$(basename "$1")
    if [ -z "$KIND" ]; then
        case "$cmd_basename" in
            validate.sh)    KIND="validate" ;;
            stress-test.sh) KIND="stress"   ;;
            *)              KIND="other"    ;;
        esac
    fi

    mkdir -p "$(dirname "$LOG_PATH")"
    local capture
    capture=$(mktemp --suffix=.run-log)
    # Cleanup on any exit path. The trap intentionally does NOT use
    # 'set -e' propagation - we want the captured exit code, not the
    # trap's.
    trap 'rm --force "${capture:-}" 2>/dev/null || true' EXIT

    printf '%s[log-run]%s wrapping: %s%s%s  (kind=%s)\n' \
        "${C_BLUE}${C_BOLD}" "${C_RESET}" \
        "${C_DIM}" "$*" "${C_RESET}" "$KIND" >&2
    printf '%s[log-run]%s log file: %s\n' \
        "${C_BLUE}${C_BOLD}" "${C_RESET}" "$LOG_PATH" >&2

    local rc=0
    local started_at
    started_at=$(date --iso-8601=seconds)
    local t0
    t0=$(date +%s)
    if [ "$DO_TEE" -eq 1 ]; then
        "$@" 2>&1 | tee "$capture" || rc=${PIPESTATUS[0]}
    else
        "$@" >"$capture" 2>&1 || rc=$?
    fi
    local t1
    t1=$(date +%s)
    local elapsed=$((t1 - t0))

    # Build the JSONL record. Order of operations matters here: snapshot
    # AFTER the wrapped command so any state changes (e.g. ollama
    # version after a restart) are reflected.
    local snapshot_json
    snapshot_json=$(snapshot_versions_json)

    local body=""
    case "$KIND" in
        validate) body=$(parse_validate_output "$capture" "$rc") ;;
        stress)   body=$(parse_stress_output   "$capture" "$rc") ;;
        *)        body="\"summary\":{\"exit_code\":${rc}}" ;;
    esac

    # MES dmesg fingerprint at the time of recording (best-effort, may be empty).
    # mes_count_total handles dmesg/sudo gating + always returns a number.
    local mes_warnings_count
    mes_warnings_count=$(mes_count_total)

    local label_json="null"
    if [ -n "$LABEL" ]; then
        label_json="\"$(printf '%s' "$LABEL" | sed 's/\\/\\\\/g;s/"/\\"/g')\""
    fi

    # Build the JSONL line in memory so a mid-write failure can't corrupt
    # the log (and so failures still get logged via the trailing else).
    local cmd_escaped
    cmd_escaped=$(printf '%s' "$*" | sed 's/\\/\\\\/g;s/"/\\"/g')
    local line=""
    line+='{'
    line+="\"kind\":\"${KIND}\","
    line+="\"started_at\":\"${started_at}\","
    line+="\"elapsed_sec\":${elapsed},"
    line+="\"command\":\"${cmd_escaped}\","
    line+="\"label\":${label_json},"
    line+="\"mes_dmesg_count\":${mes_warnings_count},"
    line+="\"snapshot\":${snapshot_json},"
    line+="${body}"
    line+='}'
    printf '%s\n' "$line" >>"$LOG_PATH"

    printf '%s[log-run]%s recorded: kind=%s exit=%d elapsed=%ds\n' \
        "${C_BLUE}${C_BOLD}" "${C_RESET}" "$KIND" "$rc" "$elapsed" >&2
    if [ "$mes_warnings_count" -gt 0 ]; then
        printf '%s[log-run]%s NOTE: %d MES dmesg lines present (see docs/build-fixes.md Fix 4)\n' \
            "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$mes_warnings_count" >&2
    fi

    exit "$rc"
}

# ---------------------------------------------------------------------------
# arg parsing + dispatch
# ---------------------------------------------------------------------------

usage() {
    sed --quiet '2,/^$/p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

if [ $# -eq 0 ]; then
    usage 0
fi

case "$1" in
    show)   shift; cmd_show "$@"; exit 0 ;;
    diff)   shift; cmd_diff "$@"; exit 0 ;;
    -h|--help) usage 0 ;;
esac

# Wrap mode: collect options up to '--' then forward the rest.
WRAP_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --kind)     KIND="$2"; shift 2 ;;
        --kind=*)   KIND="${1#*=}"; shift ;;
        --label)    LABEL="$2"; shift 2 ;;
        --label=*)  LABEL="${1#*=}"; shift ;;
        --log)      LOG_PATH="$2"; shift 2 ;;
        --log=*)    LOG_PATH="${1#*=}"; shift ;;
        --no-tee)   DO_TEE=0; shift ;;
        --)         shift; WRAP_ARGS=("$@"); break ;;
        -h|--help)  usage 0 ;;
        *)
            # If we haven't seen a '--' and the arg looks like an
            # executable command, treat the rest as the wrapped command.
            WRAP_ARGS=("$@")
            break ;;
    esac
done

cmd_wrap "${WRAP_ARGS[@]}"
