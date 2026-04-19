#!/usr/bin/env bash
# scripts/lib/dmesg.sh - dmesg / MES regex helpers shared by validate.sh,
# stress-test.sh, torture.sh, and log-run.sh.
#
# Why a shared library: the MES failure regex appeared verbatim in 4
# different scripts (3 distinct phrasings, 6 grep call sites total).
# A wording drift here is a real risk - we don't want one script to miss
# a class of failure the others catch. Centralizing the regex constants
# makes the truth obvious in one place.
#
# All helpers shell out to `sudo --non-interactive dmesg` and degrade
# gracefully if dmesg is unreadable (no sudo cred, kernel.dmesg_restrict=1
# without CAP_SYS_ADMIN, etc.). Counts return 0 / functions return empty.

# shellcheck shell=bash

# ---------------------------------------------------------------------------
# regex constants (treat as readonly; do not edit per-script)
# ---------------------------------------------------------------------------

# Combined MES failure regex. Match-anywhere semantics in dmesg lines.
# Used by validate.sh Layer 1 and log-run.sh's MES-warning counter.
#
# Two failure shapes are folded together because the kernel emits both
# under the same root cause (drm/amd MES queue exhaustion):
#   - "MES failed to respond" / "amdgpu_mes_reg_write_reg_wait" - timed
#     out waiting for an MES register write. Workload may still complete.
#   - "MES ring buffer is full" - terminal: the GPU stays wedged until
#     reboot. See docs/build-fixes.md Fix 4 'Future-proofing'.
MES_DMESG_REGEX='MES failed to respond|amdgpu_mes_reg_write_reg_wait|MES ring buffer is full'

# Sub-regexes for counting the two failure modes separately. stress-test.sh
# uses these to compute pre/post deltas around a stress run.
MES_TIMEOUT_REGEX='MES failed to respond|amdgpu_mes_reg_write_reg_wait'
MES_RING_FULL_REGEX='MES ring buffer is full'

# Broader "GPU is wedged right now" regex. Any of these means an
# in-flight reset is happening or the MES is dead. Used as a
# pre-flight gate by torture.sh.
GPU_WEDGED_REGEX='MES.*ring.*full|MES failed|MES is hung|amdgpu_amdkfd_pre_reset|GPU reset begin'

# Counter regexes for torture.sh's per-stage telemetry.
MES_EVICTIONS_REGEX='queue evicted'
MES_VM_FAULTS_REGEX='amdgpu.*VM_L2|amdgpu.*page fault'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# _dmesg_read - print the kernel ring buffer with human-readable
# timestamps (best-effort; "" on failure). Centralizes the sudo
# invocation so we can swap to `journalctl --kernel` in one place if
# dmesg becomes unreadable on a future kernel/distro.
#
# We pass --ctime so the one caller that prints matching lines verbatim
# (validate.sh Layer 1) shows wall-clock timestamps. For grep --count
# and grep --quiet callers the prefix is irrelevant, so this is free.
_dmesg_read() {
    if command -v sudo >/dev/null 2>&1; then
        sudo --non-interactive dmesg --ctime 2>/dev/null || true
    fi
}

# mes_grep_recent [tail-n] - print the last N matching dmesg lines for
# any MES failure mode. Default tail = 5 (matches validate.sh Layer 1).
# Empty output if dmesg is unreadable or no matches.
mes_grep_recent() {
    local tail_n="${1:-5}"
    _dmesg_read \
        | grep --extended-regexp "$MES_DMESG_REGEX" \
        | tail -n "$tail_n" \
        || true
}

# mes_count_total - total MES failures of any kind in the current ring
# buffer. Returns "0" on no-match (callers don't have to guard).
# Used by log-run.sh to surface "GPU was unhappy during the run" warnings.
mes_count_total() {
    local n
    n=$(_dmesg_read | grep --count --extended-regexp "$MES_DMESG_REGEX" || true)
    printf '%s' "${n:-0}"
}

# Per-mode counters (return "0" on no-match).
mes_count_timeouts() {
    local n
    n=$(_dmesg_read | grep --count --extended-regexp "$MES_TIMEOUT_REGEX" || true)
    printf '%s' "${n:-0}"
}

mes_count_ring_full() {
    local n
    n=$(_dmesg_read | grep --count --extended-regexp "$MES_RING_FULL_REGEX" || true)
    printf '%s' "${n:-0}"
}

mes_count_evictions() {
    local n
    n=$(_dmesg_read | grep --count --extended-regexp "$MES_EVICTIONS_REGEX" || true)
    printf '%s' "${n:-0}"
}

mes_count_vm_faults() {
    local n
    n=$(_dmesg_read | grep --count --extended-regexp "$MES_VM_FAULTS_REGEX" || true)
    printf '%s' "${n:-0}"
}

# gpu_wedged - returns 0 (true) if the GPU is currently wedged. Looks at
# the last 200 lines so we don't false-positive on stale boot-time errors.
# Used by torture.sh as a pre-flight gate and after each stage.
gpu_wedged() {
    _dmesg_read \
        | tail -n 200 \
        | grep --quiet --extended-regexp "$GPU_WEDGED_REGEX"
}
