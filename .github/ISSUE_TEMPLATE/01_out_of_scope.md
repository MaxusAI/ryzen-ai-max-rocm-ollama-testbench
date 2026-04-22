---
name: Out of scope / wrong hardware
about: Strix Halo gfx1151 only — other GPUs belong elsewhere
title: "[out-of-scope] "
labels: []
---

**This repository targets AMD Strix Halo (`gfx1151`) and the stack versions in the README.**

If your question is about a different GPU, distro, or generic Ollama/ROCm support,
you will get better answers from [ollama/ollama](https://github.com/ollama/ollama)
or AMD ROCm forums.

If you still believe this repo applies, include:

- `rocminfo` marketing name + `Name:` gfx line
- Ubuntu (or distro) version and kernel
- Output of `make mes-check` and `make validate` (first failing layer)
