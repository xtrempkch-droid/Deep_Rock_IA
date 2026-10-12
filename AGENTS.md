# AGENTS.md — Memória do projeto ai-cpu-os

> **LEIA ESTE ARQUIVO ANTES DE QUALQUER COISA.**
> Este é o ponto de entrada para qualquer IA (ou humano) que retome o projeto
> após um tempo parado. Ele resume o propósito, a filosofia, o hardware, a
> estrutura e — o mais importante — **as regras de trabalho**.

---

## ⚡ Retomada rápida (leia isto primeiro se chegou agora)

```bash
# 1. O essencial, nesta ordem:
#    AGENTS.md (este) → docs/STATE.md § 6 (próxima ação) → docs/JOURNAL.md
#    (§ 5 threads abertas · § 6 armadilhas já pisadas)

# 2. Sincronizar e conferir a saúde do repositório
cd /home/juju/Deep_Rock_IA
git pull --ff-only
make ci            # lint + docs + dry-run (igual ao job 'validate')

# 3. Saber o que já foi PROVADO e o que NÃO foi:
#    validate ✅ · build-llama ✅ · container ✅ · /**iso ⚠️ nunca executado**
```

> **Regra de ouro:** não confie na memória — confie no **`docs/STATE.md` § 6
> ("Próxima ação imediata")** e no **`docs/JOURNAL.md` § 5 ("threads abertas")**.
> Os dois são reescritos ao fim de **cada** sessão de trabalho exatamente para isto.

---

## 1. Propósito do projeto

O `ai-cpu-os` transforma um Debian/Ubuntu minimal em um sistema operacional
afinado para **inferência de LLMs inteiramente em CPU**. Ele existe porque,
sem GPU, o gargalo real deixa de ser FLOPs e passa a ser **banda de memória,
latência de memória e escalonamento**. Um sistema "genérico" desperdiça ciclos
em page faults, migração de páginas, C-states profundos e swappiness agressivo
— desperdício que, somado, custa dezenas de por cento de tokens/s.

O projeto é organizado em **duas dimensões independentes** — e misturá-las é o
principal erro a evitar:

- **Família de CPU** (`families/`) — *quem é o hardware*: define `-march`, ISA e
  a política de AVX-512. Uma família cobre **dezenas de modelos** e há
  **herança** entre gerações (o tuning do Broadwell-EP vale para toda a família
  E5 **v4**; o de Haswell-EP, para toda a **v3**).
- **Papel** (`roles/`) — *para que serve a máquina*: `inference` (servidor de
  inferência) ou `builder` (Docker + registry + Gitea). Qualquer família pode
  exercer qualquer papel.
- **Mods** (`mods/`) — *modificações isoladas e reversíveis* que qualquer
  pessoa aplica e testa no seu próprio sistema operacional.

O projeto foi desenhado em torno de **dois sistemas reais**: um **servidor de
inferência** baseado em Intel Xeon E5-2680 v4 (família `intel-broadwell`,
papel `inference`) e uma **máquina de build** baseada em AMD Ryzen 5 3500X
(família `amd-zen2`, papel `builder`), que também serve um registry Docker
privado e um servidor Gitea.

Todo o sistema é gerado por **script** (`build.sh`), é **idempotente**, suporta
`--dry-run` e documenta *cada* otimização com a razão técnica de existir.

### 🎯 Entregável final: uma ISO de instalação

> **O fim do projeto NÃO é "clonar e rodar um script".** O objetivo final é uma
> **imagem ISO de instalação** de um SO (Debian/Ubuntu) **já com o ai-cpu-os
> embutido**: você dá boot na ISO, a instalação é automática e o sistema nasce
> afinado. Isso está implementado em `iso/` e especificado em `docs/ISO.md`.
>
> **Não é uma ideia futura — é o critério de conclusão do projeto.** Enquanto a
> ISO não existir e não for validada, o projeto **não está terminado**, por mais
> que os scripts estejam prontos.

Arquitetura da ISO em uma frase: a ISO entrega o *software e a intenção*
(o perfil); o **primeiro boot** entrega o *contexto* (o hardware real), porque é
lá que `detect-hardware.sh` vê o SMBIOS completo e escolhe `xeon` ou `ryzen`
corretamente. Ver `docs/ISO.md` § 3.

---

## 2. Filosofia: "1% importa"

Cada otimização, por menor que pareça, é acumulada. Não buscamos um único
"truque de 2x"; buscamos **100 ganhos de 1%** que, combinados, mudam a
experiência de uso. Isso significa que:

- Nunca descartamos uma micro-otimização por "parecer pequena".
- Nunca aplicamos uma otimização sem saber **por que** ela funciona.
- Sempre medimos antes/depois (`llama-bench`) e registramos em `docs/STATE.md`.

---

## 3. Hardware alvo (resumo)

### Sistema A — Família `intel-broadwell` · papel `inference` (Servidor de IA)
- **CPU:** Intel Xeon E5-2680 v4 — 14c/28t, **Broadwell-EP**, **AVX2 apenas**
  (sem AVX-512, sem AMX). Herda o tuning de `intel-haswell` (E5 v3).
- **Placa-mãe:** JGINYUE X99M-D3 (LGA2011-3, DDR3).
- **RAM:** 16 GB DDR3-1333, 4×4 GB, **quad channel** (4 canais; Haswell-EP,
  1 pente por canal).
- **Disco:** SSD NVMe 256 GB.
- **GPU:** nenhuma (inferência 100% CPU).
- **Limitação conhecida:** modelos > 7B Q4 não cabem em 16 GB.

### Sistema B — Família `amd-zen2` · papel `builder` (Build + Registry + Gitea)
- **CPU:** AMD Ryzen 5 3500X — 6c/6t, Zen 2, **AVX2 apenas**.
- **Placa-mãe:** MSI B550 (AM4).
- **RAM:** 64 GB DDR4, 4×16 GB, operando em **SINGLE CHANNEL** ⚠️ (perda de
  ~50% de banda — o script alerta).
- **Disco:** NVMe 256 GB + HDD 1 TB.
- **GPU:** AMD RX 580 8 GB — **apenas saída de vídeo**, nunca computação
  (artefatos sob carga).
- **Função:** compilar via Docker, servir registry privado, hospedar Gitea.

---

## 4. Estrutura do repositório (comentada)

```text
ai-cpu-os/
├── README.md               # Visão geral, uso, avisos, contribuição
├── README.technical.md     # Manual do MANTENEDOR (internals, contratos, CI)
├── AGENTS.md               # ← você está aqui (ponto de entrada)
├── LICENSE                 # MIT
├── Makefile                # Atalhos locais (make ci, lint, build-xeon, docker…)
├── build.sh                # Script principal (orquestra tudo)
├── detect-hardware.sh      # Detecção de CPU/RAM/canal/disco + escolha de perfil
├── .github/
│   ├── workflows/
│   │   ├── validate.yml    # Lint + dry-run + guarda-corpo das regras (push/PR)
│   │   ├── build-llama.yml # Compila o llama.cpp por perfil + Release (tags/manual)
│   │   ├── container.yml   # Imagem de runtime no GHCR (portable / znver2)
│   │   └── iso.yml         # 🎯 Gera a ISO de instalação (tags/manual)
│   ├── ISSUE_TEMPLATE/     # Templates de issue (bug / feature)
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── dependabot.yml      # Atualização de actions e da imagem base
├── docker/
│   ├── Dockerfile          # Runtime do llama.cpp (GGML_NATIVE=OFF — ver docs/CI.md)
│   └── docker-compose.example.yml
├── iso/                    # 🎯 ENTREGÁVEL FINAL: ISO de instalação
│   ├── build-iso.sh        # Remasteriza a ISO base (--distro ubuntu|debian)
│   ├── verify-iso.sh       # Verifica o CONTEÚDO da ISO (ou de uma árvore: --dir)
│   ├── test-vm.sh          # Boota a ISO em qemu e espera instalação + 1º boot
│   ├── autoinstall/        # Templates do Ubuntu (Subiquity/autoinstall)
│   │   └── autoinstall.yaml # Config de instalação automática (padrão)
│   └── preseed/            # Templates compartilhados + os do Debian (legado)
│       ├── ai-cpu-os.cfg   # Respostas automáticas do debian-installer
│       ├── late-command.sh # Copia o projeto p/ /opt/ai-cpu-os (os 2 instaladores)
│       ├── firstboot.sh    # Aplica as mods no primeiro boot (hardware real)
│       └── ai-cpu-os-firstboot.service
├── docs/
│   ├── ROADMAP.md          # Concluído / Em progresso / Planejado / Ideias
│   ├── ARCHITECTURE.md     # Diagramas, fluxos, decisões de design
│   ├── STATE.md            # Estado atual + métricas + PRÓXIMA AÇÃO
│   ├── HARDWARE.md         # Detalhes técnicos do hardware alvo
│   ├── TUNING.md           # Explicação de cada otimização
│   ├── TROUBLESHOOTING.md  # Problemas conhecidos e soluções
│   ├── CI.md               # Como o GitHub compila e valida o sistema
│   ├── TUTORIAL.md         # TUTORIAL explicado (obrigatório por marco/versão)
│   ├── VALIDATION.md       # Protocolo de testes em hardware (preenchível)
│   ├── ISO.md              # 🎯 A ISO de instalação (decisões e como gerar)
│   ├── GPU.md              # 🎮 Usar GPU (opcional, sempre explícito)
│   └── JOURNAL.md          # 📓 Diário de sessões + continuidade (retomada)
│   └── build-runner.sh # Build Docker + push p/ registry local
├── families/               # 🧬 Suporte por FAMÍLIA de microarquitetura
│   ├── README.md           # Conceito família × papel, como adicionar família
│   ├── resolve.sh          # "Cérebro": casa o CPU → família → ISA/march
│   ├── _base/family.conf   # Padrões herdados por todas as famílias
│   ├── intel-haswell/      # Xeon E5 v3 (AVX2)
│   ├── intel-broadwell/    # Xeon E5 v4 (AVX2) — herda de intel-haswell
│   ├── intel-skylake-avx512/ # Scalable v5/v6 — AVX-512 por opt-in
│   ├── amd-zen1/ … amd-zen4/ # Ryzen 1000/2000 … 7000/9000 (herança em cadeia)
│   └── generic/            # Fallback x86-64 (ISA em runtime, AVX-512 auto)
├── roles/                  # 🎯 O que a máquina FAZ (independente da CPU)
│   ├── README.md           # Fronteira papel × família
│   ├── inference/          # Servidor de inferência em CPU
│   │   ├── install.sh      # Instala deps + llama.cpp + serviço
│   │   ├── sysctl.conf     # Referência do sysctl do papel
│   │   ├── shell-ia.py     # Shell-IA em Python (tools + sandbox)
│   │   └── ai-server.service # Unit systemd do llama-server
│   └── builder/            # Build + registry + Gitea
│       ├── install.sh      # Orquestra o papel builder
│       ├── docker-setup.sh # Docker Engine + Compose
│       ├── registry-setup.sh # Registry privado localhost:5000
│       ├── gitea-compose.yml # Gitea via docker compose
│       └── build-runner.sh # Build Docker + push p/ registry local
├── llama-build.sh          # Compila o llama.cpp para a FAMÍLIA (compartilhado)
├── mods/                    # 🔧 Modificações portáveis (aplicar/testar/reverter)
│   ├── README.md            # Catálogo
│   ├── apply.sh             # Motor: list/info/check/apply/revert/test
│   ├── kernel-tuning/       # sysctl + cmdline + io_uring   (conjunto system)
│   ├── hugepages/           # THP + huge pages estáticas    (conjunto system)
│   ├── governor/            # scaling_governor=performance (conjunto system)
│   └── openblas-threads/    # OPENBLAS_NUM_THREADS=1       (conjunto portable)
└── tests/
    ├── smoke-test.sh       # Testes rápidos pós-build
    ├── test-families.sh    # Casamento CPU → família (corpus; sem hardware)
    └── families-matrix.txt # ~60 modelos reais → família esperada
```

---

## 5. Onde encontrar cada coisa

| Preciso de...                          | Vá para...                                   |
|----------------------------------------|----------------------------------------------|
| Ver o que está feito/planejado         | `docs/ROADMAP.md`                            |
| Entender a arquitetura e os fluxos     | `docs/ARCHITECTURE.md`                       |
| **Entender o projeto POR DENTRO (mantenedor)** | **`README.technical.md`**            |
| Saber o estado atual + próxima ação    | **`docs/STATE.md`**                          |
| Detalhes de CPU/RAM/disco              | `docs/HARDWARE.md`                           |
| Entender uma otimização específica     | `docs/TUNING.md`                             |
| Resolver um problema                   | `docs/TROUBLESHOOTING.md`                    |
| **Saber/testar uma otimização específica** | **`mods/`**, **`docs/MODS.md`**   |
| **Entender as famílias de CPU / adicionar uma** | **`families/README.md`**, **`docs/FAMILIES.md`** |
| **Testar o casamento CPU → família sem ter o hardware** | **`tests/test-families.sh`**, **`tests/families-matrix.txt`** |
| **Usar uma GPU (opcional, explícito)** | **`docs/GPU.md`**, `bash llama-build.sh --gpu-check` |
| **Aprender o projeto do zero (passo a passo explicado)** | **`docs/TUTORIAL.md`**        |
| Como o CI compila/valida o sistema     | `.github/workflows/`, `docs/CI.md`, `Makefile` |
| **Testar em hardware e registrar resultados** | **`docs/VALIDATION.md`**              |
| **Gerar a ISO de instalação (entregável final)** | **`iso/build-iso.sh`**, **`docs/ISO.md`** |
| **Validar a ISO (conteúdo, sem bootar)** | **`iso/verify-iso.sh`**, `docs/ISO.md` § 4.6 |
| **Testar a ISO de verdade (boot em VM)** | **`iso/test-vm.sh`**, `docs/VALIDATION.md` Bloco M |
| **Entender a variante Ubuntu (autoinstall)** | **`iso/autoinstall/autoinstall.yaml`**, **`docs/ISO.md`** § 4.5 |
| **Retomar/continuar depois de um tempo parado** | **`docs/JOURNAL.md`** (§ 1 retomada, § 5 threads abertas) |
| Scripts principais                     | `build.sh`, `detect-hardware.sh`, `llama-build.sh` |
| Famílias de CPU (ISA/march)            | `families/`                                  |
| Papel: inferência                      | `roles/inference/`                           |
| Papel: build/registry/Gitea            | `roles/builder/`                             |
| Modificações portáveis                 | `mods/`                                      |
| Testes                                 | `tests/smoke-test.sh`                        |

---

## 6. Regras para IAs que trabalham neste projeto

Estas regras são **obrigatórias**:

1. **SEMPRE** ler `docs/STATE.md` **antes** de começar qualquer tarefa.
2. **SEMPRE** atualizar `docs/STATE.md` **ao terminar** uma tarefa
   (incluindo a seção "Próxima ação imediata").
3. **SEMPRE** atualizar `docs/ROADMAP.md` se mover algo entre
   Concluído/Em Progresso/Planejado.
4. **NUNCA** remover código sem explicar o porquê em `docs/ARCHITECTURE.md`.
5. **SEMPRE** testar em VM antes de sugerir mudanças de kernel.
6. **SEMPRE** deixar explícito o que **não** foi testado.
7. Todo script Bash: `set -euo pipefail`, logs com timestamp
   (`INFO/WARN/ERROR`), idempotência, `--dry-run` e confirmação antes de
   comandos destrutivos (salvo `--yes`).
   *Exceção única:* scripts POSIX `sh` que rodam **dentro do instalador**
   (caso de `iso/preseed/late-command.sh` — o `/bin/sh` do debian-installer é
   dash, que não tem `pipefail`) usam `set -eu`. Isso é verificado pelo CI.
8. Toda verificação de ISA deve consultar `/proc/cpuinfo` **em tempo de
   execução** — nunca assumir que uma flag existe.
9. **OBRIGATÓRIO:** ao **concluir um marco** (ex.: um perfil validado em
   hardware) ou **publicar uma versão (release)**, é obrigatório
   **criar/atualizar o tutorial explicado** em `docs/TUTORIAL.md`. O
   tutorial deve cobrir o fluxo completo **do zero** (preparar o sistema →
   aplicar → usar → medir), explicando **o que** cada passo faz e **por quê**,
   em linguagem didática. Não é um documento "de uma vez só": evolui a cada
   marco. O estado do tutorial deve ser refletido em `docs/STATE.md`.
10. **NUNCA** declarar um marco/versão "concluído" sem que o
    `docs/TUTORIAL.md` correspondente esteja atualizado e coerente com o
    estado real (incluindo o que **não** foi testado).
11. **ANTES** de abrir um Pull Request, rodar `make ci` localmente e garantir
    o CI verde (workflow `validate`). Nunca faça merge com CI vermelho.
    Se você alterar os jobs, atualize `docs/CI.md`.
12. **NUNCA** escreva `-mavx512*` / `GGML_AVX512=ON` **fixo** em código,
    script ou imagem. Mas **AVX-512 não é proibido para sempre**: ele é
    decidido pela `FAMILY_AVX512_POLICY` (`never` | `optin` | `auto`) do
    `family.conf`, sempre com verificação em runtime e opt-in explícito
    (`--allow-avx512`). Máquinas com AVX-512/AMX (Skylake-SP, Zen 5, futuras)
    são suportadas — via família, nunca por flag hardcoded. Em containers,
    `GGML_NATIVE` deve permanecer `OFF` (dentro do Docker o CMake detectaria a
    CPU do runner de CI, não a do alvo).
12-b. **Padrão de build = portátil, não nativo.** O default do `llama-build.sh`
    é `GGML_NATIVE=OFF` + flags explícitas da família. Em cross-build (CI, para
    OUTRA máquina) use `--assume-family-isa`: sem isso, um runner com AVX-512
    gera binário que sofre `SIGILL` no alvo.
12-c. **GPU é opcional e SEMPRE explícita.** O projeto é de inferência 100% em
    CPU; nenhum script liga backend de GPU por conta própria (não existe
    `--gpu auto`). O caminho é `llama-build.sh --gpu <cuda|rocm|vulkan|sycl|metal>`
    (`--gpu-check` só relata). Quem usar precisa dos avisos de
    [`docs/GPU.md`](docs/GPU.md): com GPU, o tuning de CPU passa a ser
    secundário e os números de `docs/STATE.md` **não valem**. O build registra o
    backend em `AI-CPU-OS-BUILD.txt` para ninguém comparar medições
    incomparáveis. **Nenhum backend de GPU foi compilado ou testado por este
    projeto** — não declare suporte a GPU.
13. **A ISO é o entregável final e define "terminado".** Qualquer trabalho deve
    manter funcional o caminho `iso/build-iso.sh` → instalação → primeiro boot.
    Se você mudar `build.sh`, `detect-hardware.sh`, as famílias, os papéis ou o
    `docker/`, **verifique se a ISO continua coerente** (o `late-command.sh`
    copia o projeto inteiro; o `firstboot.sh` o executa). Ao mexer na ISO,
    atualize **`docs/ISO.md`** e o **Bloco M** de `docs/VALIDATION.md`.
    **Base padrão = Ubuntu Server (autoinstall); Debian (preseed) é o caminho
    legado.** Mudou um template? Rode `make iso-yaml` — o autoteste substitui os
    marcadores e valida o `autoinstall.yaml` resultante com `yamllint` (o
    template isolado NÃO é YAML válido: `@` é reservado).
    **"Terminado" exige DUAS provas distintas**, e não confunda uma com a outra:
    `iso/verify-iso.sh` prova o **conteúdo** (não boota); `iso/test-vm.sh` prova
    o **comportamento** (boota, instala e aplica no 1º boot). Nenhuma delas
    substitui a outra.
    ⚠️ Nunca declare a ISO pronta sem tê-la **bootado e instalado** em VM.
13-b. **A ISO deve ser AIR-GAPPED, e o llama.cpp é compilado no 1º boot**
    (decisões firmadas; ver `docs/ISO.md` § 3.1). Consequências obrigatórias:
    - **Nunca** embutir binário pré-compilado do llama.cpp como atalho: exigiria
      uma ISO por família e reintroduziria o risco de portabilidade (`SIGILL`).
      Compilar no alvo é o que garante o `-march` correto da família detectada.
      (Há guardas no CI contra `--prebuilt` e contra `COPY build/bin`.)
    - **Nenhum passo pode exigir rede** na instalação ou no 1º boot. Tudo que
      fosse baixado tem de estar na mídia, e as três peças já estão:
      **fonte do llama.cpp** (`--iso-source`, o passo mais demorado do 1º boot),
      **modelo** (`--iso-model`, que leva o `.gguf` a `/opt/models`) e
      **toolchain + pacotes** (`--iso-repo`, repositório apt local em `/apt-repo`).
      A rede é usada **só na máquina que GERA a ISO**.
    - O repositório local entra como fonte **EXTRA**, nunca como `primary`: o
      sistema instalado tem de nascer apontando para o arquivo oficial, e um
      repositório incompleto deve **degradar** (usar rede, se houver) em vez de
      abortar a instalação. A linha `file:///cdrom/...` é removida do alvo no
      `late-command.sh`.
    - A corrente `--iso-source` → `/llama-src.tar.gz` → `LLAMA_SRC`
      (`.iso-config`) → `AI_LLAMA_SOURCE` → `llama-build.sh --source` **não pode
      quebrar em nenhum elo**: se quebrar, o 1º boot volta a clonar o llama.cpp e
      o modo de falha é silencioso. Cada elo tem guarda no CI.
    - O `llama-build.sh` **precisa** continuar aceitando `--source <dir|tar.gz>`
      (offline, sem rede e sem `git`); o papel `inference`, `--model-file`/
      `AI_MODEL_FILE`; e o `build.sh`, `--model-file`/`--llama-source` (porque
      `sudo` limpa o ambiente). Há guarda no CI para todos.
    - Se você adicionar qualquer download (script, papel, template), ele é uma
      **violação** desta regra: ou embuta na ISO, ou torne-o explicitamente
      opcional com aviso. Registre em `docs/ISO.md` § 3.1 (tabela de requisitos).
15. **Integridade da tríade `build.sh` → `detect-hardware.sh` → `families/`.**
    Ao adicionar família, papel ou mod, atualize **as três** superfícies que o CI
    cobra: a lista `required` de `.github/workflows/validate.yml`, a árvore do § 4
    deste arquivo e a tabela de `docs/MODS.md` / `docs/FAMILIES.md`.
14. **SEMPRE** registrar o fim da sessão em **`docs/JOURNAL.md`**: acrescente
    uma entrada (§ 4 — objetivo, feito, decisões, problemas, commits), atualize
    as **threads abertas** (§ 5) e as **armadilhas** (§ 6). Junto com a
    "Próxima ação imediata" do `STATE.md`, é o que garante que o trabalho possa
    ser retomado **sem perder nada**. Ver o template em `docs/JOURNAL.md` § 8.

---

## 7. Próxima ação imediata

👉 Ver a seção **"Próxima ação imediata"** em
[`docs/STATE.md`](docs/STATE.md).

---

## 8. Última atualização

- **Data:** 2026-10-12
- **O que mudou:** **O repositório apt também vai na mídia** (orçamento de 8 GB
  acordado). `--iso-repo auto|<dir>|none` resolve o **fecho de dependências** dos
  pacotes que o 1º boot precisa, baixa os `.deb`, gera o índice com `dpkg-deb`
  (**sem `dpkg-dev`**) e os embute em `/apt-repo`. A fonte entra como **extra**
  (seção `sources` do curtin no Ubuntu; `apt-setup/local0/*` no Debian) para o
  `primary` continuar sendo o arquivo oficial — o alvo nasce com `apt` normal, e
  um repositório incompleto degrada em vez de abortar. O build **recusa**
  repositório de outra release. Com isso os 5 itens do § 3.1 do `docs/ISO.md`
  estão implementados; **falta só o item 2** (`firstboot.sh` usar `--source`),
  que é o que ainda faz o 1º boot precisar de rede para clonar o llama.cpp.
  Prova real feita: o **`apt` do sistema aceitou** um repositório montado pelo
  código do projeto e resolveu dependência; o `verify-iso.sh` reprova os 5 modos
  de falha testados. **Nenhuma ISO gerada; nenhum boot real.**
- **Data anterior:** 2026-10-12 — **O modelo `.gguf` vai na mídia** (resposta à dúvida em
  aberto): ~1 GB de ISO é preço justo por uma mídia que se basta. Implementado
  `--iso-model auto|<caminho>|none` no `iso/build-iso.sh` (recusa `.gguf`
  inválido — magic `GGUF` — **antes** de montar a ISO), a cópia para
  `/opt/models` no `late-command.sh` (`MODEL_FILE` no `.iso-config`), o repasse
  no `firstboot.sh` (`AI_MODEL_FILE`) e **`--model-file`** no papel `inference`
  (instala um modelo local sem rede). O `iso/verify-iso.sh` confere a corrente
  toda e reprova modelo inválido/pequeno; guardas novos no CI, incluindo
  **negativos** (proibido `--prebuilt` e `COPY build/bin`).
  **A ISO ainda exige rede no 1º boot** para o toolchain e o clone do llama.cpp —
  o repositório apt local segue como o item mais pesado em aberto.
- **Data anterior:** 2026-10-12 — **Decisões firmadas sobre a ISO (Regra 13-b):
  air-gapped e compilar no 1º boot.** A ISO **deve funcionar sem internet** e o llama.cpp é
  **compilado no alvo** — nunca um binário pré-compilado (exigiria uma ISO por
  família e reintroduziria o risco de `SIGILL`). Consequência prática: nenhum
  download novo pode entrar em script/papel/template sem ser embutido na mídia
  ou explicitamente opcional. Plano completo com o estado de cada um dos 6
  requisitos em `docs/ISO.md` § 3.1. **Item 1 implementado:**
  `llama-build.sh --source <dir|tar.gz>` — compila de um fonte **local**, sem
  rede e sem `git`, registrando a origem (e `Rede: não usada`) no
  `AI-CPU-OS-BUILD.txt`; guarda no CI. **A ISO ainda exige rede no 1º boot** —
  os itens 2–5 são plano. Nova dúvida registrada: o modelo `.gguf` vai na mídia?
- **Data anterior:** 2026-10-12 — **Documentação separada por público.** `README.md` foi
  reescrito para o **usuário final** (explicado do zero: serve para mim?, o que
  muda na minha máquina, instalação em 5 passos, uso diário, como medir, como
  desfazer, FAQ) e criado o **`README.technical.md`** — manual do **mantenedor**
  (modelo mental das três camadas, mapa do repo, contratos/invariantes, receitas
  de "como estender", o que cada teste prova, CI por dentro, playbook de
  depuração com os bugs reais, status de validação e glossário). Regra derivada:
  **usuário → `README.md`; mantenedor → `README.technical.md`; regras → este
  arquivo; "o que é fato hoje" → `docs/STATE.md`.** Corrigido de passagem um bug
  real: o `build-llama.yml` ainda usava `matrix.profile` (removido na
  refatoração) no nome do artefato — o upload falharia.
- **Data anterior:** 2026-10-12 — **Ferramentas de validação da ISO.** Criados
  `iso/verify-iso.sh` (confere o **conteúdo** da ISO — config, projeto embutido,
  marcadores, YAML, entrada de boot, Volume ID — com modo `--dir` que dispensa
  `xorriso`, o que o torna testável no CI) e `iso/test-vm.sh` (boota a ISO em
  qemu, espera a instalação e o primeiro boot por **marcadores no console
  serial**). Nova flag `--serial-console` no build (console ttyS0 na ISO **e** no
  sistema instalado) e o build agora **verifica a ISO ao final**. `make
  iso-yaml` roda o verificador sobre uma árvore real **com teste negativo**
  (reprovar quando falta a config). Novos alvos `make iso-verify` e `make
  iso-vm`. `docs/ISO.md` § 4.6 e Bloco M distro-aware. **Nenhuma ISO gerada;
  `test-vm.sh` nunca executado (sem qemu no ambiente).**
- **Data anterior:** 2026-10-12 — **ISO em base Ubuntu Server
  (autoinstall/Subiquity).** `--distro ubuntu` passou a ser o padrão
  (Debian/preseed segue como legado), com a config em
  `iso/autoinstall/autoinstall.yaml` na raiz da ISO e remontagem por `xorriso
  -indev/-outdev -map` (setores de boot da ISO oficial preservados — sem
  `mtools`/`isohdpfx.bin`). O `late-command.sh` passou a ser compartilhado pelos
  dois instaladores (`AI_CURTIN=1`) e a ISO grava **papel + família** (não mais
  "perfil"). Novo autoteste de templates (`--check-templates` / `make iso-yaml`)
  validando o `autoinstall.yaml` substituído com `yamllint`, rodando no CI.
  Docs: `ISO.md` § 4.5 e Bloco M distro-aware; passada mecânica corrigindo
  caminhos quebrados em todo o `docs/`. **Nenhuma ISO gerada/bootada.**
- **Data anterior:** 2026-10-12 — **Refatoração para FAMÍLIAS de CPU + PAPÉIS +
  MODS.** Suporte deixou de ser "um processador por perfil" e passou a ser por
  **família de microarquitetura com herança** (`families/`, 8 famílias, AVX-512
  por política), com **papéis** separados do hardware (`roles/inference`,
  `roles/builder`) e **mods portáveis** aplicáveis/reversíveis em qualquer
  sistema (`mods/`, com `apply`/`revert`/`test`). O build do llama.cpp virou um
  script único dirigido pela família (`llama-build.sh`), com padrão **portátil**
  (`GGML_NATIVE=OFF`) e modo `--assume-family-isa` para cross-build. Sistema de
  referência passou a **Ubuntu Server**. CPU do Sistema A: E5-2680 v4
  (Broadwell-EP, 14c/28t). Comentários do README aplicados e removidos.
- **Data anterior:** 2026-10-07 — Criado **`docs/JOURNAL.md`** (diário de
  sessões + continuidade) e a seção "Retomada rápida"; nova **Regra 14**.
  Unificado o hardware: o Xeon é **quad channel**.
- **Data anterior:** 2026-10-07 — Registrado o **entregável final = ISO de
  instalação** (meta no § 1, regra 13) e criada a implementação em `iso/`.
- **Data anterior:** 2026-10-07 — Criado `docs/VALIDATION.md` — protocolo
  preenchível de testes em hardware (blocos A–L).
- **Data anterior:** 2026-10-07 — Adicionada a esteira de CI/CD
  (`.github/workflows/`: `validate`, `build-llama`, `container`), `Makefile`,
  `docker/` e `docs/CI.md`. Novas regras 11 e 12.
- **Data anterior:** 2026-10-07 — Criação do `docs/TUTORIAL.md` e da diretriz
  de tutorial obrigatório por marco/versão.
- **Data anterior:** 2026-10-07 — Criação inicial do repositório (todos os
  scripts, perfis e documentação da versão `0.1.0-alpha`).
