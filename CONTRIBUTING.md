# Contributing

- **Scope:** Issues and PRs should match the hardware and stack in the root
  [README.md](README.md) (Strix Halo `gfx1151`, pinned Ollama/ROCm versions).
  Other AMD GPUs are out of scope for this repository.

- **Submodule:** Run `make submodules` or clone with `--recursive` before
  building. Bump `external/ollama` only with a clear reason and updated docs.

- **License:** By contributing, you agree your contributions are licensed under
  the same terms as the repository overlay (MIT; see README “License and
  upstream”). The `external/ollama` submodule keeps its own license.
