#!/usr/bin/env bash
# Container entrypoint for amd-rocm-ollama.
#
# Prints a one-shot ROCm/GPU discovery summary on startup so `docker compose
# logs ollama` shows whether the GPU was detected, then execs `ollama "$@"`.
#
# OLLAMA_DEBUG defaults to 2 in docker-compose.yml so ollama's per-device
# discovery output (rocm/HSA logs) is visible. Override at compose-up time
# (e.g. `OLLAMA_DEBUG=0 docker compose up`) to silence that once healthy.

set -euo pipefail

log() {
    printf '[entrypoint] %s\n' "$*" >&2
}

log "amd-rocm-ollama starting"
log "ollama version: $(ollama --version 2>&1 | head -n1 || true)"
log "ROCm path: ${ROCM_PATH:-/opt/rocm}"

if command -v rocminfo >/dev/null 2>&1; then
    log "rocminfo agents:"
    rocminfo 2>/dev/null \
        | grep --extended-regexp 'Marketing Name|Name:[[:space:]]+gfx|Compute Unit|Wavefront Size' \
        | sed 's/^/[entrypoint]   /' >&2 || log "rocminfo produced no output"
else
    log "rocminfo not found in PATH; skipping GPU summary"
fi

if command -v rocm-smi >/dev/null 2>&1; then
    log "rocm-smi (showid):"
    rocm-smi --showid 2>/dev/null | sed 's/^/[entrypoint]   /' >&2 || true
fi

log "/dev/kfd exists: $([ -e /dev/kfd ] && echo yes || echo no)"
log "/dev/dri contents:"
ls -l /dev/dri 2>/dev/null | sed 's/^/[entrypoint]   /' >&2 || log "/dev/dri not present"

log "OLLAMA_HOST=${OLLAMA_HOST:-unset}"
log "OLLAMA_MODELS=${OLLAMA_MODELS:-unset}"
log "OLLAMA_DEBUG=${OLLAMA_DEBUG:-unset}"
log "OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION:-unset}"
log "OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE:-unset}"
log "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH:-unset (server picks)}"

log "exec: ollama $*"
exec ollama "$@"
