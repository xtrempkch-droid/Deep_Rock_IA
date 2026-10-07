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
 && cmake --build build --config Release -j "$(nproc)"

# Sanidade: o binário precisa EXECUTAR nesta CPU (pega SIGILL cedo).
RUN set -eux; \
    for b in llama-server llama-cli llama-bench; do \
      test -x "/src/build/bin/${b}"; \
    done; \
    /src/build/bin/llama-bench --help > /dev/null

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

# Copiamos o diretório inteiro de binários: além dos executáveis, ele pode
# conter bibliotecas compartilhadas (libllama.so/ggml) dependendo da versão.
COPY --from=builder /src/build/bin/ /usr/local/bin/

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
