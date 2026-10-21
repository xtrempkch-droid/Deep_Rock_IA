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
> **Última entrada:** sessão **#28** (2026-10-16) — 🔴 o `build-llama` do CI
> quebrou com **SIGILL** (AVX-512 `auto` + cross-build executado em runner sem
> AVX-512); famílias AVX-512 viraram **compile-only** no CI. Ver § 4.

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

# 3. Ver o que já foi provado (verde) e o que NÃO foi provado
#    - validate         ✅ verde
#    - build-llama      ✅ verde (compila e roda de verdade)
#    - container        ✅ verde (imagem no GHCR)
#    - ISO Ubuntu (#21) ✅ GERADA e BOOTADA em VM (KVM) — hardware Ubuntu 🔴
#    - ISO Debian (#35/#37) ✅ VM + metal, mas DEPRECADA (ADR-001)
#    - webui (#24) ⚠️ 34 asserções de API; 🔴 NUNCA aberta num navegador
#    - identidade por papel / ai-talk 🔴 só decisão/desenho (sessão #39)
```

**Depois disso**, vá para a "Próxima ação imediata" em `docs/STATE.md` § 6.

> 🖥️ **Para gerar a ISO sem decorar flags:** `make ui` → http://127.0.0.1:8787
> (sessão #24; só biblioteca padrão; sem `xorriso` ela **recusa** e explica).


> 🎉 **A ISO existe e roda (2026-10-13).** O critério de conclusão do projeto
> (uma ISO que instala sozinha e aplica o ai-cpu-os no 1º boot) **foi cumprido
> numa VM** e o fluxo já foi validado em metal (A8-9600, Debian). O que falta é
> repetir em **hardware físico com Ubuntu** (Xeon/Ryzen) e validar o **UEFI**.
> O caminho Debian foi executado (#35/#37), mas está **deprecado** (ADR-001) e
> será removido. Ver `STATE.md` § 3.3/§ 3.6.
>
> 🧭 **Decisões de 2026-10-20 (sessão #39), ainda não implementadas:** uma ISO
> **Ubuntu** (ADR-001), **identidade pelo papel** (ADR-002) e chat de frota
> **`ai-talk`** (ADR-003). Leia `docs/DECISIONS.md` e `docs/CHAT.md` antes de
> propor trabalho nessas áreas; a ordem é P0→P3 em `STATE.md` § 6.

> ⚠️ **Regra de ouro da retomada:** não confie na memória — confie no
> `STATE.md` § 6. Ele é reescrito ao fim de cada sessão justamente para isto.

---

## 2. 🧰 Inventário do ambiente de desenvolvimento

Isto evita perder tempo (re)descobrindo o que já se sabe sobre **esta** máquina.

| Item | Situação | Consequência |
|------|----------|--------------|
| Máquina (atual, sessão #21) | **24 vCPU** (Xeon E5-2676 v3), **14 GB RAM**, 790 GB livres, Ubuntu **26.04**, `/dev/kvm` ✅, Docker ✅ | **Tudo que era "bloqueado por ambiente" foi destravado**: gerar/bootar a ISO, compilar o llama.cpp. Ver § 4, sessão #21. |
| Máquina (antiga) | Notebook AMD A4-3300M, 2 núcleos | Compilar era inviável — por isso o CI compilava. |
| `shellcheck`/`yamllint`/`xorriso`/`qemu` | ❌ no host; ✅ via `docker run ubuntu:24.04` | `make validate`/ISO rodam **dentro do container** (`apt-get install -y shellcheck yamllint xorriso make python3-yaml`). |
| `gh` (GitHub CLI) | ❌ ausente e sem token | Não dá para disparar/consultar workflows por CLI. Use o **navegador** ou a **API pública**. |
| API do GitHub (sem token) | 60 req/h | **Nunca faça polling agressivo** — ativa a "abuse detection" e bloqueia por minutos. Ver § 6. |
| `sudo` no host | pede senha | Prefira o **container** (root grátis) para o que exige root (`build-iso.sh`, `apt`). |

### Receita: rodar a esteira e a ISO nesta máquina (sem sudo no host)

```bash
# 1) make validate + verificação (num container com as ferramentas)
docker run --rm -v "$PWD":/work -w /work ubuntu:24.04 bash -c \
 'apt-get update -qq && apt-get install -y -qq make shellcheck yamllint xorriso \
   curl python3-yaml gzip coreutils >/dev/null && make validate'

# 2) gerar a ISO air-gapped (container 24.04 = base da ISO + root)
docker run --rm -v "$PWD":/work -w /work -e DEBIAN_FRONTEND=noninteractive \
 ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq \
   xorriso curl ca-certificates coreutils xz-utils tar gzip python3-yaml >/dev/null && \
   bash iso/build-iso.sh --distro ubuntu --disk /dev/vda --serial-console \
     --role auto --family auto --iso-source auto --iso-model auto \
     --iso-repo auto --yes'

# 3) bootar/instalar em VM (qemu do HOST, com /dev/kvm)
bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-<data>.iso \
  --ram 6144 --cpus 4 --timeout-min 90 --keep --yes
```

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

**Commits desta sessão:** `10aa352` — `feat(iso)!: a fonte do llama.cpp vai na mídia — o air-gapped está fechado`.

---

### Sessão #18 — 2026-10-12 · 🧹 Limpeza + 🔴 o CI estava VERMELHO no `main`

**Objetivo (pedido do usuário, verbatim):** *"não estarei aqui para acompanhar.
limpe e organize o repo e verifique os erros do action e corrija"*.

**A descoberta que muda tudo:** o workflow `validate` estava **vermelho no
`main`** havia duas sessões — e **eu não tinha visto**, porque `make validate`
passa aqui. Fui olhar os runs pela API (`gh` não existe nesta máquina; a API
pública do GitHub funciona sem token para repo público, e as *annotations* são
legíveis mesmo com o log em 403).

```
2026-10-12T18:58  validate  main  push  failure   ← commit da sessão #17
2026-10-12T17:39  validate  main  push  failure   ← commit da sessão #16
2026-10-12T17:05  validate  main  push  success   ← antes das minhas mudanças
```

Passo exato que falhava: **"ISO (dry-run dos dois caminhos)"** (e só ele).

**A causa (e por que o local não pegou):**

- Aquele passo roda `--distro debian --dry-run` **sem** as flags novas,
  então `--iso-repo` caía no valor **default** (`auto`) — e o meu código
  fazia `exit 1` quando o alvo era Debian numa máquina Ubuntu (os `.deb` de
  uma base não servem na outra).
- **Eu tinha quebrado um default.** Qualquer invocação existente
  (`--distro debian`) passaria a falhar, mesmo sendo um pedido razoável.
- O `make validate` local **não rodava aquele passo**: ele era um bloco
  `run:` **duplicado** dentro do `validate.yml`. Comando duplicado entre CI
  e `make` é comando que diverge — e divergiu.

**Feito:**

1. **`--iso-repo auto` degrada, nunca aborta** (Regra 13-a, nova). Quando não
   dá para montar um repositório *correto* — alvo Debian numa máquina Ubuntu,
   ou release diferente da ISO — ele **avisa alto e segue sem o repo**: a ISO
   continua válida (só passa a precisar de rede para instalar pacotes). Erro
   **fatal** ficou reservado para **entrada do usuário** (`--iso-repo DIR`
   inexistente ou sem `.deb`), que é corrigível. As mensagens do caso
   não-fatal passaram de `log_error` para `log_warn` (error em vermelho que
   não falha confunde quem procura o problema no log).
2. **`make iso-dry-run-both`** — o comando dos dois caminhos agora é um alvo
   do `Makefile`, está dentro do `validate` e o **CI chama esse alvo**. Um só
   lugar para manter.
3. **`iso.yml` alinhado:** estava em `actions/*@v4` enquanto todo o resto do
   repo já estava em `@v6`/`@v7` — o bump do Dependabot (PR #1) não o
   alcançou porque o arquivo nasceu depois. Agora `checkout@v7` +
   `upload-artifact@v6`.
4. **Runner fixado em `ubuntu-24.04`** nos jobs que dependem da release (o
   `lint`, que roda o dry-run da ISO, e o `build-iso`). Motivo concreto: o
   `--iso-repo auto` compara a release **desta máquina** com a da ISO, e o
   label `ubuntu-latest` **migra para Ubuntu 26 em 2026-10-19** (o próprio
   GitHub avisa isso como *notice* em cada run). Sem fixar, o resultado
   passaria a depender do ambiente por um motivo invisível.
5. **`build-llama` agora compila do TARBALL** (`--source`), não do clone.
   Isso exercita o **caminho offline** (extração + diretório de topo do
   tarball — onde eu já tinha encontrado o `find | head` com `pipefail`) com
   **cmake de verdade, nas 7 famílias**. Se o download falhar, cai no clone e
   o job continua: o objetivo é *provar*, não depender da rede para passar.
   O `INFO.txt` do artefato passou a registrar a origem do fonte.
6. **Limpeza do repo:** removido o diretório **fantasma `profiles/`** (só um
   `__pycache__/shell-ia.cpython-313.pyc` da estrutura *anterior* à
   refatoração) e corrigida a entrada obsoleta `profiles/ryzen/data/` no
   `.gitignore` (virou `roles/*/data/`). Acrescentadas entradas para o payload
   do gerador de ISO.
7. **Guardas novos no CI** para os dois invariantes: (a) `iso-dry-run-both`
   existe, está no `validate` e o CI o **chama**; (b) nenhum `actions/*` em
   major antigo (`@v1..@v4`). O segundo guarda foi testado com um caso
   positivo (detecta um `@v4` de propósito).

**Auditoria dos workflows que NÃO posso executar** (é onde mora o risco, já
que não tenho `xorriso` nem `cmake`):

| Workflow | Achado |
|----------|--------|
| `validate` | 🔴 o passo da ISO falhava — **corrigido** |
| `iso` | `actions/*@v4` desalinhado — **corrigido**; e o run que falhou na branch do Dependabot era **código velho** (a branch não tem o `--iso-source`), não um bug do `main` |
| `build-llama` | sólido; `matrix.family` em todo lugar (o bug do `matrix.profile` foi corrigido na #13). **Melhorado**: passou a provar o caminho offline |
| `container` | sólido; roda o smoke da imagem em PR e em `main` |

**Estado dos PRs abertos (verificado pela API):**

- **PR #2** (debian `12-slim` → `13-slim` no `docker/`): **✅ 6/6 checks
  verdes**, incluindo os dois smokes de imagem. É seguro mesclar.
- **PR #3** (bump de 2 actions): está **EM CONFLITO** (`mergeable: false`,
  `dirty`) e a análise anterior de "redundante" era **imprecisa** — correção
  abaixo. O único check vermelho dele é o workflow `iso` disparado à mão numa
  branch com código antigo.

  **Correção (mesma sessão, depois de conferir as versões reais na API):**
  o PR #3 mexe em 2 linhas, e o acerto é **50/50**:

  | linha | PR #3 quer | `main` tem | veredito |
  |---|---|---|---|
  | `iso.yml` · `checkout` | `@v4` → `@v7` | **`@v7`** | já feito (foi o que corrigi) → **redundante** |
  | `iso.yml` · `upload-artifact` | `@v4` → `@v7` | `@v6` | **bump REAL** (v7.0.2, 2026-10-07) → não é redundante |
  | `build-llama.yml` · `upload-artifact` | `@v6` → `@v7` | `@v6` | **bump REAL** |

  Ou seja: ao alinhar o `iso.yml` eu pus `@v6` (copiando o resto do repo), mas
  o **`upload-artifact` já está em v7** (v7.0.0 em 2026-02-26). O PR #3 tem
  valor real em `upload-artifact` e **nenhum** em `checkout`.

  O conflito **não** vem do PR #2: os dois PRs mexem em arquivos
  **disjuntos** (`docker/Dockerfile` × workflows), logo **não conflitam entre
  si**. O PR #3 está `dirty` contra o **`main`**, e já estava assim antes de
  qualquer merge — porque eu editei o `iso.yml` no `main` e mudei o contexto
  das duas linhas que ele altera.

  **Segurança da versão v7** (conferida no release notes): é **aditiva** — novo
  parâmetro opcional `archive: false` para upload direto de arquivo único, e
  migração do pacote para ESM. Mesmo runtime (`node24`) nos dois majors. O nosso
  uso (`name:` + `path:` com glob) é o comportamento inalterado do default.

  **Desfecho (caminho B, escolhido pelo dono):** em vez de rebasear o PR #3 por
  uma linha, o `@v6 → @v7` do `upload-artifact` foi aplicado **direto no
  `main`** (nos dois workflows) e o PR #3 fica para ser fechado. Sobrevive
  exatamente o que tinha valor; o hunk do `checkout` já estava satisfeito. Foi
  adicionado guarda no CI para o `upload-artifact` não voltar atrás:
  **negativo** (`@v1..@v6` reprova) + **positivo** (tem de estar em `@v7` nos
  dois arquivos), testado com um caso positivo plantado.

**Decisões (e por quê):**

- **Caminho B para o PR #3: aplicar o bump no `main`, não rebasear.** O PR #3
  tinha **uma** linha com valor real (`upload-artifact` `@v6`→`@v7`) e uma já
  satisfeita (`checkout`). Rebasear um PR de dependabot por causa de uma linha
  é cerimônia sem retorno; aplicar no `main` + guarda no CI dá o mesmo
  resultado e deixa só **um** PR aberto para o dono decidir (o #2). Evidência de
  que o v7 é seguro: release notes aditivo (parâmetro **opcional** `archive`),
  mesmo runtime `node24`, default `name:`/`path:` inalterado.
- **Default degrada; entrada do usuário falha.** É a diferença entre "o
  ambiente não permite" (degrada e avisa) e "você digitou um caminho errado"
  (aborta e explica). Misturar os dois foi o que quebrou o CI.
- **O CI chama o alvo, não repete o comando.** O custo de duplicar é uma
  regressão que passa local e falha remoto — o pior tipo, porque parece que
  está tudo bem.
- **Fixar o runner onde a release importa.** `ubuntu-latest` é conveniente e
  não-determinístico; num job cuja lógica compara a release do host, isso é
  um bug esperando data marcada.
- **Provar o caminho offline onde há ferramenta.** Não tenho `cmake` aqui; o
  CI tem, e compila 7 famílias. Fazer o CI compilar do tarball converte o
  caminho do air-gap de "testado com stubs" para "compilado de verdade".

**Como o erro foi pego (e por que não antes):** foi preciso consultar a API do
GitHub. Nada no ambiente local indicava o problema — `make validate` verde,
`shellcheck` verde, `yamllint` verde, dry-runs manuais verdes. **O único sinal
estava no servidor.** Daí a regra nova: o que o CI roda tem de ser
reproduzível por um alvo do `make`.

**NÃO feito / não testado (importante):**

- **Nada foi validado em hardware nem em VM.** A ISO continua **nunca bootada**.
- **O `iso.yml` corrigido não foi executado ainda:** o workflow só dispara em
  `workflow_dispatch`/tag. A verificação é indireta (dry-run + guardas).
- **Não consigo rodar `xorriso` nem `cmake`** aqui, então os passos "Gerar a
  ISO" e "Compilar" do CI continuam sem execução local — quem prova são o
  workflow e os guardas.
- **Não mesclei os PRs:** o usuário não está presente, e mesclar PR alheio não
  é uma decisão que eu deva tomar sozinho. Deixei a análise pronta (PR #2
  verde, PR #3 redundante).

**Commits desta sessão:** `3bb16cf` — `fix(ci): o validate estava VERMELHO no main — default que abortava + comando duplicado`.

---
### Sessão #19 — 2026-10-12 · 🐛 A ISO **Ubuntu** não era gerada (`exit code 22`)

- **Objetivo:** o dono relatou "confirmado, há erro em gerar a imagem ubuntu".
  Entender e corrigir — sem poder rodar `xorriso` nem ler os logs do CI.
- **Feito:**
  - **Causa achada:** `exit code 22` é código do **`curl`** para HTTP ≥ 400 sob
    `-f`. O `SHA256SUMS` do **Ubuntu** marca o modo binário com **`*`** antes do
    nome (`*ubuntu-24.04.5-live-server-amd64.iso`, igual ao `md5sum -b`); o do
    **Debian** não usa marcador. O `*` ia inteiro para dentro da URL
    (`.../24.04/*ubuntu-…iso`) → **404**. Só por isso o Debian funcionava.
  - **Segundo bug no mesmo lugar:** o `SHA256SUMS` do Ubuntu lista **todas** as
    point releases (24.04.3, .4, .5…) e as variantes desktop/wsl. O `awk` pegava
    a **primeira** entrada casada → baixaria a versão mais **velha**. E o padrão
    sem âncora (`netinst\.iso$`) casava `debian-edu-*` e `debian-mac-*`.
  - **Correção:** `pick_iso_entry` / `pick_iso_entry_by_name` / `normalize_iso_name`
    em `iso/build-iso.sh`; padrões **ancorados** (`^debian-[0-9][^ ]*-amd64-netinst[.]iso$`,
    `^ubuntu-[0-9][^ ]*-live-server-amd64[.]iso$`); escolha da **maior versão**
    (`sort -V | tail -1`); e uma checagem final que **falha com mensagem clara**
    se o nome não for um nome de arquivo simples — em vez de deixar o `curl`
    devolver um 404 mudo.
  - **Teste de regressão:** `tests/test-iso-selection.sh` + `tests/fixtures/`
    com `SHA256SUMS` **reais** (cópias fiéis de `releases.ubuntu.com/24.04/` e
    `cdimage.debian.org/…/current/amd64/iso-cd/`). 13 asserções, sem rede, sem
    root, sem xorriso. Novo alvo **`make iso-select-test`**, ligado ao
    `make validate` e ao CI.
  - **Diagnóstico em falha** no `iso.yml`: extrai as linhas de erro do log e as
    publica como **anotações** — que são **públicas**, ao contrário dos logs de
    job (que exigem token). Foi a falta disso que tornou o `exit code 22`
    indecifrável. E o passo de relatório não derruba mais o job quando o
    `.sha256` não existe (era o que fazia o *segundo* passo ficar vermelho por
    consequência, escondendo a causa).
  - Docs: `TROUBLESHOOTING.md` (seção nova **ISO / Remasterização** com os dois
    sintomas), `ISO.md` (como a ISO base é escolhida), `CI.md` (passos novos),
    `README.technical.md`, `AGENTS.md` (§ 4 e § 8), `STATE.md`, `ROADMAP.md`.
- **Decisões:**
  - **A URL é a evidência, não o código.** Um `exit` numérico do `curl` não diz
    nada; a URL montada diz tudo. Por isso a correção inclui uma **validação do
    nome** com mensagem explícita — o próximo erro desse tipo se explica sozinho.
  - **Fixture inventada não pega esse bug.** Precisei do `SHA256SUMS` **real**
    (o `*` e as múltiplas point releases não existem num arquivo de duas
    linhas). Daí guardar cópias fiéis em `tests/fixtures/`.
  - **Maior versão, não a primeira.** "A versão atual" é o que o comentário
    original prometia; a primeira linha do arquivo é a mais **velha**.
- **Problemas:**
  - **Não consigo ler o log do job** (403 sem token). Rodei a investigação a
    partir das **anotações públicas** (que deram `exit code 22` e os nomes dos
    passos) + a inspeção dos arquivos `SHA256SUMS` **reais** via `curl`.
  - **Esgotei a cota anônima da API (60 req/h)** fazendo polling do CI na sessão
    anterior e fiquei cego no fim. Lição registrada no § 6.
  - **Edição repetida me mordeu de novo:** o `multi_replace_string_in_file`
    inseriu `filename="$(normalize_iso_name ...)"` dentro do `if ubuntu` em vez
    do bloco certo. Foi pego pelo `unbound variable` do `make validate` — a
    lição antiga (conferir a **contagem** de ocorrências) continua valendo e eu
    não a apliquei na hora.
  - **`source` do `build-iso.sh` colidiu com `readonly REPO_ROOT` do teste** —
    a mesma armadilha que já tinha aparecido com `FAMILIES_DIR`. Renomeei para
    `TEST_DIR`/`TEST_ROOT` e registrei no § 6.
  - **O passo "Relatório" também ficou vermelho** no run #6 e eu quase tratei
    como segundo bug: era **consequência** (`cat` de um `.sha256` que só existe
    se o build passou).
- **Verificado:** `make validate` verde com **29 scripts** (entrou o teste novo)
  — `bash -n`, `shellcheck`, `python`, `yamllint`, `iso-lint`, `docs`,
  `families-test` (60/60) e `iso-select-test` (13/13). O passo de diagnóstico do
  `iso.yml` foi **extraído e executado**, e emite as anotações certas. URLs
  conferidas à mão: `curl -sIL` → **200** sem o `*` e **404** com ele.
**2ª parte — o CI voltou a falhar e o motivo era OUTRO (o passo de diagnóstico
funcionou e entregou a causa):**

```
[ERROR] Pacote pedido está AUSENTE no repositório: gnupg
[ERROR] Pacote pedido está AUSENTE no repositório: jq
[ERROR] Pacote pedido está AUSENTE no repositório: git
[ERROR] Repositório incompleto — o alvo precisaria de rede.
```

- **Causa MEDIDA:** `apt-get download a b c` **aborta o LOTE INTEIRO** se UM dos
  nomes não tiver candidato — não baixa nem os válidos:

  ```
  apt-get download git PACOTE-QUE-NAO-EXISTE jq   →  rc=100, ZERO arquivos
  ```

  O fecho do `apt-cache depends --recurse` inclui pacotes **virtuais**, e quais
  são **depende da release do host**. O script baixava em lotes de 25 com
  `|| true`, então cada lote com a isca perdia até 25 pacotes **em silêncio**. Os
  três "ausentes" eram só os **pedidos** que caíram no lote da isca. Na minha
  máquina o fecho não tinha isca — por isso passava local (bug **dependente do
  ambiente**, o pior tipo).
- **Correção:** `packages_with_candidate()` descarta os nomes sem candidato
  **antes** de baixar (barato e resolve o caso comum); o lote que **mesmo assim**
  falhar é refeito **um a um** (isola a falha no nome ruim); os nomes que
  falharam são **reportados** no log (o `|| true` mudo acabou).
  Lote de 25 vs 1-a-1 foi **medido** (5× de diferença) antes de escolher:
  31s vs 155s para 60 pacotes — daí manter lote com fallback, não `-n 1` puro.
- **Teste:** `make iso-repo-test` (`tests/test-iso-repo-filter.sh`, 13
  asserções) — reproduz o caso **offline**, com `apt-get` e `apt-cache`
  substituídos por stubs, e cobre filtro, fallback, degrade e a fixture real do
  `apt-cache policy`. **Verificado contra o código antigo:** com o código
  anterior o teste mostra `obtido: ''` (o lote inteiro perdido) — é o bug do CI
  reproduzido.

**🔴 E um achado MAIOR, ao testar os guardas:**

Ao plantar a violação `xargs -r -n 25` para conferir o guarda novo, o passo
**não reprovou** — com o `grep` achando a violação:

```
grep rc=0 (achou a violação)   →   step4 rc=0 (NÃO reprovou)
```

O `set -e` do bash **ignora o exit status de um comando invertido com `!`**
(está na doc do `set`). Ou seja: **SEIS guardas negativos deste repositório eram
DECORATIVOS** — detectavam a violação e não derrubavam nada. Os testes que eu
fizera antes "reprovavam" por causa do guarda **positivo** que vinha logo depois,
o que dava a impressão de que o negativo funcionava.

- **Correção:** todos os seis convertidos para
  `if cmd; then echo "::error::..."; exit 1; fi` (ganho extra: a **anotação** diz
  o que regrediu, em vez de só o código de saída); meta-guarda que proíbe a forma
  `! cmd` nos workflows; e o teste **`make ci-guards-test`**
  (`tests/test-ci-guards.sh`, 14 casos) que planta **cada** violação numa
  **cópia temporária** e exige que o job falhe — inclusive um caso de árvore
  suja, que **pegou uma linha de teste que eu havia deixado no repositório**.
- **Armadilha nova (a pior do dia):** o meu script de prova anterior mutava a
  árvore real e o `restore` dele não cobria um dos arquivos — deixou uma isca no
  `validate.yml`. O teste novo roda em cópia e detectou. Teste que mexe no
  workspace precisa de cópia ou de backup completo.

**NÃO feito / não testado:**
  - **A ISO ainda não foi gerada nem bootada** — os consertos provam a escolha da
    ISO, a montagem da URL e o download do repo, **não** a remasterização (não há
    `xorriso` aqui). O próximo passo é rodar o workflow `iso` com
    `distro=ubuntu` e `air_gapped=true`.
  - **O `iso.yml` alterado não foi executado.**
  - 🔴 **Caminho Debian + `air_gapped=true` continua quebrado e SEM CAUSA
    CONHECIDA:** o run #6 gerou a ISO (2046 MB) e falhou no fim (`exit 1`),
    provavelmente na verificação automática — mas o log não é legível de fora e
    o diagnóstico só passa a existir agora. O run #7 (mesmo commit, **sem**
    payload: 943 MB) passou. **Reproduzir e ler as anotações novas.**
- **Commits:** `7a3d60d` (parte 1: a escolha da ISO) · `12145db` (parte 2: o repo apt + os guardas decorativos).

---
### Sessão #20 — 2026-10-12 · 🏁 Os dois últimos erros da ISO (runs #9 e #10)

- **Objetivo:** o dono reportou "erro iso #9 e iso #10". O passo de diagnóstico
  criado na sessão #19 já existia, então a causa veio direto nas **anotações**.
- **Feito:**
  - **#9 (ubuntu):** `Pacote pedido está AUSENTE no repositório: git` — e **só
    `git`**. O filtro de candidatos resolveu `gnupg`/`jq` (o mesmo bug da sessão
    #19), então o que sobrou foi **outra** coisa: falha **intermitente de rede**
    no meio do download, que é **indistinguível de "pacote não existe"** no log.
    Corrigido com `Acquire::Retries` e uma **segunda tentativa só dos ausentes**
    (`repo_missing_packages` + `check_repo_completeness` reescrita sobre ela):
    custa **segundos** em vez de repetir 330 MB.
  - **#10 (debian):** `verify-iso.sh` reprovou a ISO com **2 problema(s)**, um
    deles *"o repositório está na mídia mas o autoinstall NÃO o usa"*. Era
    **FALSO POSITIVO**: numa ISO **Debian** não existe `/autoinstall.yaml` (o
    Debian usa **preseed**), e o verificador só olhava o autoinstall para decidir
    se a fonte extra estava em uso. O repo **estava** na mídia e a preseed **o
    usava** (`d-i apt-setup/local0/repository`). A checagem ficou
    **distro-aware**.
  - **Dependências implícitas do runner:** ao tentar reproduzir num container
    `ubuntu:24.04` **limpo**, o build abortou em `openssl não encontrado` — o
    workflow não instalava `openssl`, que existia no runner **por acaso**
    (descobertos também `gzip` e `ca-certificates`). Passaram a ser explícitos.
  - **Diagnóstico mais afiado:** o passo do `iso.yml` só capturava `[ERROR]`.
    O `verify-iso.sh` reprova com `[FAIL]` — então a anotação que chegou era o
    **sintoma** ("não passou na verificação"), sem dizer **o quê**. Agora captura
    `[FAIL]`/`[erro]` e mostra os `[WARN]` (que dizem **qual** pacote falhou).
  - **Teste novo:** `make iso-verify-test`
    (`tests/test-verify-iso-repo.sh`, 6 asserções): monta árvores mínimas
    das **duas** distros e roda o verificador de verdade — sem xorriso, root,
    rede ou Docker. Inclui o **negativo** (config sem a fonte extra → reprova) e
    a **prova de regressão**: pega o verificador do `git` e exige que ele
    **reprove a ISO Debian correta** (isto é, que o bug exista na versão antiga).
- **Decisões:**
  - **Reproduzir para achar a causa, não deduzir.** O container `ubuntu:24.04`
    limpo entregou o `openssl` em segundos — e nada no repositório indicava isso.
  - **No Docker, só o necessário.** O container parou antes de baixar a ISO de
    3 GB (a máquina do dono é lenta e o disco estava em 79%): o que importava era
    o **repo apt** e a **distro**, que eu consigo exercitar sem download.
  - **Verificador com viés de distro é bug de projeto.** Ao escrever uma checagem
    que compara **mídia × configuração**, pergunte **em qual base** ela faz
    sentido — e cubra a outra. Foi o erro do `verify-iso.sh`.
  - **Falha de rede não pode virar "não existe".** Foi o que transformou um 5xx
    momentâneo em "Pacote pedido está AUSENTE: git". `Acquire::Retries` + retry
    dirigido pelos ausentes.
- **Problemas:**
  - O `git` foi o **único** ausente: levou tempo até aceitar que não era o bug do
    lote (já corrigido) e sim uma falha de rede.
  - Reproduzir o build completo em container exige ~6 GB e dezenas de minutos — e
    a máquina do dono não aguenta. **Parei no que dava para provar localmente.**
- **Verificado:** `make validate` verde com **32 scripts** — `families 60/60`,
  `iso-selection 13/13`, `iso-repo-filter 16/16`, `iso-verify-test 6/6`,
  `ci-guards 16/16`; os 4 passos do job `project-rules` extraídos do workflow e
  rodados com `bash -e` (como o CI roda) passam.
- **NÃO feito / não testado:**
  - 🔴 **A ISO continua nunca bootada.** Nada aqui prova a instalação: prova a
    escolha da ISO, o download do repo, o verificador e os guardas.
  - O `iso.yml` alterado **não foi executado** — o próximo passo real é rodar o
    workflow com `distro=ubuntu` **e** `distro=debian`, `air_gapped=true`.
- **Commits:** `274ad96` — `fix(iso): run #9 (git ausente por falha de rede) + run #10 (falso positivo do verificador)`.

---

### Sessão #21 — 2026-10-13 · 🎉 A ISO é GERADA e BOOTADA (o critério de conclusão)

- **Objetivo:** retomar o projeto numa máquina **melhor** que o notebook (24 vCPU,
  `/dev/kvm`, Docker, 790 GB livres, rede) — o que destrava as três threads que
  estavam "bloqueadas por ambiente" (§ 5.1 antigo). Fazer o **passo 3 + passo 4**
  do checklist: gerar a ISO air-gapped e bootá-la/instalar numa VM.
- **Feito (o caminho TODO executado, a primeira vez na vida do projeto):**
  - **Gerada a ISO** dentro de um container `ubuntu:24.04` (resolve o *release
    mismatch* do repo apt — esta máquina é 26.04 — e o `root` que o `build-iso.sh`
    exige). Air-gapped: **fonte do llama.cpp + modelo + repositório apt** na mídia.
  - Descoberto (no container) que o runner não tinha `make`/`shellcheck`; nada que
    afete o produto.
  - **`make validate` verde** (num container com as ferramentas): `families 60/60`,
    `iso-selection 13/13`, `iso-repo-filter 16/16`, `verify-repo-distro 5/5`,
    `ci-guards 16/16`, `iso-dry-run-both` OK.
  - **ISO verificada** (`verify-iso.sh`): **PASS=41 FAIL=0**.
  - **ISO bootada e instalada numa VM** (qemu + KVM, `-cpu host` = Xeon
    Haswell-EP) e o **1º boot aplicou** o ai-cpu-os: `test-vm.sh` →
    **`TESTVM_EXIT=0`**, os **dois marcadores** no console serial, e
    `.firstboot-status: status=ok`, `Concluído (papel 'inference', família
    'intel-haswell')`, `llama-server`/`llama-cli` compilados do tarball, modelo
    em `/opt/models`, repo em `/opt/apt-repo`.
- **Decisões / achados que exigem AÇÃO (8 bugs reais, todos só visíveis ao EXECUTAR):**
  1. `xorriso … -rm X -commit -end`: o `-rm` engole `-commit`/`-end` como
     caminhos → `SORRY` → **exit 32** com a ISO já escrita. Fix: `-rm X --`.
  2. `-boot_image any keep` **não copia a imagem UEFI oculta** do Ubuntu → ISO
     ~6 MB menor, `efi.img` de 1 bloco, MBR protetor além do fim (exit 32).
     Fix: `-boot_image any replay` (re-anexa a partição EFI via `imported_iso`).
  3. O caminho Ubuntu mapeia só o que muda (`-map`): **faltavam** `/apt-repo`,
     `/models` e `/llama-src.tar.gz` na ISO. Fix: 3 `-map`.
  4. `verify-iso.sh`: `xorriso -find` cita caminhos entre **aspas simples** →
     igualdade quebrava → **408 falsos** "repositório incompleto". Fix: helper
     `xfind` que tira as aspas.
  5. `verify-iso.sh`: `printf … | grep -q` com `set -o pipefail` → **SIGPIPE
     (141)** → falsos "fonte não tem CMakeLists". Fix: here-string `<<<`.
  6. **GRUB**: `set default="ai-cpu-os-auto"` casa por **id** ou título, e a
     `menuentry` **não tinha `--id`** → o GRUB caía na entrada **0** (a
     interativa) e a instalação automática **nunca acontecia**. Fix: `--id`.
     (O verificador só fazia `grep`, casando com o próprio `set default`.)
  7. **Repositório apt local**: o curtin roda `apt-get update` **dentro de um
     chroot no alvo**, onde **`/cdrom` não existe** → `file:///cdrom/apt-repo`
     derrubava o `apt-config` (**exit 100**, "does not have a Release file").
     Fix: o repo vai para o **alvo** (`/opt/apt-repo`) pelo late-command e é
     usado no 1º boot; o `sources` do autoinstall não o declara mais; e o índice
     ganhou `Release`.
  8. **Marcadores**: o `log()` do late-command vai para o log do subiquity e o
     firstboot logava só no **journal** → o `test-vm.sh` **nunca via** os
     marcadores (era o teste que "não via nada"). Fix: eco no `/dev/console` e
     `StandardOutput=journal+console`.
  - Também: `build.sh` repassava `--yes` ao `smoke-test.sh`, que não o aceitava
    ("Argumento desconhecido") — corrigido (era ruído não-fatal, mas agora limpo).
  - `test-vm.sh`: `-boot d` + `-no-reboot` matavam o 1º boot (o instalador
    reinicia). Fix: `-boot order=c,once=d`, sem `-no-reboot`.
- **Problemas:**
  - Depurar o "não boota" sem tela: resolvido com **screenshot do framebuffer via
    QMP** (`screendump`) + OCR (`tesseract` em container) + **console serial
    bidirecional** (`-serial unix:`) para logar na VM e ler `journalctl`.
  - O serial do subiquity **não** traz a saída do curtin; o erro real estava no
    `journalctl` (`curtin.util.ProcessExecutionError`, exit 100).
- **Verificado:** build **exit 0** + `verify-iso.sh` **PASS=41/FAIL=0** +
  `test-vm.sh` **exit 0** + `.firstboot-status: status=ok` (login na VM
  instalada) + `make validate` verde.
- **NÃO feito / não testado:**
  - 🔴 **Debian/preseed nunca executado** (só o caminho Ubuntu foi bootado).
  - 🔴 **Boot UEFI nunca testado** (`--boot-mode uefi`).
  - 🔴 **Hardware físico** (Xeon E5-2680 v4 e Ryzen 5 3500X) — Blocos A–O.
  - ⚠️ **Resíduo air-gapped em investigação** (§ 5.3): o build do llama.cpp
    ainda tenta baixar o **UI** do HuggingFace (parece best-effort; o `.sha256`
    falhou e o build seguiu).
- **Commits:** *(ver `git log`)* — `fix(iso): a ISO é gerada e bootada pela
  primeira vez` + docs.

---
### Sessão #22 — 2026-10-14 · 🔌 O passo final: gravar num PENDRIVE

- **Objetivo:** o dono quis uma ferramenta para transformar a ISO (agora provada
  na sessão #21) num **pendrive bootável** — e é o passo mais perigoso do
  projeto. Ele também cogitou uma **WebUI** para isso; a análise está no fim
  desta entrada.
- **Feito:** `iso/write-pendrive.sh` + `tests/test-write-pendrive.sh` (16
  asserções) + `make pendrives` / `make pendrive DEVICE=/dev/sdX` /
  `make pendrive-test`.
  As **9 travas** (o produto é a trava; o `dd` é consequência):
  1. recusa o disco que contém `/`; 2. recusa disco **não removível** sem
  `--allow-internal` (que exige o caminho completo); 3. exige **disco inteiro**
  (`TYPE=disk` — um `sr0`/DVD tem `RM=1` e passaria como “removível”);
  4. recusa se houver partição **montada**; 5. exige assinatura **`CD001`**;
  6. confere que a ISO **cabe**; 7. **avisa** se o dispositivo for muito maior
  (alvo errado); 8. exige digitar o **nome** do dispositivo (`--yes` pula só a
  pergunta, **nunca** as travas 1–6); 9. **lê de volta** e compara byte a byte
  (`cmp -n`, com `dd conv=fsync` antes).
- **Decisões:**
  - **O teste nunca toca um dispositivo.** `make pendrive-test` grava num
    **arquivo** e exercita as funções de trava com um `lsblk` **simulado** —
    inclusive os casos que **devem** ser recusados. É assim que um passo
    destrutivo vira testável no CI.
  - **`--yes` não é “sem travas”.** `--yes` só evita digitar o nome do alvo;
    nenhuma trava de segurança é pulada. Confundir os dois é como um passo
    destrutivo vaza para automação.
  - **Falha rápido na entrada:** a checagem da ISO (existe? é ISO 9660?) roda
    antes de tudo — melhor descobrir na hora do que depois de abrir o
    dispositivo.
  - **`cmp -n BYTES`** em vez de `cmp` puro: compara exatamente o tamanho da ISO
    e para na primeira diferença, sem depender de EOF dos dois lados.
- **Problemas:**
  - A rodada anterior foi interrompida e deixou o repositório **vermelho**: a
    mensagem de aviso do passo “Tamanho da ISO” tinha a linha partida e a 2ª
    linha virou **comando solto** → `command not found` → **exit 127** (foi o
    que fez o run #15 falhar **com a ISO já gerada**, 3891 MB). Corrigido
    montando a mensagem numa **variável** (mantém as linhas curtas para o
    `yamllint` **sem** quebra com `\`, que exigiria indentação e quebraria o
    bloco YAML do `run: |`).
  - O `README.md` tinha uma nota **desatualizada** (“ninguém ainda bootou a
    ISO”) contradizendo o resto do próprio arquivo, já que a sessão #21 provou
    o boot. Corrigida.
- **Sobre a WebUI (que o dono perguntou):** ideia válida, **escopo da proposta
  era ~3× maior do que serve**. O que acerta: wizard, preview do `--dry-run`,
  teste em VM e validação de “modelo × RAM do alvo”. O que não se aplica:
  Celery + Redis + Svelte + JWT + quotas para **duas máquinas** — e a própria
  regra do projeto (“1% importa”) rejeita infra que não paga por si. Upload de
  4.5 GB por HTTP é pior que `cp` (o filesystem **é** o cache). E o ponto que a
  proposta não trata: **onde isso roda?** Não pode entrar na ISO (Regra 13-b),
  não roda no notebook do dono (sem `xorriso`) — roda num container na máquina
  de build, ou (melhor) vira **front-end do GitHub Actions**, que já gera a ISO.
  Regra inegociável se for adiante: a UI **chama `make`/os scripts, nunca
  reimplementa** — comando duplicado divergiu e quebrou o CI **duas vezes em
  duas sessões**.
  **Ordem sugerida:** (0) o pendrive — **feito aqui**, e é o que entrega o
  objetivo declarado; (1) UI fina (FastAPI + SSE, sem banco/fila) só sobre alvos
  do `make`; (2) front-end do Actions.
- **Verificado:** `make validate` verde com **34 scripts** — `families 60/60`,
  `iso-selection 13/13`, `iso-repo-filter 16/16`, `verify-repo-distro 6/6`,
  `ci-guards 16/16` e **`write-pendrive 16/16`**. Guardas novos no CI para as
  travas (`TYPE=disk`, `CD001`, `dev_is_removable`, `conv=fsync`, `cmp -n`,
  `confirm_target`, `allow-internal`, `root_disk_name`, `sistema em execução`) e
  para o teste gravar num **ARQUIVO**.
- **NÃO feito / não testado:**
  - 🔴 **Nenhum pendrive real foi gravado.** As travas e o `dd`→`cmp` foram
    provados **contra um arquivo**; a gravação num dispositivo físico segue
    **não validada**.
  - `iso/write-pendrive.sh` (`--list`) foi exercitado nesta máquina (reconheceu
    e **recusou** o disco interno corretamente), mas o hardware do dono não tem
    pendrive plugado.
- **Commits:** `3692771` — `feat(iso): gravar a ISO num PENDRIVE — o passo final, com 9 travas`.

---
### Sessão #23 — 2026-10-14 · 📥 A ISO volta a ser BAIXÁVEL (+ conferência sem xorriso)

- **Objetivo:** o dono pediu "uma ferramenta adicional onde o usuário possa ou
  não criar um arquivo ISO para usar com outros programas", e avisou que está
  numa **máquina limitada**. Praticamente: ele **não tem `xorriso`**, então não
  consegue gerar a ISO aqui — e sem ISO não há pendrive.
- **Feito:**
  - 🔴 **Achado grave:** o workflow gateava o **artifact** pelo limite de
    **2 GiB** — que é de **asset de Release**. O mesmo booleano (`too_big`)
    decidia os dois canais, então a ISO air-gapped (~4 GB) era **gerada e
    descartada**, e quem não tem `xorriso` ficava **sem nenhum caminho** para
    obter o arquivo. Agora só a Release é gateada (`release_too_big`) e o
    artifact **sobe sempre**. Guarda no CI contra a regressão.
  - **`iso/check-iso.sh`** + `make iso-check ISO=…` — confere uma ISO **baixada**
    com `dd`/`od`/`sha256sum`, **sem `xorriso` e sem root**: tamanho plausível,
    SHA256 (lê o `.sha256` ao lado sozinho), assinatura **`CD001`** no setor 16,
    **Volume ID** `AI_CPU_OS_*` e assinatura de boot (**MBR `0x55AA`**).
  - **`tests/test-check-iso.sh`** (20 asserções) com fixtures construídas **byte
    a byte** (`python3`), cobrindo os modos de falha reais: **artifact `.zip`
    renomeado** para `.iso` (o erro mais comum do caminho), download truncado,
    1 byte corrompido, Volume ID de outra origem e ausência de assinatura de
    boot. `make ci-guards-test` passou a provar os guardas novos (22 casos).
- **Decisões:**
  - **Medir o limite, não assumir.** Fui ao README oficial do
    `upload-artifact` em vez de confiar no comentário que eu mesmo tinha escrito
    antes: os limites documentados para artifacts são **número por job** e
    **perda de permissões** — **não existe 2 GiB** para artifact. O comentário
    antigo estava errado e custava o entregável.
  - **Canal certo para cada limite.** 2 GiB é limite de **Release**; artifact é
    para artefato de execução. Gatear os dois pelo mesmo número foi o bug.
  - **Complementar, não duplicar.** `check-iso.sh` **não** reimplementa o
    `verify-iso.sh`: ele usa ferramentas de base e responde a outra pergunta
    ("o arquivo chegou inteiro e é o certo?" × "o conteúdo está certo?"). A
    divisão está escrita nos dois cabeçalhos para ninguém fundir os dois.
  - **Exit code 2 = erro de uso; 1 = a ISO tem problema.** Quem scripta em cima
    precisa distinguir "você digitou o caminho errado" de "o download está
    ruim".
  - **Sem token, sem mágica.** Baixar artifact exige estar logado (o
    `artifact-url` também). Então a ferramenta **não** tenta automatizar o
    download com credenciais: ela confere o que você baixou e **diz o próximo
    comando**. Automação que exige segredo do usuário não entra aqui.
- **Problemas:**
  - **O `name:` do passo com `:` solto quebrou o YAML** (`mapping values are not
    allowed here`) — precisa de aspas. Erro barato, mas o `yamllint` pegou.
  - Coloquei `if-no-files-found` **fora do `with:`** (não é parâmetro de passo):
    corrigido antes de validar. É o tipo de erro que só aparece no run.
- **Verificado:** `make validate` verde com **36 scripts** — families 60/60,
  iso-selection 13/13, iso-repo-filter 16/16, verify-repo-distro 6/6,
  ci-guards **22/22**, write-pendrive 16/16 e **check-iso 20/20**.
- **NÃO feito / não testado:**
  - 🔴 **Nada disso foi executado contra um artifact real do GitHub.** O
    `check-iso.sh` foi provado com fixtures byte a byte (inclusive um `.zip`
    fingindo de `.iso`), mas **nenhum download de verdade** passou por ele.
  - A correção do gate do artifact **ainda vai rodar** num run novo; até lá, a
    prova é a documentação oficial + o guarda.
  - Continua: nenhum **pendrive físico** gravado; caminho **Debian**, **UEFI** e
    **hardware físico** sem validação.
- **Commits:** `263aeff` — `fix(iso)!: a ISO volta a ser BAIXAVEL + make iso-check (conferencia sem xorriso)`.

---

### Sessão #24 — 2026-10-15 · 🖥️ Interface web local (gerar a ISO sem decorar flags)

- **Objetivo:** o pedido foi direto — *"uma ferramenta de web UI para facilitar a
  vida do usuário que usa o repositório, assim ele pode criar uma imagem ISO sem
  dificuldade"*. O foco é o **usuário que não conhece o projeto**: ele não sabe
  que existe `--iso-source`, nem o que é `--iso-repo auto`, e não deveria
  precisar saber.
- **Feito:**
  - **`webui/server.py`** — servidor **só de biblioteca padrão** (`http.server`,
    `json`, `subprocess`), que serve a página e expõe uma **API pequena**:
    `/api/status` (hardware detectado, espaço livre, quais ferramentas existem),
    `/api/options` (famílias lidas de `families/`, mods de `mods/` — **lidas do
    repositório**, não duplicadas numa lista paralela que diverge), `/api/preview`,
    `/api/build`, `/api/iso-check`, `/api/iso-verify`, `/api/pendrives` e
    `/api/jobs/<id>` + `/api/jobs/<id>/events` (**SSE** para o log ao vivo).
  - **`webui/index.html`** — página única, HTML+CSS+JS **inline, sem CDN**: o
    alvo é justamente a máquina offline/limitada, uma tag `<script src="https://…">`
    quebraria a página ali.
  - **`tests/test-webui.sh`** — sobe o servidor de verdade numa porta livre e
    exercita a API: **34 asserções**.
  - **Nova Regra 16** no `AGENTS.md` com os invariantes da UI, e **9 guardas
    novos** no CI (cada um com violação plantada).
- **Decisões:**
  - **A UI não é um segundo caminho.** Ela monta a linha de comando a partir de
    valores **validados** e chama **alvos do `Makefile`** que já existem e já
    são testados (`iso/build-iso.sh`, `iso/check-iso.sh`, …). Se um dia ela
    "implementar" algo, isso é decisão de arquitetura — não atalho.
  - **Lista branca fechada** (`ACTIONS`): a UI nunca aceita comando, caminho de
    script ou nome de alvo vindo do navegador. Cada entrada tem o seu validador
    (`v_disk` → `^/dev/[a-zA-Z0-9]+$`, `v_family` → existe `family.conf`?,
    `v_iso_path` → dentro de `iso/out` ou um `.iso` que existe).
  - **Nunca lida com senha.** Gravar pendrive exige root; a UI só **lista** os
    dispositivos e mostra o comando `sudo make pendrive DEVICE=/dev/sdX` pronto
    para o usuário colar no terminal. Senha não entra no navegador, no servidor
    nem em log (há guarda negativo proibindo `password`/`sudo -S`/`askpass`).
  - **Só stdlib.** Esta máquina é limitada e `pip install` **não pode** ser
    pré-requisito para gerar a ISO. Guardas negativos proíbem
    `fastapi`/`flask`/`django`/`requests` e qualquer `pip install`.
  - **Sem `xorriso`, ela RECUSA — com o motivo.** O servidor responde
    `"xorriso não está instalado nesta máquina — gerar a ISO aqui é
    impossível…"` e a página aponta o caminho do **GitHub Actions**. É a Regra
    13-a aplicada ao usuário final: degradar com aviso explícito, nunca falhar
    em silêncio (nem mostrar um botão que não faz nada).
  - **`webui/` fica FORA da ISO** (`--exclude=./webui`): é ferramenta da máquina
    que **gera** a mídia; um `webui/` dentro de `/opt/ai-cpu-os` no alvo não faz
    nada e só confunde.
- **Problemas:**
  - **O teste "não achava" o `<title>` da página** — e a página estava certa.
    Eu passava o corpo de ~17 KB por `printf | grep -q` e a asserção falhava; a
    mesma expressão casava quando rodada à mão. Troquei por comparação direta
    (`[[ "$r" == *"<title>ai-cpu-os"* ]]`): sem pipe, sem `cut`, sem 3
    processos para checar uma substring. **Lição: para checar substring, não
    passe 17 KB por um pipeline — compare na variável.**
  - **`stdout` em bloco escondeu o `PORT=`.** O teste lia a porta que o servidor
    imprime ao subir; com a saída redirecionada para arquivo, o Python **não
    faz flush** e o teste concluía que o servidor nunca subiu. Corrigido com
    `flush=True` no `print` da porta.
  - **`set -u` + `$3` não passado** no helper `expect_400` → `unbound variable`;
    resolvido com `${3:-{}}`.
  - **`status_of` devolvia várias linhas** quando o corpo HTTP era multi-linha
    (`cut -f1` sobre um texto enorme) → `head -1 | cut -f1`.
  - O meu próprio script de repro em `/tmp` falhou porque **eu** esqueci de
    definir `BASE` — perdi tempo perseguindo um bug que era meu, não do código.
- **Verificado:** `make validate` verde; `make ui-test` **34/34**;
  `make ci-guards-test` **31/31** (eram 22 — os 9 novos são todos da UI);
  `make python` compila `webui/` junto com `roles/`.
- **NÃO feito / não testado:**
  - 🔴 **A interface NUNCA foi aberta num navegador de verdade.** Nem por mim.
    Os testes exercitam a **API** (lista branca, validadores, SSE, recusa sem
    `xorriso`, ausência de rota de escrita, bind em `127.0.0.1`). Tudo que for
    **visual** (layout, contraste, um botão que não responde ao clique) é
    **afirmação não verificada**.
  - Não cliquei em "gerar ISO" no navegador **porque esta máquina não tem
    `xorriso`** — e é exatamente isso que a UI responde com uma recusa
    explicativa, o que o teste prova.
  - Continua: nenhum **pendrive físico** gravado; caminho **Debian**, **UEFI** e
    **hardware físico** sem validação.
- **Commits:** `6adc3fd` — `feat(webui): interface web local para gerar/conferir a ISO`.

---

### Sessão #25 — 2026-10-15 · 🔬 O run #16 da ISO voltou a falhar com `git` (e a causa era invisível)

- **Objetivo:** conferir o CI depois de publicar a sessão #24. `validate` e
  `container` estavam em andamento, mas apareceu um run que eu **não tinha
  visto**: `iso` (nº **#16**), disparado **manualmente** no `be2662f`,
  `completed failure`.
- **Feito:**
  - **Diagnóstico sem token.** Os **logs** de job exigem token (403), mas as
    **anotações são públicas**: `curl -s …/check-runs/<job_id>/annotations`.
    Foi de lá que veio a causa:
    `[ERROR] Pacote pedido está AUSENTE no repositório: git` +
    `[ERROR] Repositório incompleto — o alvo precisaria de rede.`
  - **A pista estava no RELÓGIO.** As duas mensagens `Repositório incompleto`
    aparecem com **4 segundos** de diferença. Um download de fecho leva
    **minutos**; 4 s significa que o `apt-get download` **falhou na hora**.
    Logo não era "a rede caiu no meio" — era falha **imediata e repetível**.
  - **Medi em vez de supor:** `apt-get download git` + `find -name 'git_*.deb'`
    na minha máquina → funciona, e o arquivo é `git_1%3a2.51.0-…_amd64.deb`
    (o `%3a` é o epoch). Ou seja: o `find` do `repo_missing_packages` **casa**
    e o mecanismo está certo — o que falhou foi o download, não a checagem.
  - **Causa raiz:** a 2ª tentativa repetia `apt-get download` **com a mesma
    lista** e com `Acquire::Retries`. `Retries` **não conserta uma lista
    inválida**: se o espelho dá **404** (a versão citada já saiu do `archive`,
    típico em virada de *point release*), repetir reproduz o erro **idêntico**,
    rápido. E — o pior — a saída do `apt` era **descartada**
    (`>/dev/null 2>&1`): **a causa não ia para lugar nenhum**.
  - **Corrigido** (`iso/build-iso.sh`, 2ª tentativa): (a) `apt-get update`
    **antes** de repetir — índice fresco é o que resolve o 404; (b) download
    **um a um logando a resposta do `apt`**
    (`log_warn "  <pacote>: <erro do apt>"`); (c) aviso final `Ainda faltando…`.
  - **Mensagem honesta:** `Pacote pedido está AUSENTE no repositório: X` virou
    `Pacote pedido não entrou no repositório local: X (veja os avisos do apt
    acima)`. A palavra "AUSENTE" **afirmava que o pacote não existe** — falso,
    e foi o que me fez caçar um bug inexistente em `git` na sessão #18.
  - **Anotações públicas ganharam a causa:** o `PAT` do `iso.yml` (o filtro que
    converte log em anotação) passou a incluir `Refazendo o download`,
    `Ainda faltando` e `falhou:`. Sem isso a informação ficaria presa no log,
    **que exige token**.
  - **Guardas novos** (3) e **violações plantadas** (2): remover o
    `apt-get update` da 2ª tentativa e fazer o retry voltar a descartar a saída
    do `apt`. `make ci-guards-test`: 31 → **33** casos.
- **Decisões:**
  - **Registrar a causa é parte da correção.** Uma falha que não diz *por quê*
    custa uma sessão inteira: foi o que aconteceu nos runs #9, #10, #16 e #18.
    O par "logar o erro da ferramenta" + "levar isso para a anotação pública" é
    o que transforma uma falha opaca em algo diagnosticável de fora do repo.
  - **Não tratar um default/ambiente como erro fatal** (Regra 13-a): se o
    `apt-get update` da 2ª tentativa falhar (sem rede), **avisa e segue** com o
    índice atual — o build ainda pode dar certo.
- **Problemas:**
  - Perdi um tempo considerável suspeitando do filtro `packages_with_candidate`
    e do `find` do `repo_missing_packages`. **Os dois estavam certos** — e a
    prova custou 1 comando (`apt-get download git` + `find`). **Lição: quando
    uma hipótese é testável em um comando, teste antes de teorizar mais.**
  - O ISO roda **manualmente** (`workflow_dispatch`): eu não fui avisado da
    falha porque não recebo notificação de run manual. Descobri de passagem,
    olhando a lista de runs por outro motivo. **Thread aberta.**
- **Verificado:** `make validate` verde (37 scripts; families 60/60;
  iso-repo-filter 16/16; **ci-guards 33/33**; **webui 34/34**; dry-run dos dois
  caminhos OK). `make iso-lint` e `make iso-repo-test` verdes.
- **NÃO feito / não testado:**
  - 🔴 **A correção não foi exercitada por um run novo.** O `iso` precisa ser
    disparado outra vez para provar que (i) a 2ª tentativa com índice fresco
    resolve o 404 e (ii) a causa aparece na anotação. Até lá, o que está
    provado é o **diagnóstico**, não a **cura**.
  - Não consigo reproduzir o **404 do espelho** localmente (preciso de um
    índice que cite uma versão já removida). A causa raiz é a **melhor
    explicação compatível com a medição** (4 s, erro idêntico), não uma
    observação direta.
- **Commits:** `8e49043` — `fix(iso): a 2a tentativa do repo apt refresca o INDICE e loga o erro do apt`.

---

### Sessão #26 — 2026-10-16 · 🧬 14 famílias de CPU + AVX-512 por padrão

- **Objetivo:** pedido do dono, em paralelo aos testes dele (webui e a ISO
  gerada pela ferramenta — funcionando bem): expandir o suporte às famílias de
  **SERVIDOR**, tornar o **AVX-512 o padrão** nas CPUs que o têm (mais
  desempenho) e incluir as famílias AMD que faltavam (o Zen 5 já está no
  mercado).
- **Feito:**
  - **6 famílias novas** (herança em cadeia): `intel-cascadelake-sp` (v6,
    `-march=cascadelake`), `intel-icelake-sp` (v7, `icelake-server`),
    `intel-sapphirerapids-sp` (v8, `sapphirerapids` + AMX),
    `intel-emeraldrapids-sp` (v9, `emeraldrapids` + AMX),
    `intel-graniterapids-sp` (Xeon 6 P-cores, `graniterapids`, GCC≥14 com
    fallback `sapphirerapids`) e **`amd-zen5`** (Ryzen 9000, Ryzen AI 300,
    EPYC Turin; `znver5`, GCC≥14 com fallback `znver4`).
  - **Decisão do dono aplicada:** `FAMILY_AVX512_POLICY="auto"` nas famílias
    cujas CPUs têm AVX-512 — Skylake-SP (agora **v5 somente**), Cascade Lake+,
    Zen 4 (que TEM `avx512f`) e Zen 5. O AVX-512 liga quando a CPU reporta a
    flag; verificação em runtime mantida (Regra 8), hardcode proibido (Regra 12).
  - **`--no-avx512`** (resolve.sh + llama-build.sh): desliga e **troca o
    `-march` pelo fallback sem AVX-512** (novo `FAMILY_MARCH_HAS_AVX512`) — sem
    isso o GCC continuaria emitindo AVX-512 via `-march`. É o caminho para
    medir AVX2 × AVX-512 no Skylake-SP (downclock) e afins.
  - `amd-zen4` ganhou EPYC 4124P/9754/9684X no casamento e o AVX-512 auto;
    `skylake-avx512` teve o regex restringido (Bronze 32xx/Cascade Lake saíram
    daqui e foram para as famílias novas — o teste de corpus pegou os casos).
  - **Corpus:** 60 → **85 CPUs reais**, incluindo negativos (Xeon `6766E`
    Sierra Forest → `generic`) e cada geração Xeon/EPYC na família certa.
  - CI: matrix do `build-llama.yml` (7 → **14 famílias**) e `required` do
    `validate.yml`.
- **Problemas:**
  - Regex EPYC com `[0-9]{3}` não casava os modelos de **4 dígitos** (9554,
    9755…): o corpus pegou na hora (7 divergências → 0). É o tipo de erro que o
    teste existe para pegar — e pegou.
- **Verificado:** `make validate` verde (**families 85/85**, ci-guards 33/33,
  webui 33/33, write-pendrive 16/16, check-iso 20/20); cross-build dry-run de
  `graniterapids` com `-DGGML_AVX512=ON -DGGML_AVX512_VNNI=ON -DGGML_AMX=ON`;
  `--no-avx512` em skylake → march `broadwell` + aviso; `build.sh
  --list-families` mostra as 14.
- **NÃO feito / não testado:**
  - 🔴 **Nenhuma das famílias novas foi compilada nem medida** — o `build-llama`
    do CI é o que exercita; hardware físico (Bloco N) continua pendente.
  - O `-march` de cada família nova depende do GCC do runner (13 no
    `ubuntu-24.04`): `graniterapids`/`znver5` vão cair no fallback lá até o
    runner ter GCC ≥ 14 — comportamento correto, mas é o fallback que será
    exercitado.
- **Commits:** `793d540` — `feat(families)!: 14 famílias (Xeon Scalable
  v5–v9, Xeon 6 P, Zen 5) + AVX-512 por padrão` · `84c2f79` — docs.

---

### Sessão #27 — 2026-10-16 · 🔑 Senha de usuário/root na webui (hash crypt)

- **Objetivo:** pedido do dono: ele bateu no **root bloqueado** ao testar o
  papel **builder** numa máquina instalada pela ISO (o mesmo aconteceria no
  `inference`). Hoje o build só define a senha do usuário (aleatória ou
  `--password-hash`) e o root fica bloqueado. Pedido: gerar/definir senha de
  **root e de usuário** na **webui**.
- **Feito:**
  - **`build-iso.sh`**: novo `--root-password-hash` (hash crypt; valida que
    começa com `$` e não tem espaço — nunca texto puro). `resolve_root_password`
    roda no main. Resumo do build: "root HABILITADO (hash crypt, não exibido) /
    root bloqueado".
  - **Ubuntu**: o late-command ganhou a seção 3-c — `ROOT_PASSWORD_HASH` e
    `echo "root:<hash>" | in_target chpasswd -e` (o `-e` é o que garante hash,
    nunca texto puro). O Subiquity não tem campo de root, então esse é o
    caminho dos DOIS instaladores.
  - **Debian**: preseed com o marcador `@@ROOT_PRESEED@@` expandido por
    `expand_root_preseed_block()` (root-login true + senha crypt, ou false).
  - **`verify-iso.sh`**: nova seção "Senha do root" (coerência: hash no
    late-command × `chpasswd -e` × root-login da preseed; e o inverso).
  - **webui**: campos `type=password` para usuário e root (vazio = gerar
    aleatória / root bloqueado), botões 🎲 (senha no navegador,
    `crypto.getRandomValues`) e 👁. No servidor, `_crypt_hash()`: stdlib `crypt`
    (PEP 594 a removeu no Python 3.13 — ambiente desta máquina!) com fallback
    `openssl passwd -6 -stdin` (a MESMA ferramenta que o build-iso.sh exige; o
    texto vai pelo STDIN, nunca nos argumentos). **Só o hash entra no argv.**
    `_password_or_none()` valida (≤128, sem CR/LF/NUL).
  - **Guardas do CI** (Regra 16 atualizada): proibido `sudo -S`/`askpass`;
    proibida flag de senha em TEXTO PURO (`--password`/`--root-password`);
    obrigatório `crypt.crypt|mksalt` no server.py. `ci-guards` foi de 33 → 35
    (com a planta de cada violação).
  - **`test-webui.sh`**: +4 asserções — as flags de hash entram no argv, os
    hashes são `$6$`, o texto puro NÃO aparece em nenhum campo, sem senha no
    formulário o argv fica sem as flags, e senha com `\n` é recusada (400).
- **Problemas / armadilhas (não repita):**
  - **O módulo `crypt` não existe no Python 3.13+** (PEP 594). A máquina roda
    3.14 — o primeiro teste 500. Fallback `openssl passwd -6 -stdin`.
  - **Comentário contendo o token literal** `@@ROOT_PRESEED@@` fez o guarda
    "sobrou marcador" reprovar — a MESMA armadilha já registrada no § 6.
  - **`test-ci-guards` estourou a cota do /tmp (tmpfs)** ao copiar a árvore
    inteira: `iso/work` tem GB de cache. Fix: a cópia exclui `iso/work`,
    `iso/out`, `*.iso`, `*.gguf`.
  - shellcheck SC2188 (redireção sem comando) e SC1072/1073 (comentário com a
    palavra `shellcheck`) — a redireção foi para o próprio comando `python3`.
- **Verificado:** `make validate` verde: families **85/85**, ci-guards
  **35/35**, webui **38/38**, write-pendrive 16/16, check-iso 20/20; autoteste
  de templates com o exemplo de root (PASS=42, seção "Senha do root" incluída);
  dry-runs: root habilitado / bloqueado / hash inválido recusado.
- **NÃO feito / não testado:**
  - 🔴 **Nenhuma ISO nova foi gerada/bootada** com a senha de root — o caminho
    foi exercitado só até dry-run/autoteste. O primeiro boot de verdade com
    root habilitado é o teste que falta (mesma rotina da sessão #21).
- **Commits:** *(ver `git log`)*.

---

### Sessão #28 — 2026-10-16 · 🔴 O `build-llama` do CI quebrou com SIGILL (AVX-512 auto)

- **Objetivo:** o dono reportou "erro" no commit de docs da sessão #27. Era o
  workflow **`build-llama`** disparado na branch `v0.2.5`: **5 jobs de famílias
  Intel AVX-512 falharam** (skylake-avx512, cascadelake-sp, sapphirerapids-sp,
  emeraldrapids-sp, graniterapids-sp).
- **Causa raiz (medida, não deduzida):** log do job → `Illegal instruction
  (core dumped) "$BIN/llama-bench" --help`, `exit code 132`. A política AVX-512
  `auto` (sessão #26) fez o **cross-build** (`--assume-family-isa`) gerar
  binário **com AVX-512** para essas famílias — correto para o ALVO — mas o
  passo "Verificar binários e execução" roda `llama-bench` no **runner sem
  AVX-512** → SIGILL. (Zen4/zen5/icelake "passaram" por sorte: caíram em
  runners Genoa com AVX-512 — **não-determinístico**, pior ainda.)
- **Feito:**
  - Matriz do `build-llama.yml`: famílias AVX-512 ganharam **`exec: false`** —
    elas **compilam** (prova que o caminho AVX-512 existe e os binários são
    gerados) mas **não executam** no runner. As famílias AVX2 (haswell,
    broadwell, zen1–zen3) seguem executando tudo.
  - Passo "Verificar binários e execução": só roda `llama-bench --help` quando
    `matrix.exec != false`; senão, avisa que é compile-only. Idem o passo de
    inferência real (`if: ... && matrix.exec != 'false'`).
  - Docs: `CI.md` § 3 ("As três provas" com a nota compile-only; linha do
    SIGILL na tabela de troubleshooting) e `FAMILIES.md` § 9.3 (marcador ¹).
- **Lição (registrada para não repetir):** política `auto` + cross-build +
  "executar no runner" é uma combinação que **inverte** o propósito do smoke:
  o SIGILL passa a ser *esperado* para o alvo, não um erro. O smoke de execução
  só vale quando o binário é para A CPU do runner — senão, compile-only.
- **Verificado:** `make validate` verde (families 85/85, ci-guards 35/35,
  webui 38/38) + `yamllint build-llama.yml` limpo. **O workflow real não foi
  re-executado** — o `build-llama` só dispara em tag/manual/semanal; a prova
  será o próximo run.
- **Commits:** *(ver `git log`)*.

---

### Sessão #33 — 2026-10-16 · 🧷 Sincronizar com o GitHub + a correção do #28 que não corrigia

- **Objetivo:** o dono pediu "houve mudanças no GitHub; verifique como está e
  atualize o repo local para não ter erros de envio".
- **Diagnóstico (medido, não deduzido):** o `main` local estava **7 commits
  atrás** de `origin/main` (sessões #26/#27/#28 + tag `v0.2.5`) **e** com 20
  arquivos modificados **não commitados** — o trabalho da sessão #26 *desta*
  máquina (2026-10-14: AVX-512 por padrão + `flock`/`download_to`). Era isso
  que fazia o git/push falhar. A comparação arquivo a arquivo provou que o
  remoto **não tem** `flock`, `--speed-time`, `download_to`, `avx512-test`
  nem `iso-lock-test`.
- **Feito:**
  1. **Sync seguro:** `git add -A` → commit numa **branch de backup**
     (`backup/local-sessao26-pre-sync`) + patch em `/tmp/backup-sessao26/` →
     `git reset --hard origin/main`. Resultado: `main == origin/main` e
     `git push --dry-run` → *Everything up-to-date*.
  2. **🔴 A correção do #28 NÃO funcionava.** O run do **próprio commit da
     correção** (`93df769`, `workflow_dispatch`) voltou **vermelho**:
     `icelake-sp`, `sapphirerapids-sp`, `emeraldrapids-sp` e
     `graniterapids-sp` morreram no passo **9** ("Inferência real") com
     `exit code 132` (SIGILL). **Causa raiz:** `if: … && matrix.exec !=
     'false'` — `exec: false` é **booleano** no YAML e o GitHub coage
     booleano × string para **NÚMERO** (`false`→0, `'false'`→NaN), então o
     `!=` dá **sempre true** e o passo **nunca é pulado** (as annotations
     mostraram o passo 9 rodando nas **8** famílias `exec: false`; as 4 que
     "passaram" foi porque o runner, por sorte, tinha a ISA). **Conserto:** o
     valor vai por `env:` e a decisão é feita no **bash** — o mesmo padrão que
     já funcionava no passo 7. Guarda novo no `project-rules` (âncora
     `^[[:space:]]*if:.*matrix\.exec`) + violação plantada no
     `ci-guards-test`.
  3. **Trabalho local recuperado:** `acquire_build_lock()` (`flock`,
     instância única) e `download_to()` (confere que o `.part` existe e
     aborta download estagnado com `--speed-time/--speed-limit`) portados
     para o `iso/build-iso.sh` **atual** (pós-#26/#27), com a chamada no
     `main()` antes do `check_deps`. Entraram `tests/test-iso-lock.sh`
     (**10** asserções) e `tests/test-avx512-policy.sh`, com os alvos
     `make iso-lock-test` / `make avx512-test` no `validate` (Makefile **e**
     CI).
  4. **`avx512-test` estendido de 8 → 14 famílias** (as 6 novas do #26 + o
     `generic`): **37 → 61 asserções**. O `resolve.sh` ganhou duas melhorias
     de relatório que o teste cobrava: o motivo do AVX-512 diz **de onde vem
     a verdade** ("a família declara avx512f" em cross-build; "a CPU reporta
     avx512f" no nativo) e há **`Atenção:`** quando o AVX-512 está ligado mas
     o `-march` efetivo é o fallback (znver4→znver3 com GCC 12).
- **Decisão:** a parte de AVX-512 do trabalho local (política nos
  `family.conf` + `resolve.sh`) era **superada** pela versão do remoto, mais
  completa (`FAMILY_MARCH_HAS_AVX512`, 14 famílias) — foi **descartada de
  propósito**; só o que era **único** foi reaplicado.
- **Verificado:** `make validate` verde — families **85/85**, avx512 **61/61**,
  iso-selection 13/13, iso-repo-filter 16/16, verify-repo-distro 6/6,
  ci-guards **40/40** (eram 35), iso-lock **10/10**, pendrive 16/16,
  check-iso 20/20, webui 38/38 — mais `iso-dry-run-both` OK e o dry-run do
  `build.sh` OK (`rc=0`). `yamllint .github/` limpo.
  ⚠️ **O `sudo` desta máquina pede senha**, então o `make ci` completo (cujo
  `dry-run` usa `sudo`) **não foi executado**; os dois dry-runs foram rodados
  direto, sem `sudo`.
- **O que NÃO foi provado:** o `build-llama` do GitHub **só dispara em
  tag/manual/semanal** — a prova do conserto é o **próximo run** (manual). A
  ISO **não** foi gerada nem bootada aqui (sem `xorriso`/`qemu`).
- **Commits:** *(ver `git log`)*.

---

### Sessão #30 — 2026-10-16 · 🔎 Auditoria do gatilho do autoinstall (sinalizado, não resolvido)

- **Objetivo:** o dono relatou *"havia outro bug que fazia a ISO não instalar
  automaticamente"* e pediu **só olhar e deixar sinalizado**.
- **Método novo (barato, vale repetir):** em vez de baixar a ISO de ~3 GB, **li
  a estrutura dela por HTTP Range** (~poucos KB): PVD no setor 16 (*root
  directory record* no **offset 156** — errei na 1ª tentativa, usei 190), *path
  table* L (offset 132 = tamanho, 140 = LBA) para listar **todos** os
  diretórios, e os *directory records* para baixar arquivos específicos. Foi
  assim que li o `/boot/grub/grub.cfg` **de fábrica** sem baixar a ISO.
- **Fatos medidos (ISO 24.04.5 live-server):**
  - `/boot/grub/grub.cfg` **existe** (573 B) e é o **único** menu. A entrada **0**
    é `"Try or Install Ubuntu Server"` (interativa) — é ela que o GRUB sobe
    quando o `set default` não casa (o bug #6 da sessão #21).
  - `/EFI/boot/grub.cfg` **NÃO existe** (só `bootx64.efi`/`grubx64.efi`/
    `mmx64.efi`): a branch *"o UEFI delegará para /boot/grub/grub.cfg"* do
    `prepare_ubuntu` é o caminho **normal** — e o UEFI usa o MESMO menu patchado.
  - ⚠️ O `.list` publicado em `releases.ubuntu.com` é **INCOMPLETO** (omite
    `/boot`, `/install`, `/.disk` e quase todo `/dists`): **não** sirva dele
    para concluir sobre a estrutura da ISO (cheguei a achar que faltava
    `/boot/grub` — era o `.list`).
- **Auditado e DESCARTADO:** o `prompt 1` do `patch_isolinux` (Debian) — a doc
  do syslinux diz que `PROMPT` **não** cancela o `TIMEOUT`, então o `default`
  sobe sozinho após o timeout.
- **Conclusão:** **nenhum defeito novo confirmado** no gatilho do autoinstall.
  Ficam **sinalizados 3 modos** de a ISO não instalar sozinha (ver
  `docs/TROUBLESHOOTING.md` § "SINALIZADO" e `STATE.md` § 6): **(1)** `--disk`
  fixado que não existe no alvo (o **default do CI é `/dev/vda`**); **(2)**
  **UEFI nunca bootado**; **(3)** **Debian/preseed nunca executado**.
- **NÃO feito:** nenhuma linha de código mudou; nenhuma ISO gerada/bootada.
- **Commits:** *(ver `git log`)*.

---

### Sessão #31 — 2026-10-16 · 🎯 O Modo 1 era um BUG REAL: `--disk auto` não funcionava

- **Objetivo:** o dono relatou erro ao testar ("criação da ISO apresentou
  travamento", `mv: cannot stat '…gguf.part'`, e "a ISO pode não instalar
  automaticamente") e pediu: **corrigir os erros** e **documentar a tentativa
  para implantar em outro PC**. O `main` local estava **1 commit à frente** do
  GitHub (só docs) e o CI estava **verde** — não havia erro em aberto no código.
- **Método:** em vez de "procurar bug no escuro", testei **a mitigação que a
  própria documentação recomendava** para o Modo 1. Foi onde o bug estava.
- **O BUG (encontrado em 1 comando):** `--disk auto` — recomendado pela
  documentação como *a* solução para "o disco fixado não existe no alvo" — era
  usado **literalmente**: `storage_layout_line()` produzia
  `layout: {name: direct, match: {path: auto}}`. Isso é um **caminho
  inventado**: nenhum disco casa, o Subiquity não instala sozinho e **não há
  erro visível**. **A mitigação documentada reproduzia exatamente o bug que ela
  deveria evitar.** (E com `--disk auto` no CI isso passaria batido, porque o
  `verify-iso.sh` confere o *conteúdo* — não a semântica do `match`.)
- **Feito:**
  - `--disk auto|any|none` → **não fixa o disco** (`layout: {name: direct}`).
  - Formato validado: `^/dev/[a-zA-Z0-9]+$`; `sda`, `/etc/passwd`, `/dev/../etc`
    → **rc 2** (erro de uso, com o próximo passo na mensagem).
  - **AVISO** quando o `--disk` não existe nesta máquina (na hora e **no resumo
    final**), porque gerar para outra máquina é legítimo — mas silencioso não.
  - **Default do CI = `auto`** (era `/dev/vda`, que só existe em VM).
  - `build-iso.sh --keep-templates`: mantém a árvore do autoteste e imprime
    `TEMPLATES_DIR=…` — é o que permite **testar a semântica** do YAML gerado
    (sintaxe o `yamllint` já validava; "o layout não pode restringir disco" não).
  - Removidas duas chamadas `expand_apt_local_block` **duplicadas** (inócuas —
    o marcador já tinha sido consumido — mas é resíduo de edição repetida).
  - **`docs/IMPLANTAR-EM-OUTRO-PC.md`** (novo): roteiro para a máquina de
    destino, os 3 modos de falha, o que medir e **o que trazer de volta**.
- **Decisões:**
  - **Testar a mitigação documentada é um caso de teste.** A doc recomendava uma
    saída que não existia de fato. Passei a testar o que a doc **promete**, e não
    só o que o código faz.
  - **Disco inexistente é AVISO, não erro** (Regra 13-a): a ISO pode ser para
    outra máquina, onde o disco é outro. Erro fatal só para **entrada inválida**
    (formato), que é corrigível pelo usuário.
  - **O default do CI tem de servir para o mundo real**, não só para VM.
- **Problemas:**
  - `sed` com `||` **dentro** do padrão quebrou (`|` é o delimitador do `s`) —
    usei `#`. Erro bobo que custou um ciclo; fica registrado.
  - **De novo** o `:` dentro de um `name:` do YAML (precisa de aspas) e uma
    linha > 120 colunas. Os dois já estavam no § 6 — reli o meu próprio § 6
    **depois** de errar. A lição continua valendo: rode `make yaml` **antes** de
    escrever o texto, não depois.
- **Verificado:** `make validate` **verde** — 40 scripts, families 85, avx512 61,
  iso-selection 13, iso-repo-filter 16, verify-repo-distro 6, **ci-guards 43**,
  iso-lock 10, **iso-disk 16**, write-pendrive 16, check-iso 20, webui 38,
  dry-run dos dois caminhos OK.
- **NÃO feito / não testado:**
  - 🔴 **Nenhuma ISO foi gerada nem bootada nesta rodada.** O conserto do Modo 1
    é provado **por teste de comportamento e de conteúdo do YAML**, **não** por
    uma instalação real. A prova que falta é: gerar com `--disk auto`, bootar no
    **outro PC** e ver a instalação acontecer sozinha.
  - 🔴 **Modo 2 (UEFI)** e **Modo 3 (Debian/preseed)** continuam **sem execução**.
  - ⚠️ O aviso de disco inexistente nunca foi visto contra um alvo real.
- **Commits:** `65a50a9` — fix(iso)!: `--disk auto` era a mitigacao DOCUMENTADA e estava QUEBRADA.

---

### Sessão #32 — 2026-10-16 · 🧷 `validate` #57 vermelho: o teste da trava dependia de uma otimização que o bash **não promete**

- **Objetivo:** o dono relatou o `validate` **#57 vermelho** no `main` e pediu
  para corrigir. O log do job é **403** sem token, então o caminho foi:
  `/actions/runs/<id>/jobs` (dá `steps[].conclusion`) → **anotações**
  (`Process completed with exit code 2`).
- **Método (é o que vale registrar):** comparar o run vermelho com o **último
  verde** (`#56`, mesmo `runs-on`, horário próximo) em vez de ler código no
  escuro.
  - `git diff --stat 1079ceb HEAD` (o commit do #56 até o HEAD): **o único
    arquivo funcional que mudou é `iso/build-iso.sh`** (disco do autoinstall) e
    `tests/test-iso-lock.sh` está **idêntico** nos dois runs.
  - `#57`: o passo 17 (`make iso-lock-test`) levou **6 s** e falhou; no `#56` ele
    levou **0 s** e passou.
  - **6 s ≈ os 5 s de um laço de espera que estoura** → a asserção que falhou era
    a última: *"a trava continuou presa depois do build anterior terminar"*. O
    build do teste rodou (não foi recusado) — a trava já não estava presa.
- **Causa raiz (mecanismo provado, não suposto):** o detentor da trava era
  `bash -c '…; sleep 30' &` e o teste matava o PID do job contando que o bash
  **trocasse de identidade** pelo último comando (*exec*). Essa otimização **não
  é garantida** — basta um `BASH_ENV` que defina um `trap` para o bash desistir
  dela, e então o `sleep` fica um **filho que herda o fd 9**: o `kill` mata só o
  pai e a trava continua presa. Reproduzido em 1 comando, com a assinatura exata
  do CI (mesma asserção, ~6-8 s):

  ```bash
  printf 'trap ":" EXIT\n' > /tmp/besen.sh
  BASH_ENV=/tmp/besen.sh bash tests/test-iso-lock.sh   # 9/10: FALHOU a trava continuou presa
  ```

- **Feito (`tests/test-iso-lock.sh` reescrito, 10 → 13 asserções):**
  - Detentor **determinístico**: `sleep 300 9>&- &` + `wait` — o filho **não**
    herda o fd 9 e quem segura a trava é o próprio `bash`; matar o detentor
    solta a trava **em qualquer ambiente**, com ou sem a otimização.
  - **`flock -w 20`** (esperando) no detentor, e não `-n`: com `-n` o detentor
    perdia a corrida para as **sondas do próprio teste** (`flock -c true`, que
    pegam a trava por um instante) e o teste era **flaky** (~1 de cada 3).
  - **Pré-voo:** a trava tem de estar **livre** ao começar; se não estiver, diz
    **quem** a segura (PID lido do arquivo + varredura de `/proc` por **todos**
    os fds) e falha na hora, em vez de dar falso negativo lá na frente.
  - **Anotação do GitHub:** todo `FALHOU` também emite
    `::error::test-iso-lock: …` — é o único canal **público** quando o job fica
    vermelho sem token (já estava no § 6 como lição; agora está no código).
  - **Nunca toca a rede:** os builds reais do teste ganharam
    `--iso none --iso-model none --iso-source none --iso-repo none --no-verify`
    e teto de `timeout 180`. Antes, uma falha na trava faria o teste (e o CI)
    **baixar 2,6 GB de ISO / 1,1 GB de modelo**.
- **Decisões:**
  - **Nunca depender de otimização de shell que a doc não promete**: `exec` do
    último comando, `&&` como última instrução da função e `! cmd` com `set -e`
    — as três já derrubaram este repositório.
  - **Teste flaky é pior que teste ausente** (treina a pessoa a ignorar o CI).
    Um teste que depende de corrida vence às vezes: use **espera** (`-w`).
- **Problemas (2, os dois meus):**
  1. **Instrumentar um `bash -c '…'` adicionando um `printf '%s:%s '`**: a aspa
     simples **fechou o `bash -c`** antes da hora, o resto do texto virou
     *argumento* e o shell criou um **arquivo `_`** na raiz do repositório
     (`exec 9>"_"`). Passei um bom tempo caçando "o detentor não toma a trava"
     quando o defeito era da **minha instrumentação**. As armadilhas de quoting
     valem também para DEPURAR.
  2. O § 5.2 do `IMPLANTAR-EM-OUTRO-PC.md` e o resumo desta sessão citavam
     `iso-lock` com **10** asserções — atualizados (13).
- **Verificado:** `make validate` **verde** — iso-lock **13/13**, families 85,
  avx512 61, iso-selection 13, iso-repo-filter 16, verify-repo-distro 6,
  ci-guards 43, iso-disk 16, write-pendrive 16, check-iso 20, webui 38,
  dry-run dos dois caminhos OK. O teste rodou **20/20** em sequência e **5/5** no
  ambiente hostil (`BASH_ENV` + `trap`), que é o modo de falha do CI.
- **Confirmado no CI:** `validate` **#58** (`0041c0e`) — **4/4 jobs verdes**, e o
  passo 17 ("ISO (trava de instância única do gerador)") **passou em 0 s** (sem
  os 5 s de espera estourando do #57). Leitura pelos `steps[].conclusion` da API
  (o log do job é 403).
- **NÃO feito / não testado:**
  - 🔴 **Não sei POR QUE o runner deixou de fazer a otimização entre o #56 e o
    #57** (o mecanismo está provado; a mudança do lado do runner, não). O teste
    ficou **imune aos dois lados** (com e sem a otimização) e o #58 confirmou —
    mas a causa do lado do runner segue como **dúvida aberta**.
  - ⚠️ Nenhum outro teste da árvore usa `flock` (auditado por `grep`), mas a
    mesma classe de erro — *depender de detalhe do shell* — não foi varrida no
    resto do repositório.
- **Commits:** `e43cceb` — fix(ci): a trava do teste dependia do `exec` do bash — `validate` #57 vermelho.

---

### Sessão #33 — 2026-10-17 · 🌐 O sistema instalado subia SEM REDE (rede virou preparação da ISO)

- **Objetivo:** o dono instalou uma ISO mais antiga numa máquina de teste e
  relatou: **não conseguia logar por SSH**, e depois descobriu que **a rede não
  ativava por DHCP sozinha** — era preciso configurar à mão no terminal.
  Pedido: "adicionar uma pré-configuração na preparação da ISO, assim como foi
  com a senha".
- **Causa raiz:** o `autoinstall.yaml` do caminho Ubuntu **não tinha a chave
  `network:`**. O Subiquity usa DHCP para si mesmo, mas **não grava uma
  configuração de rede persistente no alvo** — o sistema instalado nasce sem
  netplan, com a placa DOWN. Não é hardware, não é o tuning: é a configuração
  que nunca foi escrita.
- **Feito:**
  - `iso/build-iso.sh`: novas flags **`--network auto|dhcp|static|none`**,
    `--network-interface`, `--network-ip` (aceita `/N`), `--network-gateway`,
    `--network-dns`, `--network-prefix`. Validação estrita de IPv4/prefixo/DNS/
    interface; **default `auto`** (DHCP) — e o default nunca derruba o build
    (Regra 13-a: IP/gateway sem `static` só geram aviso).
  - `iso/autoinstall/autoinstall.yaml`: recebeu `@@NETWORK_SECTION@@`, que vira
    o bloco `network:` (dhcp com `match: en*`/`eth*`, ou IP fixo) **ou
    desaparece** no modo `none` (não dá para emitir `network:` vazio).
  - `iso/preseed/ai-cpu-os.cfg`: `@@NETWORK_PRESEED@@` → `netcfg`
    (`disable_autoconfig false` ou ip/netmask/gateway/dns). **Bug de passagem
    corrigido:** o hostname da preseed era fixo em `ai-cpu-os` e ignorava
    `--hostname`; agora usa `@@HOSTNAME@@`.
  - `iso/preseed/late-command.sh` (§ 2-e): copia o **mesmo** netplan
    (`/preseed/ai-cpu-os-netplan.yaml`, gerado pelo build) para
    `/etc/netplan/99-ai-cpu-os.yaml` (0600), move o netplan do instalador/
    cloud-init para `.ai-cpu-os.bak` e grava
    `/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg`
    (`network: {config: disabled}`) para o cloud-init não reescrever.
  - `iso/verify-iso.sh`: nova seção **"Rede do sistema instalado"** — confere
    modo × autoinstall × netplan da mídia × aviso do cloud-init.
  - `iso/build-iso.sh --check-templates`: agora exercita **rede `auto`,
    `static` e `none`** nos dois layouts de disco (6 variantes), validando o
    YAML resultante (autoinstall + netplan) e a preseed.
  - `webui/`: seletor de rede + campos de IP fixo (só aparecem no modo
    `static`); validadores `v_network_mode`, `v_net_ip`, `v_gateway`,
    `v_iface`, `v_dns` (nada de texto do navegador vai ao shell sem formato
    conferido).
  - Guardas novos no `validate.yml` e casos plantados no `test-ci-guards.sh`:
    default DHCP, marcador do autoinstall, marcador da preseed, netplan na
    mídia, netplan no alvo, cloud-init desligado.
- **Verificado:** `make iso-yaml` (6 variantes) OK; `make ci-guards-test`
  **41/41**; `make ui-test` **46/46**; `bash -n`/`sh -n` nos scripts.
- **O que NÃO foi provado:** **nenhuma ISO nova foi gerada/bootada** depois da
  mudança. O que vale hoje é "o YAML é válido e coerente" — ainda **não** é
  "o alvo pega IP sozinho". A prova é o **Bloco M.5-b** do `VALIDATION.md`.

### ✅ Continuação da sessão #33 — a prova em VM (e 3 bugs reais)

O dono pediu: *"instalei numa máquina de teste uma versão mais antiga, tente
conectar via SSH e faça os testes"*. A varredura da rede (`192.168.1.0/24`,
host em `.5`) não achou nenhum host com a porta 22 aberta — só o roteador. A
máquina de teste **estava sem rede por DHCP**, que é exatamente o bug que esta
sessão corrige. Sem endereço, não há SSH.

Como o ambiente tem `qemu` + `/dev/kvm` + as ISOs em cache, a validação foi
feita **em VM**, com o mesmo rigor: gerar a ISO → instalar → **bootar o disco
instalado com `hostfwd` na 22** → entrar por SSH e rodar os testes no alvo.

**Resultado (tudo verificado dentro do alvo):**

| Verificação | Resultado |
|---|---|
| IP por DHCP **sozinho** | ✅ `ens3: DHCPv4 address 10.0.2.15/24 … acquired` |
| Netplan instalado 0600, idêntico ao build | ✅ `/etc/netplan/99-ai-cpu-os.yaml` |
| cloud-init desligado | ✅ `99-ai-cpu-os-disable-network.cfg` |
| SSH | ✅ `ai-cpu-os@ai-cpu-os` |
| Família / manifesto | ✅ `intel-haswell`, `-march=haswell`, `AVX-512: no` |
| Mods | ✅ swappiness 10, rmem 128 MB, THP `always`, `max_cstate=1` |
| `smoke-test.sh` | ✅ 11 PASS / 1 FAIL (governor: VM sem `cpufreq`) / 1 SKIP |
| `ai-server` `/health` | ✅ `{"status":"ok"}` |
| Inferência real | ✅ 48 tokens coerentes (Qwen2.5-Coder-1.5B Q4_K_M) |
| `llama-bench` (4 vCPU, AVX2) | ✅ **pp64 46,55 t/s · tg32 25,95 t/s** |

**3 bugs reais encontrados executando (e corrigidos):**

1. **Arquivos com 0 byte após o 1º boot.** `llama-server`,
   `ai-server.service` e `.firstboot-status` existiam com tamanho **zero**: o
   `test-vm.sh` matava o qemu no instante do marcador, sem o guest nem o qemu
   descarregarem o disco. Um unit vazio é lido pelo systemd como **`masked`** —
   o serviço de inferência simplesmente não existia, e o sintoma
   (`is-enabled → masked`) não aponta para o disco. Correção: `sync` no
   `firstboot.sh` **antes** de remover a sentinela (+ no caminho de falha) e
   15 s de espera antes de encerrar a VM. Bônus: protege contra queda de
   energia num servidor real.
2. **`--no-mmap` foi REMOVIDO do llama.cpp.** A unit fixava a flag (era
   intencional: não mmap-ar o modelo importa num servidor cujo gargalo é
   memória) e o serviço entrava em loop com
   `error: invalid argument: --no-mmap` + `restart counter is at 13`. O
   equivalente moderno é `--load-mode none`. Correção: a unit usa
   `${LLAMA_EXTRA_ARGS}` e o `install.sh` **pergunta ao binário** que acabou de
   compilar (`--help`) qual sintaxe vale — funciona nas duas gerações. Sem
   isso, **toda** ISO gerada com `LLAMA_REF=master` subiria o `ai-server`
   quebrado.
3. **`shell-ia.py` devolvia a linha do protocolo.** Ao esgotar as rodadas de
   ferramentas, retornava `messages[-1]` — o `RESULT: …` cru — como resposta ao
   usuário. Pior: logava "ferramenta 'X' executada" mesmo quando X não existia,
   e o erro não listava as ferramentas válidas (um 1,5B repetia o nome
   inventado até esgotar). Correção: pedido de resposta final em texto + lista
   das ferramentas válidas + log honesto.

**Guardas novos (provados por violação plantada):** `ci-guards` 43 → **46**;
`webui` **46**; `families` 85; `validate` verde.

**Prova final (ISO NOVA, com as três correções):** `ai-cpu-os-ubuntu-rede-v2.iso`
foi gerada (`verify-iso` **PASS=38 FAIL=0**) e **instalada do zero** numa VM
(qemu/KVM, `--ram 6144 --cpus 4`). Depois, o disco foi bootado com `hostfwd` na
22 e inspecionado **por SSH** — e é aí que os dois bugs anteriores provariam
não estar corrigidos:

| Verificação na ISO v2 | Antes (bug) | Agora |
|---|---|---|
| `/etc/systemd/system/ai-server.service` | 0 byte → `masked` | **2179 bytes**, `enabled` |
| `/etc/default/ai-server` | vazio | `LLAMA_EXTRA_ARGS=--load-mode none` |
| `.firstboot-status` | 0 byte | `status=ok` + role/family/data |
| `llama-server` | 0 byte | 17.888 bytes (`--version` ok) |
| Rede no alvo | placa DOWN | `ens3 UP 10.0.2.15/24` + rota default **por DHCP** |
| `/etc/netplan/99-ai-cpu-os.yaml` | ausente | presente, 0600, idêntico ao build |
| Login por SSH | impossível | ✅ `ai-cpu-os@ai-cpu-os` |
| `systemctl start ai-server` | loop `invalid argument` | falha **só** por não haver modelo (`--iso-model none`) — a flag foi aceita |

O log do `test-vm.sh` mostrou a espera de 15 s antes de encerrar a VM
("Aguardando 15 s para o guest/qemu descarregarem o disco"), que é o que
garante os arquivos íntegros acima.
- **Nota de campo (para a próxima tentativa de SSH na máquina de teste):** a
  rede do ambiente de desenvolvimento é `192.168.1.0/24` (host em
  `192.168.1.5`); a varredura não achou nenhum host com a porta 22 aberta além
  do roteador (`192.168.1.1`), e `enp5s0` do host está sem carrier. Ou seja: o
  problema do SSH era **o mesmo** do alvo — sem configuração de rede, não há
  endereço para conectar. Gerar a ISO nova e repetir a validação é o caminho.
- **Commits:** *(ver `git log`)*.

---


---

### Sessão #34 — 2026-10-18 · 🔧 Reparo da máquina JÁ instalada (mod `network`)

- **Objetivo:** o dono repetiu o relato ("a rede não ativa DHCP automaticamente,
  é preciso configurar à mão") — e a chave é que a **máquina já está
  instalada**. A correção da sessão #33 vale para ISOs **novas**; uma ISO nova
  não conserta o que está no chão.
- **Feito:** nova mod **`mods/network/`** (`mod.conf` + `apply.sh` +
  `revert.sh`). O projeto já vive em `/opt/ai-cpu-os` no sistema instalado, logo
  o reparo é um comando:
  `sudo bash /opt/ai-cpu-os/mods/network/apply.sh`.
  - Grava `/etc/netplan/99-ai-cpu-os.yaml` (0600) — DHCP em `en*`/`eth*` por
    padrão, `--interface` para bloco nominal, `--mode static` com
    `--ip/--gateway/--dns`.
  - **Move** `00-installer-config.yaml`/`50-cloud-init.yaml`/`01-netcfg.yaml`
    para `*.ai-cpu-os.bak`: duas definições do mesmo adaptador fazem o netplan
    **recusar** a configuração e o sistema ficaria sem rede — o oposto do
    objetivo.
  - Grava `99-ai-cpu-os-disable-network.cfg` (cloud-init não reescreve).
  - **Valida com `netplan generate` ANTES de aplicar**: se a config nova for
    inválida, não aplica (a rede atual continua de pé). Esse é o ponto mais
    importante do script.
  - Validação estrita de IPv4/prefixo/interface (um YAML torto = máquina sem
    rede), `--dry-run` e `--root DIR` (testar/preparar disco montado sem tocar
    no sistema em execução), idempotente, `revert.sh` restaura os backups.
  - Conjunto próprio (`MOD_SETS="network"`): **nunca** entra em
    `apply --set system`, que roda no build — tuning não deve mexer na
    conectividade.
- **Aviso de placa que não casa (achado ao revisar):** um netplan **válido** que
  não casa placa nenhuma é um sucesso do script e um **fracasso do objetivo** —
  a máquina continua sem IP com sintoma idêntico. Acontece com Wi-Fi
  (`wlp*`/`wlx*`) e nomes fora do padrão. A mod agora **avisa** e sugere
  `--interface <placa-real>`; a detecção usa `NET_SYSFS` (padrão
  `/sys/class/net`) para poder ser simulada no teste — 3 asserções novas.
- **Testes:** `tests/test-network-mod.sh` (**41 asserções**, árvore falsa,
  sem root/rede/netplan/docker) cobre os 3 modos, o `.bak`, o cloud-init, a
  idempotência, o revert-com-restauração, 8 entradas inválidas (`rc 2` e nada
  escrito) e o `--dry-run`. `make network-test` no `validate`;
  `make network-fix` para esta máquina. Guardas novos no `validate.yml`, cada
  um provado por violação plantada: `ci-guards` 54 → **62**.
- **Docs:** `TROUBLESHOOTING.md` § "sobe sem rede" (a seção que o dono vai ler),
  `MODS.md` § 3, `ISO.md`, `README.md` e `STATE.md` — todos apontam a mod como
  o caminho de reparo, e a alternativa manual (`/etc/netplan/99-rede.yaml`).
- **O que NÃO foi provado:** a mod **nunca rodou numa máquina real com
  `netplan`** — os testes usam `--root`. O `netplan generate`/`apply` do
  caminho real não foi exercitado, e o revert também não. É a próxima prova
  (basta rodar na máquina de teste).
- **Commits:** *(ver `git log`)*.

### Sessão #46 — 2026-10-20 · 📖 README reescrito + o 6º bug real do chat (chaves)

- **Objetivo:** *"para fechar, atualize o readme pois teve muitas atualizações e
  mudanças"*. Acabou sendo também a sessão em que o **modelo de chaves do
  `ai-talk` foi consertado** — porque documentar é testar.
- **O README (novo, para o usuário final):** bloco "O que mudou nesta rodada"
  logo depois do índice; tabela de CPUs corrigida (**14** famílias, estava 8);
  `--install-source` e a identidade por papel (ADR-002) com o aviso de que
  `--role auto` **não** deriva nome; **§ 10.1 nova — o chat da frota** (como
  ligar, tabela de regras, o que ele **não** faz, e o que falta provar) e a
  antiga § 10.1 virou **§ 10.2 (interface web)**, com o bug da página e os
  testes novos; FAQ +3 perguntas; bloco `make` de início rápido; tabela de
  docs com `CHAT.md`/`DECISIONS.md`; status final `0.3.0-dev` com a validação
  em hardware físico (A8-9600).
- **O que a escrita revelou (bug real, o 6º do chat):** o modo **recomendado**
  do chat — `--chat-keydir keys/` + `--chat-peers-file` — gerava um config cujo
  `key_file` era `/etc/ai-talk/fleet.key`, arquivo que **só existe no modo
  `--key-file` (chave global)**. Resultado: config válido, unit escrita,
  serviço **habilitado** e o daemon **morto no start** (`chave não encontrada`).
  - **A confusão de fundo:** uma chave tem **dois papéis** — a do peer
    **verifica**, a do próprio nó **assina**. `--keydir` só fornecia as de
    verificação, e o `key_file` (que é o lado que assina) ficou sem dono.
  - **Correção:** se `--key-file` não veio e `keys/<nó>.key` existe, ela vira a
    chave própria (`OWN_KEY_FROM_KEYDIR=1`); a config aponta para
    `/etc/ai-talk/keys/<nó>.key` e a chave é copiada para o alvo.
    `--key-file` continua vencendo. Sem chave própria: **aviso explícito** e
    serviço **desabilitado** (não se habilita um serviço que morre).
  - **Segundo erro, da mesma família:** a checagem de **chave órfã** rodava
    **antes** de ler `--peers-file` → todo peer vindo do arquivo era acusado
    de órfão. Movida para **depois** da montagem da frota (o modo de 15 nós,
    que é o recomendado, era justamente o mais afetado).
- **Bugs meus nesta sessão (todos pegos por execução, não por revisão):**
  - guarda de ordenação com `awk` que **sempre reprovava** (havia `done` depois
    do ponto checado) → reescrito comparando **posições** de duas linhas-âncora;
  - a mesma comparação com `grep -n` **sem `head -1`**: duas ocorrências →
    string multilinha → `[[ -lt ]]` estourava e o guarda passava **calado**
    (o `ci-guards-test` acusou "NÃO reprova");
  - **heredoc dentro de `run:` do workflow**: a linha final (`PYGUARD`) saía do
    bloco YAML e quebrava o arquivo (o `yamllint` pegou na hora);
  - violação plantada com `app` (que **acrescenta** ao fim) para um guarda que
    olha a **primeira** ocorrência → não reprovava; trocada por um `sed_` que
    insere **antes** da âncora.
- **Resultado:** `make validate` **verde** — `ci-guards` **118** (era 116),
  `ai-talk-install` **47** (era 39), `ai-talk` 30, `iso-chat` 31,
  `webui` 51, `webui-page` 13, `role-identity` 22, `docs`/`lint`/`iso-lint` OK.
- **O que NÃO foi provado:** nenhuma máquina conversando de verdade (o
  `ai-talk serve` subiu em **loopback**, não sob `systemd`); nenhuma ISO gerada
  desde a sessão #21 — as mudanças de #42–#46 **ainda não viram mídia**.
- **Commits:** *(ver `git log`)*.

### Sessão #45 — 2026-10-20 · 🐛 A página da UI ficava vazia + `git` já vem na base

- **Objetivo:** dois achados do dono: *"bug no webui e se não me engano o git já
  vem no ubuntu. bom dar uma observada"*. Os dois eram reais.
- **1) O bug da página.** O `<script>` chamava `syncIdentityHint()` **no topo**
  — antes de `loadOptions()` preencher `OPTIONS`. `OPTIONS.identity` com
  `OPTIONS === null` lança `TypeError`, e um erro **no topo** aborta o resto do
  script: o IIFE de `start` nunca roda. Sintoma: papéis vazios, sem famílias,
  sem status, sem lista de ISOs — e **nenhuma mensagem**. A página parecia
  carregar para sempre. Bug meu, da sessão #43.
  - **Por que os testes não pegaram:** o `ui-test` exercita a **API**, que
    sempre esteve certa. A limitação ("nunca aberta num navegador") estava
    documentada desde a #24 — e cobrou o preço.
  - **Correção:** nada no topo toca dados do `fetch`; handlers em `wireForm()`
    (que não depende de dados) e a parte assíncrona dentro do IIFE com
    `try/catch` → erro aparece em `#alert` em vez de morrer calado. Guarda de
    `OPTIONS` nulo na dica de identidade.
  - **Teste novo:** `tests/test-webui-page.sh` (**13**) extrai o `<script>`,
    roda num **DOM falso** (Node) e confere o que a página FEZ. Provado por
    violação plantada: reintroduzir o bug faz **12 de 13** falharem.
- **2) O `git` já vem — e o projeto dependia de um default.** Fato verificado,
  não memória:
  - `/casper/install-sources.yaml` da ISO 24.04.5 (extraído do arquivo real)
    oferece `ubuntu-server-minimal` (380 pacotes) e `ubuntu-server`
    (**default**, 707);
  - `git`/`curl`/`gnupg` **não** estão na minimal (0 ocorrências de `^git` no
    `ubuntu-server-minimal.manifest`) e **estão** na `ubuntu-server`
    (`apt-cache depends ubuntu-server` → `Depende: git`);
  - o `autoinstall.yaml` **não** tinha `source:`, ou seja: a base era o
    `default: true` de terceiro. Se a Canonical mudar a default, o alvo perde
    `git` em **silêncio** e o build que clona o llama.cpp falha no 1º boot.
  - **Correção:** `--install-source` (padrão `ubuntu-server`) + `source: id:`
    no autoinstall, com **duas travas**: o build recusa (rc 2) um id
    inexistente listando os disponíveis, e o `verify-iso.sh` repete a
    checagem na mídia. `EXTRA_PACKAGES` **mantém** `git`/`curl`/`gnupg` como
    defesa de quem escolher a minimal.
- **Bugs/quase-bugs meus nesta sessão:**
  - esqueci o **alvo do `sed_`** em duas violações plantadas (`sed_ <expr>`
    sem arquivo) → "variável não associada" sob `set -u`;
  - plantei violações em arquivos que o job `project-rules` **não executa**
    (a página é testada no outro job) → o `ci-guards-test` acusou "NÃO
    reprova". Solução: dois **guardas estáticos** no `project-rules` (chamada
    de topo na coluna 0 é proibida; a guarda `(OPTIONS && OPTIONS.identity)`
    tem de existir), e os plants passaram a atacá-los;
  - dois plants miravam em texto que não era o guarda (`log_error`/`section`),
    então "não reprovavam" — reancorados no valor (`Bases disponíveis`,
    `install-sources.yaml`).
- **Resultado:** `make validate` **verde** — `webui-page` **13** (novo),
  `ci-guards` **116** (era 110), `webui` 51, `iso-chat` 31,
  `ai-talk-install` 39, `role-identity` 22, `iso-lint` OK.
- **O que NÃO foi provado:** a página continua **sem ser aberta num navegador**
  (o teste executa o JS, mas layout/CSS/`<dialog>` não são cobertos); e
  `--install-source` foi provado por `--check-templates`/verificador —
  **nenhuma ISO gerada/instalada** para confirmar a base no alvo.
- **Commits:** *(ver `git log`)*.

### Sessão #44 — 2026-10-20 · 💬 ADR-003 F2: o chat da frota chega à máquina

- **Objetivo:** o dono pediu o ADR-003. A F1 (transporte) já existia desde a
  #41; o que faltava era tudo o que transforma "existe um daemon" em "a máquina
  tem o serviço": instalador, unit, ISO e a corrente até o primeiro boot.
- **O que foi feito:**
  - `talk/install.sh` (idempotente, `--dry-run`, `--yes`, `--root`,
    `--status`): cria o usuário de sistema `ai-talk`, escreve o config
    (`0640`), copia as chaves (`0640`), gera a unit e habilita o serviço —
    **só se houver chave**. Sem chave: instala **desabilitado** e avisa.
  - `talk/ai-talk.service` com o endurecimento do §9 (`NoNewPrivileges`,
    `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
    `RestrictAddressFamilies`).
  - `iso/build-iso.sh`: flags `--chat-node/-port/-bind/-peer/-peers-file/
    -key-file/-keydir/-disable` + `validate_chat` + `stage_chat_payload`
    (payload em `/ai-cpu-os-boot/chat/`, chaves `0640` na mídia também).
  - `iso/common/late-command.sh`: seção **2-f** copia o payload para
    `/target/etc/ai-talk` e registra `CHAT_KEY`/`CHAT_KEYDIR`/`CHAT_PEERS` no
    `.iso-config`.
  - `iso/common/firstboot.sh`: exporta `AI_CHAT_*` (mesmo padrão de
    `AI_MODEL_FILE`/`AI_LLAMA_SOURCE`).
  - `build.sh`: **etapa 2/5** (`run_chat_install`) — o chat vem **antes** do
    papel, para a máquina poder relatar uma falha da inferência por ele; falha
    do chat é **aviso**, nunca derruba o build (Regra 13-a).
  - `iso/verify-iso.sh`: seção "Chat da frota (ADR-003)".
  - Testes novos: `tests/test-ai-talk-install.sh` (**39**) e
    `tests/test-iso-chat.sh` (**31**); `make talk-install-test` e
    `make iso-chat-test` no `validate` e no CI; `ci-guards` 100 → **110**.
- **Decisões:**
  - **`--chat-peer` vence o `--chat-peers-file`** independente da ordem ("a
    exceção explícita manda" é previsível; "o último vence" não é).
  - O gerador de config passou a emitir **sempre** a forma objeto
    (`{"addr": …}`) para os peers: o contrato aceita a string como atalho, mas
    uma config gerada pelo projeto não deve ter dois formatos.
  - O teto de 15 é cobrado em **três** lugares (daemon, instalador, ISO).
- **Bugs reais encontrados por execução (cinco, todos meus):**
  1. **`fetch` devolve o CAMINHO, não o conteúdo** — a primeira versão da seção
     do verificador contava/comparava o caminho e reprovava uma ISO correta
     ("1 nó" para 2 peers, "chave inválida" para uma chave boa).
  2. **Chave por nó não entrava na config com `--root`**: o gerador testava
     `os.path.isfile(keys/<nome>.key)` no caminho **prefixado**. O peer saía
     sem `key_file` e cairia na chave global — exatamente o que o ADR-005
     existe para evitar. Agora a chave é explícita (`--peer-key`).
  3. **Caminho prefixado indo para a config do alvo** (`/tmp/…/etc/ai-talk`):
     no alvo o daemon morreria. Agora a config grava `/etc/ai-talk/…`.
  4. **`--peers-file` vencia o `--peer`** (ordem de leitura invertida),
     ao contrário do documentado.
  5. **Seis guardas decorativos meus**, pegos pelo `ci-guards-test`:
     `ENABLE_SERVICE=0` (aparece em `--no-service`), `stage_chat_payload`
     (a definição sobra), `run_chat_install` (idem), `NoNewPrivileges`
     (`=no` casa `^NoNewPrivileges=`), `8#004` e `--peer-key` (sem guarda).
     Todos reancorados na **condição/valor**.
- **Resultado:** `make validate` **verde** — `ai-talk-install` **39**,
  `iso-chat` **31**, `ci-guards` **110**, `ai-talk` 30, `webui` 51,
  `role-identity` 22, `iso-lint` OK, `docs` OK.
- **O que NÃO foi provado:** **duas VMs trocando mensagens** (Bloco R) — o
  único teste que mede latência real; o **serviço rodando sob systemd** de
  verdade (o teste usa `--root`, sem `useradd`/`systemctl`); a **bancada de 15
  nós** (o teto é aplicado, não medido); e **nenhuma ISO** foi gerada ou
  bootada depois de todas as mudanças.
- **Commits:** *(ver `git log`)*.

### Sessão #43 — 2026-10-20 · 🧑‍🔧 ADR-002: a identidade do sistema segue a FUNÇÃO

- **Objetivo:** o dono pediu *"o usuário será definido pela função (builder ou
  inference)"*. A decisão estava no ADR-002 desde a #39; esta sessão a executou.
- **Decisão-chave (por que não no 1º boot):** com `--role` concreto o papel já é
  conhecido na **geração da ISO**; renomear usuário depois da instalação mexe
  em home, `sudoers`, chaves e serviços — rejeitado no ADR. E com `--role auto`
  o papel só aparece no 1º boot, quando o usuário já existe → `auto` mantém
  `ai-cpu-os` e **avisa** (Regra 13-a: default degrada, nunca aborta).
- **O que foi feito:**
  - `iso/build-iso.sh`: `resolve_identity()` + `role_default_username()` +
    `identity_line()`; marcadores `USERNAME_EXPLICIT`/`HOSTNAME_EXPLICIT` (o
    valor já nascia preenchido — sem eles não dá para distinguir "o usuário
    pediu `ai-cpu-os`" de "é o default"); GECOS passou a declarar a função
    (`ai-inference (inference)`); `--hostname` diferente do usuário é
    reconhecido como frota do mesmo papel (ADR-002 §5).
  - `.iso-config` no alvo ganhou `ISO_USERNAME`/`ISO_HOSTNAME`/
    `IDENTITY_SOURCE` (prefixo `ISO_` porque `HOSTNAME` é variável do shell e o
    `firstboot.sh` **dá source** nesse arquivo).
  - `iso/verify-iso.sh`: seção "Identidade (ADR-002)" que confere a
    **derivação** (papel concreto → nome esperado, salvo `origem=explicito`) e
    a coerência `autoinstall.yaml` × `late-command.sh`.
  - `webui/`: `ROLE_IDENTITY` em `/api/options`, campos opcionais de
    usuário/hostname com `RE_USERNAME`/`RE_HOSTNAME` e sugestão ao trocar o
    papel. Campo vazio = o build deriva.
  - Novo `tests/test-role-identity.sh` (**22 asserções**) + `make identity-test`,
    no `validate` e no CI; `ui-test` 46 → **51**; `ci-guards` 93 → **100**.
- **Bug real encontrado (pré-existente e silencioso):** o `verify-iso.sh`
  conferia `ROLE`/`FAMILY` no `late-command.sh` procurando **aspas duplas**
  (`"inference"`) — mas o template usa **simples** (`'@@ROLE@@'` →
  `'inference'`). Como o `make iso-yaml` **sempre** rodou com `--role auto`,
  esse ramo nunca foi exercitado; o primeiro `--check-templates --role
  inference` reprovou uma árvore correta com "não grava ROLE=inference". Achado
  só porque o teste novo exercita papel concreto.
- **Outro guarda decorativo pego pelo próprio teste:** `grep -q 'ai-inference'`
  passava mesmo trocando a derivação por `ai-cpu-os` (o nome aparece em
  comentário e na mensagem de log). Ancorado no **braço do case**
  (`^    inference) printf 'ai-inference'`), e o mesmo para a condição de
  `USERNAME_EXPLICIT`. `ci-guards-test` denunciou os dois.
- **Resultado:** `make validate` **verde** — `role-identity` **22**,
  `ci-guards` **100**, `webui` **51**, `ai-talk` 30, `iso-lint` OK, `docs` OK.
- **O que NÃO foi provado:** **nenhuma ISO foi gerada nem bootada** — a
  identidade nunca foi vista num sistema instalado (`getent passwd
  ai-inference`). A prova é `--dry-run` + `--check-templates` +
  `verify-iso --dir`. A UI continua **sem ter sido aberta num navegador**.
  Frota (`ai-inference-2`) só por `--dry-run`. **Dívida = P5 no `STATE.md` § 6.**
- **Commits:** *(ver `git log`)*.

### Sessão #42 — 2026-10-20 · 🗑️ ADR-001 executado: o caminho Debian da ISO saiu

- **Objetivo:** o dono disse *"esse projeto está ficando complicado demais com 2
  imagens de ISO. Vamos ficar só com o UBUNTU"*. A sessão #39 registrou a
  decisão (ADR-001); esta sessão a **executou**.
- **O que foi feito:**
  - `iso/preseed/` **removido** (`git rm -r`). Os três arquivos que serviam os
    dois instaladores foram para **`iso/common/`** (`late-command.sh`,
    `firstboot.sh`, `ai-cpu-os-firstboot.service`) com os ramos Debian
    apagados; o caminho na mídia passou de `/preseed/` para
    **`/ai-cpu-os-boot/`** (inclusive no `autoinstall.yaml`).
  - `iso/build-iso.sh`: 14 funções/opções Debian apagadas (constantes,
    `extract_iso_debian`, `expand_apt_offline_block`,
    `expand_root_preseed_block`, `expand_network_preseed_block`,
    `inject_preseed_initrd`, `patch_isolinux`, `patch_efi_debian`,
    `debian_locale_args`, `grub_bootdev_line`, `repack_iso`,
    `regenerate_md5sums`, `backup_file`, `--mirror-host`/`--mirror-dir`), mais
    as dependências `isolinux`/`mtools`. `--distro debian` agora **sai com
    exit 2** e cita o ADR (entrada do usuário → erro fatal é permitido, Regra
    13-a).
  - `iso/verify-iso.sh`: um caminho só; recusa `--distro debian`; cobra os
    caminhos novos; as checagens de preseed/initrd/md5sum/localechooser/
    grub-bootdev saíram.
  - `Makefile`: `DISTRO` e `iso-dry-run-both` fora; `iso-dry-run` é o alvo
    único; `iso-lint` aponta para `iso/common/`.
  - `webui/`: `DISTROS = ("ubuntu",)`, seletor de distro trocado por uma nota.
  - Testes: `test-verify-iso-repo-distro.sh` → **`test-verify-iso-repo.sh`**
    (6 asserções), `test-iso-selection.sh` sem os casos Debian,
    `test-ci-guards.sh` com ~14 violações plantadas reescritas.
- **Decisões:**
  - O **diretório compartilhado** chama-se `iso/common/` (e não
    `iso/shared/`): "common" já é o vocabulário do repositório.
  - O que o Debian ensinou **não foi jogado fora**: virou guarda no caminho
    Ubuntu (`autoinstall quiet`, `-map … /autoinstall.yaml`,
    `shutdown: reboot`, `refresh-installer update: false`, `geoip: false`,
    `ssh.install-server`, `sync` no firstboot, marcador no `ttyS0`).
  - O CI ganhou **dois guardas negativos** que não existiam: `preseed/` não
    pode voltar ao `build-iso.sh` nem reaparecer como diretório.
- **Problemas encontrados (todos por execução, não por revisão):**
  1. **Guarda apontando para o texto errado:** `grep -q 'late_command'` no
     `autoinstall.yaml` — o arquivo tem `late-commands:`. O `test-ci-guards`
     reprovou a árvore **limpa** e denunciou.
  2. **`no-mmap` sumiu junto:** ao substituir um bloco grande do
     `validate.yml` eu levei um guarda **inteiro** embora. Só apareceu porque
     `test-ci-guards` exige que a violação plantada **reprove** — o guarda
     tinha virado decorativo por ausência.
  3. **Guarda preso a texto que não existe mais:** `ISO_REPO_ALLOW_MISMATCH …
     "$DISTRO" == "ubuntu"` (a condição deixou de ter o `$DISTRO`). Trocado
     pelo invariante real: o mismatch **degrada** (`ISO_REPO="none"`).
  4. **Três guardas novos que não reprovavam** (decorativos por construção):
     `-map` da raiz da ISO, `geoip` e `--no-mmap`. Os dois primeiros foram
     ancorados no valor (`-map … /autoinstall.yaml`, `geoip: false`).
  5. **`shellcheck` pegou código morto:** `DISTRO_NAME` ficou sem uso depois de
     o ramo Debian sair (SC2034) — removido.
  6. **`make iso-lint` apontava para um arquivo apagado** (`iso/preseed/…`).
- **Resultado:** `make validate` **verde** — `ci-guards` **93**, `ai-talk` 30,
  `webui` 46, `iso-lint` OK, `iso-selection` 10, `verify-repo` 6, `iso-lock`
  13, `iso-disk` 16, `iso-release` 10, `verify-iso-space` 6, `mod-network` 41,
  `mod-apt-sources` 17, `write-pendrive` 16, `check-iso` 20, `avx512` 61.
  `make iso-dry-run` gera o plano do caminho Ubuntu sem erro.
- **O que NÃO foi provado:** **nenhuma ISO foi gerada nem bootada** depois da
  remoção, e nada foi instalado em hardware físico. A prova de comportamento
  continua sendo a da sessão #21 (anterior à mudança). `--check-templates` e
  `verify-iso --dir` provam **conteúdo**, não boot (Regra 13).
  **Dívida registrada como P5 no `STATE.md` § 6.**
- **Commits:** *(ver `git log`)*.

### Sessão #41 — 2026-10-20 · 💬 O `ai-talk` virou código: F1 implementada e testada

- **Objetivo:** “vamos testar essa solução; se não for satisfatória, futuramente
  trocamos”. Para **testar de verdade**, a F1 saiu do papel.
- **O que foi implementado (`talk/ai_talk.py`, stdlib):**
  - daemon (`serve`) + CLI (`status`, `peers`, `send`, `ping`, `hello`,
    `listen`, `tail`, `check-config`, `shutdown`);
  - TCP 7331, JSON por linha, envelope v1 e **HMAC-SHA256 canônico**;
  - **chave por nó** (`peers[nome].key_file`), com a chave global como
    fallback; `read_key` **recusa** chave legível por “outros”;
  - `ack` **depois** do append + `fsync` (sem ack se a gravação falhar);
  - `TCP_NODELAY`, conexão persistente por peer, `connect_timeout` e
    `ack_timeout` com 3 tentativas e backoff 1 s/2 s;
  - **espaçamento de 50 ms por par** (msg e ping), `hello`/`ack` isentos,
    fila de 256 com **exit 5** no overflow e teto global de 120/s;
  - dedupe de **8.192** IDs, `log.control=false`, rotação em 32 MB × 5;
  - **teto de 15 peers** no `load_config` (ADR-005), com mensagem que aponta
    para relay/hub;
  - Unix socket de controle por onde o CLI fala (o daemon é o único que abre
    porta de rede).
- **Três pontos que a implementação tornou mais precisos (corrigidos no
  contrato):**
  1. **`ping` CONTA no throttle** (só `ack`/`hello` são isentos). O teste
     anterior supunha o contrário; o contrato já dizia “msg e ping”.
  2. **`queue_max` conta só quem AGUARDA** — a mensagem em trânsito não ocupa
     vaga. Sem essa definição o teste da fila ficava ambíguo (era o único
     vermelho da primeira rodada).
  3. **`--no-wait` retorna após ENFILEIRAR**, não após o write TCP.
- **Provas (`make talk-test`, 30 asserções, loopback, sem root, sem rede):**
  entrega + ack + log; espaçamento medido (548 ms para 2 mensagens com
  intervalo de 400 ms); `hello` em 0,8 ms (isento) e `ping` em 399 ms
  (throttled); dedupe (2 acks, 1 linha); assinatura inválida sem ack e sem
  gravar; peer desconhecido (4) e corpo grande (5); fila (3 aceitas, 4ª com
  5); `ECONNREFUSED` → exit 3 em **106 ms**; `listen`/`tail`; chave 0644 → 2;
  16 peers → 2; “somente stdlib” por AST.
- **Dois bugs reais achados ao EXECUTAR (não ao revisar):**
  1. `accept(ctl, control_loop)` passava o socket como primeiro argumento —
     a assinatura é `(daemon, sock)`, então **todo** `status` travava com
     `TypeError` na thread. Só apareceu ao rodar o daemon de verdade.
  2. `--config` só era aceito **antes** do subcomando; o systemd e o próprio
     contrato usam `ai-talk serve --config …`. Agora os dois funcionam
     (`parents=` com `SUPPRESS` para não sobrescrever o global).
- **Guardas:** `ci-guards` 89 → **98**, com violação plantada para
  `compare_digest`, `TCP_NODELAY`, `os.fsync`, `MAX_PEERS = 15`,
  `dedupe_window = 8192`, chave frouxa e import de terceiro. Duas guardas
  nasceram **decorativas** (casavam com o nome/valor e não com o código) e o
  próprio `make ci-guards-test` as denunciou — corrigidas para âncora no
  valor (`"dedupe_window": 8192`) e no check (`stat.S_IROTH`).
- **Arquivos:** `talk/ai_talk.py`, `talk/README.md`, `tests/test-ai-talk.sh`,
  `Makefile` (`talk-test` + no `validate` + `compileall`), `validate.yml`
  (passo + arquivos obrigatórios + guardas), `tests/test-ci-guards.sh`,
  `docs/CHAT.md`, `docs/CI.md`, `docs/DECISIONS.md`, `docs/STATE.md`,
  `docs/ROADMAP.md`, `AGENTS.md`.
- **Verificado:** `make talk-test` **PASS=30 FAIL=0** (3 execuções seguidas,
  sem flakiness e sem daemon órfão); `ci-guards` **98**; **`make validate`
  inteiro verde** (lint, docs, famílias 85, AVX-512 61, ISO, rede 41, apt 17,
  pendrive 16, check-iso 20, webui 46, ai-talk 30, dry-run Ubuntu+Debian).
- **O que NÃO foi provado:** latência em **rede real** (o loopback não mede
  LAN), duas VMs (Bloco R), bancada de 15 nós, `talk/install.sh`, unit e
  integração na ISO (F2), ponte com o modelo (F3).

### Sessão #40 — 2026-10-20 · 💬 O contrato do `ai-talk`: delay, durabilidade e teto de 15 nós

- **Objetivo:** “como fica o delay entre as mensagens?” e depois “será possível
  outras máquinas entrarem na mesma conversa (umas 30)?” → “mantenha um teto de
  15 máquinas, assim fica confortável”.
- **Decisões (todas do dono, via formulário):**
  - **Delay = intervalo mínimo entre `msg` do mesmo nó para o mesmo peer.** Não
    é atraso por mensagem, nem inclui `ack`/`hello`.
  - **50 ms por par** (= 20 msg/s), com fila **FIFO de 256** e **exit 5** no
    overflow (nunca descarte silencioso).
  - **Meta de latência: p99 ≤ 10 ms** em LAN cabeada.
  - **`fsync` por mensagem** (durável): o `ack` significa “gravado no disco”.
  - **Teto de 15 nós** em malha completa; acima disso, **relay/hub
    obrigatório**.
- **Lacunas e inconsistências corrigidas no contrato:**
  - O §8 dizia “~6 s no pior caso”; a conta do §6.4 dá **9 s**
    (2 s + 1 s + 2 s + 2 s + 2 s). O contrato passou a declarar **9 s** e a
    explicar em §6.7.3.
  - Faltava **`connect_timeout`**: com IP obsoleto/ARP pendurado, o `connect`
    pode levar ~2 min e o timeout de ack nunca vale. Agora é 1 s.
  - Faltava **`TCP_NODELAY`**: Nagle + delayed ACK podem injetar ~40 ms numa
    mensagem pequena — sozinho estourava a meta.
  - Faltava definir o **escopo do throttle** (por par, não global) e a
    **isenção** de `ack`/`hello` — sem ela, cada envio pagaria +50 ms.
- **Ajustes que o teto de 15 exige (ADR-005):** janela de dedupe **1024 →
  8.192** (cobrir o retry de 9 s a 280 msg/s), **chave por nó** (evita
  impersonação; revoga um nó sem trocar a chave de todos), `log.control=false`
  (não gravar ack/hello/ping), `max_out_per_sec=120` (teto global além do
  20/s por par) e configuração por **`--chat-peers-file`/`--chat-keydir`**.
- **Números calculados (15 nós, no teto de 280 msg/s por nó):** 14 conexões por
  nó (105 no cluster), ~106 KB/s (~0,85 Mbit/s), `fsync` ~84 ms/s (~8% de 1
  core), broadcast em **2 RTTs** (concorrência 8), log de 32 MB girando a cada
  ~5 min no pior caso.
- **Arquivos:** `docs/CHAT.md` (§1, §5.2, §6.1, §6.4, §6.7, §6.8, §7, §9,
  §13.1, §13.5, §14, §15, §16), `docs/DECISIONS.md` (ADR-004 e ADR-005,
  índice), `AGENTS.md` (Regra 18 + resumo da fase), `docs/STATE.md`
  (§ 3.8/§ 4/§ 6/histórico), `docs/ROADMAP.md`.
- **Verificado:** `make validate` (lint, docs, famílias, AVX-512, ISO, rede,
  UI, guardas 89, dry-run Ubuntu+Debian). **Nada de código do chat foi escrito**
  — é contrato; nenhuma medição de latência foi feita.
- **O que NÃO foi provado:** os números de escala e de latência são **cálculo**,
  não medição. O teto de 15 só vale como decisão depois da bancada de 15 nós
  (`CHAT.md` §13.5), que **não foi executada**.
- **Commits:** nenhum nesta sessão (árvore para revisão).

### Sessão #39 — 2026-10-20 · 🧭 Preparar “uma ISO, duas funções, uma frota”

- **Objetivo:** “o projeto está ficando complicado demais com 2 imagens de ISO;
  vamos ficar só com o Ubuntu; o usuário será definido pela função (builder ou
  inference); precisamos de um chat pela rede para as IAs se comunicarem
  (talk ou algo do tipo). Prepare o ambiente para implantar isso num futuro
  não muito distante.”
- **O que foi feito (preparação, sem implementar as três mudanças):**
  - **`docs/DECISIONS.md`** — três ADRs com contexto, decisão, consequências,
    mapa de impacto, plano e critérios de aceite:
    - **ADR-001:** base **única Ubuntu Server**; Debian/preseed **deprecado**,
      remoção **P0**. O runtime Debian (`build.sh`/`mods/`) continua suportado.
    - **ADR-002:** identidade por papel — `inference`→`ai-inference`,
      `builder`→`ai-builder`, `auto`→`ai-cpu-os` + aviso; `--username`/
      `--hostname` explícitos vencem.
    - **ADR-003:** chat de frota **`ai-talk`** (TCP 7331, JSON lines, HMAC,
      Python stdlib), com alternativas descartadas.
  - **`docs/CHAT.md`** — contrato do `ai-talk`: envelope v1, assinatura
    canônica, handshake/ack/retry, config, CLI, systemd, segurança, log,
    falhas, testes (offline/ISO/duas VMs/ponte com o modelo), fases e
    alternativas. Deixa explícito por que o `talk` do netkit **não** será usado.
  - **`iso/build-iso.sh`** — `--distro debian` agora emite **aviso de
    depreciação** (sem quebrar o build, Regra 13-a); help e comentários
    apontam o ADR-001 e a futura identidade por papel. Nenhuma remoção de
    código.
  - **`Makefile` + `.github/workflows/validate.yml`** — `docs/DECISIONS.md` e
    `docs/CHAT.md` passam a ser obrigatórios (`make docs` e o job
    `project-rules`), para a preparação não desaparecer em silêncio.
  - **`AGENTS.md`, `docs/STATE.md`, `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`,
    `docs/ISO.md`, `README(s)`** — fontes de verdade apontam para a nova fase;
    `STATE.md` § 6 foi reescrita com a ordem P0→P3.
- **Decisões de arquitetura (resumo):**
  - A ISO é **Ubuntu-only**; o Debian continua como **hospedeiro** das mods,
    não como base de mídia.
  - A identidade segue a **função**, não o hardware; `--role auto` não pode
    derivar identidade porque o papel só é conhecido no 1º boot.
  - O chat é **transporte**, não orquestrador: mensagem é dado, nunca comando;
    a ponte com o modelo é opcional (fase 3) e não executa tool calls remotas.
- **O que NÃO foi feito (de propósito):**
  - Nenhum código Debian foi removido; `--distro debian` ainda funciona.
  - Nenhuma identidade por papel foi implementada.
  - Não existe `talk/` nem `ai-talk`; nenhum teste de chat foi escrito.
  - Nenhuma ISO foi gerada/bootada nesta sessão.
- **Estado do repositório:** o `main` local já estava no commit `bf2117f`
  (“a ISO instala sem internet — sessão #38”), à frente do `AGENTS.md`; a
  preparação foi feita sobre esse estado. O `AGENTS.md` foi atualizado junto.
- **Próximo:** P0 (remover Debian) → P1 (identidade) → P2/P3 (`ai-talk`). Ver
  `docs/STATE.md` § 6.
- **Commits:** nenhum nesta sessão — as mudanças ficaram na árvore para
  revisão; o commit deve ser feito depois de `make validate`.

### Sessão #38 — 2026-10-18 · ⚡ "sem internet não instala": 4 defeitos, um deles engana

- **Objetivo:** "ambas as distribuições não instalaram automaticamente se não
  tiver internet... com a internet o ubuntu fez o auto install certinho, o
  debian a instalação funcionou bem. agora o debian está disponível para testes
  de acesso via ssh".
- **SSH primeiro (o pedido explícito):** a nova instalação apareceu no meu DHCP
  em `192.168.0.117`, `ssh` **enabled+active** e login com senha OK;
  `apt-get update` do alvo **sem** nenhuma fonte fantasma. Ou seja: as
  correções das sessões #36/#37 seguraram em metal.
- **Depois, o defeito de fundo — a ISO exigia internet.** Reproduzi numa VM
  ligada a uma **bridge isolada** (DHCP de verdade, **sem NAT**), que é o
  cenário do dono: rede local sem internet. Quatro defeitos, cada um numa
  camada diferente:
  1. **`[!] Please check the specified mirror`** — o `apt-setup` **sempre**
     configurava o espelho de rede. Sem internet ele para e pede outro. →
     `d-i apt-setup/use_mirror boolean false`.
  2. **`[!!] Select and install software — Installation step failed`** — li o
     `postinst` do `pkgsel` (udeb 0.85): `tasksel`/`apt-get install` falhando
     caem em `aptfailed`, que faz `exit $ret` → o d-i mostra a tela e **espera
     um Enter**. → sem repo local: `pkgsel/include` vazio,
     `pkgsel/run_tasksel false`, `pkgsel/upgrade none`.
  3. **`[!!] Configure the network`** — o `netcfg` reprova DHCP **sem
     gateway** (rede isolada). Não é bug do projeto: com gateway passa.
  4. **O bug mais enganoso:** com `--iso-repo auto` o repositório **estava** na
     mídia, era copiado para `/opt/apt-repo`… e **nunca virava fonte**. O
     `Release` gerado pelo build tinha **`Suite: ./` / `Codename: ./`**, e a
     validação que eu mesmo escrevi na #36 comparava esse codename com o do
     alvo — `./` nunca casa, então o `late-command` **descartava o repo** com
     um `AVISO` no log. Resultado: alvo sem fonte local → `apt` falha (rc=100)
     e `git clone` falha (rc=128). → agora o Release traz o codename **real**
     (`trixie`, via `iso_base_codename`, com reserva por tabela Debian).
- **Provado SEM INTERNET NENHUMA** (ISO gerada num container `debian:13-slim`,
  VM em bridge isolada, `--iso-repo auto --iso-source auto`):
  `reiniciando` → `aplicação concluída com sucesso` → `.firstboot-status:
  status=ok` e `AI-CPU-OS-BUILD.txt` com **`Rede: não usada (fonte local)`**.
  `verify-iso` **PASS=56 FAIL=0**; `sshd` e `sudo` presentes no alvo.
- **Achado de processo (importante):** `--iso-repo auto` **exige a mesma
  base/release** da ISO. No meu host (Ubuntu 26.04) gerando ISO Debian, o build
  **avisou e seguiu sem repo** — proteção correta, mas significa que quem
  precisa de uma ISO auto-suficiente tem de gerá-la num container da mesma
  distro/release. Documentado no `ISO.md` § 4.5.2 e no `TROUBLESHOOTING`.
- **Uma descoberta de método:** inspecionar o disco instalado **offline**
  (`qemu-nbd` + `mount -o ro`) foi o que separou "não instalou" de "instalou e
  o 1º boot falhou": o `sshd`/`sudo` estavam lá, o que faltava era a **fonte**
  do apt.
- **Guardas:** `ci-guards` 86 → **89**, com violação plantada para
  `use_mirror`, `run_tasksel` e `Codename: ./`.
- **O que NÃO foi provado:** Ubuntu **sem internet** (só Debian), rede **sem
  DHCP**, e o mesmo teste em hardware físico.

### Sessão #37 — 2026-10-18 · 🖥️ A PRIMEIRA validação em hardware FÍSICO (e o primeiro `llama-bench`)

- **Objetivo:** "teste debian, boot ok e auto install ok. agora só falta testar
  o ssh e fazer a validação".
- **O que se fez, por medição:**
  - Encontrei o alvo pelo meu DHCP (lease novo): **`192.168.0.115`**,
    OpenSSH 10.0p2 — ou seja, **o `sshd` existia desta vez**. A correção da
    sessão #36 (garantir o SSH no `late-command`) funcionou em metal.
  - Sem a senha eu não podia entrar, então validei o **conteúdo** das duas ISOs
    do dono: `ai-cpu-os-debian.iso` **PASS=56 FAIL=0**;
    `ai-cpu-os-ubuntu.iso` **PASS=47** (com `--disk /dev/sda`, que é o que ela
    fixa — sem isso o verificador reprova, corretamente). Nenhuma das duas
    levava repositório apt: os pacotes vieram da rede (havia NAT).
  - Com a senha, entrei por SSH e acompanhei o 1º boot (que ainda estava
    compilando): **`status=ok`** ao final.
- **A máquina é HARDWARE FÍSICO REAL, e não é uma das de referência:**
  **AMD A8-9600** (Excavator, 4C/4T), 6,7 GiB, Debian 13 trixie. Família
  detectada: **`generic`** — fallback **correto**, porque Excavator é anterior
  ao Zen e o projeto não tem (nem precisa ter) família para ele.
- **Provas coletadas (Bloco Q do `VALIDATION.md`):**
  - llama.cpp compilado **do tarball da mídia, sem rede**: o
    `AI-CPU-OS-BUILD.txt` diz literalmente `Rede: não usada (fonte local)`;
  - `smoke-test.sh` **PASS=12 FAIL=0 SKIP=1** (o SKIP é o `llama-server` não
    iniciado na hora; depois subiu e respondeu `{"status":"ok"}`);
  - tuning **persistiu após reboot**: swappiness 10, vfs_cache_pressure 50,
    numa_balancing 0, THP `[always]`, governor `performance`;
  - **SSH sobreviveu ao reboot** (login feito de novo, `ssh` enabled+active) e
    a rede também (DHCP sozinho, com default route);
  - `firstboot` **não** repetiu (sentinela removida);
  - **primeira medição de inferência do projeto**:
    `pp64 17,05 ± 0,36 t/s` · `tg32 10,40 ± 0,03 t/s` (4 threads, BLAS,
    Qwen2.5-Coder-1.5B Q4_K_M) — e uma requisição real devolveu `OK`.
- **Bug de log encontrado na execução:** o `llama-build.sh` dizia
  **"Seleção: forçada por --family"** para uma família que o próprio projeto
  havia **detectado** e apenas repassado pela cadeia (build → install →
  llama-build). Confunde quem lê o log procurando o que foi forçado. Agora ele
  detecta também e diz a verdade: *"detectada na CPU e repassada pela cadeia
  (mesma família)"* ou *"forçada por --family (a CPU sugere 'X': motivo)"*.
  Guarda nova (`ci-guards` 85 → **86**).
- **O que NÃO foi provado:** o **Xeon E5-2680 v4** e o **Ryzen 5 3500X** (sem
  acesso), **UEFI**, `--network static`, Ubuntu em metal, air-gapped completo
  (faltaram os pacotes apt) e o **ganho** do tuning (não houve medição "antes"
  nesta máquina).
- **Commits:** *(ver `git log`)*.

### Sessão #36 — 2026-10-18 · 🔌 "A máquina instalada não aceita SSH" (e a causa era o próprio projeto)

- **Objetivo:** "instalei a versão ubuntu e preciso que você tente acessar via
  ssh no dispositivo enp5s0".
- **O que se encontrou (por medição, não por leitura):**
  - **Não havia DHCP nenhum** no cabo. O `enp5s0` do host de trabalho está em
    **IP fixo** (`192.168.0.2/24`, sem gateway) e um cabo direto não tem
    servidor DHCP. Sem DHCP a máquina instalada não tem endereço e "não
    aparece na rede" — o primeiro sintoma engana.
  - Subi um `dnsmasq` só DHCP nessa interface e a máquina apareceu sozinha:
    `192.168.0.113`, MAC `e0:d5:5e:20:ae:b2`, **hostname `ai-cpu-os`** (ou seja:
    é o **sistema instalado**, não o instalador).
  - `nmap -Pn -p-` → **65535 portas em `closed`**, nenhum listener. TTL 64
    (Linux). Ping responde em 0,29 ms.
  - Conclusão: **a máquina não tem `sshd`**. Não é firewall (firewall daria
    `filtered`/timeout; `closed` = RST do kernel).
- **Causa raiz (é um bug do projeto, não do usuário):** a ISO pede o SSH ao
  instalador — `ssh: install-server: true` no Ubuntu, `openssh-server` no
  `pkgsel` do Debian — e **os dois falham em silêncio quando não há rede
  durante a instalação**. O resultado é o pior modo de falha possível: a
  máquina **instala, sobe, pega IP e não tem nenhum acesso remoto**; sem
  teclado/tela ela é um tijolo. E nada avisava.
- **Correções (a promessa passa a ser cumprida, não presumida):**
  - `iso/preseed/late-command.sh`: **verifica** o `sshd` no alvo e, se faltar,
    instala ali mesmo (a mídia ainda está montada; se houver rede, o espelho
    responde). Se ainda assim falhar, escreve um aviso no `/etc/motd` e em
    `/root/LEIA-SSH.md` — quem chega no console descobre o que fazer em 5 s.
    A detecção usa `[ -x /target/usr/sbin/sshd ]` (não depende de chroot).
  - `build.sh`: novo `ensure_ssh` (roda em **todo** primeiro boot): verifica,
    instala, habilita e — se não der — deixa o mesmo aviso. Nunca derruba o
    build (Regra 13-a).
  - `iso/build-iso.sh`: quando a ISO sai **sem repositório apt**, o aviso agora
    diz a consequência explícita ("alvo sem rede sobe SEM SSH") e recomenda
    `--iso-repo auto`.
  - `iso/verify-iso.sh` + CI: guarda nos **dois** instaladores (o
    late-command é compartilhado) — `ci-guards` 76 → **78**, com violação
    plantada para cada um.
- **Rede de laboratório montada para o diagnóstico (fica de pé):**
  `dnsmasq` em `enp5s0` (faixa `192.168.0.100-200`, gateway/DNS `192.168.0.2`)
  + `ip_forward` + `MASQUERADE` na interface de saída, para o alvo ter
  internet. Um **flap de link** (`ip link set … down/up`) faz o cliente
  renovar o lease e receber as opções novas — foi assim que o alvo passou a
  ter gateway/DNS sem tocar nele.
- **Prova em VM (Debian 13.7, depois da correção):** ISO gerada
  (`verify-iso` **PASS=52**), `test-vm.sh` **OK** nos dois marcadores e, ao
  subir o disco instalado com a porta encaminhada, **a 22 estava aberta**:
  login por SSH feito e `systemctl is-enabled ssh` = **enabled**.
- **Estado no fim da sessão:** a máquina **Ubuntu** do dono segue **sem SSH**
  (só o console resolve); o monitor de porta 22 ficou rodando. A correção é
  para as **próximas** instalações — e está provada em VM.
- **Lição registrada (TROUBLESHOOTING):** "responde a ping mas não aceita SSH"
  → **varra as portas** antes de culpar firewall: `RST` em tudo = sem
  listener; e cabo direto **não tem DHCP**.
- **O DONO APONTOU O OUTRO LADO DO MESMO PROBLEMA:** "`sudo apt-get update`
  sempre dá erro; o sistema não acha o repositório, como se não houvesse link".
  Investigação por medição:
  - O `apt` **realmente aceita** o repositório que vai na ISO (testei o
    `apt-repo` extraído da ISO num `Dir::Etc` temporário: `Release` + `Packages`
    + pacotes, OK). Logo, a ISO está certa **quando o repositório é copiado**.
  - O defeito está no `late-command.sh` **da época**: ele gravava
    `deb [trusted=yes] file:///opt/apt-repo ./` no alvo **sem verificar se o
    `/opt/apt-repo` existia** (só olhava o rc do `cp`). Sem o diretório, TODO
    `apt-get update` falha com "não possui um arquivo Release" e — como o apt
    aborta no erro — **nada** instala, incluindo o `openssh-server`. Os dois
    sintomas (sem SSH, apt quebrado) são o **mesmo** evento: instalação sem
    rede + fonte local fantasma.
  - A rede do alvo **funciona** (os contadores de `FORWARD`/`MASQUERADE`
    mostram tráfego passando), então o problema não era rota: era sources.
- **Correções:**
  - `late-command.sh`: o repositório local só vira fonte depois de (1)
    `Release`+`Packages` presentes, (2) **mesma release** do alvo (comparação
    pelo `VERSION_CODENAME`) e (3) **`apt-get update` restrito àquela fonte**
    como prova. Falhou qualquer passo → **não grava** (melhor sem repo local do
    que com o apt quebrado). Três guardas novos no CI.
  - **Nova mod `mods/apt-sources/`** (`make apt-fix`, `make apt-test`,
    **17 asserções** em árvore falsa, sem root e sem rede) — o reparo da
    máquina **já instalada**: remove fontes que apontam para o nada
    (`file://` inexistente, `cdrom:`, `.sources` sem `URIs:`) com backup
    `.ai-cpu-os.bak`, grava a lista **oficial** da distro quando nada sobra e
    valida com `apt-get update` (ou avisa que pulou, sem chroot). `revert.sh`
    devolve tudo.
  - Superfícies atualizadas (Regra 15): `required` do CI, árvore do
    `AGENTS.md` § 4, tabela do `docs/MODS.md`, `mods/README.md`, `Makefile`
    (`apt-test` no `validate`) e um passo de CI que roda as **duas** mods de
    reparo. `ci-guards` 78 → **81**.
- **Terceiro achado, na véspera do build do dono:** ao conferir o comando
  recomendado (`--iso <arquivo local>` + `--iso-repo auto`) com `--dry-run`,
  o build respondeu **"Release incompatível: a ISO é Ubuntu 24.04 (noble) e
  esta máquina é 'resolute'"** — para um arquivo **26.04**. Dois defeitos:
  (a) `iso_release_version()` só olhava `$ISO_URL`; com `--iso` ficava o
  **default 24.04**, então quem gerava a ISO da própria release **perdia o
  repositório local** (e a ISO passava a depender de rede — exatamente o que
  produziu os sintomas originais); (b) o codename vinha de uma **tabela fixa**
  sem 26.04 → `want` vazio → o build imprimia "não sei o codename, não vou
  conferir a release" e **seguia montando o repo sem conferir nada** (buraco
  para `.deb` de outra release). Correção: versão do **nome do arquivo**;
  codename lido do **`.disk/info`** da ISO (reserva na tabela, agora com
  26.04=resolute); a conferência só roda quando `DISTRO=ubuntu` (antes, numa
  máquina Debian ela comparava `noble` com `trixie` e descartava o repo).
  Prova: `make iso-release-test` (10 asserções, ISOs falsas) — 26.04 em host
  26.04 → "Release confere: resolute" + "baixaria o fecho … openssh-server";
  22.04 em host 26.04 → aviso + repo descartado. `ci-guards` 81 → **83**.
- **Quarto achado, ao RODAR o build recomendado de ponta a ponta** (não em
  dry-run): a ISO de 26.04 foi gerada com sucesso — `Release confere:
  resolute`, **459 pacotes** no repositório (com `openssh-server`, `sudo`,
  `git`) — e então o **próprio verificador reprovou a ISO**: 2 problemas, um
  deles *"rede auto sem /preseed/ai-cpu-os-netplan.yaml"*. Mas o arquivo
  **estava na ISO** (extraí e conferi). Causa real: o verificador extraía o
  **modelo inteiro** (1,1 GB) para ler 4 bytes de `magic`; o diretório de
  trabalho é `mktemp -d` → **/tmp**, que aqui é **tmpfs de 7,5 GB**. O tmpfs
  enchia e, do primeiro ENOSPC em diante, **toda** extração falhava →
  cascata de falsos `AUSENTE`. Correção: `fetch_head()` (LBA via `report_lba`
  + `dd bs=2048 count=1`) e `fetch_size()` (metadado `lsdl`); diretório de
  trabalho escolhido pelo **espaço livre** (`$TMPDIR` → `/tmp` → dir da ISO →
  atual, mais `--tmp DIR`); e `[SKIP]` honesto quando não dá para ler — nunca
  acusar a ISO por falta de espaço. Detalhe que quase passou: o LBA de início
  é o campo **depois da primeira vírgula** de `File data lba:  0 ,  1633166 ,`;
  pegar o primeiro número lia o começo da ISO e o magic saía `eb63 9090`.
  **Prova:** `make iso-space-test` (6 asserções, modelo esparso de 2 GB) e a
  ISO real voltou a **PASS=50 FAIL=0**. `ci-guards` 83 → **85**.
- **PROVA NAS DUAS DISTROS (2026-10-18):** ISO **Ubuntu 24.04.5** gerada
  (`verify-iso` **PASS=43**) e **Debian 13.7** (**PASS=52**); nos dois casos
  `test-vm.sh` **OK** nos dois marcadores e, ao subir o disco instalado com a
  porta encaminhada, **a 22 abriu** com login por SSH e
  `systemctl is-enabled ssh` = `enabled`. É a prova que faltava para a distro
  do dono.
- **Commits:** *(ver `git log`)*.

### Sessão #35 — 2026-10-18 · 🐧 A ISO Debian: 10 travas, todas mudas

- **Objetivo:** "a criação de ISO Debian está apresentando falhas, corrija". O
  caminho Debian (preseed + isolinux) **nunca havia sido bootado** — só o
  Ubuntu tinha prova de VM. Nenhuma das falhas abaixo aparece como mensagem de
  erro: o sintoma é sempre "a máquina fica parada" ou "o 1º boot não aplica".

#### Parte 1 — a instalação não acontecia

- **Bug 1 — o build abortava, e a culpa era do verificador.** O
  `verify-iso.sh` exigia o netplan do alvo **também** no Debian, que é preseed:
  a ISO era gerada e reprovada com 2 problemas. A seção "Rede do sistema
  instalado" virou **distro-aware** (Ubuntu = netplan/autoinstall; Debian =
  `netcfg/disable_autoconfig`, `dhcp_timeout`, `get_ipaddress`…).
- **Bug 2 — `prompt 1` no isolinux.** O isolinux mostrava `boot:` e **esperava
  uma tecla**; o `timeout` não vale nesse modo. Sintoma: VM parada, disco
  intocado (qcow2 em 193 KB) e serial com **zero byte**. `prompt 0` resolveu.
  De quebra, `--serial-console` agora põe `serial 0 115200` + `console 0` no
  isolinux (sem isso o menu nem existe para um teste headless).
- **Bug 3 — o preseed estava no lugar errado.** O `S30initrd-preseed` do
  initramfs lê **`/preseed.cfg` na raiz do initrd**;
  `preseed/file=/cdrom/...` só é aplicado quando o udeb `file-preseed` instala
  — tarde demais. Nova `inject_preseed_initrd()`: anexa um segundo `cpio`
  (newc) ao `initrd.gz` com `/preseed.cfg`, `/preseed/ai-cpu-os.cfg` e
  `/preseed/late-command.sh` (o kernel desempacota os dois; um overlay
  posterior sobrescreve). As 3 cmdlines passaram a usar
  `preseed/file=/preseed.cfg`, e o `late-command.sh` autodetecta o ponto de
  montagem (`/cdrom`, `/media/cdrom`, `/hd-media`, `/media/usb`).
- **Bug 4 — `[!!] Select a language` para sempre (o mais difícil).** Com o
  preseed no initrd e `language=pt country=BR locale=pt_BR.UTF-8 keymap=br` na
  cmdline, a interface ficava **em português** e a pergunta aparecia **mesmo
  assim**. Diagnóstico por execução, não por leitura: troquei o
  `S30initrd-preseed` por uma versão que loga em `/dev/console` e bootei
  `-kernel vmlinuz -initrd initrd-dbg.gz` direto. Resultado: `preseed_location
  rc=0` e `language=[pt] seen=[true]` no db — **o preseed estava aplicado**.
  Então li o fonte do componente (localechooser 2.112) e achei: a pergunta
  exibida é `localechooser/languagelist`, e `do_preseed` só propaga o `seen`
  quando `has_choice` encontra o idioma **nas escolhas da lista**; a lista vem
  de `language_display_level()`, e em **console serial o nível é 0**, onde só
  existe `en`. Correção: `d-i localechooser/languagelist select @@LANG@@`.
- **Bug 5 — `[!!] Configurando grub-pc`.** `grub-installer/bootdev` é pergunta
  crítica, feita **depois** de copiar o sistema inteiro; sem resposta o
  instalador espera para sempre com tudo já instalado. Agora o build gera
  `d-i grub-installer/bootdev string <DISCO>` (ou `default` sem disco fixado).
- **Bug 6 — o mais cruel: `$` de um hash crypt entre aspas DUPLAS.**
  `ROOT_PASSWORD_HASH="$6$sal$hash"` faz o shell expandir `$6`; sob `set -u` o
  `late-command.sh` morria com **exit 2 antes de copiar arquivo nenhum**. A
  única pista na VM era `Failed to run preseeded command … exit code 2`, com
  `/opt` vazio no alvo. Todos os marcadores literais viraram **aspas simples**,
  e o autoteste (`--check-templates`) passou a **avaliar** a linha gerada com
  `sh -u -c` provando que o hash chega byte a byte (`sh -n` não pega isso).
  O script também ganhou um `trap … EXIT` que imprime a falha no
  `/dev/console` (antes ela só existia no tty4 do instalador).

#### Parte 2 — a instalação terminava, mas o 1º boot não aplicava

Depois de instalar de verdade e **entrar por SSH no alvo** (porta encaminhada,
`systemctl status ai-cpu-os-firstboot` + `journalctl`), apareceram mais dois
bugs — invisíveis pelo console serial, porque o `firstboot.sh` escreve no
journal e no arquivo de log:

- **Bug 7 — `deb cdrom:[Debian …]` no apt do alvo.** Quem grava essa fonte é o
  **próprio instalador** (`apt-cdrom-setup`), não o `--iso-repo`. Depois da
  instalação a mídia não existe e **todo** `apt-get update` falha ("não tem um
  arquivo Release") → o papel `inference` aborta com **rc=100** antes de
  instalar qualquer dependência. Agora o `late-command.sh` remove **só** as
  linhas `deb … cdrom:` (o espelho oficial fica intacto) e roda o
  `apt-get update` uma vez para confirmar.
- **Bug 8 — `sudo` não existe no Debian.** O usuário da ISO está no grupo
  `sudo`, mas o pacote **não** vem numa instalação padrão do Debian
  (`sudo: comando não encontrado`) — e com o root bloqueado o sistema ficava
  **sem nenhum acesso administrativo**. `sudo` entrou em `EXTRA_PACKAGES` e em
  `DEFAULT_REPO_PACKAGES` (para o repositório local cobri-lo).
- **Bônus — a máquina não reiniciava.** O `finish-install.d/20final-message` do
  d-i pergunta a nota final e trata um `db_go` "back" como **`exit 10`**; o
  `finish-install` interpreta 10 como "backed up", **aborta** a sequência (nem
  `94save-logs` nem `99reboot` rodam) e a instalação para no menu. Preseedar
  `finish-install/reboot_in_progress note` não bastou em console serial.
  Primeira tentativa: o `late-command.sh` (hook `07preseed`, antes do `20`)
  substitui o hook por um no-op. **Não bastou** — e a razão é fina: o
  `20final-message` vem do udeb `finish-install`, que é desempacotado **depois**
  do hook `07preseed`, então no momento em que o substituíamos o arquivo ainda
  não existia (bastava ver que o log do d-i não tinha a linha do patch). Quem
  resolve de verdade é o **`reboot -f` no fim do `late-command.sh`**, depois do
  `sync` e do `umount /target` (o `95umount` do d-i não roda depois daqui). É o
  único ponto do fluxo que depende só de nós; o patch do hook fica como cinto
  de segurança caso o reboot falhe.

#### Parte 3 — o 1º boot aplicava, mas o teste não via

- **Bug 9 — o marcador não chegava ao console serial.** Instalado de verdade com
  todas as correções, o `test-vm.sh` **ainda** estourava o timeout — e o sistema
  estava **pronto** (`/opt/llama.cpp/build/bin/` cheio, `.firstboot-status` com
  `status=ok`, log completo). A saída do unit (`journal+console`) escreve em
  `/dev/console`, e no sistema **instalado** esse device aponta para o **último**
  `console=` da cmdline: o d-i grava `console=ttyS0,115200 console=tty1`, então
  tudo ia para o `tty1` (invisível numa VM sem vídeo). Quem apontou a causa foi
  o `cat /proc/cmdline` no alvo, não o log.
  **Primeira tentativa, descartada por medição:** espelhar a saída inteira em
  `/dev/ttyS0` (`exec > >(tee -a "$LOG" > /dev/ttyS0)`). Funcionou por ~8
  linhas e **travou o console da VM de vez** — nem as mensagens do kernel saíam
  mais, `%CPU` do qemu em 0, com o build parado no meio. Correção final: só os
  **marcadores** vão ao `/dev/ttyS0` (`serial_marker()`), escritas raras e
  curtas, como o `late-command.sh` já fazia.
- **Bug 10 — a espera por rede do 1º boot não tinha teto por sonda.** Cada
  `getent hosts` com DNS que não responde bloqueia por dezenas de segundos; o
  laço de 24 tentativas passava de **40 min** em silêncio (idle, sem log) — foi
  isso, e não a compilação, que estourou o `test-vm.sh` no t6 e no t8. Agora
  cada sonda tem `timeout 5` (teto total ~2 min, como a mensagem promete).
- **A lição de tempo (medida, não estimada):** com **8 vCPU** o 1º boot inteiro
  leva **~4,5 min** (instalação ~8 min, llama.cpp ~4 min com `-j8`); com **4
  vCPU** e DNS lento a coisa muda de ordem. E o qcow2 **não** cresce durante o
  build (clusters já alocados): medir `stat -c %b` dá a impressão falsa de que a
  VM travou — o jeito de saber em 10 s é entrar por SSH e olhar `ps` (cc1plus a
  99% = compilando).

#### Testes e guardas

- `verify-iso.sh` ganhou 11 checagens Debian (as 9 primeiras + o marcador no
  `/dev/ttyS0` + a proibição de espelhar o build inteiro) (`prompt 0`, `language=`/`keymap=`
  na cmdline, `localechooser/languagelist`, `grub-installer/bootdev`,
  `/preseed.cfg` **dentro** do initrd — com `grep -c`, nunca `grep -q |
  pipefail`, que morre por SIGPIPE —, limpeza do `cdrom:`, troca do
  `20final-message`, reinício explícito, espelho no `ttyS0` e `sudo` no
  `pkgsel/include`). Na ISO final: **PASS=51 FAIL=0**.
- Guardas novos no `validate.yml`, cada um provado por violação plantada:
  `ci-guards` 63 → **76**.
- Incremento de robustez do build: o temporário do `inject_preseed_initrd` saiu
  do `/tmp` (tmpfs que enchia e fazia o gzip falhar com uma mensagem que
  mentia: "formato inesperado?") e os backups (`.orig`) saíram de dentro da
  árvore da ISO — eles iam **parar dentro da ISO gerada** (24 MB no initrd).
- **Prova real (VM qemu/KVM, console serial):** ISO Debian gerada, instalada
  sozinha, reiniciada e o 1º boot aplicou o ai-cpu-os. Ver `docs/STATE.md` § 3
  e o Bloco M de `docs/VALIDATION.md`.
- **Commits:** *(ver `git log`)*.

---

## 5. 🧵 Threads abertas (o que ficou no ar)

> **Esta é a seção mais importante para retomar.** Lista o que está *incompleto*,
> *decidido mas não feito* ou *em dúvida*.

### 5.1 Bloqueado por ambiente

> ✅ **DESTRAVADO na sessão #21.** O ambiente mudou: uma máquina com **24 vCPU,
> `/dev/kvm`, `qemu`, Docker, 790 GB livres e rede**. Como `build-iso.sh` exige
> root e `xorriso` (ausente no host), a ISO foi gerada **dentro de um container
> `ubuntu:24.04`** (root grátis + resolve o *release mismatch* do repo apt) e
> bootada no **qemu do host** (com `/dev/kvm`). **Gerar e bootar a ISO não é
> mais bloqueio.**

| Thread | Bloqueio |
|--------|----------|
| **Validar em hardware real** | Ainda falta acesso físico ao Xeon E5-2680 v4 e ao Ryzen 5 3500X (Blocos A–O do `VALIDATION.md`). |
| **Medir tokens/s (`llama-bench`)** | Depende do item acima. |
| ~~Gerar e bootar a ISO~~ | ✅ **Feito na sessão #21** (VM com KVM). Ver § 4, sessão #21. |

### 5.2 Decidido, mas ainda não executado

| Thread | Nota |
|--------|------|
| **Nada de código no caminho da ISO** | ✅ Os 5 requisitos do § 3.1 do `docs/ISO.md` estão implementados. **Não há pendência de implementação conhecida** — falta EXECUTAR (ver abaixo). |
| 🔴 **CI estava vermelho no `main`** | ✅ **Corrigido na sessão #18** (default que abortava + comando duplicado CI×make). Os runs verdes anteriores eram de antes das mudanças. |
| 🔴 **A ISO Ubuntu não era gerada** | ✅ **Corrigido na sessão #19.** `exit code 22` = 404 do `curl`: o `SHA256SUMS` do Ubuntu marca o modo binário com `*` e o `*` ia para a URL. Teste de regressão: `make iso-select-test`. **Reproduzir no workflow `iso` para confirmar.** |
| 🔴 **Guarda do CI decorativo (`! cmd`)** | ✅ **Corrigido na sessão #19 (2ª parte).** Seis guardas negativos nunca derrubaram o job (`set -e` ignora comando invertido com `!`) — convertidos para `if cmd; then exit 1; fi`, com meta-guarda e `make ci-guards-test`. |
| ✅ **Debian + `air_gapped=true`: causa era FALSO POSITIVO** | **Resolvido (sessão #20).** O `verify-iso.sh` procurava o repo em uso **só no `/autoinstall.yaml`**, que **não existe** numa ISO Debian (que usa preseed) → reprovava uma ISO **correta** ("2 problema(s)"). Agora é **distro-aware**; `make iso-verify-test` prova os dois caminhos e **reprova o verificador antigo**. |
| ✅ **Ubuntu: `git` ausente no repo apt** | **Resolvido (sessão #20).** Sobrou **só `git`** (o filtro resolveu `gnupg`/`jq`): falha **intermitente de rede**, indistinguível de "pacote não existe" no log. `Acquire::Retries` + **segunda tentativa só dos ausentes**. |
| ⚠️ **Dependências implícitas do runner** | **Resolvido (sessão #20):** `openssl` (hash da senha), `gzip` (índice do repo) e `ca-certificates` (curl HTTPS) passaram a ser instalados explicitamente. Descobertos num container `ubuntu:24.04` limpo — dependência que existe no runner "por acaso" some quando o runner muda. |
| **Rodar o workflow `iso` de novo (ubuntu e debian, `air_gapped=true`)** | É o **próximo passo real**: as três causas conhecidas estão fechadas. Se falhar de novo, as **anotações** dirão o motivo (agora capturam `[FAIL]` do verificador também). |
| **PRs abertos para decidir** | **PR #2** (debian `13-slim` no `docker/`): ✅ **mesclado** em `63eebff` (o `main` remoto já está à frente). **PR #3** (bump de actions): ✅ **resolvido no `main`** (caminho B) — o `@v7` do `upload-artifact` foi aplicado direto, com guarda no CI; **pode fechar o PR**. |
| ✅ **Obter a ISO numa máquina SEM `xorriso`** | **Existe (sessão #23):** artifact do CI sobe **sempre** (o limite de 2 GiB é da Release) e `make iso-check ISO=…` confere o arquivo baixado (tamanho, SHA256, `CD001`, Volume ID, boot). ⚠️ **Ainda não exercitado contra um artifact real** — a prova foi com fixtures byte a byte. |
| ✅ **Pendrive bootável (o passo final)** | **Existe (sessão #22):** `iso/write-pendrive.sh` com 9 travas + `make pendrive-test` (16 asserções). ⚠️ **Nenhum pendrive FÍSICO foi gravado ainda** — as travas e o `dd`→`cmp` foram provados contra um **arquivo**. |
| **Gerar a ISO (passo 3 do checklist)** | ✅ **FEITO na sessão #21** — build **exit 0**, `verify-iso.sh` **PASS=41/FAIL=0**. Ver `STATE.md` § 3.3. |
| **Bootar em VM (passo 4 — o critério de conclusão)** | ✅ **FEITO na sessão #21** (Ubuntu) e **na #35** (Debian) — `test-vm.sh` **exit 0** nos dois (instalou + reiniciou + 1º boot aplicou). Ainda falta **hardware físico**. |
| ⚠️ **Limite de 2 GiB por arquivo de Release** | A ISO air-gapped (~5,2 GB) **não pode** ser anexada a uma Release. O CI pula o upload e avisa. Distribuição: pendrive/`scp`, runner self-hosted, ou outro host + SHA256 na Release. |
| ✅ **Aceite do instalador para o repo local** | **RESOLVIDO (sessão #21) — era BUG.** A `sources` (Subiquity) **não funciona**: o curtin roda `apt-get update` num **chroot no alvo** (sem `/cdrom`) → `apt-config` exit 100. Agora o repo é **carregado para o alvo** (`/opt/apt-repo`) pelo late-command. (O `apt-setup/local0` do Debian segue **não testado**.) |
| **PR #1 do Dependabot** | ✅ **mesclado** em 2026-10-09 (verificado pela API: `merged: true`). |
| **Bloco M** (`VALIDATION.md`) | ✅ **EXECUTADO no caminho Ubuntu em VM (sessão #21)**; falta o Debian e o hardware real. |
| **Blocos A–L** (`VALIDATION.md`) | Idem — nenhum resultado preenchido (hardware físico). |
| **`md5sum.txt` da ISO** | Gerado pelo script, mas **nunca validado** por um instalador real. |
| **Boot UEFI da ISO** | ⚠️ **não testado.** O `-boot_image replay` (sessão #21) restaurou a imagem EFI oculta do Ubuntu; falta o Debian (`mtools`) e o boot UEFI de fato. |
| 🎯 **Instalar de verdade em OUTRO PC** | ⚠️ O Modo 1 (disco fixado inexistente) foi **corrigido e testado** na sessão #31 — mas **por teste**, não por uma instalação. Falta: gerar com `--disk auto`, gravar o pendrive e **bootar na outra máquina**. Roteiro pronto em `docs/IMPLANTAR-EM-OUTRO-PC.md`. |
| 🖥️ **A interface web num NAVEGADOR de verdade** | ⚠️ **nunca foi aberta** — nem por quem escreveu (sessão #24). Os **34** casos de `make ui-test` exercitam a **API**: lista branca, validadores, SSE, recusa sem `xorriso`, ausência de rota de escrita, bind em `127.0.0.1`. **Tudo que for visual** (layout, um botão que não responde, contraste) é afirmação não verificada. Abrir `make ui` numa máquina com browser e clicar em **Simular** resolveria. |
| 🖥️ **A UI numa máquina COM `xorriso`** | ⚠️ O caminho "gerar a ISO" pelo navegador só foi provado **recusando** (esta máquina não tem `xorriso`). O caminho feliz (job roda, SSE mostra o progresso real até o fim, a ISO nova aparece na lista) **não** foi exercitado ponta a ponta. |
| ⚠️ **Gatilho do autoinstall (sinalizado, sessão #30)** | Dos 3 modos sinalizados: **(1)** `--disk` fixado inexistente — corrigido na #31 (`--disk auto`); **(3)** **Debian/preseed** — ✅ **executado na #35** (instala, reinicia e aplica em VM). Resta **(2)** o **UEFI nunca bootado**. Ver `docs/TROUBLESHOOTING.md`. |
| 🔬 **Quem avisa quando o `iso` falha?** | ⚠️ O workflow `iso` roda **manualmente** (`workflow_dispatch`) ou por tag. O run **#16** (2026-10-14) falhou e eu **só descobri de passagem**, numa sessão seguinte, olhando a lista de runs por outro motivo — ninguém foi notificado. Enquanto for assim, uma ISO que não gera pode ficar dias sem ninguém notar. Ideias: um lembrete em `docs/STATE.md`, ou disparar o `iso` no `main` com `air_gapped=false` (a ISO leve, ~1 GB) para usar o CI como sinal. |
| 🔬 **O run #16 depois do fix (confirmar)** | ⚠️ A 2ª tentativa agora roda `apt-get update` e loga a resposta do `apt`, mas **nenhum run novo rodou ainda**: a correção é hipótese informada pela medição (4 s + erro idêntico ⇒ lista inválida/404), não fato observado. **Disparar o `iso` com `air_gapped=true` e conferir as anotações.** |
| 🌐 **Rede do alvo (sessão #33)** | A configuração agora vai na ISO (bloco `network:` + netplan na mídia + `99-ai-cpu-os.yaml` no alvo). ✅ **PROVADO EM VM**: o alvo pegou IP por DHCP sozinho e o SSH funcionou. **Falta** o modo `static`, o hardware físico e o reboot de persistência. |
| 🔴 **Flags do llama.cpp mudam entre versões (sessão #33)** | `--no-mmap` foi removido do upstream e derrubava o `ai-server` em loop. A unit passou a usar `${LLAMA_EXTRA_ARGS}` + detecção no `install.sh`. **Vale para QUALQUER flag futura**: ao subir `LLAMA_REF`, revisar `llama-server --help`. |
| 🟠 **Gravação do disco no 1º boot (sessão #33)** | Arquivos de **0 byte** (unit vazio = `masked`) quando o disco não é descarregado. `sync` no `firstboot.sh` + espera no `test-vm.sh`. **Falta** exercitar um desligamento abrupto de propósito (queda de energia simulada). |

### 5.3 Dúvidas em aberto / dívida técnica (requerem decisão sua)

| Dúvida | Contexto |
|--------|----------|
| ⚠️ **O build do llama.cpp ainda busca o UI na rede?** | Achado na sessão #21: `llama-build.sh` usa `-DLLAMA_CURL=OFF` (runtime sem downloads), mas o **build** tentou baixar o **UI** do HuggingFace (`-- UI: downloading … llama-ui … dist.tar.gz`); o `.sha256` falhou na VM e o build **seguiu** → parece *best-effort*. **Confirmar** que a ISO é 100% offline (talvez uma flag `-DLLAMA_BUILD_UI=OFF`/`-DLLAMA_UI=OFF` conforme a versão do llama.cpp). Não bloqueou o teste, mas contraria a Regra 13-b se for obrigatório. |
| **Distribuir a ISO air-gapped (5,2 GB > 2 GiB da Release)** | Caminhos: pendrive/`scp`, runner self-hosted, ou publicar fora + SHA256 na Release. Decisão de infraestrutura, não de código. |
| ⚠️ **Por que o runner do GitHub deixou de fazer `exec` no `bash -c` entre os runs #56 e #57?** | O mecanismo que derrubou o `validate` #57 está **provado e reproduzido** (§ 6: um `BASH_ENV` com `trap` desliga a otimização) e o teste ficou **imune aos dois lados**. O que ficou em aberto é **o lado do runner** (imagem/versão do runner? `BASH_ENV`?). Não bloqueia nada — mas se alguém vir de novo um teste reprovando com o código correto, o **desconfiômetro** já está calibrado: suspeite de detalhe do shell, não do gerador. |

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

### 5.5 Decisões firmadas em 2026-10-20 (estado real)

| Thread | Decisão | Estado |
|--------|---------|--------|
| **Uma ISO Ubuntu** | Debian/preseed **removido**. O runtime Debian continua suportado. | ✅ **FEITO (#42)** — `iso/common/`, `--distro debian` aborta |
| **Identidade por papel** | `inference`→`ai-inference`; `builder`→`ai-builder`; `auto`→`ai-cpu-os` + aviso; flags explícitas vencem. | ✅ **FEITO (#43)** — `resolve_identity()` + `make identity-test` (22). **Falta** ver num sistema instalado (P5) |
| **Chat da frota** | `ai-talk`: TCP 7331, JSON lines, HMAC, stdlib; fases F1/F2/F3. | ✅ **F1 + F2** (#41/#44): transporte, instalador, unit e ISO. ⚠️ **F3** e **duas VMs** pendentes |
| **Delay entre mensagens** | Intervalo mínimo de **50 ms** entre `msg` do mesmo par (20 msg/s); `ack`/`hello` isentos; fila **256** com **exit 5** no overflow; p99 ≤ 10 ms; `fsync` por mensagem. | ✅ **no código e provado** (`make talk-test`) |
| **Teto de nós** | **15 nós** em malha completa (14 conexões/nó); acima disso, **relay/hub obrigatório**. Chave por nó, `dedupe_window=8192`, `max_out_per_sec=120`. | ⚠️ **no código**, mas **nunca medido** com 15 nós (P4) |
| **Modelo de chaves do chat** | Uma chave por nó, com **dois papéis**: a do peer verifica, a do próprio nó **assina** (`keys/<nó>.key`). Sem ela o serviço nasce **desabilitado** (nunca habilitado e morto). `--key-file` (global) vence. | ✅ **corrigido e provado (#46)** — `talk-install-test` 47; **falta** ver com duas máquinas |
| **Ordem** | P0 ✅ → P1 ✅ → F2 do chat ✅ → correções da #45 ✅ → README + fix de chaves (#46) ✅ → **P5 (boot de uma ISO)** ← agora → Bloco R (duas VMs) → P4 (bancada de 15). | `docs/STATE.md` § 6 |

> ⚠️ **Não confunda plano com fato.** A identidade por papel e o chat estão no
> código e na ISO, mas **nunca foram vistos num sistema instalado**; o
> `ai-talk` tem unit, mas **nunca rodou sob systemd** nos testes (que usam
> `--root`); e **não há medição** de latência nem do teto de 15 nós — os
> números são cálculo.
> ⚠️ E, desde a remoção do caminho Debian (#42), **nenhuma ISO foi gerada nem
> bootada**. As cinco mudanças de #42–#46 (Debian fora, identidade por papel,
> chat na ISO, base explícita, chaves do chat) só existem no código: **nenhuma
> foi vista num sistema instalado**.

---

## 6. 🕳️ Armadilhas já pisadas (não repita)

| Armadilha | O que acontece | Como evitar |
|-----------|----------------|-------------|
| Confundir **`talk` do netkit** com o **`ai-talk`** | Instalar `talkd`/UDP 517 reintroduz um protocolo obsoleto, sem auth/cripto, e não é o desenho aprovado | O componente é `talk/` + binário `ai-talk` (TCP 7331, JSON lines, HMAC). Ver `docs/CHAT.md` § 3 |
| Prometer **latência** ou **teto de nós** sem medir | Os números de §5.2 e §6.7 são **cálculo** (fsync ~0,3 ms, envelope ~380 B); uma máquina com HDD, VM sobrecarregada ou Wi-Fi estoura a meta | Medir na bancada de 15 nós (§13.5) e no Bloco R antes de afirmar; se não couber, cai o teto ou entra o relay — não se ajusta a tabela |
| Dimensionar `dedupe_window` pela **taxa média** | A janela precisa cobrir o **retry de 9 s** na taxa **de pico** (280 msg/s a 15 nós) → 1024 IDs cobrem ~3,7 s e um retry legítimo vira duplicata no log | `dedupe_window = taxa_de_entrada × 20 s` (mínimo 1024; padrão 8.192) |
| **Apagar um diretório da mídia** (`iso/preseed/`) sem varrer os guardas | Guardas que fazem `grep` num arquivo inexistente **derrubam o job com rc 2** — e o `test-ci-guards` acusa "o job falha numa árvore LIMPA". Pior: ao substituir um bloco grande do workflow, você leva guardas embora **sem perceber** (foi o caso do `--no-mmap`), e o único sinal é uma violação plantada que **para de reprovar** | Depois de mover/apagar arquivo da mídia: rode `make ci-guards-test` **antes** de olhar o `validate`. Ele é o detector de guarda quebrado **e** de guarda ausente |
| Trocar o **nome** de um invariante e deixar o guarda ancorado no texto antigo | `grep -q 'late_command'` passou a apontar para um arquivo que tem `late-commands:` — o guarda nunca reprovava e ainda assim "passava" | Ancore no **valor** que importa (`-map … /autoinstall.yaml`, `geoip: false`, `dedupe_window": 8192`), nunca num nome solto |
| **Guarda que só "passa" porque o valor aparece num comentário** | `grep -q 'ai-inference' iso/build-iso.sh` continuava verde mesmo trocando a derivação por `ai-cpu-os` — o nome está nos comentários e na mensagem de log | Ancore na **estrutura** que executa: braço do `case` (`^    inference) printf 'ai-inference'`), condição (`^  if \[\[ $USERNAME_EXPLICIT -eq 1 \]\]`). Se o `ci-guards-test` disser "NÃO reprova", o guarda é decorativo — não insista nele |
| **Confundir o retorno de um helper com o CONTEÚDO do arquivo** | `fetch` do `verify-iso.sh` imprime o **caminho** do arquivo extraído. Tratar esse caminho como o arquivo fez o verificador contar "1 nó" numa frota de 2, dizer que a chave de 32 bytes era inválida e reprovar uma ISO correta | Ou o helper imprime o caminho e quem chama faz `cat`, ou imprime o conteúdo. Nunca os dois na mesma função — e, ao escrever a checagem, imprima o valor antes de julgar |
| **Testar um caminho de arquivo com `os.path.isfile` quando há prefixo (`--root`)** | O gerador de config decidia a chave por nó com `isfile(keys/<nome>.key)` no caminho **prefixado** pelo `--root`; o arquivo não existia, o peer saía sem `key_file` e cairia na chave global (falha silenciosa de autenticação) | Passe a decisão de fora para dentro (`--peer-key nome=/caminho/do/ALVO`). Um teste com `--root` pega isso; um teste no sistema real não pegaria |
| **Testar a API e achar que testou a página** | O `ui-test` exercita `/api/*`; o JavaScript do `index.html` nunca era executado. Um erro no **topo** do `<script>` (ler dado que só existe depois do `fetch`) mata a página inteira e o teste continua verde | Se a UI importa, o **JS tem de ser executado** no CI. O `make ui-page-test` roda o script num DOM falso (Node) e confere o que ele FEZ — inclusive o cenário "servidor fora do ar" |
| **Confiar no `default` de um arquivo de terceiro** | O `autoinstall` não declarava `source:`; a base era o `default: true` do `install-sources.yaml` da ISO. A default (`ubuntu-server`) traz `git`/`curl`/`gnupg`; a `ubuntu-server-minimal` **não** — se a Canonical trocar a default, o alvo perde `git` em silêncio | Fixe o que importa e **confira que existe**: `source: id:` + checagem contra o `install-sources.yaml` da própria ISO, no build **e** no verificador |
| **Código que nunca é exercitado porque o default não o alcança** | O `verify-iso.sh` cobrava `ROLE`/`FAMILY` procurando **aspas duplas** num template que usa **simples**. Como `make iso-yaml` sempre rodou com `--role auto`, o ramo jamais rodou — e o primeiro teste com papel concreto reprovou uma árvore correta | Todo ramo condicional precisa de **um teste com o valor que o ativa**. Se só existe teste do default, o ramo é código morto até o dia em que alguém o usa |
| Usar **uma chave** para a frota inteira | Qualquer nó assina como outro (`from` é só um campo) | Chave **por nó** (`peers[nome].key_file`) quando a frota passa de 2–3 máquinas; o receptor verifica com a chave do `from` |
| **Esquecer que a chave tem DOIS papéis** | A do peer **verifica** (`peers[nome].key_file`); a **do próprio nó assina** (`key_file`). Oferecer só chaves de peer (o `--keydir` com `keys/` incompleto) gera config **válido** e serviço **habilitado** que morre no start com `chave não encontrada` — e o `check-config` do alvo, rodado antes, teria avisado | Ao instalar, derive a chave própria de `keys/<nó>.key`; sem ela, **desabilite** o serviço em vez de habilitar. Prove com o daemon **lendo as chaves de verdade** (o `talk-install-test` faz isso via `ai_talk.read_key`) |
| Checar **chave órfã** antes de montar a lista de peers | Todo peer vindo de `--peers-file` ainda não existe nesse ponto → é acusado de órfão. O modo recomendado (15 nós, arquivo) é justamente o mais afetado | A validação de "chave sem peer" tem de rodar **depois** de todas as fontes de peers (arquivo + `--peer`) |
| **Heredoc dentro de um `run:` do workflow** | A linha final do heredoc (`EOF`/`PYX`) fica na **coluna 0** e sai do bloco YAML: o arquivo fica inválido e o job nem começa | Nada de heredoc em YAML. Use `grep -n … \| head -1 \| cut -d: -f1` e compare **posições** em `(( ))`, ou um `python3 -c` de uma linha |
| Comparar **números** com `grep -n` sem `head -1` | Duas ocorrências → a variável vira string multilinha → `[[ "$a" -lt "$b" ]]` estoura a expressão aritmética, o `if` dá falso e o guarda **passa calado** (o `test-ci-guards` acusa "NÃO reprova") | `head -1` no `grep -n`, e use `(( a < b ))` (que falha alto) em vez de `-lt` dentro de `[[ ]]` |
| Plantar violação com o helper **`app`** (que acrescenta ao FIM) para um guarda que olha a **primeira** ocorrência | O guarda passa e o `test-ci-guards` diz "NÃO reprova" — parece guarda decorativo, mas o plant estava no lugar errado | Para guarda de **ordem**, plante **antes** da âncora (`sed_ 's|^ANCORA|injecao\\nANCORA|'`) |
| Derivar o **usuário do papel** com `--role auto` | O papel `auto` só é conhecido no **1º boot**; nessa hora o usuário do instalador já foi criado | Identidade derivada exige `--role inference|builder` (ADR-002); `auto` mantém `ai-cpu-os` + aviso |
| Adicionar **feature/teste ao caminho Debian** | Ele está **deprecado** e será removido (ADR-001); o esforço vira retrabalho e o CI cresce | Trabalhe só em `--distro ubuntu`; o Debian continua apenas como **hospedeiro** das mods |
| Assumir que a preparação da sessão #39 **já removeu** o Debian ou criou o chat | `--distro debian` ainda funciona, o usuário ainda é `ai-cpu-os` e não existe `talk/` | Leia `docs/STATE.md` § 3.8/§ 6 e `docs/DECISIONS.md`; a implementação é P0–P3 |
| Assumir que **`autoinstall` sem `network:`** configura a rede do alvo | O Subiquity usa DHCP para si mesmo, mas **não grava netplan no alvo** → o sistema instalado sobe **sem IP** (placa DOWN) até configurar à mão | O build grava `network:` no autoinstall **e** o netplan em `/preseed/ai-cpu-os-netplan.yaml`; o late-command copia para `/etc/netplan/99-ai-cpu-os.yaml`, move o netplan do instalador/cloud-init e desliga a rede do cloud-init. Ver `docs/ISO.md` § 4.3 (sessão #33) |
| `grep` **sem arquivo** no terminal | Ele lê o **stdin** e **trava a sessão** | Sempre passe arquivo/glob, ou use `grep ... <<<"$var"` |
| Matar o **qemu logo após o marcador** do firstboot | O guest não descarregou o disco → arquivos de **0 byte**; um `unit` vazio vira **`masked`** no systemd (parece "serviço mascado", não "arquivo corrompido") | `sync` no `firstboot.sh` e 15 s de espera antes de encerrar (`test-vm.sh`). Idem numa queda de energia real |
| Fixar uma **flag do llama.cpp** na unit | O upstream renomeia/remove (`--no-mmap` → `--load-mode none`) e o serviço entra em loop com `invalid argument` | A unit usa `${LLAMA_EXTRA_ARGS}`; o `install.sh` pergunta ao binário (`--help`) qual sintaxe vale |
| Escrever guarda de CI com `grep` **sem âncora** | O texto do próprio comentário que explica o bug casa com o guarda → **falso positivo** (aconteceu 2× na sessão #33) | Ancore na forma real (`^[[:space:]]+--flag`, `^nome()`, `^[[:space:]]*nome()`); `make ci-guards-test` denuncia na hora |
| Polling agressivo na **API do GitHub** sem token | `abuse detection` — bloqueia por vários minutos | Poll no **navegador**; na API, com calma (60 req/h) |
| Assumir que **logs** do CI são públicos | HTTP **403** (exige login) | Use as *annotations* (públicas) ou o navegador logado |
| `cmake` no **Docker** com `GGML_NATIVE=ON` | O CMake pega a CPU do **runner** (pode ter AVX-512) → `SIGILL` no alvo | Mantenha `GGML_NATIVE=OFF` no container (Regra 12) |
| Copiar `build/bin` para outra pasta | **RPATH absoluto** → `error while loading shared libraries` → **exit 127** | Use `cmake --install` + `CMAKE_INSTALL_RPATH` + `ldconfig` |
| Build **nativo** sem `pkg-config` | `Could NOT find PkgConfig` no CMake | Já instalado pelos scripts; se faltar, `apt install pkg-config` |
| Passos de CI **condicionais** (ex.: só em PR) | Ficam **sem cobertura** até alguém exercitá-los | Só apareceu no PR do Dependabot — teste os dois caminhos |
| Tokens `@@...@@` em **comentário** de template | O guarda "sobrou marcador" dava **falso positivo** e abortava o build | O guarda checa apenas os **nomes** de marcador reais |
| `find \| head -1` no `prepare_source_local` | Com `set -o pipefail`, o SIGPIPE do `head` faz o `find` sair 141 e **reprova uma extração que funcionou** | Nunca use `find ... \| head` para "pegar um item": use glob (`"$dir"/*/`) ou `-print -quit` sem pipe |
| `git push` rejeitado (`non-fast-forward`) | Alguém (você, pelo site) comitou no remoto | `git fetch` → inspecionar → `git rebase origin/main` → push (nunca force no `main`) |
| `matrix.exec != 'false'` num **`if:`** do GitHub | `exec: false` é **booleano** no YAML e a comparação **booleano × string** vira **número** (`false`→0, `'false'`→NaN): o `!=` dá **sempre true** e o passo **nunca** é pulado (AVX-512 rodando no runner sem a ISA = SIGILL/132) | Decida no **`bash`**, com o valor vindo por **`env:`** (`[[ "${EXEC:-}" == "false" ]]`); guarda no `project-rules` barra a volta |
| Trabalho **não commitado** num repo com o remoto adiantado | O `push` falha (*non-fast-forward*) e o `git pull`/`reset` pode **perder** a sessão inteira | Antes de sincronizar: `git add -A && git commit` numa **branch de backup** (`backup/…`) **e** salve o patch (`git diff > /tmp/x.diff`); só então `git reset --hard origin/main` (branches de backup guardam os arquivos **untracked**) |
| `sed -i "s/.*texto.*/.../"` em `.md` | Pode quebrar linha sem intenção | Prefira edições por bloco com contexto |
| Editar **bloco** de texto incluindo a quebra de linha final | O texto seguinte **gruda** na mesma linha (ex.: `perfil├── .github/`) e corrompe a árvore/lista | **Sempre confira o resultado** (`sed -n ...p`, `git diff`) e inclua a linha seguinte no contexto da edição |
| Editar um **trecho grande** (uma função inteira) por substituição de bloco | O match pode cair em outro ponto, duplicar trechos e destruir código vizinho — 3 ocorrências em `build-iso.sh` de uma vez, e o `bash -n` acusou erro **longe da causa** | Para edição estrutural, extraia o original com `git show HEAD:arquivo` e reaplique as mudanças por **âncoras exatas** (linha inteira) em script |
| Editar trecho grande / `main()` com `multi_replace` | Casou em **2 pontos**, inseriu o mesmo texto **duas vezes** e o arquivo ficou inválido (3ª vez que a armadilha aparece) | Extraia o original com `git show HEAD:arquivo`, reaplique por **âncoras exatas** e **asssine a contagem** (`assert`) ANTES de escrever |
| Teste que só cobre o caso feliz do próprio código | Bug real passou batido: a função devolvia `file:///apt-repo` (sem `/cdrom`) e, sem repo, ainda devolvia linha com caminho vazio | Exercite as **funções reais** num harness (extraia com `sed`) e teste os caminhos **negativos**; o `--dry-run` também tem de validar |
| Planejar um passo sem prever o **insumo** dele | O item 2 dizia "usar `--source`" e ninguém tinha previsto como o tarball chegaria ao alvo — implementar direto daria erro de arquivo inexistente | Leia o plano com olhos de **executor**: para cada passo, pergunte "de onde vem a entrada?" |
| Assumir que **CI verde = `make` verde** | O `validate` passou **duas sessões vermelho** no `main` com o `make validate` local verde: o passo do CI era um comando **duplicado**, que divergiu do Makefile | Todo comando do CI tem de ser um **alvo do `make`**, e o CI deve **chamar o alvo** — há guarda no CI para isso |
| Fazer um valor **default** abortar o build | `--iso-repo auto` (default) fazia `exit 1` no caminho Debian e quebrou qualquer `--distro debian`; o CI ficou vermelho por causa de um default razoável | Default **degrada com aviso**; `exit 1` só para **entrada do usuário** (caminho digitado errado). Ver Regra 13-a |
| Ignorar o aviso de migração do runner | `ubuntu-latest` migra para Ubuntu 26 em **2026-10-19**; o guarda de release do `--iso-repo` compara o codename do host e passaria a pular o repo sem ninguém entender | Fixe a versão (`ubuntu-24.04`) nos jobs cuja lógica depende da release do host |
| `make` com **espaços** em vez de TAB na receita | `Makefile:118: *** missing separator (did you mean TAB instead of 8 spaces?)` — erro claro, mas só aparece ao rodar o alvo | Ao gerar regra por script, use `\t` de verdade; rode o alvo antes de commitar |
| Escrever merge de PR sem o usuário presente | Decisão que não é minha: dependência bump pode quebrar o build de um jeito que os checks não pegam | Analise e **reporte** (PR #2 verde e `clean`; PR #3 em conflito e com valor parcial); quem mescla é o dono |
| Chamar um PR de dependabot de "redundante" sem conferir **linha por linha** | Um PR pode ter vários hunks e só *alguns* já aplicados: o do `checkout` já estava feito, o do `upload-artifact` não | Compare `changed_files` + o **diff real** com o conteúdo do `main`; conferir as versões publicadas na API antes de opinar |
| Guarda de CI que **conta** um padrão varrendo `*.yml` quando a *string do próprio guarda* está dentro de um `*.yml` | Auto-referência: o `validate.yml` cita `uses: actions/upload-artifact@v7` dentro do comando, então a contagem ficava inflada (3 em vez de 2) e remover o v7 de **um** dos dois workflows não reprovava | Prefira asserção **por arquivo** (`grep -q <padrão> <arquivo>` para cada um) em vez de contar ocorrências num glob que inclui o próprio arquivo do guarda |
| Guarda negativo com `grep` de texto que aparece em **comentário** | O guarda reprova o repositório correto (ex.: o Dockerfile **cita** `COPY build/bin` para explicar por que NÃO usá-lo). **Segunda vez (sessão #24):** o guarda proibia `pip install` e varria o `README.md` — que **explica** "um `pip install` não pode ser pré-requisito para gerar a ISO". A árvore limpa passou a reprovar | Ancore na forma do comando (`^COPY[[:space:]]+.*build/bin`) e teste o guarda com um caso positivo. Aqui: **escopo no código** (`webui/`) + um guarda **positivo** de que a doc promete stdlib |
| `sed -i` na 1ª linha de um script com `#!` | Pode trocar o **shebang** (`#!/usr/bin/env bash` vs `#!/bin/sh`) e mudar o interpretador | Nunca use `sed -i '1s/…'`; confirme o shebang depois (o CI verifica o modo estrito por shebang) |
| Renomear/remover uma **chave de matriz** do CI e esquecer quem a consome | Ficou `${{ matrix.profile }}` no `build-llama.yml` depois de a matriz virar `family` → o **nome do artefato ia vazio** e o `upload-artifact` falharia (só num run de tag, longe do PR) | Ao renomear uma chave de matriz, `grep -n 'matrix\.'` no workflow inteiro; prefira `matrix.family` a nomes genéricos |
| Documentar citando **nomes/comandos de cabeça** | A doc descreve algo que não existe, e ninguém descobre até alguém tentar (ex.: `@@PROFILE@@`, removido na refatoração) | Sempre **copie a saída real** (rode o script) e confira nomes com `grep` no código antes de escrever |
| Tratar um **código de saída numérico** de ferramenta como se fosse do projeto | `exit code 22` no build da ISO Ubuntu parecia erro do `build-iso.sh`; 22 é do **`curl`** (HTTP ≥ 400 sob `-f`). Perdi tempo antes de olhar a URL; era um **404** | Procure o código na documentação da ferramenta (`curl` → 22, 6, 7; `rsync` → 23, 24). Depois **imprima o insumo** (a URL) e teste com `curl -sIL -w '%{http_code}'` |
| Ler um `SHA256SUMS` de terceiro supondo o formato do **nosso** | O do Ubuntu marca modo **binário** com `*` antes do nome (como `md5sum -b`) e o do Debian não — o `*` foi para dentro da URL → 404 mudo | Nunca assuma o formato de arquivo de terceiro: **baixe o arquivo real** e faça `head`/`cat`. Valide o resultado (`^[A-Za-z0-9._-]+\.iso$`) antes de montar a URL |
| Pegar a **primeira** entrada de um índice que lista **todas** as versões | O `SHA256SUMS` do Ubuntu lista 24.04.3, .4, .5 e um `awk '{...; exit}'` pegava a **mais velha** — funcionaria, baixando a ISO errada (falha silenciosa) | Se o arquivo lista versões, escolha o **máximo** (`sort -V | tail -1`) e **ancore o padrão** (`^debian-[0-9]…`) para não casar `debian-edu-*`/`debian-mac-*`/`*-desktop-*` |
| Fixture de teste **inventada** para um formato de terceiro | Um `SHA256SUMS` de 2 linhas feito à mão **não** tem o `*` nem múltiplas point releases — o teste passa e o bug real continua | Guarde uma **cópia fiel** do arquivo real em `tests/fixtures/` e diga a origem e a data no cabeçalho do teste |
| `source` de um script que declara variáveis **`readonly`** | `REPO_ROOT: readonly variable` → o teste morre no `source` (2ª vez: a primeira foi `FAMILIES_DIR`) | Use nomes que não colidam (`TEST_DIR`, `TEST_ROOT`) no consumidor; ao criar `readonly` num script feito para ser carregado, prefira nomes **específicos** do domínio |
| Confundir um passo de CI **consequente** com um segundo bug | No run #6 **dois** passos ficaram vermelhos: o build e o *relatório*. O relatório falhava por `cat` de um `.sha256` que só existe se o build passou — era **eco**, não causa | Ao ver N passos vermelhos, procure o **primeiro** na lista: quase sempre os seguintes são consequência. Faça relatórios **tolerantes a falha** (`2>/dev/null || echo ...`) |
| Diagnóstico que só existe no **log do job** | O log exige token (403): de fora do repositório era **impossível** saber por que a ISO falhou | Faça os passos de falha emitirem **anotações** (`::error::`) e um resumo no `$GITHUB_STEP_SUMMARY` — anotações são **públicas** |
| **Guarda negativo na forma `! cmd`** | O `set -e` **ignora** o exit status de um comando invertido com `!` (está na doc do `set`). O guarda **detecta** a violação e o job fica **verde** — seis guardas do `validate.yml` estavam assim e nunca derrubaram nada. Pior: um guarda positivo logo depois "reprova", dando a impressão de que o negativo funciona | Use `if cmd; then echo "::error::..."; exit 1; fi`. E **prove** com o teste: plante a violação e exija que o job falhe (`make ci-guards-test`). Guarda que nunca reprovou não é guarda |
| Script de prova que **muta a árvore de trabalho** sem restaurar tudo | O `restore` do meu script de teste não cobria um dos arquivos e deixou uma isca (`! grep -q foo bar`) no `.github/workflows/validate.yml` — que só apareceu porque o teste novo roda numa **cópia** e reprovou a árvore limpa | Teste/prova que precisa mexer em arquivos: faça numa **cópia** (`tar -C src --exclude=.git -cf - . \| tar -C dst -xf -`), ou faça backup **de tudo** e restaure com `trap ... EXIT` |
| Ferramenta que **aborta o lote inteiro** quando um argumento falha | `apt-get download git PACOTE-QUE-NAO-EXISTE jq` → rc=100 e **ZERO** arquivos: `git` e `jq` perdidos como dano colateral. Em lotes de 25 com `\|\| true`, cada lote perdia até 25 pacotes **em silêncio** | Nunca junte N itens num comando "tudo ou nada": isole (1 a 1) ou **filhe os itens ruins antes** (`apt-cache policy` → candidato) e refaça o lote que falhar um a um |
| Bug **dependente do ambiente** que passa local e falha remoto | O fecho de dependências na minha máquina (25.10) não tinha pacote virtual; o runner (24.04) tinha — e só lá o lote morria. Nada no meu ambiente indicava o problema | Quando o sintoma é "local passa, remoto falha", desconfie de **entrada do ambiente** (release, versão de pacote, locale) e mude o teste para **injetar** essa entrada (stub/fixture) em vez de tentar adivinhar |
| Assumir que "seis guardas verdes" significa seis guardas funcionando | O job passava verde com todos eles decorativos: nada distinguia "regra respeitada" de "regra não verificada" | Para cada guarda novo, **plante a violação** e confirme que falha. Automatize isso (é o `make ci-guards-test`) |
| Polling em laço com `curl` contra a API do GitHub | Um laço de 25–30 iterações **esgota a cota anônima** (60 req/h) e você fica cego exatamente na hora de ler o resultado. Sintoma: JSON sem a chave esperada (`KeyError: 'workflow_runs'`) | Espere por **turnos** em vez de repetir `curl`; ou peça ao dono para olhar a página Actions. Trate chave ausente como **erro**, não como “sem runs” |
| `xorriso`: opção que **engole** as seguintes como argumento | `-rm X -commit -end`: a lista de `-rm` come `-commit` e `-end` como *caminhos* → `SORRY: Cannot find path '-commit'` → **exit 32** com a ISO já escrita (o sintoma é uma ISO válida em disco + rc≠0) | Termine a lista com `--`: `-rm X -- -commit -end`. Vale para toda opção que aceita `[***]` de caminhos |
| `xorriso -boot_image any keep` num ISO com **imagem El Torito oculta** (Ubuntu) | O `keep` mantém a *referência*, mas a imagem EFI **oculta** (fora da árvore ISO9660) não é copiada: a ISO sai ~6 MB menor, o `efi.img` vira 1 bloco e o MBR protetor aponta além do fim → **exit 32** + UEFI quebrado | Use `-boot_image any replay` (reexecuta o `-report_system_area cmd`: re-anexa a partição EFI via `--interval:imported_iso`) |
| Remontar ISO por `-map` **seletivo** e esquecer arquivos | O caminho Ubuntu mapeia só o que muda; o que fica no `stage` (modelo, fonte, repo) **não** entra na ISO — e o `verify-iso.sh` acusou "air-gapped sem conteúdo" | Ao adicionar algo à mídia, **acrescente o `-map`** correspondente; rode `verify-iso.sh` (ele pega) |
| `xorriso -find` **cita os caminhos entre aspas simples** | `'/apt-repo/x.deb'` não casa com `x.deb` numa comparação de igualdade → **408 falsos** "repositório incompleto" (só no modo `--iso`; o `--dir` usa `find` e não tem aspas) | Remova as aspas do resultado (`sed -e "s/^'//" -e "s/'$//"`); teste os dois modos |
| `printf … \| grep -q` com `set -o pipefail` (entrada > buffer do pipe) | O `grep -q` sai no 1º match, o `printf` leva **SIGPIPE (141)** e o pipeline "falha" → o `if` cai no else. Falsos "a fonte não tem CMakeLists". Já tinha acontecido com `find \| head`. **Terceira vez (sessão #24):** o teste da UI passava 17 KB de HTML por `printf \| grep -q` e a asserção do `<title>` falhava — com a página **correta** | Use **here-string**: `grep -qE … <<<"$VAR"`. (Ou `grep` sem `-q`, que lê tudo.) Vale para qualquer lista > ~64 KB. **Melhor ainda, se é substring de uma variável que você já tem: compare direto** — `[[ "$r" == *"<title>"* ]]` (zero processo extra) |
| Testar API HTTP com `status_of`/`body_of` sobre um corpo **multi-linha** | `printf '%s' "$body" \| cut -f1` devolve **uma linha por linha do corpo** (o `<title>` e mais 400). A comparação `== "200"` falha por "sobra lixo" | `head -1 \| cut -f1`. E, para checar conteúdo, **não** passe o corpo por pipe: compare na variável |
| `print()` do Python **sem `flush`** quando a saída é redirecionada para arquivo | `stdout` vira **block-buffered** (não line-buffered): o `PORT=8787` que o servidor imprime ao subir **não sai no arquivo na hora**, e o teste conclui que o servidor nunca subiu | `print(..., flush=True)` (ou `sys.stdout.reconfigure(line_buffering=True)`). Vale para **qualquer** script que um teste precise ler com a saída redirecionada |
| `set default="<id>"` no GRUB sem `menuentry … --id <id>` | O `set default` casa por **id** OU **título**; sem o `--id` não acha, cai na entrada **0** (a interativa) e a instalação automática **nunca acontece** — sem erro, só o instalador interativo | Sempre par `set default="X"` + `menuentry "…" --id X`. E o verificador tem de checar o `--id`, não só a string (senão casa com o próprio `set default`) |
| Declarar `file:///cdrom/...` como fonte **no apt do instalador** | O curtin roda `apt-get update` **dentro de um chroot no alvo**, onde **`/cdrom` não está montado** → `file:///cdrom/apt-repo` é inalcançável → `apt-config` **exit 100** ("does not have a Release file"), mesmo com o repo e o `Release` na mídia | Carregue o repo para o **alvo** (o late-command copia `/cdrom/apt-repo` → `/opt/apt-repo`) e aponte a fonte lá; o apt do instalador **não** o usa |
| Julgar um teste pela **saída do serial** quando o processo loga no **journal** | O `test-vm.sh` julga por marcadores no console serial, mas o `log()` do late-command vai para o log do subiquity e o firstboot logava só no journal → **nenhum marcador** aparecia e o teste parecia não ver nada (embora a instalação estivesse certa) | Faça o marcador sair **no `/dev/console`** (`printf … > /dev/console`) e use `StandardOutput=journal+console` no unit. Confirme com `--serial-console` |
| Depurar boot de VM **sem tela** | "a VM não boota" sem pista nenhuma: serial vazio. A causa (GRUB subindo a entrada errada) só apareceu com a **tela** | Capture o framebuffer por **QMP** (`screendump`) e leia com OCR (`tesseract` em container); e use **serial bidirecional** (`-serial unix:`) para logar na VM e ver `journalctl` — o serial do subiquity **não** traz a saída do curtin |
| `-boot d` **+** `-no-reboot` num teste de instalação | O instalador **reinicia** ao terminar e o `-no-reboot` encerra o qemu → o 1º boot (o teste que importa) nunca acontece | `-boot order=c,once=d` (1º boot do CD, depois do disco), **sem** `-no-reboot` |
| Retry que **repete o download com a MESMA lista inválida** | `Acquire::Retries` tenta de novo a mesma URL. Se o índice cita uma versão que já saiu do espelho (**404** — comum em virada de *point release*), repetir reproduz o erro **idêntico**, rápido (run #16: 4 s). `Retries` não conserta lista inválida | `apt-get update` **antes** de repetir — índice fresco. E interprete o **intervalo entre as tentativas** como sinal: falha em segundos é falha determinística, não rede |
| Descartar a saída da ferramenta que falhou (`>/dev/null 2>&1`) | O build dizia `Pacote pedido está AUSENTE: git` — **falso**, o pacote existe. A resposta real do `apt` não foi para lugar nenhum, e a sessão inteira caçou um bug inexistente | Capture (`saida="$(cmd 2>&1)"`) e **logue a última linha**. Se a mensagem não distingue "não existe" de "o download falhou", ela é zero-útil |
| Ferramenta de diagnóstico que só lê o **log do job** | O log exige **token** (403). Sem token o diagnóstico é ilegível — no run #16 só as **anotações** (públicas) contaram a história | Leve a causa para a **anotação** (o filtro `PAT` do `iso.yml`) e use `…/check-runs/<job_id>/annotations` para ler |
| Rodar workflow **manual** (`workflow_dispatch`) e ninguém avisar da falha | O run #16 falhou em 2026-10-14 e eu só descobri no dia seguinte, de passagem, olhando a lista de runs por outro motivo | Registre o run pendente em `docs/STATE.md`/§ 5; considere disparar a ISO leve no `main` para o CI virar sinal |
| **Recomendar na documentação uma saída que o código não implementa** | A doc dizia *"gere com `--disk auto`"* como mitigação do disco fixado — e `--disk auto` ia **literal** para o YAML (`match: {path: auto}`): a mitigação **reproduzia o bug**. Ninguém testava o que a doc promete | Trate **a promessa da doc como caso de teste**: se a doc recomenda uma flag/valor, existe um teste que a exercita. Foi assim que o bug apareceu em 1 comando |
| `sed` com `|` (ou qualquer delimitador) **dentro** do padrão | `sed "s|a || b|c|"` → `unknown option to 's'`. O `||` do shell/YAML vira delimitador | Troque o delimitador (`s#…#…#`) ou escape-o. Vale para todo `sed_` de teste de guarda |
| Escrever YAML e rodar o `yamllint` **depois** | Errei o `:` no `name:` e a linha >120 **de novo** (sessão #31) — os dois já estavam documentados aqui. Reli o § 6 depois de errar, não antes | Rode `make yaml` **enquanto** edita, e consulte este § **antes** de escrever o YAML |
| Confiar no **`.list`** que a Ubuntu publica ao lado da ISO | Ele é **incompleto** (omite `/boot`, `/install`, `/.disk` e quase todo `/dists`). Concluí que faltava `/boot/grub` e quase reportei um bug falso | Para saber a estrutura real da ISO, leia a **própria ISO**: *path table* + *directory records* por HTTP Range (~KB), sem baixar 3 GB |
| Assumir que `bash -c '…; cmd'` faz **`exec` do último comando** | A otimização **não é garantida** (basta um `BASH_ENV` com `trap` para o bash desistir dela). Quando ela não acontece, o `cmd` é um **filho** que herda os fds do pai: matar o PID do job mata só o pai e o filho **continua segurando** o `flock` — em `tests/test-iso-lock.sh` isso reprovava o teste com o gerador **correto** (`validate` #57: `exit code 2`, passo de 6 s = 5 s de laço que estourava) | Se o processo tem de MORRER quando você o mata, garanta que nenhum filho herde o recurso (`cmd 9>&-`) **e** que o pai continue vivo (`wait` é builtin: não há troca de identidade). Não conte com a otimização |
| **Sondar** uma `flock` com `flock -n FILE -c true` enquanto um detentor tenta `flock -n` | As sondas pegam a trava por um instante. O detentor que tenta **uma vez** com `-n` perde a corrida em ~1 de cada 3 execuções e o teste fica **flaky** (verde, verde, vermelho) — pior que um teste ausente, porque treina a ignorar o CI | Quem **quer** a trava espera: `flock -w 20` (ou um laço de tentativas). `-n` é para o **build**, que pode falhar rápido e dizer o motivo |
| Instrumentar um `bash -c '…'` adicionando texto com **aspa simples** | `printf '%s:%s '` dentro da string **fechou o `bash -c`** antes da hora: o resto do script virou *argumento* (`$0` = pedaço de código), `"$1"` ficou `_`, o shell criou um arquivo `_` na raiz (`exec 9>"_"`) e eu caçei o bug **na minha instrumentação** por vários ciclos | Instrumente por **arquivo** (script em `/tmp` chamado pelo detentor) ou sem aspas simples; ao ver `$0`/`$1` estranhos, **suspeite do seu próprio texto** primeiro |

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
| 2026-10-20 | Sessão #41 — 💬 **`ai-talk` F1 implementado e testado:** `talk/ai_talk.py` (stdlib) + `make talk-test` (**30 asserções**, loopback). Dois bugs achados só ao executar (thread do controle e `--config` após o subcomando). `ci-guards` 89 → **98**. Faltam F2/F3, duas VMs e a bancada de 15 nós. |
| 2026-10-20 | Sessão #40 — 💬 **contrato do `ai-talk` fechado:** delay = **50 ms** entre `msg` do mesmo par (20 msg/s), fila **256** com exit 5, **p99 ≤ 10 ms**, **`fsync` por mensagem** (ADR-004); **teto de 15 nós** em malha completa, com chave por nó (ADR-005); corrigido o pior caso de ack (**9 s**, não 6 s) e adicionado `connect_timeout`/`TCP_NODELAY`. Nada implementado; sem medição. |
| 2026-10-20 | Sessão #39 — 🧭 **preparação da fase “uma ISO, duas funções, uma frota”**: `docs/DECISIONS.md` (ADR-001 Ubuntu-only, ADR-002 identidade por papel, ADR-003 `ai-talk`) e `docs/CHAT.md` (contrato do chat); aviso de depreciação do Debian no `build-iso.sh`; `make docs`/CI passam a exigir os dois documentos. Nada de identidade/chat implementado. |
| 2026-10-16 | Sessão #28 — 🔴 `build-llama` com **SIGILL**: AVX-512 `auto` (sessão #26) + cross-build gerava binário AVX-512 que o runner **sem AVX-512** executava. Famílias AVX-512 viraram **compile-only** (`exec: false` na matriz); smoke de execução só nas AVX2. |
| 2026-10-16 | Sessão #27 — 🔑 **senha de usuário/root na webui**: campos `type=password` + 🎲/👁; hash crypt no servidor (stdlib `crypt`, fallback `openssl passwd -6 -stdin`); só o hash entra no argv. Root: `--root-password-hash` no build, `chpasswd -e` no late-command (Ubuntu e Debian), `@@ROOT_PRESEED@@` na preseed; bloqueado por padrão. `verify-iso.sh` ganhou a seção "Senha do root"; guardas do CI 33→35; webui 38 asserções. Regra 16 atualizada (senhas DA ISO sim; senha de sudo jamais). |
| 2026-10-16 | Sessão #26 — 🧬 **14 famílias** (Xeon Scalable v5–v9, Xeon 6 P-cores, `amd-zen5`) e **AVX-512 por padrão** (`auto`) nas famílias que o têm — decisão do dono. `--no-avx512` + `FAMILY_MARCH_HAS_AVX512` (troca o `-march` pelo fallback sem AVX-512). Corpus 85 CPUs; matrix do CI 7→14. |
| 2026-10-13 | Sessão #21 — 🎉 **a ISO é GERADA e BOOTADA.** Numa máquina com 24 vCPU + KVM + Docker, a ISO air-gapped foi construída (container `ubuntu:24.04`), verificada (`PASS=41`) e **bootada numa VM** (instalou sozinha; o 1º boot aplicou o ai-cpu-os, família `intel-haswell`). **8 bugs reais** só visíveis ao executar. § 5.1 deixa de ser "bloqueado"; § 5.2 marca o repo local como **bug resolvido** (o apt do curtin roda em chroot sem `/cdrom`); § 5.3 ganha o resíduo do UI do llama.cpp; § 6 ganha 11 armadilhas novas. |
| 2026-10-07 | Criação — diário de continuidade (sessões #1–#8), inventário do ambiente, threads abertas e armadilhas. |
| 2026-10-12 | Sessões #9–#13 (famílias → ISO Ubuntu → ferramentas de validação → Zen 3/4 + GPU → documentação por público). Corrigido o marcador "Última entrada" do topo (estava parado em #7) e a lista de marcadores do § 7 (era `@@PROFILE@@`, removido na refatoração). |
| 2026-10-12 | Sessão #14 — fechadas as duas dúvidas de arquitetura da ISO (**air-gapped = sim**; **compilar no 1º boot > binário pré-colado**). Item 1 dos requisitos implementado (`--source`). Nova dúvida aberta: o modelo vai na mídia? |
| 2026-10-12 | Sessão #15 — o **modelo `.gguf` vai na mídia** (`--iso-model`): implementada a corrente completa `--iso-model` → `/models` → `MODEL_FILE` → `AI_MODEL_FILE` → `--model-file`, com validação de magic/tamanho em 4 pontos e guardas (inclusive negativos) no CI. **Nenhuma dúvida de arquitetura em aberto**: as pendências agora são de execução. |
| 2026-10-12 | Sessão #18 — **limpeza + CI consertado.** O `validate` estava **vermelho no `main`** havia duas sessões (o `--iso-repo auto`, valor *default*, abortava no caminho Debian) e o `make validate` local passava porque o passo do CI era um comando **duplicado**. Regra 13-a (default degrada, nunca aborta) + `make iso-dry-run-both` compartilhado; `iso.yml` alinhado de `@v4` para `@v6`/`@v7`; runner fixado em `ubuntu-24.04`; `build-llama` passou a **compilar do tarball** (prova o caminho offline com cmake real); removido o fantasma `profiles/`. |
| 2026-10-12 | Sessão #17 — **a fonte do llama.cpp vai na mídia** (`--iso-source`): fecha o air-gapped no código (o 1º boot não precisa mais de rede). Corrente exercitada ponta a ponta num sandbox. Novo `ISO.md` § 9 (**checklist de fechamento**) e o achado do **limite de 2 GiB por arquivo de Release** do GitHub. |
| 2026-10-12 | Sessão #16 — **repositório apt local na mídia** (`--iso-repo`, orçamento de 8 GB): fecho de dependências, índice com `dpkg-deb` (sem `dpkg-dev`), fonte **extra** (seção `sources`/`apt-setup/local0`), recusa de release diferente, limpeza da fonte morta no alvo e verificação no `verify-iso.sh`. **O `apt` real aceitou o repositório** montado pelo projeto. Falta só o item 2 para o 1º boot ser offline. |

> **Ao criar uma sessão nova, atualize também a "Última entrada" no topo deste
> arquivo** — é o primeiro número que uma sessão futura olha para saber se está
> lendo algo atualizado.
