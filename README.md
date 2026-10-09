# ai-cpu-os

> Um sistema operacional Linux minimalista, otimizado cirurgicamente para
> inferência de LLMs **100% em CPU** — sem GPU, sem desperdício.

![status](https://img.shields.io/badge/status-alpha-orange)
![version](https://img.shields.io/badge/version-0.2.0-blue)
![license](https://img.shields.io/badge/license-MIT-blue)
![shell](https://img.shields.io/badge/shell-bash%205.x-green)

[![validate](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/validate.yml/badge.svg)](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/validate.yml)
[![build-llama](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/build-llama.yml/badge.svg)](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/build-llama.yml)
[![container](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/container.yml/badge.svg)](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/container.yml)

---

## 🧠 Filosofia — "1% importa"

Este projeto parte de uma premissa simples e implacável:

> **Cada 1% de performance importa. Acumulados, 100 otimizações de 1% viram
> 2,7x.**

Quando você roda LLMs em CPU, não existe margem para desperdício. Não há
"sobra de GPU" para compensar. Cada ciclo de CPU gasto em um page fault, cada
troca de contexto desnecessária, cada núcleo rodando a 1,2 GHz quando poderia
rodar a 3,3 GHz — **tudo se acumula diretamente no tempo até o primeiro
token**.

O `ai-cpu-os` não é um "truque de benchmark". É uma metodologia: transformar um
Debian/Ubuntu minimal em um sistema afinado, reprodutível e auditável para
inferência em CPU, com foco obsessivo em:

1. **Banda de memória** (o gargalo real de LLM em CPU — não FLOPs).
2. **Latência de memória** (cache, huge pages, NUMA).
3. **Escalonamento** (governor `performance`, C-states rasos).
4. **Determinismo** (idempotência, sem surpresas entre execuções).

---

## 🖥️ Hardware suportado

O projeto foi desenhado em torno de **dois sistemas reais** e possui um perfil
dedicado para cada um.

| Perfil  | CPU                      | Núcleos/Threads | ISA                | Memória            | Armazenamento | Função principal                        |
|---------|--------------------------|-----------------|--------------------|--------------------|---------------|-----------------------------------------|
| `xeon`  | Intel Xeon E5-2680 v4    | 14c / 28t       | Broadwell-EP, AVX2 | 16 GB DDR3-1333 QC | NVMe 256 GB   | Servidor de inferência (llama.cpp)      |  # tem que corrigir todo o projeco devido a atualizaçao depois da atualizaçao por favor apagar esse comentario
| `ryzen` | AMD Ryzen 5 3500X        | 6c / 6t         | Zen 2, AVX2        | 64 GB DDR4 SC ⚠️   | NVMe + HDD 1T | Build (Docker), registry privado, Gitea |  #deixar todo o sistema de uma forma que todos os Ryzen se beneficie e depois da mudança apagar esse comentario

> ⚠️ **Nenhuma das duas CPUs possui AVX-512 ou AMX.** Qualquer guia que    # deixar em aberto a opçao para que outras maquias possao usar ( ate mesmo as que tem avx-512) e depois apagar o comentario
> sugira habilitar `-mavx512` para este hardware está errado. O script
> **verifica as flags em `/proc/cpuinfo`** antes de aplicar qualquer `-march`.

### Placas-mãe de referência

- **Xeon:** JGINYUE X99M-D3 (LGA2011-3, DDR3, quad-channel).
- **Ryzen:** MSI B550 (AM4, DDR4)
---

## 📋 Pré-requisitos

- **Debian 12+ (Bookworm)** ou **Ubuntu 22.04+ (Jammy)** — instalação mínima.  # a ideia e ter uma imagem do ubuntu server-MOD com essas otimizaçoes #
- Acesso `root` (ou `sudo`).
- Conexão com a internet para baixar pacotes e o llama.cpp.
- ~10 GB livres em disco (build do llama.cpp + modelos pequenos).
- **Kernel ≥ 5.1** para `io_uring` (Debian 12 traz 6.1 — ok).

Confira sua versão:

```bash
grep PRETTY_NAME /etc/os-release
uname -r
```

---

## 🚀 Como usar

### 1. Clonar

```bash
git clone https://github.com/<seu-usuario>/ai-cpu-os.git
cd ai-cpu-os
```

### 2. Detectar o hardware (opcional, mas recomendado)

```bash
chmod +x detect-hardware.sh
./detect-hardware.sh
```

Isso imprime um relatório completo: CPU, flags (AVX2/AVX-512/AMX), RAM,
canais de memória, tipo de disco e qual perfil foi escolhido.

### 3. Aplicar o build

```bash
sudo ./build.sh --profile auto
```

- `--profile auto` → usa o perfil detectado automaticamente.
- `--profile xeon` / `--profile ryzen` → força um perfil.
- `--dry-run` → mostra o que seria feito, **sem** aplicar nada.
- `--yes` → não pede confirmação (para automação/CI).

### 4. Simular antes de aplicar (recomendado na 1ª vez)

```bash
sudo ./build.sh --profile auto --dry-run
```

---

## 🔧 O que o script faz (e por que cada coisa importa)

| Otimização                        | O que muda                                                        | Por que importa                                                                          |
|-----------------------------------|------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| Governor `performance`            | Trava todos os núcleos na frequência máxima                       | Elimina latência de "acordar" o núcleo no meio de um matmul.                              |
| Desativação de C-states profundos | `intel_idle.max_cstate=1` no kernel cmdline                       | Reduz a latência de wake-up de ~100 µs para ~1 µs.                                        |
| Transparent Huge Pages            | `always` (ou `madvise` explícito)                                 | Menos TLB misses → menos stalls no gargalo real (memória).                               |
| `vm.swappiness=10`                | Reduz paginação agressiva do modelo                                | Modelos grandes (GB) não devem encostar em swap durante inferência.                       |
| `vm.vfs_cache_pressure=50`        | Mantém dentries/inodes em cache                                    | Menos I/O ao carregar o `.gguf` repetidas vezes.                                          |
| `net.core.rmem_max/wmem_max`      | Buffers de socket maiores                                          | Importante para o `llama-server` (HTTP) e registry Docker.                                |
| `kernel.numa_balancing=0`         | Desliga o balanceamento automático NUMA (só single-socket)         | Reduz "roubo" de ciclos por migração de páginas irrelevante em 1 socket.                  |
| Huge pages estáticas              | Reserva de 2 MiB pages                                             | Ganho direto em latência de acesso a pesos.                                              |
| `io_uring`                        | Verificação de disponibilidade                                     | Alinha o carregamento de modelos com I/O assíncrono moderno.                              |
| `-DGGML_NATIVE=ON`                | O compilador usa a ISA **real** da CPU                            | Evita instruções não suportadas e extrai todo o AVX2/FMA/F16C disponível.                 |

Detalhes completos e a fundamentação técnica de cada item estão em
[`docs/TUNING.md`](docs/TUNING.md).

---

## 🎯 Objetivo final: a ISO de instalação

> **O fim do projeto não é "clonar e rodar um script".** É uma **ISO de
> instalação** (Debian) que já traz o `ai-cpu-os` embutido: você dá boot na
> ISO, a instalação é automática e o sistema **nasce afinado**.

Enquanto a ISO não existir e não for validada, o projeto **não está
terminado** — este é o critério de conclusão.

```bash
# Gerar a ISO (a partir de um Debian/Ubuntu com xorriso)
sudo apt install -y xorriso curl isolinux mtools
bash iso/build-iso.sh --disk /dev/nvme0n1 --profile auto --dry-run   # simular
sudo bash iso/build-iso.sh --disk /dev/nvme0n1 --profile auto         # gerar

# Testar em VM (sempre antes de máquina real)
qemu-system-x86_64 -m 4096 -enable-kvm -cdrom iso/out/ai-cpu-os-*.iso -boot d
```

| Etapa | O que acontece |
|-------|----------------|
| 1. Build da ISO | Baixa a netinst oficial (verificando SHA256), injeta o projeto + preseed e remonta. |
| 2. Instalação | `preseed` responde tudo automaticamente; o projeto vai para `/opt/ai-cpu-os`. |
| 3. **Primeiro boot** | `ai-cpu-os-firstboot.service` detecta o **hardware real** e aplica o perfil (`auto` → `xeon`/`ryzen`). |

> **Por que no primeiro boot, e não na instalação?** Porque o kernel do
> instalador não é o do sistema final, o systemd do alvo não está rodando e o
> hardware só é visto por completo depois. Detalhes e trade-offs em
> [`docs/ISO.md`](docs/ISO.md) § 3.

> ⚠️ **Estado:** a ISO **ainda não foi construída nem bootada**. O script foi
> validado em `--dry-run`; a validação real é o Bloco M do
> [`docs/VALIDATION.md`](docs/VALIDATION.md). A ISO **apaga o disco** indicado
> em `--disk` — teste em VM primeiro.

---

## 🤖 CI/CD — o GitHub compila o sistema

O repositório já vem com GitHub Actions para **validar**, **compilar** e
**empacotar** o sistema automaticamente:

| Workflow | Quando roda | O que faz |
|----------|-------------|-----------|
| **`validate`** | todo push/PR | `bash -n`, `shellcheck`, `python -m compileall`, `yamllint`, dry-run dos 2 perfis e guarda-corpo das regras do `AGENTS.md`. |
| **`build-llama`** | manual, tags `v*`, semanal | Compila o llama.cpp para `xeon` (AVX2) e `ryzen` (`znver2`), **executa os binários** e roda uma **inferência real** com um modelo minúsculo. Em tags, anexa os `.tar.gz` à Release. |
| **`container`** | push em `main`, tags, PR em `docker/**` | Publica a imagem de runtime no GHCR: `:latest` (portável) e `:znver2`. |
| **`iso`** | manual, tags `v*` | 🎯 Gera a **ISO de instalação** (remaster da netinst + preseed) e anexa à Release. |

**Rodar tudo localmente (idêntico ao CI):**

```bash
make help    # lista os alvos disponíveis
make ci      # lint + docs + dry-run  (= workflow 'validate')
```

**Baixar os binários já compilados pelo GitHub:** acesse *Actions →
build-llama → run mais recente → Artifacts* (`ai-cpu-os-llama-xeon` e
`ai-cpu-os-llama-ryzen`), ou baixe de uma Release.

> ⚠️ **O que o CI não testa:** tuning de kernel (governor, C-states, huge
> pages, sysctl) exige host privilegiado e, para C-states, **reboot**.
> Isso continua sendo validação manual em VM/hardware — ver
> [`docs/STATE.md`](docs/STATE.md).
>
> ⚠️ **Imagem ≠ performance máxima:** o container não tem acesso ao tuning do
> host. Para o máximo de tokens/s, use o `ai-server.service` nativo.

Detalhes, decisões de design e troubleshooting: [`docs/CI.md`](docs/CI.md).

---

## 📊 Como testar performance

Depois do build, use o `llama-bench` para medir tokens/s:

```bash
cd /opt/llama.cpp
./build/bin/llama-bench -m /opt/models/<modelo>.gguf -p 512 -n 128 -t 24
```

Compare **antes** e **depois** do tuning (rode o benchmark, aplique o
`build.sh`, rode de novo). Para o Xeon, use `-t 24`; para o Ryzen, `-t 6`.

Salve os resultados em `docs/STATE.md` na seção "Métricas de performance".

---

## ⚠️ Avisos e limitações (leia antes de tudo)

1. **Xeon E5-2678 v3 NÃO tem AVX-512.** Apenas AVX2. Não compile com
   `-mavx512*`.
2. **Ryzen 5 3500X NÃO tem AVX-512.** Apenas AVX2. O `-march` correto é
   `znver2`.
3. **Single channel no Ryzen** reduz a banda de memória em **~50%**. Para
   inferência em CPU, isto é gravíssimo — o script **alerta explicitamente**
   durante a detecção. Se possível, popule um segundo canal.
4. **A RX 580 não deve ser usada para computação** — apresenta artefatos de
   tela sob carga. Use-a apenas para saída de vídeo.
5. **Modelos acima de 7B Q4 não caberão em 16 GB de RAM** no Xeon (sem contar
   o sistema operacional e o KV cache). Acima disso, espere swap/thrashing.
6. **O tuning de kernel aumenta o consumo de energia.** Governor
   `performance` + C-states rasos = mais watts e mais calor. Em servidor,
   aceitável; em laptop, pense duas vezes.

---

## 🤝 Como contribuir

1. Faça um fork.
2. Crie um branch: `git checkout -b feat/minha-melhoria`.
3. **Leia [`AGENTS.md`](AGENTS.md)** e **[`docs/STATE.md`](docs/STATE.md)**
   antes de codar.
4. Todo script Bash deve ter `set -euo pipefail`, suporte `--dry-run` e ser
   idempotente.
5. Teste em VM antes de sugerir mudanças de kernel.
6. Atualize `docs/STATE.md` e `docs/ROADMAP.md`.
7. Se estiver fechando um **marco/versão**, atualize `docs/TUTORIAL.md`
   (diretriz obrigatória — Regra 9 do [`AGENTS.md`](AGENTS.md)).
8. Abra um Pull Request descrevendo **o que** mudou e **por que**.

---

## 📚 Documentação

| Documento                                       | Conteúdo                                        |
|-------------------------------------------------|-------------------------------------------------|
| [`AGENTS.md`](AGENTS.md)                        | Ponto de entrada para IAs e humanos.            |
| [`docs/ROADMAP.md`](docs/ROADMAP.md)            | Concluído / Em progresso / Planejado.           |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)  | Arquitetura, fluxos e decisões de design.       |
| [`docs/STATE.md`](docs/STATE.md)                | Estado atual, métricas e próxima ação.          |
| [`docs/HARDWARE.md`](docs/HARDWARE.md)          | Detalhes do hardware alvo.                      |
| [`docs/TUNING.md`](docs/TUNING.md)              | Cada otimização explicada.                      |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Problemas conhecidos e soluções.           |
| [`docs/TUTORIAL.md`](docs/TUTORIAL.md)          | **Tutorial explicado do zero** (obrigatório por marco/versão). |
| [`docs/CI.md`](docs/CI.md)                      | Como o GitHub compila e valida o sistema (CI/CD). |
| [`docs/VALIDATION.md`](docs/VALIDATION.md)      | **Protocolo de testes em hardware** (preenchível — traga os resultados depois). |
| [`docs/ISO.md`](docs/ISO.md)                    | 🎯 **A ISO de instalação** (entregável final): decisões, como gerar, limitações. |
| [`docs/JOURNAL.md`](docs/JOURNAL.md)            | 📓 **Diário de sessões + continuidade** — o que foi feito, threads abertas e armadilhas. |

---

## 📄 Licença

MIT — veja [`LICENSE`](LICENSE).
