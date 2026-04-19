# syntax=docker/dockerfile:1.7
# vim: filetype=dockerfile
#
# Multi-stage build for ollama on AMD ROCm 7.2.2, native gfx1151 (Strix Halo).
#
# Stages:
#   base    - rocm/dev-ubuntu-24.04:7.2.2-complete + cmake/ninja
#   cpu     - libggml-cpu.so (CPU backend, all SIMD variants)
#   rocm-7  - libggml-hip.so + rocBLAS pruned to gfx1151 only
#   build   - go 1.24.1 + ollama Go binary
#   runtime - rocm/dev-ubuntu-24.04:7.2.2-complete + ollama + libs
#
# Build context = repo root. All COPY paths therefore start with external/ollama/...

# -----------------------------------------------------------------------------
# Stage: base
# -----------------------------------------------------------------------------
FROM rocm/dev-ubuntu-24.04:7.2.2-complete AS base
ARG CMAKEVERSION=3.31.2
ARG NINJAVERSION=1.12.1

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
        curl \
        git \
        libnuma-dev \
        pkg-config \
        unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --silent --show-error --location \
        "https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-x86_64.tar.gz" \
      | tar --extract --gzip --directory /usr/local --strip-components 1

RUN curl --fail --silent --show-error --location \
        --output /tmp/ninja.zip \
        "https://github.com/ninja-build/ninja/releases/download/v${NINJAVERSION}/ninja-linux.zip" \
    && unzip /tmp/ninja.zip -d /usr/local/bin \
    && rm /tmp/ninja.zip

ENV CMAKE_GENERATOR=Ninja
ENV LDFLAGS=-s
# Make CMake find the HIP cmake package shipped under /opt/rocm in the
# rocm-complete base image. Required by external/ollama/CMakeLists.txt:140
# which calls find_package(hip REQUIRED) once check_language(HIP) succeeds.
# Without this even the CPU preset fails to configure because the HIP compiler
# at /opt/rocm-*/lib/llvm/bin/clang++ is auto-discovered by CMake.
ENV CMAKE_PREFIX_PATH=/opt/rocm
WORKDIR /src

# -----------------------------------------------------------------------------
# Stage: cpu  (CPU backend; GGML_CPU_ALL_VARIANTS=ON ships avx/avx2/avx512 etc.)
# -----------------------------------------------------------------------------
FROM base AS cpu
COPY external/ollama/CMakeLists.txt external/ollama/CMakePresets.json ./
COPY external/ollama/ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'CPU' \
 && cmake --build --preset 'CPU' -- -l "$(nproc)" \
 && cmake --install build --component CPU --strip

# -----------------------------------------------------------------------------
# Stage: rocm-7  (HIP/ROCm backend, gfx1151)
# -----------------------------------------------------------------------------
FROM base AS rocm-7
# /opt/rocm/bin only - the legacy /opt/rocm/hcc/bin path is gone in ROCm 7.x
ENV PATH=/opt/rocm/bin:${PATH}
COPY external/ollama/CMakeLists.txt external/ollama/CMakePresets.json ./
COPY external/ollama/ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'ROCm 7' \
 && cmake --build --preset 'ROCm 7' -- -l "$(nproc)" \
 && cmake --install build --component HIP --strip

# Strix Halo only: delete rocBLAS kernels for OTHER architectures.
#
# IMPORTANT: prune by deleting non-gfx1151 arches, NOT by keeping only
# `*gfx1151*`. rocBLAS ships architecture-agnostic fallback files like
# `TensileLibrary_Type_DD_Contraction_l_Ailk_Bljk_Cijk_Dijk_fallback.dat`
# (no arch suffix) that are read at rocBLAS init - delete them and you get
# `Memory access fault by GPU node-1 ... Reason: Page not present` during
# the first rocBLAS call. See docs/build-fixes.md (Fix 2).
#
# Arch list mirrors the "ROCm 7" preset's AMDGPU_TARGETS in
# external/ollama/CMakePresets.json:85, minus gfx1151.
RUN find dist/lib/ollama/rocm/rocblas/library -type f \
        \( \
            -name '*gfx908*'  -o \
            -name '*gfx90a*'  -o \
            -name '*gfx942*'  -o \
            -name '*gfx950*'  -o \
            -name '*gfx1010*' -o \
            -name '*gfx1012*' -o \
            -name '*gfx1030*' -o \
            -name '*gfx1100*' -o \
            -name '*gfx1101*' -o \
            -name '*gfx1102*' -o \
            -name '*gfx1103*' -o \
            -name '*gfx1150*' -o \
            -name '*gfx1200*' -o \
            -name '*gfx1201*' \
        \) \
        -delete

# -----------------------------------------------------------------------------
# Stage: build  (Go binary; Go version auto-discovered from go.mod)
# -----------------------------------------------------------------------------
FROM base AS build
WORKDIR /go/src/github.com/ollama/ollama
COPY external/ollama/go.mod external/ollama/go.sum ./
# Resolves to go1.24.1 from external/ollama/go.mod line 3; amd64-only.
RUN curl --fail --silent --show-error --location \
        "https://golang.org/dl/go$(awk '/^go/ { print $2 }' go.mod).linux-amd64.tar.gz" \
      | tar --extract --gzip --directory /usr/local
ENV PATH=/usr/local/go/bin:${PATH}
RUN go mod download
COPY external/ollama/ ./
ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/.cache/go-mod \
    go build -trimpath -buildmode=pie -o /out/ollama .

# -----------------------------------------------------------------------------
# Stage: runtime
# -----------------------------------------------------------------------------
FROM rocm/dev-ubuntu-24.04:7.2.2-complete AS runtime

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        libnuma1 \
        numactl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build  /out/ollama                   /usr/bin/ollama
COPY --from=cpu    /src/dist/lib/ollama          /usr/lib/ollama
COPY --from=rocm-7 /src/dist/lib/ollama          /usr/lib/ollama
COPY docker/entrypoint.sh                        /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV LD_LIBRARY_PATH=/usr/lib/ollama:/usr/lib/ollama/rocm:/opt/rocm/lib
ENV OLLAMA_HOST=0.0.0.0:11434
ENV OLLAMA_MODELS=/root/.ollama/models

EXPOSE 11434
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
