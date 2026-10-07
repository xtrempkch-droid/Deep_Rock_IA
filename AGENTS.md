# AGENTS.md — Memória do projeto ai-cpu-os

> **LEIA ESTE ARQUIVO ANTES DE QUALQUER COISA.**
> Este é o ponto de entrada para qualquer IA (ou humano) que retome o projeto
> após um tempo parado. Ele resume o propósito, a filosofia, o hardware, a
> estrutura e — o mais importante — **as regras de trabalho**.

---

## 1. Propósito do projeto

O `ai-cpu-os` transforma um Debian/Ubuntu minimal em um sistema operacional
afinado para **inferência de LLMs inteiramente em CPU**. Ele existe porque,
sem GPU, o gargalo real deixa de ser FLOPs e passa a ser **banda de memória,
latência de memória e escalonamento**. Um sistema "genérico" desperdiça ciclos
em page faults, migração de páginas, C-states profundos e swappiness agressivo
— desperdício que, somado, custa dezenas de por cento de tokens/s.

O projeto foi desenhado em torno de **dois sistemas reais**: um **servidor de
inferência** baseado em Intel Xeon E5-2678 v3 (perfil `xeon`) e uma **máquina
de build** baseada em AMD Ryzen 5 3500X (perfil `ryzen`), que também serve um
registry Docker privado e um servidor Gitea.

Todo o sistema é gerado por **script** (`build.sh`), é **idempotente**, suporta
`--dry-run` e documenta *cada* otimização com a razão técnica de existir.

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

### Sistema A — Perfil `xeon` (Servidor de IA)
- **CPU:** Intel Xeon E5-2678 v3 — 12c/24t, Haswell-EP, **AVX2 apenas** (sem
  AVX-512, sem AMX).
- **Placa-mãe:** JGINYUE X99M-D3 (LGA2011-3, DDR3).
- **RAM:** 16 GB DDR3-1333, 4×4 GB, **dual channel**.
- **Disco:** SSD NVMe 256 GB.
- **GPU:** nenhuma (inferência 100% CPU).
- **Limitação conhecida:** modelos > 7B Q4 não cabem em 16 GB.

### Sistema B — Perfil `ryzen` (Build + Registry + Gitea)
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
├── AGENTS.md               # ← você está aqui (ponto de entrada)
├── LICENSE                 # MIT
├── Makefile                # Atalhos locais (make ci, lint, build-xeon, docker…)
├── build.sh                # Script principal (orquestra tudo)
├── detect-hardware.sh      # Detecção de CPU/RAM/canal/disco + escolha de perfil
├── .github/
│   ├── workflows/
│   │   ├── validate.yml    # Lint + dry-run + guarda-corpo das regras (push/PR)
│   │   ├── build-llama.yml # Compila o llama.cpp por perfil + Release (tags/manual)
│   │   └── container.yml   # Imagem de runtime no GHCR (portable / znver2)
│   ├── ISSUE_TEMPLATE/     # Templates de issue (bug / feature)
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── dependabot.yml      # Atualização de actions e da imagem base
├── docker/
│   ├── Dockerfile          # Runtime do llama.cpp (GGML_NATIVE=OFF — ver docs/CI.md)
│   └── docker-compose.example.yml
├── docs/
│   ├── ROADMAP.md          # Concluído / Em progresso / Planejado / Ideias
│   ├── ARCHITECTURE.md     # Diagramas, fluxos, decisões de design
│   ├── STATE.md            # Estado atual + métricas + PRÓXIMA AÇÃO
│   ├── HARDWARE.md         # Detalhes técnicos do hardware alvo
│   ├── TUNING.md           # Explicação de cada otimização
│   ├── TROUBLESHOOTING.md  # Problemas conhecidos e soluções
│   ├── CI.md               # Como o GitHub compila e valida o sistema
│   ├── TUTORIAL.md         # TUTORIAL explicado (obrigatório por marco/versão)
│   └── VALIDATION.md       # Protocolo de testes em hardware (preenchível)
├── profiles/
│   ├── xeon/               # Servidor de inferência
│   │   ├── install.sh      # Instala deps + llama.cpp + serviço
│   │   ├── llama-build.sh  # Compila llama.cpp com flags do Haswell-EP
│   │   ├── sysctl.conf     # Tuning sysctl do perfil
│   │   ├── shell-ia.py     # Shell-IA em Python (tools + sandbox)
│   │   └── ai-server.service # Unit systemd do llama-server
│   └── ryzen/              # Build + registry + Gitea
│       ├── install.sh      # Orquestra o perfil ryzen
│       ├── docker-setup.sh # Docker Engine + Compose
│       ├── registry-setup.sh # Registry privado localhost:5000
│       ├── gitea-compose.yml # Gitea via docker compose
│       ├── build-runner.sh # Build Docker + push p/ registry local
│       └── llama-build.sh  # Compila o llama.cpp com -march=znver2 (Zen 2)
├── common/
│   ├── kernel-tuning.sh    # sysctl + cmdline + io_uring
│   ├── hugepages.sh        # Transparent/static huge pages
│   └── governor.sh         # Governor performance
└── tests/
    └── smoke-test.sh       # Testes rápidos pós-build
```

---

## 5. Onde encontrar cada coisa

| Preciso de...                          | Vá para...                                   |
|----------------------------------------|----------------------------------------------|
| Ver o que está feito/planejado         | `docs/ROADMAP.md`                            |
| Entender a arquitetura e os fluxos     | `docs/ARCHITECTURE.md`                       |
| Saber o estado atual + próxima ação    | **`docs/STATE.md`**                          |
| Detalhes de CPU/RAM/disco              | `docs/HARDWARE.md`                           |
| Entender uma otimização específica     | `docs/TUNING.md`                             |
| Resolver um problema                   | `docs/TROUBLESHOOTING.md`                    |
| **Aprender o projeto do zero (passo a passo explicado)** | **`docs/TUTORIAL.md`**        |
| Como o CI compila/valida o sistema     | `.github/workflows/`, `docs/CI.md`, `Makefile` |
| **Testar em hardware e registrar resultados** | **`docs/VALIDATION.md`**              |
| Scripts principais                     | `build.sh`, `detect-hardware.sh`             |
| Perfil Xeon (inferência)               | `profiles/xeon/`                             |
| Perfil Ryzen (build/registry/Gitea)    | `profiles/ryzen/`                            |
| Tuning comum a ambos                   | `common/`                                    |
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
12. **NUNCA** habilitar AVX-512 (`-mavx512*`, `GGML_AVX512=ON`) em código,
    script ou imagem: nenhum dos dois hardwares alvo suporta (o build faz
    `SIGILL`). Em containers, `GGML_NATIVE` deve permanecer `OFF` — dentro do
    Docker o CMake detectaria a CPU do runner de CI, não a do alvo.

---

## 7. Próxima ação imediata

👉 Ver a seção **"Próxima ação imediata"** em
[`docs/STATE.md`](docs/STATE.md).

---

## 8. Última atualização

- **Data:** 2026-10-07
- **O que mudou:** Criado **`docs/VALIDATION.md`** — protocolo preenchível de
  testes em hardware (blocos A–L), para executar no Xeon/Ryzen e trazer os
  resultados depois (consolidados em `docs/STATE.md` e `docs/TUTORIAL.md`).
  Ligado no AGENTS/README/TUTORIAL/ROADMAP/Makefile e verificado pelo job
  `project-rules` do CI.
- **Data anterior:** 2026-10-07 — Adicionada a esteira de CI/CD
  (`.github/workflows/`: `validate`, `build-llama`, `container`), `Makefile`,
  `docker/` e `docs/CI.md`. Novas regras 11 e 12.
- **Data anterior:** 2026-10-07 — Criação do `docs/TUTORIAL.md` e da diretriz
  de tutorial obrigatório por marco/versão.
- **Data anterior:** 2026-10-07 — Criação inicial do repositório (todos os
  scripts, perfis e documentação da versão `0.1.0-alpha`).
