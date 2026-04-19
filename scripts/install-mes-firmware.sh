#!/usr/bin/env bash
# scripts/install-mes-firmware.sh - install a known-good MES firmware
# blob for AMD Strix Halo (gfx1151), bypassing whatever recent regression
# the distro's linux-firmware package ships.
#
# === Why this script exists ===
#
# The MES (Micro Engine Scheduler) firmware on RDNA3+ AMD GPUs is
# fragile. Multiple regressions across multiple firmware revisions, on
# multiple kernels, all cause some flavour of "compute doesn't work":
#
# Known firmware revisions seen in the wild on gfx1151 (run --list-known
# to print this table from a live shell):
#
#   0x74  community-tested OK on older kernels (Framework user, kernel 6.13)
#   0x80  default for this script. Last known-good Ubuntu shipped before 0x83
#         regression. Verified on this repo's box, kernel 6.14.0-1018-oem.
#   0x83  BROKEN on Ubuntu Noble linux-firmware
#         20240318.git3b128b60-0ubuntu2.x. Every compute kernel page-faults:
#           amdgpu: [gfxhub] page fault ... CPF (0x4)
#                                          WALKER_ERROR=1 MAPPING_ERROR=1
#         Container side: 'Memory access fault by GPU node-1' then Ollama
#         falls back to library=cpu / total_vram="0 B".
#
# Tracking issues for the 0x83 regression specifically:
#   - https://github.com/ROCm/ROCm/issues/5724
#   - https://github.com/ROCm/ROCm/issues/6118
#   - https://github.com/ROCm/ROCm/issues/6146
#   - https://bugs.launchpad.net/bugs/2129150
#
# === Important: this fixes one MES regression, not all of them ===
#
# There are SEPARATE, kernel-side MES bugs (not firmware) that surface
# as messages in dmesg even after this firmware override is in place.
# Two related modes:
#   Mode A: "MES failed to respond to msg=MISC (WAIT_REG_MEM)"
#     Bisected to upstream commit e356d321d024 ("drm/amdgpu: cleanup
#     MES11 command submission"), mainline since 6.10:
#       - https://www.spinics.net/lists/amd-gfx/msg110461.html (bisect)
#       - https://www.spinics.net/lists/amd-gfx/msg110519.html (Deucher follow-up)
#     Patch series in flight (March 2026, sets SEM_WAIT_FAIL_TIMER_CNTL):
#       - https://lists.freedesktop.org/archives/amd-gfx/2026-March/141006.html
#       - https://lists.freedesktop.org/archives/amd-gfx/2026-March/141012.html
#   Mode B: "MES ring buffer is full" (escalated; GPU wedged until reboot)
#     Reported on Linux 6.18 + linux-firmware 20260110 against
#     gc_11_5_0 (Phoenix). Same MES subsystem, different GC variant -
#     so this is NOT chip-specific to gfx1151; Strix Halo will hit it
#     under the same upstream conditions:
#       - https://gitlab.freedesktop.org/drm/amd/-/work_items/4749
# Same fragile subsystem, different fault modes. validate.sh Layer 1
# scans dmesg for all three. See docs/build-fixes.md Fix 4
# "Future-proofing" for the full picture and what to do when the next
# regression lands.
#
# === What this script does ===
#
# Downloads the pre-regression gc_11_5_1_* blobs from upstream
# kernel-firmware git (commit e2c1b15108..., 2025-07-16, ships MES 0x80),
# compresses them to zstd, installs them as overrides in
# /lib/firmware/updates/amdgpu/. That directory has precedence over
# /lib/firmware/amdgpu/ and survives linux-firmware package upgrades.
# Then rebuilds the running kernel's initramfs so the overrides are
# loaded at very early boot.
#
# Idempotent: re-running with the same commit is a no-op (skips download
# if md5s match).
#
# Usage:
#   sudo ./scripts/install-mes-firmware.sh                    # install + initramfs
#   sudo ./scripts/install-mes-firmware.sh --check            # only verify state
#   sudo ./scripts/install-mes-firmware.sh --no-initramfs     # install but skip update-initramfs
#   sudo ./scripts/install-mes-firmware.sh --uninstall        # remove the overrides
#   sudo ./scripts/install-mes-firmware.sh --commit <SHA>     # use a different upstream commit
#        ./scripts/install-mes-firmware.sh --list-known       # print known firmware revisions
#        ./scripts/install-mes-firmware.sh --help             # show this help
#
# To install a different MES revision (e.g. if a future linux-firmware
# update breaks the 0x80 we currently pin), browse upstream for an older
# commit that touched gc_11_5_1_mes_2.bin and pass its SHA via --commit:
#   https://gitlab.com/kernel-firmware/linux-firmware/-/commits/main/amdgpu
# The KNOWN_MD5 table at the top of this script must be regenerated for
# any new commit (md5sum the downloaded .bin.zst files and update the
# table) - the script will refuse to install with mismatched md5s as a
# safeguard against truncated downloads.
#
# Exit codes:
#   0   installed (or --check passed)
#   1   error
#   2   bad invocation
#   3   --check found a problem (e.g. MES still 0x83)

# Re-exec under bash if invoked via 'sh script.sh' or 'sudo sh script.sh'.
# Everything above this line is comments, so still POSIX-safe under dash;
# everything below uses bash-specific syntax (set -o pipefail, [[ ]],
# arrays, ${VAR:-default} substitution, etc.).
# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

# Pre-regression commit in upstream kernel-firmware. 2025-07-16; ships MES
# firmware version 0x80 (the last known-good blob before the 0x83 update).
DEFAULT_COMMIT="e2c1b151087b2983249e106868877bd19761b976"
COMMIT="${MES_FW_COMMIT:-$DEFAULT_COMMIT}"
UPSTREAM_BASE="https://gitlab.com/kernel-firmware/linux-firmware/-/raw"
DEST_DIR="/lib/firmware/updates/amdgpu"
DRI_INDEX="${DRI_INDEX:-1}"

# Files to override. The MES blobs are the critical ones (mes_2 + mes1 for
# the scheduler, kiq for the kernel interface queue), but we install the
# whole gc_11_5_1_* set from the same commit to avoid kernel-firmware-
# mismatch warnings on driver init.
FW_FILES=(
    gc_11_5_1_imu.bin
    gc_11_5_1_me.bin
    gc_11_5_1_mec.bin
    gc_11_5_1_mes1.bin
    gc_11_5_1_mes_2.bin
    gc_11_5_1_pfp.bin
    gc_11_5_1_rlc.bin
)

# Known-good md5s for the e2c1b151... commit. Used to detect manual edits
# or partial downloads. Recompute after changing COMMIT.
declare -A KNOWN_MD5=(
    [gc_11_5_1_imu.bin.zst]=5d58ffc3b54f32e4460c080653c26980
    [gc_11_5_1_me.bin.zst]=b1cdd6ae0170a850ebb82a315fbbc734
    [gc_11_5_1_mec.bin.zst]=486fcb8422768a84be9f9f018f7cd2ff
    [gc_11_5_1_mes1.bin.zst]=c549609af7120b5a95795d1d27f87012
    [gc_11_5_1_mes_2.bin.zst]=01c2a51ea8c226a341dfab50fc41a194
    [gc_11_5_1_pfp.bin.zst]=96649c89a2b4b92dc9d817d95a7d03e7
    [gc_11_5_1_rlc.bin.zst]=9153a62dda9f66e627cb443e3008da70
)

DO_INITRAMFS=1
DO_INSTALL=1
DO_UNINSTALL=0
DO_CHECK=0
DO_LIST_KNOWN=0

# ---------------------------------------------------------------------------
# pretty-printing
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
else
    C_RESET= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_BOLD= C_DIM=
fi

info()  { printf '  %s\n' "$1"; }
ok()    { printf '  %s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn()  { printf '  %s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()   { printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; }
header(){ printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        err "This action requires root. Re-run with: sudo $0 $*"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --check)         DO_CHECK=1; DO_INSTALL=0; DO_INITRAMFS=0; shift ;;
        --no-initramfs)  DO_INITRAMFS=0; shift ;;
        --uninstall)     DO_UNINSTALL=1; DO_INSTALL=0; shift ;;
        --commit)        COMMIT="$2"; shift 2 ;;
        --commit=*)      COMMIT="${1#*=}"; shift ;;
        --list-known)    DO_LIST_KNOWN=1; DO_INSTALL=0; DO_INITRAMFS=0; shift ;;
        -h|--help)       usage 0 ;;
        *)               err "unknown arg: $1"; usage 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# state inspection helpers
# ---------------------------------------------------------------------------

current_mes_version() {
    local fw_path="/sys/kernel/debug/dri/${DRI_INDEX}/amdgpu_firmware_info"
    if [ ! -r "$fw_path" ]; then
        if [ "$EUID" -ne 0 ]; then
            sudo --non-interactive cat "$fw_path" 2>/dev/null || return 1
        else
            cat "$fw_path"
        fi
    else
        cat "$fw_path"
    fi | grep '^MES feature' \
        | grep --extended-regexp --only-matching '0x[0-9a-fA-F]+' \
        | tail -n 1
}

show_state() {
    header "Current state"
    info "kernel:         $(uname -r)"
    if dpkg --status linux-firmware >/dev/null 2>&1; then
        info "linux-firmware: $(dpkg --status linux-firmware | grep '^Version' | awk '{print $2}')"
    fi
    info "override dir:   $DEST_DIR"
    if [ -d "$DEST_DIR" ]; then
        local n
        n=$(ls "$DEST_DIR"/gc_11_5_1_*.bin.zst 2>/dev/null | wc -l)
        info "  files installed: $n / ${#FW_FILES[@]}"
        [ "$n" -gt 0 ] && ls "$DEST_DIR"/gc_11_5_1_*.bin.zst 2>/dev/null | sed 's|^|    |'
    else
        info "  override directory does not exist"
    fi
    local mes
    mes=$(current_mes_version 2>/dev/null || echo "?")
    case "$mes" in
        0x00000083|0x83)
            err "MES firmware running: $mes (the BROKEN 0x83 regression)" ;;
        0x*)
            local mes_dec=$((mes))
            if [ "$mes_dec" -lt $((0x83)) ]; then
                ok "MES firmware running: $mes (< 0x83, safe)"
            else
                warn "MES firmware running: $mes (>= 0x83, suspect)"
            fi ;;
        *)
            warn "MES firmware running: unknown (could not read /sys/kernel/debug/dri/${DRI_INDEX}/amdgpu_firmware_info)" ;;
    esac
    if [ -r "/boot/initrd.img-$(uname -r)" ] && command -v lsinitramfs >/dev/null 2>&1; then
        # Ubuntu's update-initramfs flattens /lib/firmware/updates/ into
        # the main /lib/firmware/ tree inside the initramfs, so the path
        # inside the initramfs is usr/lib/firmware/amdgpu/, not .../updates/...
        local in_initramfs
        in_initramfs=$(lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null \
            | grep --extended-regexp 'gc_11_5_1_mes_2\.bin(\.zst)?$' || true)
        if [ -n "$in_initramfs" ]; then
            ok "override is embedded in current initramfs ($in_initramfs)"
        else
            warn "override is NOT in current initramfs (run 'sudo update-initramfs -u -k \$(uname -r)')"
        fi
    fi
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

action_uninstall() {
    require_root "$@"
    header "Uninstalling MES firmware overrides"
    local removed=0
    for f in "${FW_FILES[@]}"; do
        if [ -e "${DEST_DIR}/${f}.zst" ]; then
            rm --force --verbose "${DEST_DIR}/${f}.zst"
            removed=$((removed+1))
        fi
    done
    info "removed $removed file(s)"
    if [ "$DO_INITRAMFS" -eq 1 ]; then
        info "rebuilding initramfs for kernel $(uname -r)..."
        update-initramfs -u -k "$(uname -r)"
    fi
    info "Reboot to load Ubuntu's stock blobs again (will re-introduce the 0x83 bug)."
}

action_install() {
    require_root "$@"
    header "Installing MES firmware override (commit ${COMMIT:0:12}...)"

    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required"; exit 1
    fi
    if ! command -v zstd >/dev/null 2>&1; then
        err "zstd is required ('apt install zstd')"; exit 1
    fi
    if ! command -v update-initramfs >/dev/null 2>&1 && [ "$DO_INITRAMFS" -eq 1 ]; then
        err "update-initramfs is required (Ubuntu/Debian) - re-run with --no-initramfs to skip"; exit 1
    fi

    install --owner=root --group=root --mode=0755 --directory "$DEST_DIR"

    local TMP
    TMP=$(mktemp --directory)
    trap 'rm --recursive --force "$TMP"' EXIT

    info "downloading firmware blobs to $TMP..."
    cd "$TMP"
    for f in "${FW_FILES[@]}"; do
        local url="${UPSTREAM_BASE}/${COMMIT}/amdgpu/${f}"
        printf '    %-30s %s\n' "$f" "$url"
        if ! curl --silent --show-error --fail --location \
                --output "$f" \
                "$url"; then
            err "download failed: $f"
            exit 1
        fi
    done

    info "compressing to .zst..."
    zstd --quiet --keep "${FW_FILES[@]/%/}"

    info "verifying md5 checksums against known-good values for commit $COMMIT..."
    local mismatch=0
    for f in "${FW_FILES[@]}"; do
        local zst="${f}.zst"
        local actual expected
        actual=$(md5sum "$zst" | awk '{ print $1 }')
        expected="${KNOWN_MD5[$zst]:-}"
        if [ -z "$expected" ]; then
            warn "no known-good md5 for $zst (different commit?); skipping verify"
            continue
        fi
        if [ "$actual" = "$expected" ]; then
            ok "md5 ok: $zst"
        else
            err "md5 mismatch: $zst"
            err "  expected: $expected"
            err "  actual:   $actual"
            mismatch=1
        fi
    done
    if [ "$mismatch" -eq 1 ]; then
        err "Refusing to install; got unexpected blob contents."
        err "If you intentionally changed --commit, re-compute KNOWN_MD5 in this script."
        exit 1
    fi

    info "installing into $DEST_DIR..."
    install --owner=root --group=root --mode=0644 \
        --target-directory="$DEST_DIR" \
        gc_11_5_1_*.bin.zst

    cd /
    rm --recursive --force "$TMP"
    trap - EXIT

    if [ "$DO_INITRAMFS" -eq 1 ]; then
        local kver
        kver=$(uname -r)
        info "rebuilding initramfs for kernel $kver..."
        update-initramfs -u -k "$kver"
        # Ubuntu flattens /lib/firmware/updates/ into the main amdgpu/
        # path inside the initramfs - both layouts are loaded at boot.
        if lsinitramfs "/boot/initrd.img-${kver}" 2>/dev/null \
                | grep --extended-regexp --quiet 'gc_11_5_1_mes_2\.bin(\.zst)?$'; then
            ok "override embedded in /boot/initrd.img-${kver}"
        else
            err "override NOT embedded in initramfs - check 'lsinitramfs /boot/initrd.img-${kver} | grep gc_11_5_1'"
            exit 1
        fi
    else
        warn "--no-initramfs: you must rebuild manually before reboot:"
        warn "    sudo update-initramfs -u -k \$(uname -r)"
    fi

    header "Next steps"
    info "1. sudo reboot"
    info "2. After reboot, verify:"
    info "     sudo cat /sys/kernel/debug/dri/${DRI_INDEX}/amdgpu_firmware_info | grep '^MES feature'"
    info "     # expect: MES feature version: 1, firmware version: 0x000000XX  (XX < 0x83)"
    info "3. ./scripts/validate.sh --layer 1   # automated re-check"
}

action_check() {
    show_state
    local mes
    mes=$(current_mes_version 2>/dev/null || echo "?")
    case "$mes" in
        0x00000083|0x83)
            err "FAIL: running MES firmware is $mes - apply the fix:"
            err "    sudo $0"
            exit 3 ;;
        0x*)
            local mes_dec=$((mes))
            if [ "$mes_dec" -lt $((0x83)) ]; then
                ok "PASS: running MES firmware is $mes (< 0x83)"
                exit 0
            fi
            err "FAIL: running MES firmware is $mes (>= 0x83) - install the override"
            exit 3 ;;
        *)
            err "FAIL: could not determine MES firmware version"
            exit 3 ;;
    esac
}

action_list_known() {
    header "Known MES firmware revisions for gfx1151 (Strix Halo)"
    cat <<'TABLE'

    MES ver  Status                Source / commit / notes
    -------  --------------------  ----------------------------------------------
    0x74     OK on older kernels   Reported by Framework community on
                                   amd-ai-300; see "Related discussions" below
    0x80     OK (this script's     kernel-firmware commit
             default - pinned)     e2c1b151087b2983249e106868877bd19761b976
                                   (2025-07-16). Verified on this repo's box.
    0x83     BROKEN on Ubuntu      Ships in Ubuntu Noble linux-firmware
             Noble                 20240318.git3b128b60-0ubuntu2.x.
                                   Compute kernels page-fault immediately.
                                   ROCm/ROCm#5724, ROCm#6118, ROCm#6146,
                                   launchpad bug 2129150.

  IMPORTANT: this firmware override fixes ONE class of MES failure (the
  gfxhub page-fault from 0x83). There are separate, kernel-side MES
  bugs that surface even with 0x80/0x74 in place:
    Mode A: 'MES failed to respond to msg=MISC (WAIT_REG_MEM)'
            -> bisected to upstream commit e356d321d024 (mainline >= 6.10);
               fix series in flight (Deucher, March 2026,
               SEM_WAIT_FAIL_TIMER_CNTL).
    Mode B: 'MES ring buffer is full' (GPU wedged until reboot)
            -> reported on Linux 6.18 + linux-firmware 20260110;
               occurs on gc_11_5_0 too, so NOT gfx1151-specific.
  scripts/validate.sh Layer 1 scans dmesg for both modes. See
  docs/build-fixes.md Fix 4 "Future-proofing" for the playbook.

  Related discussions:
    https://github.com/ROCm/ROCm/issues/5724
    https://github.com/ROCm/ROCm/issues/6118
    https://github.com/ROCm/ROCm/issues/6146
    https://bugs.launchpad.net/bugs/2129150
    https://www.spinics.net/lists/amd-gfx/msg110461.html  (Mode A bisect)
    https://lists.freedesktop.org/archives/amd-gfx/2026-March/141006.html
    https://gitlab.freedesktop.org/drm/amd/-/work_items/4749  (Mode B)
    https://community.frame.work/t/amd-gpu-mes-timeouts-causing-system-hangs-on-framework-laptop-13-amd-ai-300-series/71364

  Browse upstream firmware history (look for commits touching
  amdgpu/gc_11_5_1_mes_2.bin) to pick a different commit:
    https://gitlab.com/kernel-firmware/linux-firmware/-/commits/main/amdgpu

  To pin a different revision than 0x80, regenerate the KNOWN_MD5 table
  at the top of this script and run:
    sudo ./scripts/install-mes-firmware.sh --commit <SHA>

TABLE
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

if [ "$DO_LIST_KNOWN" -eq 1 ]; then
    action_list_known
elif [ "$DO_CHECK" -eq 1 ]; then
    action_check
elif [ "$DO_UNINSTALL" -eq 1 ]; then
    action_uninstall
    show_state
elif [ "$DO_INSTALL" -eq 1 ]; then
    action_install
    show_state
fi
