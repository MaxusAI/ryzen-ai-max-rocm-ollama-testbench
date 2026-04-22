#!/usr/bin/env bash
# quickstart.sh - one-command bring-up + validate for amd-rocm-ollama.
#
# Default behaviour (no flags):
#   1. Prereq check         (docker, docker compose, render/video groups)
#   2. Submodule init       (idempotent; populates external/ollama if missing)
#   3. .env scaffold        (copy from .env.example if absent; print detected GIDs)
#   4. Image present check  (FAIL FAST if amd-rocm-ollama:7.2.2 not built; --build to opt in)
#   5. docker compose up    (detached) + wait for /api/tags healthcheck
#   6. Auto-pull smoke      (llama3.2:latest, ~2 GiB, ONLY if no models installed; --no-pull to suppress)
#   7. ./scripts/validate.sh --skip-long-ctx (layers 0-7; Layer 8 stays opt-in via make validate-full)
#   8. Footer with next-step hints
#
# Flags:
#   --build         Run `docker compose build` before `up` (~30 min on first run).
#   --no-build      Explicit no-op for clarity in scripts (default).
#   --no-pull       Skip the auto-pull of llama3.2:latest even if no models are installed.
#   --skip-up       Don't start/build the container; validate whatever's already running
#                   (use this to validate a host-installed ollama instead).
#   --help, -h      Show this message.
#
# Exit codes:
#   0   prereqs + bring-up + validate all green
#   1   one or more steps failed (validate output names the failing layer)
#   2   bad invocation / mutually-exclusive flags
#
# Re-exec under bash if invoked via `sh quickstart.sh`.
# shellcheck disable=SC2128
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${COMPOSE:-docker compose}"
SERVICE="${SERVICE:-ollama}"
HOST_PORT="${HOST_PORT:-11434}"
IMAGE_TAG="${IMAGE_TAG:-amd-rocm-ollama:7.2.2}"
SMOKE_PULL_MODEL="${SMOKE_PULL_MODEL:-llama3.2:latest}"

# shellcheck source=scripts/lib/pretty.sh
. "${REPO_ROOT}/scripts/lib/pretty.sh"

DO_BUILD=0
DO_PULL=1
DO_UP=1

usage() {
    sed --quiet '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build)    DO_BUILD=1; shift ;;
        --no-build) DO_BUILD=0; shift ;;
        --no-pull)  DO_PULL=0; shift ;;
        --skip-up)  DO_UP=0; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)
            err "unknown flag: $1"
            echo "Run '$0 --help' for usage." >&2
            exit 2 ;;
    esac
done

if [ "$DO_BUILD" -eq 1 ] && [ "$DO_UP" -eq 0 ]; then
    err "--build and --skip-up are mutually exclusive (build implies bringing the container up)"
    exit 2
fi

# _port_listener <port> - print the LISTEN row(s) for a TCP port, empty if
# nothing is bound. Used to pre-empt the most common quickstart failure: the
# host's bundled ollama.service still binding :11434 and shadowing our
# container at the bind layer (docker emits an unhelpful 'address already
# in use' with no hint that systemctl stop ollama is the fix).
_port_listener() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss --tcp --listening --processes --numeric "sport = :${port}" 2>/dev/null \
            | awk 'NR>1 {print}'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# step 1: prereqs
# ---------------------------------------------------------------------------

header "Quickstart: prereq check"

PREREQ_FAIL=0

if command -v docker >/dev/null 2>&1; then
    ok "docker:         $(docker --version 2>/dev/null | head -1)"
else
    err "docker:         NOT FOUND - install Docker Engine first (https://docs.docker.com/engine/install/)"
    PREREQ_FAIL=1
fi

if docker compose version >/dev/null 2>&1; then
    ok "docker compose: $(docker compose version --short 2>/dev/null)"
else
    err "docker compose: NOT FOUND - install the compose plugin (apt install docker-compose-plugin)"
    PREREQ_FAIL=1
fi

# Capture host GIDs once so we can both verify and seed .env from them.
DETECTED_VIDEO_GID="$(getent group video  2>/dev/null | cut --delimiter=: --fields=3 || true)"
DETECTED_RENDER_GID="$(getent group render 2>/dev/null | cut --delimiter=: --fields=3 || true)"

if [ -n "$DETECTED_VIDEO_GID" ] && [ -n "$DETECTED_RENDER_GID" ]; then
    ok "host groups:    video=${DETECTED_VIDEO_GID}, render=${DETECTED_RENDER_GID}"
else
    err "host groups:    video/render not found in /etc/group - install AMD GPU stack first"
    PREREQ_FAIL=1
fi

if [ ! -e /dev/kfd ]; then
    err "/dev/kfd:       NOT PRESENT - amdkfd driver not loaded; check 'lsmod | grep amdgpu'"
    PREREQ_FAIL=1
else
    ok "/dev/kfd:       present"
fi

if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
    err "/dev/dri:       no renderD* nodes - amdgpu DRI not exposed"
    PREREQ_FAIL=1
else
    ok "/dev/dri:       $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
fi

if [ "$PREREQ_FAIL" -ne 0 ]; then
    err "prerequisite check failed - fix the items marked above and re-run"
    exit 1
fi

# ---------------------------------------------------------------------------
# step 2: submodule
# ---------------------------------------------------------------------------

header "Submodule (external/ollama)"

if [ -f "${REPO_ROOT}/external/ollama/go.mod" ]; then
    ok "external/ollama already populated"
else
    info "running: git submodule update --init --recursive"
    git -C "$REPO_ROOT" submodule update --init --recursive
    ok "submodule initialized"
fi

# ---------------------------------------------------------------------------
# step 3: .env scaffold
# ---------------------------------------------------------------------------

header ".env (per-host overrides)"

if [ -f "${REPO_ROOT}/.env" ]; then
    ok ".env exists - leaving as-is"
else
    if [ -f "${REPO_ROOT}/.env.example" ]; then
        cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
        ok "copied .env.example -> .env"
        # If detected GIDs differ from the .env.example defaults (44/992),
        # patch them in so the container actually matches the host.
        if [ -n "$DETECTED_VIDEO_GID" ] && [ "$DETECTED_VIDEO_GID" != "44" ]; then
            sed --in-place "s|^VIDEO_GID=.*|VIDEO_GID=${DETECTED_VIDEO_GID}|" "${REPO_ROOT}/.env"
            info "patched VIDEO_GID=${DETECTED_VIDEO_GID} (host differs from default 44)"
        fi
        if [ -n "$DETECTED_RENDER_GID" ] && [ "$DETECTED_RENDER_GID" != "992" ]; then
            sed --in-place "s|^RENDER_GID=.*|RENDER_GID=${DETECTED_RENDER_GID}|" "${REPO_ROOT}/.env"
            info "patched RENDER_GID=${DETECTED_RENDER_GID} (host differs from default 992)"
        fi
    else
        info ".env.example missing - skipping .env scaffold (compose defaults will apply)"
    fi
fi

# ---------------------------------------------------------------------------
# step 4: build / image presence
# ---------------------------------------------------------------------------

if [ "$DO_UP" -eq 1 ]; then
    header "Container image"

    if [ "$DO_BUILD" -eq 1 ]; then
        info "running: $COMPOSE build  (~30 min on first run)"
        cd "$REPO_ROOT"
        $COMPOSE build
        ok "build complete"
    else
        if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
            ok "image present: $IMAGE_TAG"
        else
            err "image not found: $IMAGE_TAG"
            err "run with --build to compile it (~30 min), or 'make build' standalone"
            exit 1
        fi
    fi

    # ---------------------------------------------------------------------
    # step 5: bring up + wait for healthcheck
    # ---------------------------------------------------------------------

    header "docker compose up"

    # Pre-flight: bail early if HOST_PORT is already bound. The most common
    # cause is the host's bundled ollama systemd service - the README's
    # PREREQUISITE - still being active.
    listener=$(_port_listener "$HOST_PORT")
    if [ -n "$listener" ]; then
        err "port ${HOST_PORT} on the host is already in use:"
        printf '%s\n' "$listener" | sed 's/^/         /'
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
            err "the host's bundled 'ollama' systemd service is running and binding :${HOST_PORT}"
            info "fix it once:  sudo systemctl stop ollama && sudo systemctl disable ollama"
            info "then re-run:  ./quickstart.sh"
            info "(see README 'Compose / security' note for context)"
        else
            info "free port ${HOST_PORT} or run with a different port: HOST_PORT=11500 ./quickstart.sh"
        fi
        exit 1
    fi

    info "running: $COMPOSE up --detach $SERVICE"
    cd "$REPO_ROOT"
    if ! $COMPOSE up --detach "$SERVICE"; then
        err "$COMPOSE up failed - inspect with: $COMPOSE logs --tail 100 $SERVICE"
        exit 1
    fi

    info "waiting for /api/tags on http://localhost:${HOST_PORT} (up to 90s)"
    deadline=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl --silent --max-time 2 --fail --output /dev/null \
                "http://localhost:${HOST_PORT}/api/tags"; then
            ok "ollama API is responding"
            break
        fi
        sleep 2
    done
    if ! curl --silent --max-time 2 --fail --output /dev/null \
            "http://localhost:${HOST_PORT}/api/tags"; then
        err "ollama API did not respond within 90s"
        info "check logs: $COMPOSE logs --tail 100 $SERVICE"
        exit 1
    fi
else
    header "Bring-up"
    info "skipping build / docker compose up (--skip-up); validating against whatever is already on http://localhost:${HOST_PORT}"
    if ! curl --silent --max-time 2 --fail --output /dev/null \
            "http://localhost:${HOST_PORT}/api/tags"; then
        err "no ollama API on http://localhost:${HOST_PORT} - start your host ollama (or drop --skip-up)"
        exit 1
    fi
    ok "ollama API is responding"
fi

# ---------------------------------------------------------------------------
# step 6: smoke-model auto-pull (only if no models installed)
# ---------------------------------------------------------------------------

header "Smoke model"

INSTALLED_COUNT="$(curl --silent --max-time 5 \
        "http://localhost:${HOST_PORT}/api/tags" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(0); sys.exit(0)
print(len(d.get("models",[])))' 2>/dev/null || echo 0)"

if [ "${INSTALLED_COUNT:-0}" -gt 0 ]; then
    ok "${INSTALLED_COUNT} model(s) already installed - skipping auto-pull"
elif [ "$DO_PULL" -eq 0 ]; then
    info "no models installed and --no-pull set - validate Layer 6/8 will SKIP"
else
    info "no models installed; pulling $SMOKE_PULL_MODEL (~2 GiB) so the smoke test has something to load"
    info "use --no-pull next time to skip this"
    if [ "$DO_UP" -eq 1 ]; then
        $COMPOSE exec -T "$SERVICE" ollama pull "$SMOKE_PULL_MODEL"
    else
        # --skip-up path: hit the API directly, no docker exec
        curl --no-progress-meter --fail --max-time 600 \
            --request POST \
            --header 'content-type: application/json' \
            --data "{\"name\":\"$SMOKE_PULL_MODEL\",\"stream\":false}" \
            "http://localhost:${HOST_PORT}/api/pull"
    fi
    ok "pulled $SMOKE_PULL_MODEL"
fi

# ---------------------------------------------------------------------------
# step 7: validate ladder
# ---------------------------------------------------------------------------

header "Validation ladder (layers 0-7; Layer 8 needs 'make validate-full')"

VALIDATE_RC=0
"${REPO_ROOT}/scripts/validate.sh" --skip-long-ctx || VALIDATE_RC=$?

# ---------------------------------------------------------------------------
# step 8: footer
# ---------------------------------------------------------------------------

header "Quickstart complete"

if [ "$VALIDATE_RC" -eq 0 ]; then
    ok "all selected layers passed"
    cat <<EOF

  Next steps:
    make logs                # tail the ollama server log
    make ps                  # show loaded models
    make validate-full       # add Layer 8 long-context test (~4-25 min)
    make stress-test-quick   # safe ~5-min stress (concurrency=2, ctx=32K)

  Pull a long-context model for the headline test:
    docker compose exec ${SERVICE} ollama pull gemma4:31b-it-q4_K_M

EOF
else
    err "validate.sh exited with code ${VALIDATE_RC} - check the [FAIL] lines above"
    cat <<EOF

  Next steps:
    make mes-check           # rule out the MES 0x83 firmware regression first
    docs/build-fixes.md      # symptom -> root cause map
    docs/validation-tests.md # what each layer expects

EOF
    exit "$VALIDATE_RC"
fi
