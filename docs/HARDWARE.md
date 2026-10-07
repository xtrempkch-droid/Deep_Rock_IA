# HARDWARE — Detalhes do hardware alvo

> **Última atualização:** 2026-10-07

Este documento descreve, em nível técnico, o hardware para o qual o
`ai-cpu-os` foi desenhado. Toda otimização em `docs/TUNING.md` deriva das
características aqui descritas.

---

## Sistema A — Servidor de IA (perfil `xeon`)

### CPU: Intel Xeon E5-2678 v3

| Propriedade             | Valor                                                        |
|-------------------------|--------------------------------------------------------------|
| Microarquitetura        | Haswell-EP (família 6, modelo 63)                            |
| Núcleos / Threads       | 12 / 24 (Hyper-Threading ativo)                              |
| Frequência base / turbo | ~2,5 GHz / ~3,3 GHz                                          |
| L3 cache                | 30 MB (shared)                                               |
| TDP                     | 120 W                                                        |
| **ISA relevante**       | SSE4.2, **AVX2**, FMA3, F16C, AES-NI, BMI1/2, FMA              |
| **NÃO possui**          | ❌ AVX-512 · ❌ AMX · ❌ VNNI                                 |

> **Por que isso importa:** o llama.cpp pode explorar AVX2 (256-bit),
> FMA e F16C nesta CPU. Pedir AVX-512 faria o binário emitir `SIGILL`
> (crash) em tempo de execução.

### Placa-mãe: JGINYUE X99M-D3

- Socket LGA2011-3, chipset X99.
- **Suporta DDR3** (não DDR4) — incomum para X99, mas é a característica
  desta placa.
- 4 slots DIMM.

### Memória: 16 GB DDR3-1333

> ℹ️ **Confirme com `detect-hardware.sh`** (`dmidecode -t memory`). O
> **Haswell-EP tem 4 canais** e esta placa tem 4 slots, todos populados —
> portanto o esperado é **quad channel** (1 pente por canal).

| Propriedade     | Valor                                                    |
|-----------------|----------------------------------------------------------|
| Capacidade      | 16 GB total (4 × 4 GB)                                   |
| Tipo            | DDR3-1333 (PC3-10600)                                    |
| Canais          | **Quad channel** (4 × 4 GB, 1 pente por canal)           |
| Banda teórica   | ≈ 42,7 GB/s (4 canais × 1333 MT/s × 8 B)                 |
| Banda efetiva   | tipicamente ~28–34 GB/s                                   |

> **Impacto em LLM:** em inferência CPU-bound, a banda de memória é o
> gargalo dominante. O limite aqui é a **capacidade** (16 GB → ~7B Q4), e a
> banda de ~30 GB/s define o teto de tokens/s. Confirme os canais no
> Bloco B de [`VALIDATION.md`](VALIDATION.md): se aparecer **dual** em vez de
> quad, a banda cai ~50% e o teto de tokens/s também.

### Armazenamento

- SSD NVMe 256 GB (PCIe 3.0 x4 tipicamente) — ~2–3 GB/s de leitura
  sequencial, essencial para carregar o `.gguf` rapidamente.

### GPU

- **Nenhuma.** Inferência 100% CPU.

---

## Sistema B — Build + Registry + Gitea (perfil `ryzen`)

### CPU: AMD Ryzen 5 3500X

| Propriedade             | Valor                                                        |
|-------------------------|--------------------------------------------------------------|
| Microarquitetura        | Zen 2 (`znver2`)                                             |
| Núcleos / Threads       | 6 / 6 (sem SMT)                                              |
| Frequência base / turbo | 3,6 GHz / 4,1 GHz                                            |
| L3 cache                | 32 MB (2 × 16 MB CCX)                                        |
| TDP                     | 65 W                                                         |
| **ISA relevante**       | SSE4.2, **AVX2**, FMA3, F16C, AES-NI, SHA, BMI1/2             |
| **NÃO possui**          | ❌ AVX-512 · ❌ AMX · ❌ SMT (hyper-threading)                |

> **Por que isso importa:** `-march=znver2` é o alvo ideal. Sem SMT, o
> paralelismo depende de 6 threads físicas — o tuning de `-t` para
> `llama-bench` deve ser `6`.

### Placa-mãe: MSI B550 (AM4)

- 4 slots DIMM DDR4 (varia por modelo exato).
- O controlador de memória **do Ryzen 5 3500X suporta dual channel**;
  entretanto, **este sistema está operando em single channel** por
  limitação de slot/população.

### Memória: 64 GB DDR4 (SINGLE CHANNEL ⚠️)

| Propriedade      | Valor                                                     |
|------------------|-----------------------------------------------------------|
| Capacidade       | 64 GB (4 × 16 GB instalados, mas 1 canal efetivo)         |
| Canais efetivos  | **1 (single channel)** ⚠️                                  |
| Banda teórica SC | ≈ metade da de dual channel (ex.: ~25 GB/s → ~12,8 GB/s)  |

> **⚠️ ALERTA CRÍTICO:** operar em single channel reduz a banda de memória
> em **~50%**. Para inferência em CPU, isso pode significar **quase metade
> dos tokens/s**. `detect-hardware.sh` e o `install.sh` do perfil `ryzen`
> emitem alerta explícito quando isso é detectado.
>
> **Ação recomendada:** revisar os slots — na maioria das placas AM4, a
> configuração dual channel exige que os pentes sejam instalados nos slots
> `A2` e `B2` (2º e 4º, contando do CPU). Consulte o manual da sua MSI B550.

### Armazenamento

- SSD NVMe 256 GB (SO + cache de build Docker).
- HDD 1 TB (dados, volumes Docker/Gitea, imagens de build).

### GPU: AMD RX 580 8 GB

- **Uso permitido:** apenas saída de vídeo (compositor, terminal).
- **Uso PROIBIDO:** computação (OpenCL, ROCm, Vulkan compute). Apresenta
  **artefatos de tela sob carga**, o que indica instabilidade (possível
  VRAM degradada ou driver problemático). Usar para inferência resultaria
  em resultados corrompidos ou travamentos.

---

## Comparativo rápido

| Característica     | Xeon E5-2678 v3        | Ryzen 5 3500X          |
|--------------------|------------------------|------------------------|
| Função             | Inferência             | Build/Registry/Gitea   |
| Núcleos/Threads    | 12c / 24t              | 6c / 6t                |
| AVX-512            | ❌                     | ❌                     |
| AVX2 / FMA / F16C  | ✅                     | ✅                     |
| Canais de memória  | Quad ✅                | Single ⚠️              |
| RAM                | 16 GB DDR3             | 64 GB DDR4             |
| GPU para compute   | n/a                    | ❌ (RX 580 instável)   |

---

## Como verificar seu próprio hardware

```bash
# CPU, núcleos, threads, flags
lscpu
grep -m1 'model name' /proc/cpuinfo
grep -o -m1 -E 'avx2|avx512|amx|fma|f16c' /proc/cpuinfo | sort -u

# Memória e canais (requer root)
sudo dmidecode -t memory | grep -E 'Size|Locator|Speed'

# Discos
lsblk -d -o NAME,SIZE,ROTA,TRAN,MODEL
```

Para um relatório completo e a escolha automática de perfil, use:

```bash
./detect-hardware.sh
```
