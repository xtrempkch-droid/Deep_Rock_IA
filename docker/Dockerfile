# syntax=docker/dockerfile:1
#
# docker/Dockerfile — imagem de runtime do llama.cpp para inferência em CPU
# -----------------------------------------------------------------------------
# Esta imagem é o "artefato compilado" do projeto: o GitHub Actions a constrói
# (e publica no GHCR) para os hardwares alvo. Ela NÃO substitui o tuning de
# kernel (que é do host) — ela empacota o motor de inferência compilado com as
# flags AVX2 corretas.
#
# ⚠️ DECISÃO CRÍTICA DE BUILD (ver docs/CI.md):
#   GGML_NATIVE=OFF é OBRIGATÓRIO dentro do Docker.
#   Se usássemos GGML_NATIVE=ON, o CMake detectaria a CPU da MÁQUINA DE BUILD
#   (o runner do CI, possivelmente Zen 4/5 com AVX-512!) e geraria um binário
#   que sofre SIGILL no Xeon E5-2678 v3 ou no Ryzen 5 3500X, que só têm AVX2.
#   Por isso habilitamos AVX2/FMA/F16C EXPLICITAMENTE e nunca AVX-512.
#
# Build (variante portátil AVX2, funciona nos dois alvos):
#   docker build -f docker/Dockerfile -t ai-cpu-os-llama .
#
# Build (variante otimizada para Zen 2):
#   docker build -f docker/Dockerfile -t ai-cpu-os-llama:znver2 \
#     --build-arg CMAKE_C_FLAGS="-march=znver2 -mtune=znver2" \
#     --build-arg CMAKE_CXX_FLAGS="-march=znver2 -mtune=znver2" .
#
# Uso:
#   docker run --rm -p 127.0.0.1:8080:8080 -v /opt/models:/models:ro \
#     ai-cpu-os-llama -m /models/modelo.gguf --threads 24
# -----------------------------------------------------------------------------

# =============================================================================
# Estágio 1 — builder
# =============================================================================
FROM debian:12 AS builder

ARG LLAMA_REF=master
ARG GGML_NATIVE=OFF
ARG CMAKE_C_FLAGS=""
ARG CMAKE_CXX_FLAGS=""
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# pkg-config é OBRIGATÓRIO: o backend BLAS do ggml faz
# find_package(PkgConfig) para localizar o OpenBLAS. Sem ele, o CMake falha com
# "Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)" — este bug foi
# descoberto pelo workflow `container` (ver docs/CI.md § 8).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      cmake \
      build-essential \
      pkg-config \
      libopenblas-dev \
 && rm -rf /var/lib/apt/lists/*

# Fonte fixa (depth=1) para builds reprodutíveis e rápidos.
RUN git clone --depth 1 --branch "${LLAMA_REF}" \
      https://github.com/ggml-org/llama.cpp.git /src

WORKDIR /src

# Flags alinhadas com profiles/*/llama-build.sh.
# - TARGETARCH é declarado apenas para documentar que a imagem é independente
#   de arquitetura (x86-64); não é usado em condicionais aqui.
#
# ⚠️ CMAKE_INSTALL_RPATH / `cmake --install` — NÃO REMOVER (ver docs/CI.md § 8.2):
#   o llama.cpp compila bibliotecas COMPARTILHADAS (BUILD_SHARED_LIBS=ON) e os
#   binários da árvore de build ficam com RPATH ABSOLUTO `/src/build/bin`.
#   Copiar `build/bin` para outro diretório quebra o loader (`exit 127`:
#   "error while loading shared libraries"). Por isso instalamos via CMake com
#   RPATH apontando para /usr/local/lib.
ENV CG_INSTALL_RPATH="/usr/local/lib"
RUN cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_NATIVE="${GGML_NATIVE}" \
      -DGGML_AVX2=ON \
      -DGGML_FMA=ON \
      -DGGML_F16C=ON \
      -DGGML_BLAS=ON \
      -DGGML_BLAS_VENDOR=OpenBLAS \
      -DLLAMA_CURL=OFF \
      -DCMAKE_C_FLAGS="${CMAKE_C_FLAGS}" \
      -DCMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS}" \
      -DCMAKE_INSTALL_RPATH="${CG_INSTALL_RPATH}" \
 && cmake --build build --config Release -j "$(nproc)" \
 && cmake --install build --prefix /usr/local

# Sanidade 1: os binários da árvore de build existem e EXECUTAM
# (pega SIGILL cedo — flag de ISA indevida para o alvo).
RUN set -eux; \
    for b in llama-server llama-cli llama-bench; do \
      test -x "/src/build/bin/${b}"; \
    done; \
    /src/build/bin/llama-bench --help > /dev/null

# Sanidade 2: os binários INSTALADOS também executam fora da árvore de build.
# (pega exatamente o bug de RPATH descrito acima, ainda no build da imagem.)
RUN set -eux; \
    /usr/local/bin/llama-bench --help > /dev/null; \
    ! ldd /usr/local/bin/llama-bench | grep -q 'not found'; \
    ls -la /usr/local/lib/ | head -20

# =============================================================================
# Estágio 2 — runtime (mínimo)
# =============================================================================
FROM debian:12-slim AS runtime

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# libopenblas0 + libgomp1 = únicas dependências dinâmicas dos binários.
# curl é usado apenas pelo HEALTHCHECK.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libopenblas0 \
      libgomp1 \
      curl \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /var/lib/llama \
      --create-home --shell /usr/sbin/nologin llama \
 && install -d -o llama -g llama -m 0750 /models

# Copiamos os artefatos INSTALADOS (bin + lib) e rodamos ldconfig.
# NÃO usar `COPY build/bin` diretamente: os binários carregam RPATH absoluto da
# árvore de build e não achariam libllama.so/libggml*.so (ver docs/CI.md § 8.2).
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/ /usr/local/lib/
RUN ldconfig

# Auto-verificação do ENV: se os binários não executarem aqui, o build da
# imagem FALHA — em vez de só falhar depois, no passo de smoke do CI.
RUN set -eux; \
    llama-bench --help > /dev/null; \
    llama-server --help > /dev/null; \
    ! ldd /usr/local/bin/llama-bench | grep -q 'not found'

# Roda sem privilégios (sandbox básico, alinhado ao ai-server.service).
USER llama
WORKDIR /models

EXPOSE 8080
VOLUME ["/models"]

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["llama-server"]
# Override com: docker run ... ai-cpu-os-llama -m /models/outro.gguf --threads 6
CMD ["--host", "0.0.0.0", "--port", "8080", \
     "--ctx-size", "4096", "--n-gpu-layers", "0", "--no-mmap", \
     "-m", "/models/model.gguf"]
