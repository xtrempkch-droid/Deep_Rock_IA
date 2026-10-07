# TUTORIAL — ai-cpu-os: do Debian cru ao primeiro token

> **Documento obrigatório de encerramento de marco/versão.**
> Gerado/atualizado conforme a **Regra 9** do [`AGENTS.md`](../AGENTS.md).
>
> **Para quem é:** alguém que nunca viu este projeto (ou que voltou depois de
> meses) e quer entender e executar tudo do zero, **com explicações**.
>
> **O que você vai aprender:** por que inferência em CPU é um problema de
> memória (e não de FLOPs), como preparar um Debian mínimo, como aplicar o
> tuning do projeto, compilar o llama.cpp para AVX2, subir o `llama-server`,
> conversar pelo `shell-ia.py`, medir tokens/s — e, no caminho Ryzen, subir
> Docker + registry + Gitea e publicar uma imagem.
>
> **Tempo estimado:** 40–60 min de leitura guiada; +30–90 min de build real
> (depende do hardware).
>
> **Pré-requisito de leitura:** [`README.md`](../README.md) (visão geral) e
> [`docs/STATE.md`](STATE.md) (o que já foi testado e o que **não** foi).

---

## Índice

| # | Etapa | Para quem |
|---|-------|-----------|
| 0 | [Conceitos antes de começar](#0-conceitos-antes-de-começar-explicado) | Todos |
| 1 | [Preparar o Debian minimal](#1-etapa-0--preparar-o-debian-minimal) | Todos |
| 2 | [Obter o repositório e fazer o tour](#2-etapa-1--obter-o-repositório-e-fazer-o-tour) | Todos |
| 3 | [Detectar o hardware e ler a saída](#3-etapa-2--detectar-o-hardware-e-ler-a-saída) | Todos |
| 4 | [Simular tudo (`--dry-run`)](#4-etapa-3--simular-tudo-com---dry-run) | Todos |
| 5 | [Aplicar o build](#5-etapa-4--aplicar-o-build) | Todos |
| 6 | [Entender o tuning aplicado](#6-etapa-5--entender-o-tuning-aplicado-explicado) | Todos |
| 7 | [Caminho A — Xeon: do build ao 1º token](#7-caminho-a--xeon-da-compilação-ao-primeiro-token) | Perfil `xeon` |
| 8 | [Caminho B — Ryzen: build + registry + Gitea](#8-caminho-b--ryzen-build--registry--gitea) | Perfil `ryzen` |
| 9 | [Verificação final e checklist](#9-etapa-final--verificação-e-checklist) | Todos |
| 10 | [Manutenção e reversão](#10-manutenção-e-reversão) | Todos |
| 11 | [Problemas rápidos](#11-problemas-rápidos) | Todos |
| 12 | [Glossário](#12-glossário) | Todos |

---

## 0. Conceitos antes de começar (explicado)

Antes de digitar qualquer comando, é essencial entender **por que** este
projeto existe e **o que** ele otimiza. Sem isso, cada comando parece
"magia".

### 0.1 O gargalo não é FLOPs — é memória

> **Por que isso importa?** É a premissa central do projeto. Entender isso
> explica **todas** as otimizações aplicadas depois.

Em uma GPU, gerar o próximo token é limitado pela **capacidade de
processamento** (FLOPs). Em uma CPU sem GPU, o cenário muda: gerar um token
exige ler **todos os pesos do modelo** da memória RAM. Gerar 10 tokens/s com
um modelo de 7B Q4 (~4 GB) significa ler ~40 GB/s da RAM — e o Xeon E5-2678 v3
com DDR3-1333 dual channel entrega apenas ~17 GB/s.

**Conclusão prática:** o teto de tokens/s é ditado pela **banda de memória**.
Por isso o projeto ataca: canais de memória, latência de acesso (huge pages),
paginação (swappiness) e jitter de escalonamento (governor/C-states).

### 0.2 Vocabulário mínimo

| Termo | O que é (em uma frase) |
|-------|------------------------|
| **GGUF** | Formato de arquivo do modelo usado pelo llama.cpp (pesos + metadados). |
| **Quantização** | Reduzir a precisão dos pesos (ex.: `Q4_K_M` ≈ 4 bits) para caber em menos RAM. |
| **Q4_K_M** | Quantização de ~4 bits, variante "K medium" — bom equilíbrio qualidade/tamanho. |
| **tokens/s** | Velocidade de geração. O número que queremos maximizar. |
| **Contexto (`--ctx-size`)** | Quantos tokens o modelo "lembra" na conversa. Custa RAM (KV cache). |
| **Threads (`-t`)** | Quantas threads de CPU usam o modelo. Nem sempre "mais = melhor". |
| **THP** | Transparent Huge Pages: páginas de 2 MiB em vez de 4 KiB → menos TLB misses. |
| **Governor** | Política de frequência da CPU (`performance` trava no máximo). |
| **C-state** | Estados de baixo consumo da CPU; estados profundos têm alta latência de retorno. |
| **AVX2 / AVX-512** | Conjuntos de instruções SIMD. **Nosso hardware só tem AVX2.** |

### 0.3 Avisos que você precisa ter em mente desde já

- ❌ **O Xeon E5-2678 v3 e o Ryzen 5 3500X NÃO têm AVX-512** (apenas AVX2).
- ⚠️ **O Ryzen está em SINGLE CHANNEL** → ~50% de banda de memória perdida.
- ❌ **A RX 580 serve só para vídeo** — nunca para computação (artefatos sob carga).
- ⚠️ **16 GB no Xeon:** modelos acima de ~7B Q4 não cabem.
- ⚠️ **O tuning aumenta o consumo de energia** (governor `performance` + C-states rasos).

---

## 1. Etapa 0 — Preparar o Debian minimal

### 1.1 O que você precisa

| Item | Requisito |
|------|-----------|
| SO | Debian 12 (Bookworm) ou Ubuntu 22.04+ |
| Acesso | `root` ou `sudo` |
| Rede | Acesso à internet (pacotes + clone do llama.cpp) |
| Disco | ~10 GB livres |
| Kernel | ≥ 5.1 (Debian 12 traz 6.1 — OK para `io_uring`) |

### 1.2 Verificação inicial

```bash
# Confirmar a distro
grep PRETTY_NAME /etc/os-release

# Confirmar o kernel (io_uring precisa de >= 5.1)
uname -r

# Confirmar espaço em disco
df -h /
```

> **Por que verificar o kernel?** `io_uring` (I/O assíncrono moderno, usado no
> carregamento de modelos) só existe a partir do kernel 5.1. Em Debian 12 você
> está tranquilo.

### 1.3 Sudo disponível

```bash
sudo -v     # pede a senha e valida o sudo
```

Se `sudo` não existir (instalação muito minimal):

```bash
su -                      # entre como root
apt-get update
apt-get install -y sudo
usermod -aG sudo <seu-usuario>
exit
```

---

## 2. Etapa 1 — Obter o repositório e fazer o tour

### 2.1 Clonar

```bash
git clone https://github.com/<seu-usuario>/ai-cpu-os.git
cd ai-cpu-os

# Torna os scripts executáveis (o git preserva o bit, mas por segurança:)
chmod +x build.sh detect-hardware.sh common/*.sh \
         profiles/xeon/*.sh profiles/xeon/shell-ia.py \
         profiles/ryzen/*.sh tests/*.sh
```

### 2.2 Tour guiado (o que é cada peça)

> **Por que fazer o tour?** Saber onde está cada coisa faz você resolver
> problemas sozinho depois.

```text
ai-cpu-os/
├── build.sh            ← ORQUESTRADOR: você vai rodar este no fim das contas
├── detect-hardware.sh  ← LÊ o hardware e escolhe o perfil (não altera nada)
├── docs/               ← documentação viva (leia STATE.md SEMPRE)
├── profiles/
│   ├── xeon/           ← servidor de inferência (llama.cpp + shell-IA)
│   └── ryzen/          ← build + registry + Gitea
├── common/             ← tuning de kernel compartilhado
└── tests/              ← smoke-test.sh (verificação rápida)
```

**Regra de ouro do projeto:** antes de qualquer tarefa, leia
[`docs/STATE.md`](STATE.md). Ele diz o que está testado, o que **não** está,
e qual é a próxima ação.

---

## 3. Etapa 2 — Detectar o hardware e ler a saída

### 3.1 Rodar a detecção

```bash
./detect-hardware.sh
```

Este script é **somente leitura**: pode rodar como usuário comum (para
detectar canais de memória ele tenta `dmidecode`, que precisa de root — sem
root, cai num fallback por heurística).

### 3.2 Ler a saída (exemplo anotado)

```text
== CPU ==
[i] Modelo:      Intel(R) Xeon(R) CPU E5-2678 v3 @ 2.50GHz   ← CPU alvo do perfil xeon
[i] Sockets:     1                                            ← single-socket ⇒ numa_balancing=0
[i] Núcleos:     12
[i] Threads:     24                                           ← -t 24 (ou 12; meça os dois)

== Flags ISA ==
[i] AVX2:    SIM      ← obrigatório para performance
[i] FMA:     SIM      ← multiplicação-acumulação fundida
[i] F16C:    SIM      ← conversão half→float em hardware
[i] AVX-512: NÃO      ← CORRETO para este hardware (não compile com -mavx512!)
[ok] Sem AVX-512/AMX (esperado para os hardwares alvo).

== Memória ==
[i] Total:       16384 MiB (~16 GiB)
[i] Canais:      dual (heurística por Bank Locator)   ← dual channel = banda cheia

== Armazenamento ==
[i] NVMe: nvme0n1 (Samsung ...)   ← carrega o GGUF rápido

== Resultado ==
[ok] Perfil escolhido: xeon
PROFILE=xeon                       ← linha consumida pelo build.sh
```

### 3.3 Como interpretar cada bloco

| Bloco | O que observar | Se estiver diferente do esperado |
|-------|----------------|----------------------------------|
| **CPU** | Modelo, sockets, núcleos, threads | Se não for Xeon/Ryzen, o perfil cairá por heurística (RAM ≤32 GB → `xeon`). |
| **Flags ISA** | AVX2 = SIM | ⚠️ Se **AVX2 = NÃO**, o build será genérico (lento) — confira se é VM com CPU limitada. |
| **Memória** | Canais = dual | ⚠️ Se **single**, veja o alerta abaixo. |
| **Armazenamento** | NVMe presente | SATA funciona, mas carrega o modelo mais devagar. |

> **Se aparecer "single channel":** é o problema mais caro do projeto
> (~50% de banda). Nas MSI B550, instale os pentes nos slots **A2 + B2**
> (2º e 4º a partir do soquete da CPU). Confirme com:
> ```bash
> sudo dmidecode -t memory | grep -E 'Locator|Size'
> ```

### 3.4 Forçar um perfil (quando a detecção "erra")

```bash
./build.sh --profile xeon      # força xeon
./build.sh --profile ryzen     # força ryzen
# ou via variável de ambiente:
AI_PROFILE=xeon ./build.sh
```

---

## 4. Etapa 3 — Simular tudo com `--dry-run`

> **Por que simular?** Tuning de kernel é sensível. O `--dry-run` mostra
> **exatamente** o que seria feito — arquivos escritos, serviços habilitados,
> parâmetros de kernel — **sem aplicar nada**.

```bash
sudo ./build.sh --profile auto --dry-run
```

Você verá as 4 etapas, mas tudo prefixado com `[dry-run]`:

```text
=== Etapa 1/4: Tuning de kernel comum ===
[INFO ] [dry-run] Aplicando common/kernel-tuning.sh: bash .../kernel-tuning.sh --dry-run
[INFO ] [dry-run] Aplicando common/hugepages.sh: bash .../hugepages.sh --dry-run
[INFO ] [dry-run] Aplicando common/governor.sh: bash .../governor.sh --dry-run
=== Etapa 2/4: Instalação do perfil 'xeon' ===
[INFO ] [dry-run] Executando .../profiles/xeon/install.sh: bash .../install.sh --dry-run
...
```

**O que observar no dry-run:**

1. O arquivo de sysctl que seria gerado (`/etc/sysctl.d/99-ai-tuning.conf`).
2. Se `kernel.numa_balancing` está `0` (single-socket) ou `1` (multi-socket).
3. Se o parâmetro de C-state está correto para o fabricante
   (`intel_idle.max_cstate=1` em Intel, `processor.max_cstate=1` em AMD).
4. Se o `<script>` do perfil apontado é o que você espera.

---

## 5. Etapa 4 — Aplicar o build

### 5.1 Rodar de verdade

```bash
sudo ./build.sh --profile auto
# em automação (sem perguntas):
sudo ./build.sh --profile auto --yes
```

### 5.2 O que acontece em cada etapa

| Etapa | O que roda | Resultado |
|-------|-----------|-----------|
| **1/4** | `common/kernel-tuning.sh`, `hugepages.sh`, `governor.sh` | `/etc/sysctl.d/99-ai-tuning.conf`, THP, governor `performance` |
| **2/4** | `profiles/<perfil>/install.sh` | xeon: llama.cpp + serviço. ryzen: Docker + registry + Gitea |
| **3/4** | Verificação embutida | Imprime sysctl/governor/THP efetivos |
| **4/4** | `tests/smoke-test.sh` | PASS/FAIL/SKIP por item |

> **Importante:** o log é espelhado em `/var/log/ai-cpu-os-build.log`
> (requer root). Útil para auditar depois.

### 5.3 Se algo falhar

O script usa `set -euo pipefail` e para no primeiro erro com nível `[ERROR]`.
Leia a mensagem — ela aponta o script e o comando. Consulte
[`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## 6. Etapa 5 — Entender o tuning aplicado (explicado)

Cada item abaixo foi aplicado pela Etapa 1. Entenda **por que**:

| Otimização | Valor aplicado | Por que importa |
|-----------|----------------|-----------------|
| `vm.swappiness` | `10` | Impede que o modelo (GB na RAM) vá para swap → sem I/O de disco no 1º token. |
| `vm.vfs_cache_pressure` | `50` | Mantém dentries/inodes em cache → menos I/O ao recarregar o `.gguf`. |
| `vm.dirty_ratio` / `dirty_background_ratio` | `15` / `5` | Evita picos de escrita (write stall) que "engasgam" o sistema. |
| `kernel.numa_balancing` | `0` (só single-socket) | Remove overhead de migração de páginas inútil em 1 socket NUMA. |
| `net.core.rmem_max`/`wmem_max` | `134217728` (128 MiB) | Buffers maiores para o `llama-server` (HTTP) e o registry Docker. |
| Governor | `performance` | Trava núcleos no máximo → elimina jitter de frequência por token. |
| C-states | `*_idle.max_cstate=1` (cmdline) | Reduz latência de wake-up de ~100 µs para ~1 µs. **Requer reboot.** |
| THP | `always` | Páginas de 2 MiB → menos TLB misses no acesso aos pesos. |

### 6.1 Verificar por conta própria

```bash
# sysctl aplicados
sysctl vm.swappiness vm.vfs_cache_pressure kernel.numa_balancing net.core.rmem_max

# governor aplicado
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# THP
cat /sys/kernel/mm/transparent_hugepage/enabled

# C-states ativos (após reboot, deve parar em C1)
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
```

### 6.2 ⚠️ Reboot pendente

Se o `kernel-tuning.sh` alterou a **cmdline do kernel** (C-states), o efeito
só vale após reiniciar:

```bash
cat /proc/cmdline        # deve conter max_cstate=1
sudo reboot
```

> Aprofundamento completo: [`docs/TUNING.md`](TUNING.md).

---

## 7. Caminho A — Xeon: da compilação ao primeiro token

> Perfil `xeon` = servidor de inferência. Se você está no Ryzen, pule para a
> [seção 8](#8-caminho-b--ryzen-build--registry--gitea).

### 7.1 Entender o que será compilado

Antes do build, veja **o que** cada flag faz (`llama-build.sh` as aplica):

| Flag | O que faz | Por que |
|------|-----------|---------|
| `-DGGML_NATIVE=ON` | Compila para a ISA **real** da CPU | Nunca emite instrução inexistente (evita `SIGILL`). |
| `-DGGML_AVX2=ON` | Habilita path SIMD de 256 bits | ~2× throughput sobre SSE em operações vetoriais. |
| `-DGGML_FMA=ON` | Fused Multiply-Add | Menos instruções por GEMM (multiplicação de matrizes). |
| `-DGGML_F16C=ON` | Conversão half→float em hardware | Mais rápido ao lidar com pesos FP16. |
| `-DGGML_BLAS=ON` + OpenBLAS | Delega GEMMs grandes a um BLAS otimizado em AVX2 | Melhor uso de cache. |
| ❌ `-mavx512*` | **Não usado** | A CPU não tem AVX-512 → crash (`SIGILL`). |

O script **valida** as flags em `/proc/cpuinfo` **antes** de compilar e faz
*fallback*: se uma flag não existir, ela é omitida.

### 7.2 Compilar

```bash
sudo bash profiles/xeon/llama-build.sh --yes
```

Saída esperada (resumo):

```text
[i] ISA detectada: AVX2=1 FMA=1 F16C=1 AVX-512=0
[i] Flags de CMake: -DGGML_NATIVE=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON ...
[ok] Build concluído. Binários em /opt/llama.cpp/build/bin.
```

> **Dica:** se o Xeon tem 16 GB, use `--jobs 6` para não estourar a RAM
> durante o build:
> ```bash
> sudo bash profiles/xeon/llama-build.sh --jobs 6 --yes
> ```

### 7.3 Instalar serviço, usuário e (opcional) modelo

```bash
# Só instala o serviço/usuário e aplica o sysctl:
sudo bash profiles/xeon/install.sh --yes

# Com download do modelo sugerido (Qwen2.5-Coder-1.5B, ~1.1 GB):
sudo bash profiles/xeon/install.sh --auto-model --yes
```

O `install.sh` do Xeon:

1. Instala dependências de build e runtime.
2. Chama o `llama-build.sh` (compila o llama.cpp).
3. Copia `sysctl.conf` → `/etc/sysctl.d/99-ai-tuning.conf`.
4. Cria o usuário de serviço **`llama`** (sem login, sem shell).
5. Instala `ai-server.service` e `/etc/default/ai-server` (com `MODEL_PATH`).
6. Opcionalmente baixa o modelo para `/opt/models/`.

> ⚠️ Sem modelo, o serviço **não sobe**. Baixe um com `--auto-model` **ou**
> manualmente e ajuste `MODEL_PATH` em `/etc/default/ai-server`.

### 7.4 Subir o serviço e testar

```bash
sudo systemctl enable --now ai-server
sudo systemctl status ai-server --no-pager

# Health check (endpoint do llama-server)
curl -s http://127.0.0.1:8080/health
```

Se falhar:

```bash
sudo journalctl -u ai-server -n 50 --no-pager   # veja o erro real
free -h                                          # confirme que o modelo cabe
```

### 7.5 Conversar pelo shell-IA (o "1º token")

Modo interativo:

```bash
python3 profiles/xeon/shell-ia.py
# você> quanta RAM livre tem nesta máquina?
```

Prompt único (não-interativo):

```bash
python3 profiles/xeon/shell-ia.py -p "liste os arquivos em /opt/models"
```

> **Como funciona por dentro:** o `shell-ia.py` envia sua pergunta ao
> `llama-server` (HTTP). Quando o modelo quer usar uma ferramenta, ele emite
> uma linha `TOOL: <nome> <json>`. O shell valida contra uma **whitelist**,
> executa sem `shell=True`, com timeout, e realimenta o modelo com
> `RESULT:`. É o sandbox básico do projeto.

**Exemplos de prompts úteis:**

```text
liste os arquivos em /opt/models
quanto de RAM está livre?
mostre as últimas 20 linhas do journal do ai-server
procure por "swappiness" em /etc/sysctl.d
```

**O que o sandbox bloqueia:** comandos fora da whitelist (ex.: `rm`, `dd`),
argumentos perigosos, caminhos fora das raízes permitidas
(`AI_ALLOWED_ROOTS`, padrão `/opt/models:~:/tmp/ai-shell`).

### 7.6 Medir performance (llama-bench)

> **Regra do projeto:** medir, não adivinhar. `docs/STATE.md` exige números.

```bash
/opt/llama.cpp/build/bin/llama-bench \
    -m /opt/models/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf \
    -p 512 -n 128
```

| Flag | Significado |
|------|-------------|
| `-p 512` | Mede **prompt processing** (prefill) com 512 tokens. |
| `-n 128` | Mede **generation** com 128 tokens. |
| `-t N` | Threads. Xeon: teste `-t 12` e `-t 24` e compare. |

**Comparação antes/depois (o ponto do projeto):**

```bash
# 1. Meça ANTES (com governor powersave e THP madvise, num sistema cru):
#    rode o bench e anote os números.
# 2. Aplique o build:  sudo ./build.sh --profile xeon
# 3. Meça DEPOIS e compare.
```

### 7.7 Interpretar os números

```text
| model | size | params | backend | threads | test | t/s |
| qwen2 1.5B Q4_K_M | 1.1 GiB | 1.54 B | CPU | 24 | pp512  |  95.3 ± 2.1 |
| qwen2 1.5B Q4_K_M | 1.1 GiB | 1.54 B | CPU | 24 | tg128  |  28.7 ± 0.4 |
```

- **`pp512`** (prompt processing): quanto rápido ele "lê" seu prompt. Beneficia-se de **threads**.
- **`tg128`** (text generation): tokens/s de geração. Beneficia-se de **banda de memória**.
- Se aumentar `-t` **piorar** `tg128`, você saturou a banda — reduza as threads.

> **Anote os resultados em [`docs/STATE.md`](STATE.md)**, seção "Métricas de
> performance". É uma regra do projeto (Regra 2 do `AGENTS.md`).

---

## 8. Caminho B — Ryzen: build + registry + Gitea

> Perfil `ryzen` = máquina de build, registry privado e Gitea.
> **Não** roda inferência.

### 8.0 Antes de tudo: o alerta de single channel

O `install.sh` do Ryzen **abre com um alerta** sobre single channel (~50% de
banda perdida) e **pede confirmação**. Isso é intencional — é o problema de
hardware mais caro deste perfil.

```bash
sudo bash profiles/ryzen/install.sh
```

### 8.1 Docker Engine + Compose

```bash
sudo bash profiles/ryzen/docker-setup.sh --yes
```

O script:

1. Adiciona o **repositório oficial** do Docker (não o `docker.io` antigo do Debian).
2. Instala `docker-ce`, `containerd`, `buildx` e `compose`.
3. Escreve `/etc/docker/daemon.json` com `insecure-registries: ["localhost:5000"]`.
4. Habilita o serviço e adiciona seu usuário ao grupo `docker`.

> **Por que "insecure-registry"?** O Docker exige TLS por padrão. Como o
> registry é local (`localhost:5000`), TLS é desnecessário — liberamos
> explicitamente.

Verifique:

```bash
docker --version && docker compose version
```

### 8.2 Registry privado

```bash
sudo bash profiles/ryzen/registry-setup.sh --yes
curl -s http://localhost:5000/v2/          # deve responder {} ou catálogo
```

- Container: `registry:2`, nome `registry`, porta `127.0.0.1:5000`.
- Dados persistentes em `/var/lib/registry`.
- `--restart unless-stopped` → sobe sozinho no boot.

### 8.3 Gitea

```bash
cd profiles/ryzen
docker compose -f gitea-compose.yml up -d
```

- Web: **http://localhost:3000** (crie o admin no primeiro acesso).
- SSH do Git: `ssh://git@localhost:2222/<user>/<repo>.git`.
- Banco: **SQLite** (`./data/gitea/gitea.db`) — menos partes móveis.

> **Por que SQLite e não Postgres?** Para um servidor de projetos pessoal, o
> ganho de Postgres não compensa a complexidade operacional.

### 8.4 Build + push de uma imagem

Crie um repositório de teste com um `Dockerfile` e rode:

```bash
bash profiles/ryzen/build-runner.sh \
    --context /caminho/do/repo \
    --tag localhost:5000/meu/app:1.0 \
    --push
```

O que ele faz:

1. Valida que existe um `Dockerfile` no contexto.
2. `docker build --cache-from` (reusa cache do registry local; primeiro build não tem cache).
3. `docker tag` + `docker push` para `localhost:5000`.

Confirmar o que foi publicado:

```bash
curl -s http://localhost:5000/v2/_catalog
curl -s http://localhost:5000/v2/meu/app/tags/list
```

> **Manutenção:** o registry **não** faz garbage collection automática. De
> tempos em tempos:
> ```bash
> docker exec -it registry registry garbage-collect -m /etc/docker/registry/config.yml
> ```

### 8.5 Ciclo de trabalho sugerido

```text
Gitea (:3000)  →  você faz push do código
      │
      ▼
build-runner.sh  →  docker build + push
      │
      ▼
Registry (:5000)  →  imagens prontas
      │
      ▼
(transportar para o Xeon: docker save | scp | docker load)
```

---

## 9. Etapa final — Verificação e checklist

### 9.1 Rodar o smoke-test

```bash
bash tests/smoke-test.sh --profile auto
# em CI/strict (falha = exit 1):
bash tests/smoke-test.sh --profile auto --strict
```

Itens verificados (exemplos):

| Item | Esperado |
|------|----------|
| `vm.swappiness ≤ 10` | aplicado |
| `vm.vfs_cache_pressure ≤ 100` | aplicado |
| `net.core.rmem_max ≥ 128 MiB` | aplicado |
| Governor cpu0 | `performance` |
| THP | `always` ou `madvise` |
| AVX2 presente | SIM |
| *(xeon)* binário `llama-server` | existe |
| *(xeon)* `/health` em :8080 | responde |
| *(ryzen)* registry :5000 | responde |
| *(ryzen)* containers `registry`/`gitea` | rodando |

### 9.2 Checklist final

- [ ] `./detect-hardware.sh` rodou e o perfil faz sentido.
- [ ] `sudo ./build.sh --profile auto --dry-run` foi revisado.
- [ ] `sudo ./build.sh --profile auto` concluiu sem `[ERROR]`.
- [ ] `sysctl`/governor/THP conferidos manualmente.
- [ ] *(se alterou C-states)* **reboot** feito e `cat /proc/cmdline` confere.
- [ ] *(xeon)* `curl http://127.0.0.1:8080/health` responde.
- [ ] *(xeon)* `python3 profiles/xeon/shell-ia.py -p "quanta RAM livre?"` responde.
- [ ] *(xeon)* `llama-bench` rodou e os números foram anotados em `docs/STATE.md`.
- [ ] *(ryzen)* `docker`, registry (:5000) e Gitea (:3000) ativos.
- [ ] *(ryzen)* um build+push de teste funcionou.
- [ ] `bash tests/smoke-test.sh` sem FAILs críticos.
- [ ] `docs/STATE.md` e `docs/ROADMAP.md` atualizados.

---

## 10. Manutenção e reversão

### 10.1 Atualizar o llama.cpp

```bash
sudo bash profiles/xeon/llama-build.sh --ref master --yes
```

O script faz `git fetch` + `checkout` e recompila. Se mudou de versão, reinicie
o serviço: `sudo systemctl restart ai-server`.

### 10.2 Trocar de modelo

```bash
sudoedit /etc/default/ai-server     # ajuste MODEL_PATH e LLAMA_CTX
sudo systemctl restart ai-server
```

**Regra de dimensionamento (16 GB):** escolha modelo + KV cache dentro de
~13 GB (deixe folga para o SO). Acima de ~7B Q4 você vai paginar e perder
desempenho.

### 10.3 Reverter o tuning

O projeto é **aditivo e documentado**; reverter é direto:

```bash
# 1. Remover sysctl de IA
sudo rm -f /etc/sysctl.d/99-ai-tuning.conf /etc/sysctl.d/99-ai-hugepages.conf
sudo sysctl --system

# 2. Reverter THP
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled

# 3. Reverter governor
sudo systemctl disable --now ai-cpu-governor.service
echo schedutil | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# 4. Reverter C-states: remova o parâmetro de /etc/default/grub e:
sudo update-grub && sudo reboot

# 5. Desabilitar serviços do projeto
sudo systemctl disable --now ai-server ai-hugepages.service
```

> **Backups:** os scripts que editam arquivos de sistema criam cópias
> `*.bak.<timestamp>` (ex.: `/etc/default/grub.bak.1699...`). Use-as se
> precisar voltar um arquivo específico.

### 10.4 Limpar o registry (liberar disco)

```bash
docker exec -it registry registry garbage-collect -m /etc/docker/registry/config.yml
```

---

## 11. Problemas rápidos

| Sintoma | Vá para (em [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)) |
|---------|--------------------------------------------------------|
| `SIGILL` / "Illegal instruction" | *Compilação do llama.cpp* |
| Governo não muda para `performance` | *Kernel / Tuning* |
| `max_cstate=1` não fez efeito | *Kernel / Tuning* |
| `docker push` falha com TLS/HTTPS | *Docker / Registry* |
| `Cannot connect to the Docker daemon` | *Docker / Registry* |
| Gitea "port already allocated" | *Gitea* |
| Clone SSH na 2222 falha | *Gitea* |
| `shell-ia.py` não conecta no server | *shell-IA* |
| Modelo não carrega / OOM | *shell-IA* |
| Rodar duas vezes "quebrou" algo | *Geral* (reporte — é bug de idempotência!) |

---

## 12. Glossário

| Termo | Definição |
|-------|-----------|
| **AVX2** | Extensão SIMD de 256 bits. Presente em ambas as CPUs do projeto. |
| **AVX-512** | Extensão de 512 bits. **Ausente** no hardware alvo. |
| **C-state** | Estado de economia de energia da CPU (C1, C2, C3...). Mais profundo = menos consumo, maior latência de retorno. |
| **GGUF** | Formato de arquivo de modelo do llama.cpp. |
| **Governor** | Política que decide a frequência da CPU. |
| **Huge page** | Página de memória de 2 MiB (vs. 4 KiB). Menos pressão na TLB. |
| **Idempotência** | Propriedade de rodar duas vezes com o mesmo resultado. Requisito de todo script do projeto. |
| **io_uring** | Interface de I/O assíncrono de baixa latência (kernel ≥ 5.1). |
| **KV cache** | Memória do contexto da conversa; cresce com `--ctx-size`. |
| **llama.cpp** | Motor de inferência LLM em C/C++ otimizado para CPU. |
| **llama-server** | Binário do llama.cpp que expõe uma API HTTP (compatível com OpenAI). |
| **NUMA** | Non-Uniform Memory Access. Em single-socket, o balanceamento é overhead puro. |
| **Q4_K_M** | Quantização de ~4 bits (variante K medium). |
| **THP** | Transparent Huge Pages. |
| **TLB** | Cache de tradução de endereços virtuais→físicos; transbordar custa stalls. |
| **tokens/s** | Métrica de velocidade de geração. |

---

## 13. Mapa do que você aprendeu / próximos passos

Você agora sabe:

1. **Por que** inferência CPU-bound é limitada por memória, não FLOPs.
2. **Como** detectar o hardware e interpretar ISA/canais.
3. **Como** simular (`--dry-run`) e aplicar o tuning com segurança.
4. **Como** compilar o llama.cpp para AVX2 e **por que** não usar AVX-512.
5. **Como** subir o `llama-server` e conversar pelo `shell-ia.py`.
6. **Como** medir com `llama-bench` e interpretar `pp512`/`tg128`.
7. **Como** subir Docker + registry + Gitea e publicar imagens.

**Próximas leituras:**

| Quero... | Leia |
|----------|------|
| Aprofundar cada otimização | [`docs/TUNING.md`](TUNING.md) |
| Entender a arquitetura e fluxos | [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) |
| Detalhes técnicos do hardware | [`docs/HARDWARE.md`](HARDWARE.md) |
| Saber o que está feito/planejado | [`docs/ROADMAP.md`](ROADMAP.md) |
| Saber o que **não** foi testado | [`docs/STATE.md`](STATE.md) |
| Contribuir | [`README.md`](../README.md) § "Como contribuir" |

---

## Manutenção deste documento

> **Diretriz (Regra 9 do `AGENTS.md`):** ao concluir um **marco** (perfil
> validado, release) ou **versão**, este tutorial **DEVE** ser revisado e
> atualizado para refletir o estado real — especialmente:
>
> - ✅ marcar o que passou a ser **testado em hardware** (hoje nada é);
> - ✅ substituir números `pendente` por medições reais de `llama-bench`;
> - ✅ corrigir comandos/saídas que mudaram;
> - ✅ remover seções obsoletas (e explicar em `docs/ARCHITECTURE.md` se
>   código foi removido).
>
> Não é um documento "de uma vez só": ele evolui com o projeto, junto com
> `docs/STATE.md`.

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação inicial (v0.1.0-alpha) — tutorial completo; nada testado em hardware ainda. |
