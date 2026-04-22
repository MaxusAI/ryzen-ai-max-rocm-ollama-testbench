# Security

## Reporting

Please report sensitive security issues through a **private** channel your
organization uses for this repository (maintainer contact or GitHub private
security advisory), not public issues.

## Supply chain notes

- **`scripts/install-mes-firmware.sh`** runs as **root**, downloads firmware
  blobs over HTTPS, and verifies checksums. Review that script before use on
  production systems.

- **Docker builds** pull base images and toolchain archives from vendor
  registries (AMD ROCm, CMake, Ninja, Go). Use pinned versions in
  [`docker/Dockerfile`](docker/Dockerfile) and verify digests where your policy
  requires it.

- **`external/ollama`** is a git submodule; treat updates like any third-party
  dependency review.

## Container hardening

The default [`docker-compose.yml`](docker-compose.yml) relaxes some isolation
(`seccomp=unconfined`, `SYS_PTRACE`, `ipc: host`) for ROCm debugging. See the
README “Compose / security” note before exposing the stack beyond a trusted LAN.
