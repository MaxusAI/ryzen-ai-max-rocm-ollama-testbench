#!/usr/bin/env bash
# scripts/lib/pretty.sh - terminal colors + status-line helpers shared by
# the operational scripts (install-mes-firmware.sh, stress-test.sh,
# torture.sh) and partially by validate.sh and log-run.sh (colors only).
#
# Design notes:
#   - Sourceable, not executable. Registers `C_*` color vars and the
#     pretty-printers in the caller's shell.
#   - Auto-detects whether stdout is a TTY (`[ -t 1 ]`) and disables
#     escape codes when piped/redirected so log files stay clean.
#   - Provides ONE flavour of status helpers (`info/ok/warn/err/header`).
#     Scripts with their own dialect (notably validate.sh, which uses
#     layer-aware `pass/fail/skip`) can source this file purely for the
#     color vars and define their own helpers on top.
#
# Why not POSIX sh: `$'\e[0m'` ANSI escape is a bash-ism. All call sites
# already require bash via the self-promote idiom at their top, so this
# is consistent with the rest of the codebase.

# shellcheck shell=bash

# ---------------------------------------------------------------------------
# colors (active only if stdout is a TTY)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    C_RESET=$'\e[0m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
else
    C_RESET= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_BOLD= C_DIM=
fi

# ---------------------------------------------------------------------------
# status helpers (one-line indented messages)
# ---------------------------------------------------------------------------
#
# All helpers take a single string arg and print to stdout (info/ok/warn/
# header) or stderr (err). Indentation matches the previously-duplicated
# implementations in install-mes-firmware.sh / torture.sh / stress-test.sh
# so consumers don't have to retune their downstream sed / grep filters.

info()   { printf '  %s\n' "$1"; }
ok()     { printf '  %s[ OK ]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$1"; }
warn()   { printf '  %s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()    { printf '  %s[FAIL]%s %s\n' "${C_RED}"    "${C_RESET}" "$1" >&2; }

# header - bold blue section divider with `=====` decoration. Visible
# enough to stand out in long stress-test / torture / install logs.
header() {
    printf '\n%s%s===== %s =====%s\n' "${C_BOLD}" "${C_BLUE}" "$1" "${C_RESET}"
}
