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
> **Última entrada:** sessão **#7** (2026-10-07) — ISO de instalação.

---

## 1. ⏱️ Retomada em 5 minutos

Se você só tem 5 minutos, faça exatamente isto:

```bash
# 1. Ler o essencial (nesta ordem)
less AGENTS.md            # propósito + regras
less docs/STATE.md        # onde estamos + "Próxima ação imediata" (§ 6)
less docs/JOURNAL.md      # este arquivo: § 5 (threads abertas) e § 6 (armadilhas)

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

**Commits desta sessão:** (a preencher após o push).

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

**Commits desta sessão:** (a preencher após o push).

---

## 5. 🧵 Threads abertas (o que ficou no ar)

> **Esta é a seção mais importante para retomar.** Lista o que está *incompleto*,
> *decidido mas não feito* ou *em dúvida*.

### 5.1 Bloqueado por ambiente (não dá para fazer nesta máquina)

| Thread | Bloqueio |
|--------|----------|
| Gerar e bootar a ISO | Falta `xorriso`/`mtools`. *Solução:* `sudo apt install -y xorriso isolinux mtools`, ou rodar o workflow `iso` no GitHub. |
| Validar em hardware real | Falta acesso físico ao Xeon e ao Ryzen. |
| Medir tokens/s (`llama-bench`) | Depende do item acima. |
| Compilar o llama.cpp localmente | CPU fraca (2 núcleos) — use os binários da Release `v0.2.0` ou o CI. |

### 5.2 Decidido, mas ainda não executado

| Thread | Nota |
|--------|------|
| **PR #1 do Dependabot** | ✅ verde, rebaseado sobre `main`, **não mesclado**. Basta clicar em *Merge*. Bumps verificados com `git ls-remote`. |
| **Bloco M** (`VALIDATION.md`) | Roteiro da ISO pronto; nenhuma execução ainda. |
| **Blocos A–L** (`VALIDATION.md`) | Idem — nenhum resultado preenchido. |
| **`md5sum.txt` da ISO** | Gerado pelo script, mas **nunca validado** por um instalador real. |
| **Boot UEFI da ISO** | Implementado como *best-effort* (precisa de `mtools`); **não testado**. |

### 5.3 Dúvidas em aberto (requerem decisão sua)

| Dúvida | Contexto |
|--------|----------|
| A ISO deve ser **air-gapped** (sem internet)? | Hoje o 1º boot precisa de rede para clonar o llama.cpp. Um variante pode embutir o fonte + `.deb`. Ver `docs/ISO.md` § 8. |
| Embutir o **binário pré-compilado** em vez de compilar no 1º boot? | Muito mais rápido, mas exige uma ISO **por perfil**. |
| Suportar **Ubuntu** também? | O usuário pediu "Ubuntu ou Debian". Hoje só Debian. Ubuntu = autoinstall/Subiquity (mecanismo diferente). |

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
| `git push` rejeitado (`non-fast-forward`) | Alguém (você, pelo site) comitou no remoto | `git fetch` → inspecionar → `git rebase origin/main` → push (nunca force no `main`) |
| `sed -i "s/.*texto.*/.../"` em `.md` | Pode quebrar linha sem intenção | Prefira edições por bloco com contexto |
| Editar **bloco** de texto incluindo a quebra de linha final | O texto seguinte **gruda** na mesma linha (ex.: `perfil├── .github/`) e corrompe a árvore/lista | **Sempre confira o resultado** (`sed -n ...p`, `git diff`) e inclua a linha seguinte no contexto da edição |
| `sed -i` na 1ª linha de um script com `#!` | Pode trocar o **shebang** (`#!/usr/bin/env bash` vs `#!/bin/sh`) e mudar o interpretador | Nunca use `sed -i '1s/…'`; confirme o shebang depois (o CI verifica o modo estrito por shebang) |

---

## 7. 🧭 Convenções de trabalho (o que o CI exige)

O job **`project-rules`** do CI transforma as regras do `AGENTS.md` em testes.
Se você violar uma, o **CI fica vermelho**:

| Regra verificada | Consequência |
|------------------|--------------|
| Arquivos obrigatórios presentes (inclui `iso/`, `docs/ISO.md`, `JOURNAL.md`) | Erro nomeando o arquivo que falta |
| `AGENTS.md` referencia `docs/TUTORIAL.md` e diz "entregável final" | Erro |
| Modo estrito em todo `.sh` (bash: `set -euo pipefail`; sh: `set -eu`) | Erro nomeando o script |
| `docs/STATE.md` tem "Próxima ação imediata", "Última atualização", "Métricas de performance" | Erro |
| `docs/VALIDATION.md` segue preenchível (`_(preencher)_`, `Bloco F`, `Template de relatório`) | Erro |
| Templates do preseed mantêm os marcadores (`@@PROFILE@@`, `late_command`, `firstboot-pending`) | Erro |

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

> **Ao criar uma sessão nova, atualize também a "Última entrada" no topo deste
> arquivo** — é o primeiro número que uma sessão futura olha para saber se está
> lendo algo atualizado.
