# JOURNAL — Diário de trabalho e continuidade

> **Para que serve:** garantir que **qualquer sessão futura (ou você, depois de
> esquecer) retome o projeto sem perder nada.** Enquanto o `docs/STATE.md` diz
> *onde estamos*, este diário diz *como chegamos aqui*, *o que ficou em aberto*
> e *quais armadilhas já foram pisadas*.
>
> **Quando ler:** logo depois do [`AGENTS.md`](../AGENTS.md) e do
> [`docs/STATE.md`](STATE.md).
> **Quando escrever:** **ao fim de TODA sessão de trabalho** (ver § 8).
>
> **Última entrada:** sessão **#17** (2026-10-12) — ISO fechada no código: a **fonte do llama.cpp** também vai na mídia; checklist de fechamento no `ISO.md` § 9.

---

## 1. ⏱️ Retomada em 5 minutos

Se você só tem 5 minutos, faça exatamente isto:

```bash
# 1. Ler o essencial (nesta ordem)
less AGENTS.md            # propósito + regras
less docs/STATE.md        # onde estamos + "Próxima ação imediata" (§ 6)
less docs/JOURNAL.md      # este arquivo: § 5 (threads abertas) e § 6 (armadilhas)
# (para MANTER o projeto, não só usar: less README.technical.md)

# 2. Sincronizar e conferir a saúde do repositório
cd /home/juju/Deep_Rock_IA
git pull --ff-only        # ou: git fetch && git status
make ci                   # lint + docs + dry-run (igual ao CI 'validate')
git log --oneline -12     # os últimos passos dados

# 3. Ver o que o CI já provou (verde) e o que NÃO foi provado
#    - validate      ✅ verde
#    - build-llama   ✅ verde (compila e roda de verdade)
#    - container     ✅ verde (imagem no GHCR)
#    - iso           ⚠️ NUNCA executado
```

**Depois disso**, vá para a "Próxima ação imediata" em `docs/STATE.md` § 6.

> ⚠️ **Regra de ouro da retomada:** não confie na memória — confie no
> `STATE.md` § 6. Ele é reescrito ao fim de cada sessão justamente para isto.

---

## 2. 🧰 Inventário do ambiente de desenvolvimento

Isto evita perder tempo (re)descobrindo o que já se sabe sobre **esta** máquina.

| Item | Situação | Consequência |
|------|----------|--------------|
| Máquina | Notebook AMD A4-3300M, 2 núcleos, Ubuntu 25.10 | **Compilar o llama.cpp localmente é inviável** (~40 min+, testado até 32 min sem terminar). Use o CI. |
| `shellcheck` | ✅ em `~/.local/bin` (instalado via `pip install --user shellcheck-py`) | `make shellcheck` funciona |
| `yamllint` | ✅ (instalado via `pip install --user yamllint`) | `make yaml` funciona |
| `jq`, `make`, `git`, `docker` | ✅ | ok |
| `xorriso`, `mtools` | ❌ **ausentes** | **Não é possível gerar a ISO aqui.** Use `make iso-dry-run` (só simula). |
| `gh` (GitHub CLI) | ❌ ausente e sem token | Não dá para disparar/consultar workflows por CLI. Use o **navegador** ou a **API pública**. |
| API do GitHub (sem token) | 60 req/h | **Nunca faça polling agressivo** — ativa a "abuse detection" e bloqueia por minutos. Ver § 6. |

### Como o CI é verificado daqui (sem `gh`)

- **Navegador** (preferido): abrir `https://github.com/xtrempkch-droid/Deep_Rock_IA/actions`
  e ler os rótulos (`completed successfully` / `failed`).
- **API pública** (com moderação):
  ```bash
  curl -s -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/xtrempkch-droid/Deep_Rock_IA/actions/runs?per_page=5" \
    | jq -r '.workflow_runs[] | "\(.name) \(.status)/\(.conclusion // "…")"'
  ```
- **Mensagem de erro de um job** (os logs exigem login, mas as *annotations* não):
  ```bash
  curl -s -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/xtrempkch-droid/Deep_Rock_IA/check-runs/<id>/annotations" \
    | jq -r '.[].message'
  ```

---

## 3. 📖 Contexto mínimo do projeto (se você esqueceu tudo)

| Pergunta | Resposta curta | Onde aprofundar |
|----------|----------------|-----------------|
| O que é isto? | Um SO Debian afinado para **LLM 100% em CPU** | `README.md` |
| Qual é o **fim** do projeto? | 🎯 Uma **ISO de instalação** com tudo embutido | `docs/ISO.md` |
| Por que CPU, se é lento? | Os dois hardwares alvo **não têm GPU utilizável** | `docs/HARDWARE.md` |
| Qual é o gargalo real? | **Banda de memória**, não FLOPs | `docs/TUNING.md` § 0 |
| Quem são os alvos? | Xeon E5-2680 v4 (`intel-broadwell`) e Ryzen 5 3500X (`amd-zen2`) | `docs/HARDWARE.md` |
| O que **nunca** fazer? | AVX-512, usar a RX 580 p/ compute, `GGML_NATIVE=ON` no Docker | `AGENTS.md` Regras 12 |

### Regras que mais quebram o CI (e a paciência)

1. Todo `.sh` em **modo estrito** — bash: `set -euo pipefail`; POSIX sh: `set -eu`.
2. `docs/TUTORIAL.md` **obrigatório** a cada marco/versão.
3. Nunca remover código sem registrar o motivo em `docs/ARCHITECTURE.md`.
4. Nunca habilitar AVX-512 em lugar nenhum.

---

## 4. 🗓️ Diário de sessões (ordem cronológica)

> Cada sessão registra: **objetivo → o que foi feito → decisões → problemas →
> commits**. Este é o "filme"; o `STATE.md` é a "foto" atual.

### Sessão #1 — 2026-10-07 · Criação do projeto

- **Objetivo:** criar o repositório `ai-cpu-os` completo a partir da
  especificação (SO para LLM em CPU, dois perfis).
- **Feito:** 24 arquivos — `README`, `AGENTS`, `LICENSE`, `build.sh`,
  `detect-hardware.sh`, `common/` (3), `roles/inference/` (5),
  `roles/builder/` (5), `tests/smoke-test.sh` e 6 docs.
- **Decisões:** Bash puro (sem Ansible) para zero dependências no alvo;
  perfis separados por hardware (não "config média"); `--dry-run` em tudo.
- **Verificado:** `bash -n` em 12 scripts, `py_compile`, YAML, `--dry-run`.
- **Commits:** `6a4d4aa` (inicial), `6a8cbd5`.

### Sessão #2 — 2026-10-07 · Tutorial + diretriz

- **Objetivo:** atender o pedido de um **tutorial explicado** obrigatório.
- **Feito:** `docs/TUTORIAL.md` (13 seções, didático) + **Regras 9 e 10** no
  `AGENTS.md` (tutorial obrigatório por marco/versão).
- **Decisões:** a tag `v0.1.0-alpha` foi **movida** para incluir o tutorial —
  a própria regra diz que nenhuma versão é válida sem ele.
- **Commits:** `1015dbe` (+ `510ff57`, feito por você pelo site: "quad-channel").

### Sessão #3 — 2026-10-07 · CI/CD (o GitHub compila o sistema)

- **Objetivo:** fazer o GitHub **compilar e validar** o sistema.
- **Feito:** `validate.yml`, `build-llama.yml`, `container.yml`,
  `docker/Dockerfile`, `Makefile`, templates de issue/PR, Dependabot,
  `docs/CI.md`, badges.
- **Decisões:** `build-llama` só em manual/tag/semanal (build é caro);
  `container` publica **duas** variantes (`portable` e `znver2`);
  `GGML_NATIVE=OFF` **obrigatório** no Docker.
- **Problemas:** shellcheck (`SC2046`/`SC2034`/`SC2155`) — todos corrigidos.
- **Commits:** `6da0c35`.

### Sessão #4 — 2026-10-07 · 🐛 Bug 1: `pkg-config`

- **Objetivo:** investigar uma falha do CI.
- **Achado:** o backend BLAS do ggml usa `find_package(PkgConfig)` e o
  `libopenblas-dev` **não** traz o `pkg-config` → o CMake aborta.
  **Este bug também quebraria o build nativo** (`llama-build.sh`/`install.sh`).
- **Corrigido em 4 lugares:** Dockerfile, `llama-build.sh`, `install.sh`,
  workflow. Documentado em `docs/CI.md` § 8.1 e `TROUBLESHOOTING.md`.
- **Lição:** *lint verde ≠ build comprovado.*
- **Commits:** `4cde4bb`, `af4f599`.

### Sessão #5 — 2026-10-07 · 🐛 Bug 2: `exit 127` (RPATH) + v0.2.0

- **Objetivo:** entender por que o container falhava.
- **Achado:** o llama.cpp compila **bibliotecas compartilhadas** e os binários
  carregam **RPATH absoluto `/src/build/bin`**. O `COPY build/bin` movia os
  binários sem corrigir o RPATH → o loader não achava `libllama.so` → **127**.
  Só apareceu no **PR** porque o passo de smoke só roda em `pull_request`.
- **Corrigido:** `cmake --install` + `-DCMAKE_INSTALL_RPATH=/usr/local/lib` +
  `ldconfig` + **auto-verificação dentro do Dockerfile**.
- **Commits:** `b5d86bc`, `566583c`, `8d12dab`.
- **Versão:** tag **`v0.2.0`** publicada (marco de CI/CD) + Release com os
  `.tar.gz` dos dois perfis. ⚠️ **Sem validação de hardware nesta versão.**

### Sessão #6 — 2026-10-07 · Protocolo de validação

- **Objetivo:** documentar **todos** os testes para você executar e trazer os
  resultados depois.
- **Feito:** `docs/VALIDATION.md` — blocos 0 + A–L, com comandos exatos, campos
  `_(preencher)_`, critérios de sucesso e um **template de relatório**.
- **Commits:** `a9632bb`.

### Sessão #7 — 2026-10-07 · 🎯 A ISO (entregável final)

- **Objetivo:** registrar e implementar que **o projeto termina com uma ISO de
  instalação** já com tudo embutido.
- **Feito:** meta oficial no `AGENTS.md` § 1 + **Regra 13**; `iso/build-iso.sh`
  (remaster da Debian netinst), `iso/preseed/*` (preseed + `late-command` +
  serviço de 1º boot), `docs/ISO.md`, workflow `iso.yml`, **Bloco M** no
  protocolo de validação.
- **Decisão central:** aplicar no **primeiro boot**, não no `late_command` —
  o systemd do alvo não roda na instalação, o kernel é outro, o hardware só é
  visto por completo depois, e assim a **mesma ISO** serve para Xeon e Ryzen
  (perfil `auto`).
- **Problema corrigido de passagem:** o guarda do CI exigia
  `set -euo pipefail` em **todo** `.sh`, mas o `late-command.sh` roda no
  **dash** do instalador (sem `pipefail`) → refinado para aceitar `set -eu`.
- **Commits:** `4a45583`.
- **⚠️ Não validado:** a ISO **nunca foi construída nem bootada** (sem
  `xorriso` nesta máquina).

### Sessão #8 — 2026-10-07 · Documentação de continuidade

- **Objetivo:** garantir que tudo esteja documentado para retomar sem perder nada.
- **Feito:** este `docs/JOURNAL.md` + seção "Retomada rápida" no `AGENTS.md` +
  **Regra 14** (registrar o fim de cada sessão) + guardas de CI para os dois.
- **Bônus (inconsistência corrigida):** o Xeon estava descrito como "dual
  channel" em `AGENTS.md`/`HARDWARE.md` mas como "quad" no `README.md`.
  Unificado em **quad channel** e `detect-hardware.sh` passou a **contar os
  canais reais** (`Bank Locator`) em vez de reportar sempre "dual".
- **Problemas:** uma edição por bloco (sem incluir a linha seguinte) **juntou
  duas linhas** da árvore do `AGENTS.md` — detectado na revisão e corrigido.
  Virou armadilha registrada em § 6.
- **Verificado:** `make validate` (lint, shellcheck, yamllint, iso-lint, docs),
  `detect-hardware.sh` re-executado, guardas simulados. **Não verificado:**
  a contagem `quad` real (precisa de `dmidecode` no Xeon — Bloco B).
- **Commits:** `git log -1 --format=%h` → *o commit desta sessão* (registrado logo abaixo).

---

### Sessão #9 — 2026-10-12 · 🧬 Refatoração: FAMÍLIAS + PAPÉIS + MODS

**Objetivo (pedido do usuário, verbatim):** *"deixar muito fechado a somente um
processador é muito desperdício de tempo, vamos abranger famílias […] separe o
suporte por família assim cada família tem sua modificação específica. o sistema
operacional vamos começar com Ubuntu e se forem modificações que podem ser
feitas por script então crie uma seção onde qualquer um possa aplicar e testar
em seu sistema operacional"*.

**Feito:**

1. **`families/`** — 8 famílias com **herança** (`intel-haswell` →
   `intel-broadwell` → `intel-skylake-avx512`; `amd-zen1` → `zen2` → `zen3` →
   `zen4`; `generic` como fallback), `_base/family.conf`, `resolve.sh`
   (`pick_family`/`load_family`/`compute_isa`) e política de AVX-512
   (`never`/`optin`/`auto`).
2. **`roles/`** — `roles/inference` → `roles/inference`, `roles/builder` →
   `roles/builder` (via `git mv`, preservando histórico).
3. **`mods/`** — `mods/*/*.sh` → `mods/{kernel-tuning,hugepages,governor}/`,
   cada uma com `mod.conf` + `apply.sh` + `revert.sh`, mais a mod nova
   `openblas-threads`. Motor `mods/apply.sh` com
   `list/info/check/apply/revert/test` e conjuntos `system`/`portable`.
4. **`llama-build.sh` na raiz** — build **único** dirigido pela família,
   substituindo os dois scripts por perfil.
5. `build.sh` agora usa `--role`/`--family` (com `--profile` como alias
   obsoleto), `detect-hardware.sh` emite `FAMILY=` e `ROLE=`.
6. SO de referência passou a **Ubuntu Server** (README, AGENTS.md, STATE).
7. Comentários `#` deixados pelo usuário no README **aplicados e removidos**.

**Decisões:**

- **Herança** em vez de duplicação: um ajuste em `intel-haswell` vale também
  para Broadwell-EP e Skylake-SP.
- **Papel ≠ família:** ISA fica na família; software/serviço fica no papel. O
  build é compartilhado.
- **`--profile` mantido como alias** (`xeon`→`inference`, `ryzen`→`builder`)
  para não quebrar a ISO e os scripts já escritos.
- **“Mod” = aplicável + reversível + testável em container**, com fronteira
  explícita: o teste em container **não** prova efeito de sysctl/governor.

**Problemas encontrados e resolvidos:**

- 🐛 **Bug latente de portabilidade no CI (achado nesta sessão):** o
  `build-llama.yml` compilava com `GGML_NATIVE=ON` no *runner*. Um runner com
  AVX-512 geraria binário que sofre **SIGILL** nos alvos (E5 v3/v4 e Ryzen
  3500X têm só AVX2). Corrigido com `GGML_NATIVE=OFF` como padrão +
  `--assume-family-isa` no CI.
- `resolve.sh` declarava `FAMILIES_DIR` como `readonly`; ao ser carregado por
  `build.sh` (que já tinha essa variável) o script morria com
  *"readonly variable"*. Renomeado para `RESOLVE_FAMILIES_DIR`.
- `FAMILY_ISA_FINAL` saía como `-avx2 -fma -f16c` (ambíguo). Agora é explícito
  (`+avx2 -fma`) e as flags ausentes geram aviso (`FAMILY_ISA_MISSING`).
- `shellcheck -S warning`: `SC2034` em `ASSUME_YES`/`FAMILY_MATCH_REASON` —
  ajustado nos scripts novos.

**NÃO feito / não testado (importante):**

- A **ISO ainda é Debian**: a variante Ubuntu com autoinstall **não** foi
  escrita nem bootada. É a próxima ação (STATE § 6).
- **Nada foi validado em hardware real.** A resolução de família foi exercitada
  só com nomes de CPU simulados (o notebook de dev é um AMD A4-3300M → cai no
  `generic`).
- `docs/{HARDWARE,ARCHITECTURE,ROADMAP,TUTORIAL,VALIDATION}.md` ainda têm
  referências ao modelo antigo de perfis (pendência registrada abaixo).

**Commits desta sessão:** `8b6d57e` — `refactor!: suporte por FAMÍLIAS de CPU + papéis + mods portáveis`
  (e um commit de acompanhamento propagando o modelo de CPU E5-2680 v4 nos docs).

---

### Sessão #10 — 2026-10-12 · 🎯 ISO em base Ubuntu Server (autoinstall)

**Objetivo (pedido do usuário, verbatim):** *"vamos para o proximo passo"* —
ou seja, o passo registrado no `STATE.md` § 6 como "Passo 1": a ISO em base
**Ubuntu Server** com autoinstall.

**Feito:**

1. **`iso/autoinstall/autoinstall.yaml`** — nova config de instalação para o
   Subiquity, com locale/teclado/timezone, `identity` (usuário + hash),
   `ssh`, `storage` (layout `direct`, com `match.path` quando há `--disk`),
   `apt` determinístico, instalador congelado (`refresh-installer.update:
   false`, sem drivers/OEM/snaps) e `late-commands:` chamando o
   `late-command.sh` compartilhado.
2. **`iso/build-iso.sh` distro-aware** — `--distro ubuntu|debian` (**ubuntu
   como padrão**), `--role`/`--family` no lugar de `--profile` (que segue como
   alias obsoleto), `--hostname`, `--check-templates`.
3. **Caminho Ubuntu** — valida `casper/`, extrai apenas os `grub.cfg` (BIOS e
   UEFI), injeta uma entrada `ai-cpu-os-auto` com o parâmetro `autoinstall` e
   remonta por **`xorriso -indev/-outdev -map`**, preservando os setores de
   boot da ISO oficial (não precisa de `mtools` nem `isohdpfx.bin`).
4. **`late-command.sh` e `firstboot.sh` compartilhados** pelos dois
   instaladores: `in_target()` usa `in-target` (d-i) ou `curtin in-target --`
   (Subiquity, via `AI_CURTIN=1`); agora gravam `ROLE=`/`FAMILY=`/`DISTRO=` no
   `.iso-config` e chamam `build.sh --role … --family …`.
5. **Autoteste dos templates** (`--check-templates` / `make iso-yaml`) ligado
   ao `iso-lint` e, portanto, ao CI.
6. Docs: `docs/ISO.md` reescrito (§ 4.5 explica as 4 decisões do caminho
   Ubuntu), Bloco M de `VALIDATION.md` distro-aware, e uma passada mecânica
   corrigindo **caminhos quebrados** em toda a documentação
   (`profiles/xeon/…` → `roles/inference/…`, `common/*.sh` → `mods/*/*.sh`,
   `--profile xeon` → `--role inference`, etc.).

**Decisões (e por quê):**

- **`autoinstall.yaml` na mídia, não `nocloud`.** A doc do Subiquity permite
  os dois; o arquivo na raiz dispensa `#cloud-config`, a chave de topo
  `autoinstall:` (que só vale em 24.04) e o **escape do `;`** na cmdline do
  GRUB. Menos peças, menos modos de falha silenciosa.
- **Remontar com `-indev/-outdev -map`** em vez de extrair + `mkisofs`: os
  setores de boot (El Torito BIOS, imagem EFI, MBR híbrido) ficam idênticos
  aos do Ubuntu. Era o principal risco do caminho Ubuntu.
- **Um `late-command.sh` para os dois instaladores**, com o wrapper de
  `in-target` parametrizado — em vez de duplicar a lógica.
- **Tuning continua no primeiro boot.** O `autoinstall.yaml` só instala; quem
  detecta família/papel e aplica as mods é o `firstboot.sh`, onde o hardware é
  real.

**Problemas encontrados e resolvidos:**

- 🐛 **`HOSTNAME` colide com a variável interna do bash.** O script definia
  `HOSTNAME=""` no topo; renomeada para `SYS_HOSTNAME` (o token `@@HOSTNAME@@`
  do template ficou igual).
- 🐛 **O template do autoinstall não é YAML válido** enquanto tem
  `@@STORAGE_LAYOUT@@`: o `@` é indicador reservado do YAML, e o `yamllint`
  falhava (com razão). Solução: o autoteste `--check-templates` valida o
  arquivo **depois** da substituição — e isso ficou documentado no cabeçalho do
  template para não pegar o próximo desavisado.
- 🐛 **Lista de pacotes numa linha estourava 120 colunas** (133 com a lista
  padrão) e o `yamllint` reprovava. Trocada a sequência *flow* por uma
  sequência em **bloco** (`expand_packages_block`), que não tem limite de
  tamanho. **Foi o autoteste que pegou** — antes de qualquer ISO existir.
- `resolve.sh` é carregado por `source`; a variável `FAMILIES_DIR` já tinha sido
  renomeada para `RESOLVE_FAMILIES_DIR` na sessão #9 pelo mesmo motivo.
- **Ordem de execução no `main`**: `inject_project` precisa vir DEPOIS de
  `prepare_ubuntu`/`extract_iso_debian` (o destino depende do layout).

**NÃO feito / não testado (importante):**

- **Nenhuma ISO foi gerada, instalada ou bootada** — nem Ubuntu nem Debian.
  O ambiente de desenvolvimento não tem `xorriso`.
- O `grub.cfg` do Ubuntu **não foi inspecionado de verdade**: o patch é
  "appenda no fim", que funciona para o menu, mas só um boot real confirma
  (especialmente se o `EFI/boot/grub.cfg` só delegar ao `boot/grub/grub.cfg`).
- Nada validado em hardware real (blocos N e O de `VALIDATION.md`).
- `md5sum.txt` do Ubuntu é **removido** (não regenerado) — decisão registrada
  em `docs/ISO.md` § 6.

**Commits desta sessão:** `a1ed101` — `feat(iso): variante Ubuntu Server (autoinstall)`.

---

### Sessão #11 — 2026-10-12 · 🔍 Ferramentas de validação da ISO

**Objetivo (pedido do usuário, verbatim):** *"seria otimo essa validaçao"* — em
resposta à oferta de preparar "um script/roteiro de teste em VM com qemu +
verificação automática do autoinstall.yaml a partir da ISO gerada".

**Feito:**

1. **`iso/verify-iso.sh`** — verifica o **conteúdo** da ISO: config no lugar
   certo, projeto embutido (a mesma lista que o CI exige), templates presentes,
   nenhum `@@TOKEN@@` sobrando, `autoinstall.yaml` válido **e semanticamente
   coerente** (via PyYAML: version, hash de senha, layout de storage,
   late-commands com `AI_CURTIN=1`, shutdown), entrada de boot e Volume ID.
   Tem modo **`--dir`** que dispensa `xorriso` — é o que o torna testável.
2. **`iso/test-vm.sh`** — o teste que **boota**: cria o qcow2, sobe o qemu com
   `-display none -serial file:`, e **espera marcadores** no console serial em
   vez de olhar a tela (`[ai-cpu-os/iso-late] pós-instalação concluído` e
   `aplicação concluída com sucesso`). Timeout configurável, mostra o progresso,
   detecta falha explícita sem esperar o timeout, e limpa a VM no `trap`.
3. **`--serial-console`** no `build-iso.sh`: `console=ttyS0,115200` na entrada
   de boot da ISO **e** no sistema instalado (via ajuste de GRUB no
   late-command + `serial-getty@ttyS0`). Sem isso, um teste headless não vê
   nada do sistema instalado.
4. O build agora **verifica a ISO ao final** (`--no-verify` para pular).
5. `make iso-yaml` ganhou o **autoteste das ferramentas**: monta uma árvore com
   os templates **e o projeto reais**, roda o verificador sobre ela e — o ponto
   — roda um **teste negativo** (apaga o `autoinstall.yaml` e exige reprovação).
6. Alvos `make iso-verify` / `make iso-vm`, variáveis `ISO`/`ISO_ARGS`/`VM_ARGS`.
7. Docs: `docs/ISO.md` § 4.6 (as duas ferramentas, o que cada uma prova, os
   marcadores) e § 4.7 (dependências separadas por caminho), Bloco M do
   `VALIDATION.md` distro-aware e apontando para as ferramentas, `STATE` § 6
   com Passo 1.1/1.2, ROADMAP, este diário e a Regra 13 do `AGENTS.md`.

**Decisões (e por quê):**

- **Duas ferramentas, dois propósitos.** `verify-iso.sh` prova **conteúdo**;
  `test-vm.sh` prova **comportamento**. Misturá-las faria o usuário achar que
  "ISO verificada" significa "ISO que boota" — não significa.
- **`--dir` no verificador** para que ele seja exercitável sem `xorriso` (e,
  portanto, no CI). Sem isso, seria mais um script "escrito e nunca rodado".
- **Teste negativo no autoteste.** Um verificador que nunca reprova dá falsa
  segurança; o CI agora prova que ele **reprova** quando falta a config.
- **Marcadores no lugar de OCR/tela:** julgar por string no log serial é
  determinístico e não depende de resolução de vídeo.
- **`console=ttyS0` no sistema instalado** (e não só na ISO): era a única forma
  de o primeiro boot — que é onde o trabalho de verdade acontece — ficar
  observável num teste headless.

**Problemas encontrados e resolvidos:**

- 🐛 **Bug no próprio verificador**, pego pelo autoteste: a checagem de
  `ROLE`/`FAMILY` exigia encontrar `@@ROLE@@` no arquivo **já substituído** —
  isto é, exigia justamente o que a substituição remove. O autoteste detectou
  como `FAIL` na árvore boa e evitou um verificador que reprovaria toda ISO
  correta.
- `shellcheck SC2054` no array de argumentos do qemu (as vírgulas de
  `user,id=net0`); resolvido citando os valores, sem gambiarra de disable.
- Escrevi uma linha com uma variável inexistente (`SIMULATED_RAM_MB`) ao montar
  a dica final do build; corrigida antes de qualquer execução.

**NÃO feito / não testado (importante):**

- **`iso/test-vm.sh` nunca foi executado**: não há `qemu` no ambiente de
  desenvolvimento. Só o `--dry-run` (que não invoca o qemu) foi conferido.
- O caminho `--iso` do verificador (com `xorriso`) também **não** foi executado.
- `--serial-console` nunca validado num boot real.
- **Nenhuma ISO foi gerada** — continua valendo o de sempre: `xorriso` ausente.

**Commits desta sessão:** `c874922` — `feat(iso): verify-iso.sh + test-vm.sh`.

---

### Sessão #12 — 2026-10-12 · 🧬 Zen 3/4 prontos (sem hardware) + 🎮 GPU como opção

**Objetivo (pedido do usuário, verbatim):** *"mas não tenho hardware zen 3 e zen 4
para testar mas já deixe pronto o suporte. sei que usar gpu era a ideia base, mas
seria de bom tom deixar em aberto uma opção. vai que alguém queira usar uma gpu"*.

**Feito:**

1. **Corpus de CPUs reais** (`tests/families-matrix.txt`, ~60 modelos) +
   **`tests/test-families.sh`**, que roda a MESMA `pick_family` do build. É a
   resposta direta ao "deixe pronto sem eu ter o hardware": a parte do suporte
   que dá para provar sem o CPU é a **regra de seleção** — e é onde estavam os
   erros.
2. **O corpus achou 10 modelos mal atribuídos** (ver "Problemas" abaixo).
3. **`build-llama` do CI** passou a compilar também para `amd-zen3`,
   `amd-zen4` e `intel-skylake-avx512` — ou seja, o CI produz binário para
   famílias que ninguém aqui possui.
4. **GPU como opção explícita**: `llama-build.sh --gpu <cuda|rocm|vulkan|sycl|metal>`,
   `--gpu-check` (somente leitura) e `--cmake-extra` (escape hatch; o caso real
   é `-DAMDGPU_TARGETS=gfx803` para a RX 580).
5. **`detect-hardware.sh`** passou a detectar GPU e a dizer, com todas as
   letras, que ela **não** é usada para computação por padrão — silêncio aqui
   faria alguém supor aceleração que não existe. Nova linha `GPU=` na saída
   consumível por script.
6. **`docs/GPU.md`** + **Bloco P** de `VALIDATION.md`: o caminho completo, os
   avisos, o caso da RX 580 (Vulkan, **não** ROCm — Polaris saiu do ROCm) e a
   regra de não misturar medição de GPU com os números de CPU do `STATE.md`.
7. Docs: `docs/FAMILIES.md` § 9 (testes + **status por família**: corpus,
   compilação no CI e hardware, em colunas separadas), `AGENTS.md` (Regra 12-c
   sobre GPU + árvore), `README.md` (nota de GPU), `Makefile`
   (`families-test`, `gpu-check`, `GPU=`), `STATE`/`ROADMAP`/`validation.yml`.

**Decisões (e por quê):**

- **Provar o que dá para provar.** Sem Zen 3/4 em casa, o honesto é separar
  três coisas que costumam vir juntas no "suportado": casamento **testado**,
  compilação **testada**, hardware **não medido**. A tabela do § 9.3 tem uma
  coluna para cada.
- **GPU: flag explícita, não papel.** Criar `roles/gpu-inference` seria um papel
  inteiro sustentado por zero medição. Uma flag documentada + registro entrega
  valor hoje e pode virar papel quando houver número (registrado no ROADMAP).
- **Não existe `--gpu auto`.** Escolher backend sozinho é o tipo de mágica que
  "funciona" na máquina errada. Backend é obrigatório.
- **Registro no `AI-CPU-OS-BUILD.txt`.** Sem isso, alguém compara `llama-bench`
  de GPU com a tabela de CPU e conclui qualquer coisa.
- **Escape hatch (`--cmake-extra`)** em vez de embutir suporte a cada GPU
  antiga: `gfx803` é um detalhe da RX 580, não do projeto.

**Problemas encontrados e resolvidos (todos pelo corpus, nenhum pelo build):**

- 🐛 **Nenhum EPYC casava.** O regex era `EPYC .* [0-9]{3}1`, mas o espaço antes
  dos dígitos é o MESMO que já está em `"EPYC "` — o padrão exigia dois espaços.
  Naples (7601), Rome (7742), Milan (7763), Genoa (9554), Siena (8324P): todos
  caíam no `generic`. Isso **não** aparece num teste de compilação: o build
  funciona com `generic`, só que sem `-march` — o silêncio que custa desempenho.
- 🐛 **Série Ryzen 8000 é Zen 4** (8500G, 8600G, 8700G, 8845HS) e não casava
  com nada: caía em `generic`. Passou a casar via `8[0-9]{3}`.
- 🐛 **EPYC Genoa/Siena** idem (`9554`, `8324P`) → adicionados.
- 🐛 **Bug no próprio `--gpu`**, pego ainda no `--dry-run`: as flags eram
  capturadas com `$(gpu_apply)`, que devolvia **também as linhas de log** (o
  `log_info` escreve em stdout) — o argumento ia inteiro e corrompido para o
  CMake. Separado em `gpu_announce` (só loga) + `gpu_cmake_flags` (só ecoa a
  flag), e as flags passaram a ser adicionadas **antes** de imprimir a lista.
- `shellcheck SC2254` no `case "$GPU_BACKENDS"` → trocado por comparação em loop.
- `SC2034` (`GPU_MODELS` sem uso) → variável removida.
- `! grep` disparando "event not found" **no meu terminal** (history expansion
  do bash interativo), não no repositório: guarda negativo refeito com `test`.

**NÃO feito / não testado (importante):**

- **Nenhum backend de GPU foi compilado ou executado.** As flags são as do
  llama.cpp e o caminho está documentado; não há medição nenhuma.
- **Zen 3/4 continuam sem medição em hardware** — a coluna "hardware" do
  `docs/FAMILIES.md` § 9.3 segue ❌, de propósito.
- `--gpu-check` foi executado apenas nesta máquina (GPUs antigas, sem backend
  utilizável): ele *relata*, não valida um caminho feliz.

**Commits desta sessão:** `77b188b` — `feat(families): Zen 3/4 provados no CI + GPU opcional`.

---

### Sessão #13 — 2026-10-12 · 📚 Documentação para dois públicos (usuário × mantenedor)

**Objetivo (pedido do usuário, verbatim):** *"ótima decisão. agora só reformule
o README para que fique o mais explicado possível para o usuário final e crie um
readme técnico para que alguém mantenedor do projeto saber mais a fundo os
detalhes"*.

**Feito:**

1. **`README.md` reescrito do zero para o usuário final** (556 linhas, 15
   seções). O antigo era um bom resumo *de projeto* — mas pressupunha que o
   leitor sabia o que é família, papel, `-march`, `GGML_NATIVE`. A nova versão
   começa por *"isto serve para mim?"* (tabela ✅/❌), explica em uma frase o que
   o projeto faz (*"rodar LLM local usando só o processador, sem placa de
   vídeo"*), e só então desce. Conteúdo novo que não existia:
   - **"O que muda na minha máquina"** em tabela, com coluna de **reversão**
     (o medo real de quem vai `sudo ./build.sh`) e o aviso de consumo de energia.
   - **Instalação em 5 passos** numerados, terminando em algo *observável*
     (a API respondendo em `:8080`), não em "build concluído".
   - **Uso diário**: API compatível com OpenAI, `shell-ia.py`, e a tabela de
     variáveis de `/etc/default/ai-server` com **por que** cada uma importa.
   - **Como medir**: `pp512` vs `tg128` explicados em português, e **regras de
     medição** (nada mais rodando, mesma máquina, 3 execuções) — sem isso o
     número é ruído.
   - **Como desfazer tudo** (comando por mod + `revert`).
   - **FAQ** com a tabela de tamanho de modelo × RAM (a pergunta nº 1 de quem
     tem 16 GB) e a resposta honesta de que >7B Q4 não cabe.
   - **Troubleshooting** em tabela (sintoma → causa → correção).
2. **`README.technical.md` criado** (585 linhas, 13 seções) — o manual do
   mantenedor. Ele é o que o `README.md` não deve ser: entra nos **contratos**.
   Inclui o **playbook de depuração** com os bugs reais (o `readonly` que
   colidia, o `HOSTNAME` *builtin*, o `$(função)` que capturou log, o regex de
   EPYC com espaço duplo) e a **tabela de status de validação** que separa
   "escrito", "verificado por ferramenta" e "validado em hardware".
3. **Regra derivada, documentada nos dois arquivos:** *usuário → `README.md`;
   mantenedor → `README.technical.md`; regras → `AGENTS.md`; "o que é fato
   hoje" → `docs/STATE.md`.* Cada documento declara de quem é (§ 0 do técnico).
4. **Integração e guardas:** `README.technical.md` entrou na lista `required` e
   nos guardas do `project-rules` do CI (os dois arquivos precisam existir e se
   referenciar; o técnico precisa manter `make validate`); `AGENTS.md` § 4/§ 5 e
   o `help` do `Makefile` atualizados; `STATE`/`ROADMAP`/`JOURNAL` registrados.
5. **🐛 Bug real corrigido de passagem.** Ao procurar o nome **exato** do
   artefato para documentar, apareceu que `build-llama.yml` ainda usava
   `${{ matrix.profile }}` — chave **removida** na refatoração (hoje é
   `matrix.family`). O `upload-artifact` receberia uma string vazia: o upload
   **falharia** (ou nomearia o artefato de forma inválida). Corrigido nos 3
   lugares (nome do artefato, `INFO.txt`, nome do release).

**Decisões (e por quê):**

- **Dois arquivos, não um.** O problema do README antigo não era tamanho, era
  **mistura de públicos**: quem quer instalar tropeça em `FAMILY_AVX512_POLICY`,
  e quem quer manter se perde entre passos de instalação. Separar não é
  cosmético — é o que permite o README do usuário ser *direto* sem omitir nada
  (ele **aponta** para o técnico).
- **O técnico declara "o que cada teste NÃO prova".** É o antídoto contra a
  falha mais provável de um mantenedor novo: achar que `make validate` verde
  significa que o sistema funciona. A lacuna estrutural (nenhum teste do CI
  exercita o *efeito* dos ajustes de kernel) está escrita em negrito.
- **Documentar revelou o bug.** Isso valida a própria separação: obrigar-se a
  escrever o nome real do artefato forçou olhar o workflow com olhos de leitor,
  não de autor.
- **Guardas em vez de disciplina.** Um README que aponta para o outro é
  verificado por `grep -q` no CI — se alguém renomear, o CI avisa em vez de a
  documentação morrer em silêncio (o mesmo raciocínio do teste negativo do
  `verify-iso.sh`).
- **Amostras de saída fiéis.** O `detect-hardware.sh` foi executado de verdade
  e a amostra do README reproduz o formato real (inclusive a seção de
  recomendações de build e o `-march=broadwell -mtune=broadwell`, conferido
  contra o `family.conf`). Documentação com saída inventada é dívida técnica.

**Problemas encontrados e resolvidos:**

- 🐛 **`matrix.profile` no `build-llama.yml`** (descrito acima) — sobrevivente
  da refatoração; o CI ficaria vermelho no próximo run de tag.
- A **primeira amostra de saída** escrita no README não correspondia ao formato
  real do `detect-hardware.sh` (faltavam as seções de flags ISA, armazenamento e
  recomendações). Corrigido rodando o script e copiando a estrutura real.
- Verificados os 16 links do `README.md` e os 7 do técnico — todos resolvem.

**NÃO feito / não testado (importante):**

- **Nada mudou no status de validação.** Continua valendo: nenhuma ISO gerada
  ou bootada, `iso/test-vm.sh` nunca executado, nenhum backend de GPU
  compilado, zero medição em hardware real. A tabela do § 11 do
  `README.technical.md` é explícita sobre isso.
- Os números de exemplo de `README.md` § 7 (medição) são **ilustrativos** —
  marcados como tal no texto. Não há `llama-bench` real no repositório.

**Commits desta sessão:** `9961b2b` — `docs: README do usuário + README.technical.md`.

---

### Sessão #14 — 2026-10-12 · 🔒 ⚖️ ISO **air-gapped** + compilar no 1º boot (decisões)

**Objetivo (pedido do usuário, verbatim):** *"estava lendo as perguntas em aberto.
A ISO deve ser **air-gapped** — resposta sim. caso não ter internet já estará
pronto. e a pergunta: Embutir o binário pré-compilado em vez de compilar no 1º
boot? mesmo demorado é melhor compilar. assim teremos mais segurança no
objetivo."*

Ou seja: o usuário estava respondendo ativamente as dúvidas abertas do § 5.3.

**Feito:**

1. **Decisão ① — a ISO DEVE ser air-gapped.** Registrada como requisito (não
   "variante"): a máquina alvo pode estar numa rede isolada, então a mídia tem
   de bastar-se. Ver `docs/ISO.md` § 3.1.
2. **Decisão ② — o llama.cpp é COMPILADO no 1º boot, nunca pré-compilado.**
   Já era o design; agora está **firmado como decisão** e justificado: compilar
   no alvo é o que garante o `-march` da família **realmente detectada** (some o
   risco de `SIGILL`), o fonte fica **pinado e auditável na mídia**, e uma única
   ISO serve para todas as famílias — um binário pré-colado exigiria **uma ISO
   por família** e traria a portabilidade de volta pela porta dos fundos.
3. **O trabalho real que as duas decisões juntas exigem foi mapeado por inspeção
   do código** (não por suposição): os quatro pontos de rede do 1º boot são
   `apt-get install`, `git clone` do llama.cpp, o `curl` do modelo e o próprio
   espelho do instalador. Virou a tabela de requisitos do `docs/ISO.md` § 3.1
   (6 itens, com estado de cada um).
4. **Item 1 dos requisitos: IMPLEMENTADO.** `llama-build.sh --source <dir|tar.gz>`
   compila de um fonte **local** — sem rede, sem `git`, sem clone. É o
   substituto do `git clone` no 1º boot offline:
   - `--source` e `--ref` são **mutuamente exclusivos** (o fonte local já É uma
     versão); `--ref` sozinho continua funcionando igual.
   - `check_deps` **não exige mais `git`** quando o fonte é local (exigir git
     aqui impediria a ISO air-gapped — um exemplo de como a decisão toca o
     código em lugares inesperados). Tarball exige `tar`.
   - Tarball do GitHub tem **diretório de topo** (`llama.cpp-<ref>/`):
     o código entra nele automaticamente.
   - O `AI-CPU-OS-BUILD.txt` passou a registrar a origem do fonte **e** um campo
     `Rede: não usada (fonte local)` — para que ninguém confunda um build
     offline com um clonado.
5. **Guarda no CI** (`project-rules`) para o caminho offline não desaparecer em
   silêncio: `--source`, `prepare_source_local` e a mensagem `fonte LOCAL`
   precisam continuar existindo no `llama-build.sh`.
6. **Regra 13-b no `AGENTS.md`**: a ISO é air-gapped e compila no 1º boot;
   **proibido** embutir binário pré-compilado; qualquer download novo num
   script/papel/template é violação da regra (ou embuta na mídia, ou torne
   explícito e opcional).
7. Docs atualizados: `docs/ISO.md` (§ 3.1 novo, § 6, § 8 com o item descartado,
   § 9), `docs/ROADMAP.md`, `docs/STATE.md` (Passo 1.3 novo), `README.md` § 10
   e `README.technical.md` (§ 4.1, § 4.4, § 8.1, § 10, § 11, § 12).

**Decisões (e por quê):**

- **As duas respostas do usuário são interdependentes, e isso não é óbvio.**
  "Air-gapped" sozinho sugeriria embutir um binário pronto (nada a compilar =
  nada a baixar). Mas "compilar no 1º boot" **proíbe** essa saída: se o binário
  não é pré-colado, então o **fonte** e o **toolchain** têm de estar na mídia.
  Foi por isso que a análise de requisitos passou de "uma ideia" a **seis
  itens concretos** — três deles nem eram mencionados na dúvida original.
- **Air-gapped é requisito, não variante.** A dúvida original era "a ISO *deve*
  ser air-gapped?". A resposta sim muda o **status**: sai do roadmap como opção
  e entra como caminho planejado. A linha antiga ficou marcada como riscada no
  § 8, em vez de apagada — rastro de decisão.
- **O item descartado também fica escrito.** "Variante com binário
  pré-compilado" agora aparece como ❌ **descartado, com o motivo**. Documentar
  o que foi rejeitado evita que a ideia volte em 3 sessões como se fosse nova.
- **Uma decisão nova apareceu, e ela é do usuário.** Air-gapped significa que o
  **modelo** não pode ser baixado da HuggingFace. Ou ele vai na ISO (~1,1 GB a
  mais), ou o usuário copia o `.gguf` por pendrive. Ficou registrada como
  pergunta **aberta e explícita** (§ 5.3) em vez de escolhida por conta própria —
  ela muda o tamanho da mídia e o fluxo de uso.
- **Testar o que dá, sem mentir sobre o resto.** O `--source` foi exercitado em
  `--dry-run` (dir e tarball) **e** de verdade: extração real dos dois formatos
  de tarball, com as ferramentas de build **simuladas** por stubs para o fluxo
  chegar até o fim. A **compilação real** de um fonte do llama.cpp por esse
  caminho **não** foi executada (falta `cmake` nesta máquina e baixar o fonte
  seria pesado) — isso está escrito no § 11 do `README.technical.md` e no § 3.1
  do `ISO.md`, não escondido.

**Problemas encontrados e resolvidos:**

- 🐛 **A primeira "prova" do `--source` não provou nada.** Os testes de extração
  falharam sem motivo aparente: o `check_deps` abortou antes de chegar à cópia,
  porque **esta máquina não tem `cmake` nem `pkg-config`** e o `apt-get install`
  não tem root. Diagnóstico: criar **stubs** de `cmake`/`pkg-config`/`cc`/`make`
  num diretório à frente do `PATH` — aí o fluxo anda e a extração pode ser
  verificada de verdade. Lição: quando um teste "falha sem motivo", duvide do
  **ambiente de teste** antes de duvidar do código.
- 🐛 **`find | head -1` é armadilha com `pipefail`.** A primeira versão de
  `prepare_source_local` achava o diretório de topo do tarball com
  `find ... | head -1`. Com `set -o pipefail`, o SIGPIPE do `head` faz o `find`
  sair com 141 e **reprova uma extração que deu certo**. Trocado por glob
  (`"$tmp"/*/`). Registrado no § 10 do `README.technical.md`.
- 🐛 **Editei um bloco e grudei duas linhas — de novo.** Ao inserir os guardas no
  `validate.yml`, a linha `grep -q 'fonte LOCAL' llama-build.sh` ficou colada ao
  comentário seguinte. É exatamente a armadilha do § 6 ("editar bloco SEM
  incluir a linha seguinte"), acontecendo **de novo**, 24h depois de ser
  registrada. Corrigido, e a armadilha foi reforçada com um caso concreto.
- `--ref` + `--source` juntos: antes seriam duas intenções contraditórias —
  agora é erro explícito com mensagem clara (em vez de uma sobrescrever a outra
  em silêncio).

**NÃO feito / não testado (importante):**

- **A ISO continua NÃO sendo air-gapped.** Só o item 1 de 6 está pronto. Os
  itens 2–5 do § 3.1 (repo apt local, `--source` no `firstboot.sh`,
  `OFFLINE=1`, flag `--offline` no `build-iso.sh`) **não** foram escritos.
- **Nada foi compilado de verdade pelo caminho `--source`** (só a extração).
- Nenhuma ISO gerada ou bootada; nenhum backend de GPU compilado; zero medição
  em hardware real. A tabela do § 11 do `README.technical.md` segue sendo a
  fonte da verdade — e ela agora diz "Build offline: ⚠️".

**Commits desta sessão:** `4474b75` — `feat(iso)!: ISO air-gapped + compilar no 1º boot (--source)`.

---

### Sessão #15 — 2026-10-12 · 📦 O modelo `.gguf` vai na mídia (implementado)

**Objetivo (pedido do usuário, verbatim):** *"um pouco maior não é um problema"*
— resposta à dúvida aberta na sessão #14: a ISO pode crescer para levar o modelo.

**Feito:**

1. **Decisão registrada:** o modelo `.gguf` **vai na mídia**. ~1 GB a mais é
   aceito em troca de uma ISO que se basta — a alternativa (modelo por pendrive)
   exigiria um passo manual depois da instalação. O requisito 5 do `docs/ISO.md`
   § 3.1 saiu de "decisão pendente" para ✅ **implementado**.
2. **`build-iso.sh --iso-model auto|<caminho>|none`**: `auto` (padrão) baixa o
   modelo sugerido **na máquina que gera a ISO** — ali a rede é aceitável, e o
   arquivo passa a ser auditável dentro da mídia (nome + tamanho + magic);
   `CAMINHO` usa um `.gguf` seu; `none` gera sem modelo. Um `.gguf` inválido é
   **recusado antes de montar a ISO** (magic `GGUF` + tamanho), e o download roda
   em `$WORK_DIR/models`, idempotente (reaproveita o que já baixou).
3. **A corrente completa até o alvo** (nenhum elo pode faltar, senão a ISO volta
   a depender de rede — e o modo de falha é silencioso):
   `--iso-model` → `/models/<arquivo>` na mídia → `late-command.sh` copia para
   `/opt/models` e grava **`MODEL_FILE`** no `.iso-config` → `firstboot.sh`
   exporta **`AI_MODEL_FILE`** (mesmo padrão do `AI_FAMILY`) → papel `inference`
   instala por **`--model-file`**, **sem rede**.
4. **`roles/inference/install.sh --model-file CAMINHO`** — o caminho OFFLINE do
   papel: copia um `.gguf` local para `/opt/models`, confere o magic e não toca a
   rede. Também aceita `AI_MODEL_FILE` por ambiente. Se o usuário passar
   `--model-file` **e** `--auto-model`, o local ganha e o aviso é explícito.
5. **Bug de ordem corrigido no papel:** o modelo era escolhido **depois** de
   `install_service`, que grava `MODEL_PATH` em `/etc/default/ai-server`. Com um
   caminho vindo por flag isso passava despercebido; com o modelo local (cujo
   `MODEL_PATH` sai do **nome do arquivo**) o serviço apontaria para o lugar
   errado. A escolha do modelo passou para **antes** do serviço.
6. **`verify-iso.sh`** ganhou a seção "Modelo embutido (/models) e caminho
   offline": confere os **elos** de ligação (late-command menciona `/models` e
   `MODEL_FILE`; firstboot repassa `AI_MODEL_FILE`) e o **conteúdo** (se houver
   `.gguf` na mídia, valida o magic e recusa arquivo pequeno demais). Sem modelo,
   é `[SKIP]` — nunca um `PASS` falso.
7. **Guardas no CI**, incluindo os **negativos** que materializam a decisão:
   `! --prebuilt` e `! ^COPY.*build/bin`.
8. Docs: `ISO.md` (§ 3.1 item 5, § 4.7 sobre rede no build, § 6, § 8, § 9),
   `AGENTS.md` (Regra 13-b + § 8), `STATE`, `ROADMAP`, `README.md` § 10 e
   `README.technical.md` (§ 4.4, § 11, § 12).

**Decisões (e por quê):**

- **Baixar o modelo no BUILD da ISO, não no 1º boot.** A regra é que **o alvo**
  não precise de rede; a máquina que monta a mídia pode ter. Fazer o download ali
  torna o arquivo **parte da mídia** (auditável, com nome e tamanho conhecidos)
  em vez de um efeito colateral da instalação.
- **Validar o `.gguf` cedo e em quatro lugares:** `build-iso.sh` (antes de montar
  a ISO — erro barato), `--model-file` (antes de copiar), `verify-iso.sh` (no
  produto) e o serviço (na partida). Um `.gguf` de 2 KB ou com magic errado não
  deve chegar ao ar para só então falhar no primeiro prompt.
- **`none` existe de propósito.** Sem ele, quem estiver sem rede na máquina de
  build ficaria travado — e nem todo mundo quer 1 GB a mais na mídia.
- **O modelo ganha o mesmo tratamento que o fonte:** ambos passam a ser
  **artefatos da mídia**, com o build apenas os materializando. É isso que torna
  o air-gapped uma propriedade da ISO, e não uma esperança sobre a rede.

**Problemas encontrados e resolvidos:**

- 🐛🐛 **Editei `main()` e o arquivo ficou corrompido em três pontos:** uma linha
  colada (`fiO modelo é obtido ANTES...`), uma duplicação com texto intercalado
  (`inject_modela: o layout...`) e um bloco inserido no meio do ramo Debian. O
  `bash -n` passou a acusar `syntax error near unexpected token 'done'` numa linha
  que, isolada, estava correta — **sintoma longe da causa**. Pior: a substituição
  destruiu também o trecho que roda `bash -n`/`sh -n` dentro do `check_templates`,
  ou seja, **o autoteste que teria pegado o erro**. Reparado extraindo o `main()`
  original com `git show HEAD:iso/build-iso.sh` e reaplicando as mudanças por
  **âncoras exatas em script** (linha inteira igual a `  acquire_iso`), não por
  bloco de texto.
- **A armadilha do "editar bloco sem incluir a linha seguinte" aconteceu pela
  TERCEIRA vez** (AGENTS.md, validate.yml, agora build-iso.sh). Em todas o sintoma
  foi uma linha colada ao texto anterior; nesta a consequência foi pior (arquivo
  inteiro inválido).
- ⚠️ **Guarda negativo quase falso:** `! grep -q 'COPY build/bin' docker/Dockerfile`
  reprovava porque o Dockerfile **cita** o comando num comentário explicando por
  que não se deve usá-lo. Corrigido ancorando na forma do comando
  (`^COPY[[:space:]]+.*build/bin`) e verificado com um caso positivo de teste.
- **`--iso-model` com magic errado falhava tarde demais** se a validação ficasse
  depois de `acquire_iso`. Movido para **antes** de montar a árvore: erro barato
  primeiro.

**NÃO feito / não testado (importante):**

- **Nada do modelo foi exercitado num boot real.** Os testes foram `--dry-run`
  nas duas distros, validações de magic/tamanho (positivas e negativas),
  `verify-iso.sh` reprovando `pequeno.gguf` e `magic-ruim.gguf` numa árvore de
  teste, e o autoteste de templates (36 PASS / 0 FAIL / 2 SKIP).
- **O `late-command.sh` nunca copiou um `.gguf` de verdade**, e o `firstboot.sh`
  nunca exportou `AI_MODEL_FILE` num sistema instalado.
- **A ISO continua exigindo rede no 1º boot** (toolchain do apt + clone do
  llama.cpp). O **repositório apt local** na mídia é o item mais pesado que resta
  (~300–500 MB de `.deb`).
- O **tamanho real** da ISO com modelo (~4,3 GB estimado) continua sendo
  **estimativa** — nenhuma ISO foi gerada.

**Commits desta sessão:** `bfc8eca` — `feat(iso): o modelo .gguf vai na mídia (--iso-model)`.

---

### Sessão #16 — 2026-10-12 · 📦 O repositório apt vai na mídia (orçamento de 8 GB)

**Objetivo (pedido do usuário, verbatim):** *"a imagem do sistema chegar até 8 GB
não tem problema, então pode incluir o que for necessário"*.

Orçamento liberado: o item mais pesado que restava no § 3.1 do `docs/ISO.md`
(repositório apt local, ~300–600 MB) deixou de ser caro o bastante para adiar.

**Feito:**

1. **`--iso-repo auto|DIR|none`** no `iso/build-iso.sh`:
   - resolve o **fecho de dependências** dos pacotes que o 1º boot precisa
     (`apt-cache depends --recurse`, sem recomendados/sugeridos — só o que faz o
     pacote **funcionar**; `Pre-Depends` é mantido);
   - baixa os `.deb` (`apt-get download`, **em lotes**: um pacote virtual sem
     candidato faz o apt falhar e abortaria o resto da lista);
   - gera o índice (`Packages` + `Packages.gz`) **com `dpkg-deb`**, sem depender
     do `dpkg-dev` — o `control` do próprio `.deb` já traz `Depends`/`Provides`,
     então basta despejá-lo e acrescentar `Filename`/`Size`/`SHA256`;
   - confere que **todo pacote PEDIDO** está no repositório (o fecho pode ter
     falhas toleradas; os pedidos, não).
2. **A fonte entra como EXTRA, nunca como `primary`.** Decisão de projeto:
   - como `primary`, o `sources.list` do **sistema instalado** apontaria para
     `file:///cdrom/...`, que morre quando a mídia sai (`apt update` quebrado no
     dia a dia) — e um repo incompleto **abortaria** a instalação;
   - como fonte extra, o alvo nasce com o espelho oficial e um repo incompleto
     **degrada** para a rede em vez de quebrar.
   No Ubuntu: seção **`sources` do curtin** (o próprio Subiquity documenta como
   "adicionar um PPA"). No Debian: `apt-setup/local0/repository`, `comment` e
   `source boolean true`.
3. **O caminho veio do harness, não da minha cabeça:** o valor é
   `deb [trusted=yes] file:///cdrom/apt-repo ./` — repositório **flat** (índice
   na raiz, `./` como suite) e `trusted=yes`, porque um repo local não é assinado
   e gerenciar chave no alvo não agregaria nada.
4. **O build RECUSA repositório de outra release.** Compara o codename derivado
   da URL da ISO (24.04→noble, 25.10→questing…) com o `VERSION_CODENAME` de
   `/etc/os-release`. `.deb` de outra release têm versões que não casam com a
   base, e a falha só apareceria **no meio da instalação**. Escape:
   `--iso-repo-allow-mismatch`. E `--iso-repo auto` com `--distro debian` é
   recusado (`.deb` de Ubuntu não servem no Debian).
5. **Blocos que aparecem ou somem:** `@@APT_LOCAL_SOURCES@@` (YAML) e
   `@@APT_LOCAL_PRESEED@@` (preseed) são expandidos por
   `expand_apt_local_block` — **ou viram o bloco, ou desaparecem por completo**,
   que é o que mantém o YAML/preseed válidos nos dois casos.
6. **O alvo não fica com fonte morta:** `late-command.sh` remove qualquer linha
   apontando para a mídia (`@@APT_REPO_PATH@@`) de `/target/etc/apt/sources.list`
   e de `sources.list.d/`, com backup, preservando o espelho oficial.
7. **`verify-iso.sh` ganhou a seção do repositório**, com quatro invariantes:
   índice legível (`gzip -t` + contagem de entradas); **todo `.deb` citado no
   índice está presente na mídia**; magic `!<arch>` dos `.deb` (amostra no modo
   `--iso`, todos no `--dir`) — pega download que trouxe **HTML de erro** com
   nome de `.deb`; e **coerência mídia × configuração** nos dois sentidos.
8. Guardas no CI: `--iso-repo`, `expand_apt_local_block`, `dpkg-deb`, `apt-repo`,
   o marcador em cada template, a limpeza no late-command e a checagem no
   verificador.

**Decisões (e por quê):**

- **Orçamento de 8 GB muda o que é "caro".** ~500 MB de `.deb` era "pesado demais
  para agora"; com o orçamento dado, virou o passo natural. O build **avisa**
  acima de 6 GB, mas **não bloqueia** — quem decide o tamanho da mídia é quem
  gera.
- **`dpkg-scanpackages` não foi usado de propósito:** ele vive no `dpkg-dev`, que
  não está em toda máquina de build. Menos dependência, um só caminho de código.
- **Recusar release diferente, e não avisar.** Um aviso seria ignorado e a falha
  apareceria como "instalação quebrada", sem relação óbvia com a causa.
- **Não provar o que não dá para provar.** O aceite do instalador (seção
  `sources` do curtin / `apt-setup/local0`) **não** é verificável sem uma ISO
  real. Ficou escrito como **suposição documentada**, com o **sintoma** a
  procurar no primeiro teste em VM: "reclama de assinatura" → problema na fonte;
  "instala mas pede rede" → repositório incompleto.

**Problemas encontrados e resolvidos:**

- 🐛 **Bug real: a linha da fonte saía `file:///apt-repo`** em vez de
  `file:///cdrom/apt-repo`. Eu confundi o nome relativo à raiz da ISO com o
  caminho da mídia montada. **Foi o harness** (extrair as funções reais do
  script com `sed` e exercitá-las) que pegou, antes de qualquer teste no alvo.
  Corrigido com a constante `APT_REPO_MOUNT="/cdrom"` e uma única fonte de
  verdade para o caminho.
- 🐛 **Sem repositório, a função ainda devolvia uma linha** (com caminho vazio) —
  e o bloco seria **inserido** com uma fonte inválida. Corrigido: sem repo, a
  linha é **vazia** e o bloco desaparece. O autoteste de templates não pegaria
  (um bloco "a mais" não é erro de sintaxe); o harness pegou.
- 🐛 **O `--dry-run` não validava nada do repositório** (saía antes): um
  `--iso-repo` apontando para o diretório errado passava batido. Movido: as
  validações **somente leitura** (existe? tem `.deb`? os pacotes pedidos estão
  lá?) rodam **também** no dry-run.
- 🐛 **Linha do resumo duplicada:** duas edições casaram em pontos diferentes do
  `main()` e o mesmo bloco entrou duas vezes. Detectado contando ocorrências.
- 🐛 **`main()` corrompido de novo, por edição de bloco.** A mesma armadilha da
  sessão #15 — agora com o mesmo texto inserido em **dois** lugares. Reparado com
  **âncoras exatas em script** + `assert` de contagem antes de escrever, que é a
  defesa que a #15 tinha registrado. Terceira ocorrência do padrão; a defesa
  nova **funcionou** e evitou o quarto caso.
- **Duas provas fortes, feitas de verdade, sem ISO:** (a) o **`apt` real** rodou
  `apt-get update` contra um repositório montado **pelo código do projeto** e
  resolveu a dependência entre dois pacotes de teste (`fake-dep` → `fake-pkg`),
  apontando para os `.deb` dentro da árvore — prova de que o **formato**, o flat
  `./` e o `[trusted=yes]` em `file://` funcionam; (b) o `verify-iso.sh` reprovou
  os **cinco** modos de falha testados (Packages.gz corrompido, `.deb` citado no
  índice e ausente, `.deb` que é HTML de erro, repo sem a fonte no autoinstall,
  fonte no autoinstall sem repo).

**NÃO feito / não testado (importante):**

- **Nenhuma ISO gerada, nenhum boot real.** Vale integralmente o § 6 do
  `docs/ISO.md`.
- **O `--iso-repo auto` nunca rodou de ponta a ponta:** exige rede e uma máquina
  da **mesma release** da ISO (esta é 25.10/questing; a ISO é 24.04/noble) — o
  próprio guarda de release impede o teste aqui. Os caminhos exercitados foram o
  **diretório** (`--iso-repo DIR`), a **geração do índice** e a **verificação**.
- **O aceite do instalador é suposição:** seção `sources` no Subiquity e
  `apt-setup/local0/*` no debian-installer não foram vistos funcionando.
- **O `late-command.sh` nunca removeu uma fonte de um alvo de verdade.**
- Resta **só o item 2** do § 3.1 (`firstboot.sh` passar `--source`) para o 1º boot
  ficar 100% offline.

**Commits desta sessão:** `e1f09e9` — `feat(iso): repositório apt local na mídia (--iso-repo)`.

---

### Sessão #17 — 2026-10-12 · 🔒 A ISO está fechada no código (fonte na mídia) + checklist

**Objetivo (pedido do usuário, verbatim):** *"precisamos fechar essa ISO, se
houver recomendações eu aceito"*.

**Feito:**

1. **Descobri que faltava uma peça no item 2** — e ela não estava na lista. O
   plano dizia "`firstboot.sh` passa `--source` em vez de `--ref`", mas isso
   supõe que **o tarball esteja na mídia**, e nada o embutia. Sem resolver
   isso, implementar o item 2 daria erro: o `--source` apontaria para um
   arquivo inexistente. Criado **`--iso-source auto|<tarball>|none`**.
2. **A corrente completa, elo por elo** (nenhum pode faltar — se faltar, o 1º
   boot volta a clonar e a falha é silenciosa):
   `--iso-source` → `/llama-src.tar.gz` na mídia → `late-command.sh` copia
   para `/opt/llama-src.tar.gz` e grava **`LLAMA_SRC`** no `.iso-config` →
   `firstboot.sh` exporta **`AI_LLAMA_SOURCE`** → `llama-build.sh` a usa como
   padrão de **`--source`** → compila **do tarball**, sem `git` e sem rede.
3. **Não extraímos o tarball** em lugar nenhum: o `llama-build.sh --source`
   já sabe extrair um `.tar.gz` e tratar o diretório de topo do tarball do
   GitHub. Menos código, um caminho só, e a extração acontece no sistema já
   instalado (onde `tar` com certeza existe).
4. **`build.sh --model-file` / `--llama-source`.** `sudo` **limpa o
   ambiente**, então exportar variável não é um caminho utilizável na mão.
   As flags repassam por ambiente para o papel. É o mesmo padrão do
   `--model-file` do papel — que também ganhou um caminho usável.
5. **`verify-iso.sh`**: nova seção conferindo a corrente (late-command usa
   `llama-src`/`LLAMA_SRC`; firstboot usa `AI_LLAMA_SOURCE`) e o conteúdo
   (tarball legível, com `CMakeLists.txt` e com `ggml/`). Sem fonte é
   `[SKIP]`, nunca `PASS` falso.
6. **`iso.yml`**: input `air_gapped` (padrão `false`), o passo de geração
   passa as três flags, o **dry-run exercita os caminhos novos** e há um
   **guarda de tamanho** que pula o upload acima de 2 GiB com aviso.
7. **`docs/ISO.md` § 9 — checklist de fechamento** (novo): a ordem dos passos,
   o que **cada um prova**, onde roda, a tabela de sintomas para o teste em
   VM e o checklist final. Esta era a recomendação mais útil a fazer.

**Achado que muda o plano (recomendação aceita):**

- 🔴 **O GitHub recusa arquivo de Release acima de 2 GiB** (está na doc de
  Releases: *"Each file included in a release must be under 2 GiB"*). A ISO
  air-gapped tem ~4,3–5 GB — ou seja, **não pode ser distribuída por
  Release**. Consequências implementadas: o padrão do CI é a ISO leve, o
  workflow **pula o upload** avisando quando passa do limite, e a ISO
  air-gapped é explicitamente "para gerar na sua máquina". Sem esse guarda, o
  workflow falharia **depois** de 10+ minutos de build, num passo de upload.
- ⚠️ **`--iso-repo auto` exige a mesma release da ISO.** Nesta máquina
  (25.10) e a ISO padrão (24.04 LTS) o build **recusa** — e faz certo. A
  mensagem virou acionável com três saídas (buildar numa noble, `--iso-url`
  da sua release, ou `--iso-repo CAMINHO`), e `--iso-repo-allow-mismatch`
  ficou marcado como produtor de ISO que não instala offline.

**Decisões (e por quê):**

- **O CI continua provando o caminho completo.** Com `air_gapped: true` o
  workflow gera a ISO **com** payload e o `verify-iso.sh` roda sobre a ISO
  real (via `xorriso`) — é a prova mais forte possível sem hardware. O que não
  se pode é *baixar* essa ISO; isso ficou explícito em vez de silencioso.
- **`none` existe em todos os três.** Quem está sem rede na máquina de build
  (ou não quer 5 GB) não fica travado.
- **O tarball fica inteiro na mídia**, não extraído. Custa ~40 MB e mantém o
  artefato auditável: o que será compilado é literalmente o arquivo da mídia.
- **Guardar o tamanho e o SHA256 no `STATE.md` é parte do checklist.** Sem
  isso, a próxima sessão não sabe o que foi de fato produzido.

**Problemas encontrados e resolvidos:**

- 🐛 **A peça que faltava no plano do item 2** (descrita acima). O plano do
  § 3.1 dizia "usar `--source`" sem nunca ter previsto *como o arquivo chega
  ao alvo*. Ler o plano com olhos de executor pegou isso.
- 🐛 **`multi_replace` inserindo o mesmo bloco duas vezes** (de novo): a linha
  do resumo apareceu duplicada. Foi a **quarta** ocorrência do padrão no
  projeto — e a defesa registrada na #15 (`assert` da contagem antes de
  escrever) foi o que detectou, não o lint.
- 🐛 **Ancora com acento escrita sem acento** num patch Python (`Repositorio`
  vs `Repositório`): o `sub` não casou e abortou. Barato, porque o `assert`
  falha antes de escrever qualquer coisa.
- 🐛 **`SyntaxWarning: invalid escape sequence`** ao gerar crases escapadas no
  patch do `iso.yml`. Arquivo reescrito com `chr(92)` em vez de literal.
- **Erro de âncora que parecia bug de produto:** `payload=auto` "falhou" nos
  meus testes — era o **guarda de release funcionando** (máquina 25.10 × ISO
  24.04). Antes de "consertar", confirmei que era o comportamento desenhado e
  que `--iso-url` da release certa faz passar (`rc=0`).

**Provas desta sessão (sem ISO, mas de verdade):**

1. **`late-command.sh` REAL executado** num sandbox (caminhos `/target` e
   `/cdrom` redirecionados, `in-target` stubado): copiou o tarball para
   `/opt/llama-src.tar.gz` e gravou `LLAMA_SRC=/opt/llama-src.tar.gz` no
   `.iso-config`.
2. **`llama-build.sh` REAL**, com `AI_LLAMA_SOURCE` no ambiente: compilou do
   tarball e registrou no manifesto `llama.cpp: tarball local llama-src.tar.gz`
   / **`Rede: não usada (fonte local)`**. **Sem** a variável, voltou a clonar —
   provando que o comportamento offline é **causado** por ela.
3. **Interação de degradação:** rodei o late-command com o tarball no nome
   errado e ele **avisou e seguiu sem fonte** (limpando `LLAMA_SRC`), em vez de
   quebrar a instalação. Comportamento desenhado, verificado por acidente.
4. **`verify-iso.sh`** reprovou tarball truncado, sem `CMakeLists.txt` e sem
   `ggml/` — e aprovou o correto (6 PASS na seção).
5. **`--iso-source`** recusou: arquivo inexistente, formato errado e arquivo
   que não é tarball; e **avisou** (sem bloquear) num tarball sem
   `CMakeLists.txt`.

**NÃO feito / não testado (importante):**

- **Nenhuma ISO foi gerada nem bootada.** Nada desta sessão tocou uma ISO real.
- **O sandbox não é o alvo:** os scripts rodaram com o sistema de arquivos
  redirecionado. Que o `late-command` funcione **dentro** do Subiquity/d-i, e
  que a fonte extra de apt seja **aceita** pelo instalador, continuam sendo
  **suposições documentadas** (sintomas anotados no § 9.3 do `docs/ISO.md`).
- **`--iso-repo auto` nunca rodou de ponta a ponta** (exige a mesma release).
- **Não há mais pendência de código conhecida no caminho da ISO.** O que falta
  é **executar**: gerar (passo 3) e bootar em VM (passo 4) — e o passo 3 não
  roda nesta máquina (sem `xorriso`), então o caminho prático é o workflow
  `iso` no GitHub. O passo 4 precisa de uma máquina com `qemu`+KVM.

**Commits desta sessão:** (a preencher após o push).

---

## 5. 🧵 Threads abertas (o que ficou no ar)

> **Esta é a seção mais importante para retomar.** Lista o que está *incompleto*,
> *decidido mas não feito* ou *em dúvida*.

### 5.1 Bloqueado por ambiente (não dá para fazer nesta máquina)

| Thread | Bloqueio |
|--------|----------|
| Gerar e bootar a ISO | Falta `xorriso`/`qemu`. *Solução:* `sudo apt install -y xorriso qemu-system-x86 qemu-utils curl`, ou rodar o workflow `iso` no GitHub. (No caminho **Ubuntu** não é preciso `mtools`: a remontagem por `-indev/-outdev -map` preserva os setores de boot da ISO oficial.) |
| Validar em hardware real | Falta acesso físico ao Xeon e ao Ryzen. |
| Medir tokens/s (`llama-bench`) | Depende do item acima. |
| Compilar o llama.cpp localmente | CPU fraca (2 núcleos) — use os binários da Release `v0.2.0` ou o CI. |

### 5.2 Decidido, mas ainda não executado

| Thread | Nota |
|--------|------|
| **Nada de código no caminho da ISO** | ✅ Os 5 requisitos do § 3.1 do `docs/ISO.md` estão implementados. **Não há pendência de implementação conhecida** — falta EXECUTAR (ver abaixo). |
| **Gerar a ISO (passo 3 do checklist)** | Não roda nesta máquina (sem `xorriso`). Caminho prático: workflow `iso` no GitHub com `air_gapped: true`. Ver `docs/ISO.md` § 9.1. |
| **Bootar em VM (passo 4 — o critério de conclusão)** | Precisa de `qemu`+KVM. Gere a ISO com `--serial-console` ou o `test-vm.sh` não vê o 1º boot. Ver `docs/ISO.md` § 9.2. |
| ⚠️ **Limite de 2 GiB por arquivo de Release** | A ISO air-gapped (~4,3–5 GB) **não pode** ser anexada a uma Release. O CI pula o upload e avisa. Distribuição: pendrive/`scp`, runner self-hosted, ou outro host + SHA256 na Release. |
| **Aceite do instalador para o repo local** | A seção `sources` (Subiquity) e `apt-setup/local0/*` (debian-installer) são **suposições documentadas** — não foram vistos funcionando. Sintoma a procurar: erro de assinatura; ou instalar mas pedir rede (repo incompleto). |
| **PR #1 do Dependabot** | ✅ verde, rebaseado sobre `main`, **não mesclado**. Basta clicar em *Merge*. Bumps verificados com `git ls-remote`. |
| **Bloco M** (`VALIDATION.md`) | Roteiro da ISO pronto; nenhuma execução ainda. |
| **Blocos A–L** (`VALIDATION.md`) | Idem — nenhum resultado preenchido. |
| **`md5sum.txt` da ISO** | Gerado pelo script, mas **nunca validado** por um instalador real. |
| **Boot UEFI da ISO** | Implementado como *best-effort* (precisa de `mtools`); **não testado**. |

### 5.3 Dúvidas em aberto (requerem decisão sua)

| Dúvida | Contexto |
|--------|----------|
| — (nenhuma em aberto) | Todas as dúvidas de arquitetura registradas até aqui foram respondidas. As pendências são de **execução**, não de decisão: gerar/bootar a ISO, montar o repo apt local, medir em hardware. |

> ✅ **Resolvido na sessão #15:** o **modelo `.gguf` vai na mídia** ("um pouco
> maior não é um problema"). Implementado de ponta a ponta: `--iso-model` →
> `/models` na ISO → `MODEL_FILE` → `AI_MODEL_FILE` → `--model-file`.
>
> ✅ **Resolvido na sessão #14:** as duas dúvidas que estavam aqui foram
> respondidas pelo usuário — **a ISO DEVE ser air-gapped** (sim) e **compilar no
> 1º boot é melhor que embutir binário pré-compilado** (mesmo sendo demorado:
> dá mais segurança ao objetivo). Ver `docs/ISO.md` § 3.1 e a sessão #14.
>
> ✅ **Resolvido na sessão #10:** a dúvida "suportar Ubuntu também?" foi
> encerrada — o **Ubuntu Server (autoinstall/Subiquity) passou a ser o padrão** e
> o Debian (preseed) ficou como caminho legado, com o mesmo `late-command.sh`
> para os dois instaladores.
>
> ✅ **Resolvido na sessão #13:** a dúvida sobre **quantos READMEs** o projeto
> tem foi encerrada — são **dois**, por público: `README.md` (usuário final) e
> `README.technical.md` (mantenedor), com guardas no CI garantindo que ambos
> existem e se referenciam.

> ✅ **Resolvido na sessão #8:** a dúvida "o Xeon é dual ou quad channel?" foi
> encerrada — é **quad channel** (Haswell-EP tem 4 canais; 4 slots × 4 GB).
> `README.md`, `AGENTS.md` e `docs/HARDWARE.md` foram unificados e
> `detect-hardware.sh` passou a contar os canais reais via `Bank Locator`
> (antes ele reportava sempre "dual"). Confirmar no Bloco B.

### 5.4 Deliberadamente adiado

- Perfil `generic` (hardware não listado).
- Tuning de NVMe (`mq-deadline` vs `none`).
- Benchmark automatizado com CSV + baseline versionado.
- Assinatura GPG da ISO.
- Imagem de VM (`qcow2`) via Packer.

---

## 6. 🕳️ Armadilhas já pisadas (não repita)

| Armadilha | O que acontece | Como evitar |
|-----------|----------------|-------------|
| `grep` **sem arquivo** no terminal | Ele lê o **stdin** e **trava a sessão** | Sempre passe arquivo/glob, ou use `grep ... <<<"$var"` |
| Polling agressivo na **API do GitHub** sem token | `abuse detection` — bloqueia por vários minutos | Poll no **navegador**; na API, com calma (60 req/h) |
| Assumir que **logs** do CI são públicos | HTTP **403** (exige login) | Use as *annotations* (públicas) ou o navegador logado |
| `cmake` no **Docker** com `GGML_NATIVE=ON` | O CMake pega a CPU do **runner** (pode ter AVX-512) → `SIGILL` no alvo | Mantenha `GGML_NATIVE=OFF` no container (Regra 12) |
| Copiar `build/bin` para outra pasta | **RPATH absoluto** → `error while loading shared libraries` → **exit 127** | Use `cmake --install` + `CMAKE_INSTALL_RPATH` + `ldconfig` |
| Build **nativo** sem `pkg-config` | `Could NOT find PkgConfig` no CMake | Já instalado pelos scripts; se faltar, `apt install pkg-config` |
| Passos de CI **condicionais** (ex.: só em PR) | Ficam **sem cobertura** até alguém exercitá-los | Só apareceu no PR do Dependabot — teste os dois caminhos |
| Tokens `@@...@@` em **comentário** de template | O guarda "sobrou marcador" dava **falso positivo** e abortava o build | O guarda checa apenas os **nomes** de marcador reais |
| `find \| head -1` no `prepare_source_local` | Com `set -o pipefail`, o SIGPIPE do `head` faz o `find` sair 141 e **reprova uma extração que funcionou** | Nunca use `find ... \| head` para "pegar um item": use glob (`"$dir"/*/`) ou `-print -quit` sem pipe |
| `git push` rejeitado (`non-fast-forward`) | Alguém (você, pelo site) comitou no remoto | `git fetch` → inspecionar → `git rebase origin/main` → push (nunca force no `main`) |
| `sed -i "s/.*texto.*/.../"` em `.md` | Pode quebrar linha sem intenção | Prefira edições por bloco com contexto |
| Editar **bloco** de texto incluindo a quebra de linha final | O texto seguinte **gruda** na mesma linha (ex.: `perfil├── .github/`) e corrompe a árvore/lista | **Sempre confira o resultado** (`sed -n ...p`, `git diff`) e inclua a linha seguinte no contexto da edição |
| Editar um **trecho grande** (uma função inteira) por substituição de bloco | O match pode cair em outro ponto, duplicar trechos e destruir código vizinho — 3 ocorrências em `build-iso.sh` de uma vez, e o `bash -n` acusou erro **longe da causa** | Para edição estrutural, extraia o original com `git show HEAD:arquivo` e reaplique as mudanças por **âncoras exatas** (linha inteira) em script |
| Editar trecho grande / `main()` com `multi_replace` | Casou em **2 pontos**, inseriu o mesmo texto **duas vezes** e o arquivo ficou inválido (3ª vez que a armadilha aparece) | Extraia o original com `git show HEAD:arquivo`, reaplique por **âncoras exatas** e **asssine a contagem** (`assert`) ANTES de escrever |
| Teste que só cobre o caso feliz do próprio código | Bug real passou batido: a função devolvia `file:///apt-repo` (sem `/cdrom`) e, sem repo, ainda devolvia linha com caminho vazio | Exercite as **funções reais** num harness (extraia com `sed`) e teste os caminhos **negativos**; o `--dry-run` também tem de validar |
| Planejar um passo sem prever o **insumo** dele | O item 2 dizia "usar `--source`" e ninguém tinha previsto como o tarball chegaria ao alvo — implementar direto daria erro de arquivo inexistente | Leia o plano com olhos de **executor**: para cada passo, pergunte "de onde vem a entrada?" |
| Guarda negativo com `grep` de texto que aparece em **comentário** | O guarda reprova o repositório correto (ex.: o Dockerfile **cita** `COPY build/bin` para explicar por que NÃO usá-lo) | Ancore na forma do comando (`^COPY[[:space:]]+.*build/bin`) e teste o guarda com um caso positivo |
| `sed -i` na 1ª linha de um script com `#!` | Pode trocar o **shebang** (`#!/usr/bin/env bash` vs `#!/bin/sh`) e mudar o interpretador | Nunca use `sed -i '1s/…'`; confirme o shebang depois (o CI verifica o modo estrito por shebang) |
| Renomear/remover uma **chave de matriz** do CI e esquecer quem a consome | Ficou `${{ matrix.profile }}` no `build-llama.yml` depois de a matriz virar `family` → o **nome do artefato ia vazio** e o `upload-artifact` falharia (só num run de tag, longe do PR) | Ao renomear uma chave de matriz, `grep -n 'matrix\.'` no workflow inteiro; prefira `matrix.family` a nomes genéricos |
| Documentar citando **nomes/comandos de cabeça** | A doc descreve algo que não existe, e ninguém descobre até alguém tentar (ex.: `@@PROFILE@@`, removido na refatoração) | Sempre **copie a saída real** (rode o script) e confira nomes com `grep` no código antes de escrever |

---

## 7. 🧭 Convenções de trabalho (o que o CI exige)

O job **`project-rules`** do CI transforma as regras do `AGENTS.md` em testes.
Se você violar uma, o **CI fica vermelho**:

| Regra verificada | Consequência |
|------------------|--------------|
| Arquivos obrigatórios presentes (inclui `iso/`, `docs/ISO.md`, `JOURNAL.md`, `README.technical.md`) | Erro nomeando o arquivo que falta |
| `AGENTS.md` referencia `docs/TUTORIAL.md` e diz "entregável final" | Erro |
| `README.md` referencia o `README.technical.md` **e vice-versa** (cada um mantém seu público) | Erro |
| Modo estrito em todo `.sh` (bash: `set -euo pipefail`; sh: `set -eu`) | Erro nomeando o script |
| `docs/STATE.md` tem "Próxima ação imediata", "Última atualização", "Métricas de performance" | Erro |
| `docs/VALIDATION.md` segue preenchível (`_(preencher)_`, `Bloco F`, `Template de relatório`) | Erro |
| Templates do preseed mantêm os marcadores (`@@ROLE@@` em `firstboot.sh`, `@@FAMILY@@` em `late-command.sh`, `late_command`, `firstboot-pending`) | Erro |

### Como rodar **tudo** localmente antes de commitar

```bash
export PATH="$HOME/.local/bin:$PATH"   # shellcheck + yamllint
make ci          # = lint (bash/shellcheck/python/yaml/iso) + docs + dry-run
```

---

## 8. ✍️ Como registrar uma nova sessão (template)

Ao **fim de cada sessão**, faça nesta ordem:

1. **Acrescente uma sessão** em § 4 (copie este template):

```markdown
### Sessão #N — AAAA-MM-DD · <título curto>

- **Objetivo:** <o que você queria resolver>
- **Feito:** <arquivos/mudanças concretas>
- **Decisões:** <escolhas e o porquê (o mais valioso p/ o futuro)>
- **Problemas:** <o que deu errado e como resolveu>
- **Verificado:** <comandos/testes — e o que NÃO foi verificado>
- **Commits:** `<hash>` — <título>
```

2. **Atualize § 5** (threads abertas): feche o que resolveu, acrescente o novo.
3. **Atualize § 2** se mudou o ambiente (instalou/removeu ferramenta).
4. **Atualize § 6** com armadilhas novas.
5. **Atualize o `docs/STATE.md`** — § 3 (status), § 5 (métricas) e **§ 6
   (Próxima ação imediata)**.
6. Atualize `docs/ROADMAP.md` se moveu algo entre seções.
7. Se fechou **marco/versão**: atualize `docs/TUTORIAL.md` (**Regra 9**).
8. Rode `make ci` e só então commite/push.

> **Se você só puder fazer uma coisa:** atualize a **"Próxima ação imediata"**
> do `STATE.md` e as **threads abertas** (§ 5) daqui. É o que mais salva uma
> sessão futura.

---

## 9. Histórico deste documento

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação — diário de continuidade (sessões #1–#8), inventário do ambiente, threads abertas e armadilhas. |
| 2026-10-12 | Sessões #9–#13 (famílias → ISO Ubuntu → ferramentas de validação → Zen 3/4 + GPU → documentação por público). Corrigido o marcador "Última entrada" do topo (estava parado em #7) e a lista de marcadores do § 7 (era `@@PROFILE@@`, removido na refatoração). |
| 2026-10-12 | Sessão #14 — fechadas as duas dúvidas de arquitetura da ISO (**air-gapped = sim**; **compilar no 1º boot > binário pré-colado**). Item 1 dos requisitos implementado (`--source`). Nova dúvida aberta: o modelo vai na mídia? |
| 2026-10-12 | Sessão #15 — o **modelo `.gguf` vai na mídia** (`--iso-model`): implementada a corrente completa `--iso-model` → `/models` → `MODEL_FILE` → `AI_MODEL_FILE` → `--model-file`, com validação de magic/tamanho em 4 pontos e guardas (inclusive negativos) no CI. **Nenhuma dúvida de arquitetura em aberto**: as pendências agora são de execução. |
| 2026-10-12 | Sessão #17 — **a fonte do llama.cpp vai na mídia** (`--iso-source`): fecha o air-gapped no código (o 1º boot não precisa mais de rede). Corrente exercitada ponta a ponta num sandbox. Novo `ISO.md` § 9 (**checklist de fechamento**) e o achado do **limite de 2 GiB por arquivo de Release** do GitHub. |
| 2026-10-12 | Sessão #16 — **repositório apt local na mídia** (`--iso-repo`, orçamento de 8 GB): fecho de dependências, índice com `dpkg-deb` (sem `dpkg-dev`), fonte **extra** (seção `sources`/`apt-setup/local0`), recusa de release diferente, limpeza da fonte morta no alvo e verificação no `verify-iso.sh`. **O `apt` real aceitou o repositório** montado pelo projeto. Falta só o item 2 para o 1º boot ser offline. |

> **Ao criar uma sessão nova, atualize também a "Última entrada" no topo deste
> arquivo** — é o primeiro número que uma sessão futura olha para saber se está
> lendo algo atualizado.
