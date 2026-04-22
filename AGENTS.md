# Agent guidance for amd-rocm-ollama

This repo is a **narrow-target** Docker stack: Ollama v0.21.0 + ROCm 7.2.2 +
gfx1151 (Strix Halo). "Helpful" generalizations have repeatedly broken it.
Stay inside the rails below.

## Hard rules

- **Do not** add Vulkan, CUDA, NVIDIA, multi-arch, or
  `HSA_OVERRIDE_GFX_VERSION` paths. gfx1151 is native; alternatives are
  out of scope.
- **Do not** modify files under `external/ollama/`. It is a pinned
  submodule (Ollama v0.21.0). Upstream changes go through a submodule
  bump in a separate PR, not in-place edits.
- **Do not** flip the rocBLAS prune in `docker/Dockerfile` from
  "delete other arches" back to "keep only `*gfx1151*`". The latter
  pattern deletes 54 arch-agnostic fallback `.dat` files and causes a
  page fault at first kernel call (see `docs/build-fixes.md` Fix 2).
- **Do not** drop or weaken layers in `scripts/validate.sh`. Treat
  `make validate` (and `make validate-full` for the long-context layer)
  as the working contract.
- **Do not** silently change Ollama, ROCm, or image-tag versions. They
  appear in README, `docker-compose.yml`, `docker/Dockerfile`, and
  `docs/`; bump them together.

## Soft rules

- Prefer editing existing files over creating new ones.
- When changing behaviour, update the matching prose in `docs/`
  (`validation-tests.md`, `build-fixes.md`, `break-modes.md`,
  `rocblas-prune.md`).
- Keep MES firmware logic in `scripts/install-mes-firmware.sh`
  idempotent and root-required; do not add silent network fetches
  outside the documented commit-pinned download.
- Avoid hard-coded line-number references into `external/ollama/`;
  link the file or symbol instead (lines drift on submodule bumps).

## When you are stuck

- Run `make mes-check` before debugging anything that looks like
  GPU init failure.
- Run `./scripts/validate.sh --layer N` to isolate which ladder layer
  fails.
- Read `docs/build-fixes.md` before proposing a "fix" for any
  page-fault, Vulkan-fallback, or CPU-fallback symptom; the answer is
  almost always already there.
