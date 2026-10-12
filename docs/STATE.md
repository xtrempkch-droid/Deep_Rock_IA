# STATE — Estado atual do projeto ai-cpu-os

> **⚠️ Documento vivo. Atualize SEMPRE ao terminar uma tarefa (regra do AGENTS.md).**
> **Última atualização:** 2026-10-12 (a ISO **Ubuntu** não era gerada — bug do `*`
> no SHA256SUMS, corrigido com teste de regressão; a ISO air-gapped segue
> pendente de BOOT em VM)

---

## 1. Versão

- **Versão do projeto:** `0.3.0-dev` — marco **FAMÍLIAS de CPU + PAPÉIS + MODS**
  (a `0.2.0` foi o marco de CI/CD). **Nenhuma validação nova de hardware** foi
  feita nesta refatoração — ver § 2.
- **Commit de referência:** `1d14cbb` (último commit verde antes da refatoração)
- **Sistema operacional alvo:** **Ubuntu Server 22.04+/24.04+** (referência do
  projeto); Debian 12+ continua suportado como base das mods.
- **Suporte de hardware:** por **família de microarquitetura** (8 famílias, com
  herança) — ver [`docs/FAMILIES.md`](FAMILIES.md). O modelo “um perfil por
  processador” foi descontinuado.

---

## 2. Hardware: o que foi testado e o que não

| Sistema | Hardware                        | Família / papel | Testado em hardware real? |
|---------|---------------------------------|-----------------|---------------------------|
| A       | Intel Xeon E5-2680 v4, 16 GB    | `intel-broadwell` / `inference` | ❌ **NÃO** |
| B       | AMD Ryzen 5 3500X, 64 GB        | `amd-zen2` / `builder` | ❌ **NÃO** |

> **Nada foi executado em hardware físico ainda.** Todos os scripts foram
> escritos e revisados estaticamente (sintaxe `bash -n`, revisão de lógica),
> mas **não validados em execução real**. Trate esta versão como esqueleto
> funcional, não como release.

---

## 3. Status dos scripts

| Script                                | Escrito | Revisado (sintaxe) | Testado em hardware |
|---------------------------------------|:-------:|:------------------:|:-------------------:|
| `build.sh`                            | ✅      | ✅                 | ❌                  |
| `detect-hardware.sh`                  | ✅      | ✅                 | ❌                  |
| `mods/kernel-tuning/kernel-tuning.sh`             | ✅      | ✅                 | ❌                  |
| `mods/hugepages/hugepages.sh`                 | ✅      | ✅                 | ❌                  |
| `mods/governor/governor.sh`                  | ✅      | ✅                 | ❌                  |
| `roles/inference/install.sh`            | ✅      | ✅                 | ❌                  |
| `llama-build.sh`        | ✅      | ✅                 | ❌                  |
| `roles/inference/shell-ia.py`           | ✅      | ⚠️ py_compile     | ❌                  |
| `roles/inference/ai-server.service`     | ✅      | ✅                 | ❌                  |
| `roles/builder/install.sh`           | ✅      | ✅                 | ❌                  |
| `roles/builder/docker-setup.sh`      | ✅      | ✅                 | ❌                  |
| `roles/builder/registry-setup.sh`    | ✅      | ✅                 | ❌                  |
| `roles/builder/gitea-compose.yml`    | ✅      | ⚠️ (YAML)          | ❌                  |
| `roles/builder/build-runner.sh`      | ✅      | ✅                 | ❌                  |
| `tests/smoke-test.sh`                 | ✅      | ✅                 | ❌                  |
| `docs/TUTORIAL.md`                    | ✅      | ⚠️ (revisão manual)| ❌                  |
| `docs/VALIDATION.md` (protocolo)      | ✅      | ⚠️ (revisão manual)| ☐ **a executar**    |
| `llama-build.sh`       | ✅      | ✅                 | ❌                  |
| `docker/Dockerfile`                   | ✅      | ⚠️ (buildx --check)| ❌                  |
| `.github/workflows/*.yml`             | ✅      | ⚠️ (yamllint)      | ❌ (1º run pendente)|
| `Makefile`                            | ✅      | ⚠️ (make -n/test)  | ❌                  |
| `iso/build-iso.sh` (gerador da ISO)   | ✅      | ✅ shellcheck      | ❌ (**nunca executado**)|
| `iso/preseed/*` (preseed, 1º boot)    | ✅      | ⚠️ (templating)    | ❌ (**nunca bootado**)|
| `docs/ISO.md`                         | ✅      | ⚠️ (revisão manual)| ❌                  |
| `docs/JOURNAL.md` (continuidade)      | ✅      | ⚠️ (revisão manual)| ☐ **em uso contínuo** |

Legenda: ✅ sim · ❌ não · ⚠️ parcial

> **Lint:** todos os scripts passam em `shellcheck -x -S warning` sem
> nenhum aviso (verificado localmente em 2026-10-07 com shellcheck 0.11.0).
> O CI (`validate`) passa a garantir isso a cada push/PR.

### 3.1 Status do CI/CD

| Workflow      | Estado | Evidência |
|---------------|--------|-----------|
| `validate`    | ✅ **verde** | Run #1 (main, `6da0c35`) e #2: 4/4 jobs (Lint, Regras, Dry-run xeon, Dry-run ryzen). Também verde na tag `v0.2.0` e no PR do Dependabot. |
| `build-llama` | ✅ **verde (build real!)** | Run #1 na tag `v0.2.0` (`4cde4bb`): **6m04s** · Run #2 (manual, `main`): ✅ — os dois perfis compilam, os binários executam e a **inferência real** roda. |
| `container`   | ✅ **verde** | Runs #3/#4/#5/#7, **#8 (correção do RPATH)** e **#9 (PR do Dependabot)**: ✅ — imagens publicadas no GHCR. O job do PR passou em 8m28s **incluindo o passo "Smoke da imagem (PR)"**. |

> **PRs do Dependabot** (verificado pela API em 2026-10-12):
> - **PR #1** (`bump the actions group`, 5 updates): **✅ mesclado** em
>   2026-10-09.
> - **PR #2** (`debian:12-slim` → `13-slim` no `docker/`): **✅ 6/6 checks
>   verdes**, incluindo os dois smokes de imagem, e `mergeable: clean`. Só
>   falta a decisão do dono.
> - **PR #3** (`bump the actions group`, 2 updates): **resolvido direto no
>   `main`** — a parte do `upload-artifact` (`@v6`→`@v7`) foi aplicada aqui e
>   ganhou guarda no CI; a do `checkout` já estava feita. **Pode ser fechado.**

### 3.2 Histórico das execuções do CI (2026-10-07)

| Momento | O que aconteceu |
|---------|-----------------|
| Commit `6da0c35` | `validate` ✅ verde. `container` ❌ **revelou um bug real**: o builder não tinha `pkg-config`, exigido pelo backend BLAS do ggml (`find_package(PkgConfig)`). **O mesmo bug existia no build nativo** (`llama-build.sh` e `install.sh`) — o primeiro build real no host também teria falhado. Corrigido em 4 lugares (commit `4cde4bb`). |
| Tag `v0.2.0` (`4cde4bb`) | `build-llama` ✅ **6m04s** (compilou `xeon` e `ryzen`, executou os binários e rodou inferência real com o modelo minúsculo) · `container` ✅ **8m48s** · **Release `ai-cpu-os v0.2.0` publicada com os `.tar.gz` dos dois perfis**. |
| `main` (`4cde4bb`) | `validate` ✅ · `container` ✅ 9m14s (imagem `:latest` publicada no GHCR). |
| PR #1 do Dependabot (`afe6ab4`) | 2º ciclo: o passo **"Smoke da imagem (PR)"** falhou com **`exit code 127`**. Causa: os binários do llama.cpp carregam **RPATH absoluto `/src/build/bin`** (libs compartilhadas) e o `COPY build/bin` os movia sem corrigir o RPATH → o loader não achava `libllama.so`. Corrigido com `cmake --install` + `CMAKE_INSTALL_RPATH` + `ldconfig` + auto-verificação na imagem (commit `b5d86bc`, `docs/CI.md` § 8.2). Função não exercida antes porque o smoke só roda em `pull_request`. |
| PR #1 do Dependabot (`afe6ab4` + fix) | 3º ciclo: **✅ verde** — job `Imagem (portable)` em 8m28s, com o smoke step executando de verdade. Nenhum ❌ pendente no repositório. |

> **Resultado importante:** o CI **compila o sistema de verdade** e publica
> binários utilizáveis, sem intervenção humana. O `pkg-config` foi um bug que
> só a **execução** poderia revelar — reforçando a regra: lint verde ≠ build
> comprovado.

---

## 4. Problemas conhecidos no momento

1. **Nada validado em execução.** O maior risco atual é um erro de runtime
   que a revisão estática não pegou (ex.: nome de pacote, caminho).
2. **Kernel cmdline não persiste até reboot.** `kernel-tuning.sh` escreve a
   orientação de `intel_idle.max_cstate=1`, mas a aplicação completa exige
   edição do GRUB + reboot — deixado como passo manual documentado.
3. **Detecção de canais de memória** depende de `dmidecode` (root) e pode
   falhar em algumas BIOS/placas (ex.: JGINYUE). Há fallback por heurística
   de `dmidecode -t 17`, mas não é infalível.
4. **Modelo GGUF não é baixado automaticamente** no `install.sh` do Xeon por
   padrão (link pode expirar/HTTPS). Deixamos função `--download-model`
   explícita.
5. **`shell-ia.py`** depende de um `llama-server` acessível; sem ele, roda em
   modo degradado (erro claro).
6. **Single channel no Ryzen** não é corrigível por software — é alertado,
   não resolvido.
7. **Métricas de performance ainda não medidas.** O CI prova que o llama.cpp
   compila e roda; **não** prova quantos tokens/s o hardware entrega. As
   seções 5, 6 e 7.6 do `docs/TUTORIAL.md` seguem `pendente`.
8. **PRs do Dependabot:** #1 ✅ **mesclado** (2026-10-09). #2 ✅ **verde**
   (6/6, `mergeable: clean`) aguardando a decisão do dono. #3 ✅ **resolvido
   no `main`** (o `@v7` do `upload-artifact` foi aplicado) — pode ser fechado.
9. **A imagem do GHCR não foi validada no hardware alvo.** Ela foi construída
   e verificada pelo próprio build (auto-verificação do Dockerfile) e
   publicada, mas ninguém ainda a executou no Xeon nem no Ryzen.
10. **A Release `v0.2.0` contém binários compilados para o runner do CI**
    (x86-64 genérico AVX2). Funcionam nos alvos, mas foram produzidos em
    outra CPU; o `llama-bench` de prova rodou lá, não no Xeon/Ryzen.
11. **⚠️ A ISO nunca foi construída.** `iso/build-iso.sh` e os templates do
    preseed foram escritos e validados apenas em `--dry-run`; gerar a ISO
    exige `xorriso`, ausente no ambiente de desenvolvimento. É o maior risco
    em aberto e o **critério de conclusão do projeto**.
12. **O boot UEFI da ISO é best-effort.** O patch do `grub.cfg` dentro da
    `efi.img` exige `mtools` e nunca foi testado. O caminho BIOS (isolinux)
    é o principal. Ver `docs/ISO.md` § 6.
13. **O `md5sum.txt` regenerado nunca foi validado** por um instalador real
    (o debian-installer usa esse arquivo para checar a integridade da mídia).

---

## 5. Métricas de performance medidas

> Nenhuma métrica real ainda. Preencher após rodar `llama-bench` nos dois
> sistemas. Formato sugerido:

| Sistema | Modelo                                | Threads | Antes (tok/s) | Depois (tok/s) | Δ     |
|---------|---------------------------------------|---------|---------------|----------------|-------|
| xeon    | Qwen2.5-Coder-1.5B-Q4_K_M             | 24      | *(pendente)*  | *(pendente)*   | —     |
| ryzen   | Qwen2.5-Coder-1.5B-Q4_K_M             | 6       | *(pendente)*  | *(pendente)*   | —     |

Tempo de build do llama.cpp: *(pendente)*

---

## 6. Próxima ação imediata

> **👉 ESTA É A SEÇÃO REFERENCIADA PELO `AGENTS.md`.**

**Passo 0 — ✅ CONCLUÍDO.** O CI está verde no GitHub: `validate` (4/4 jobs),
`build-llama` (compilou os dois perfis + inferência real em 6m04s) e
`container` (imagem publicada no GHCR). A Release `ai-cpu-os v0.2.0` foi
publicada com os binários `.tar.gz` dos dois perfis. Ver § 3.1.

> 🎯 **O projeto termina quando a ISO existir, instalar e bootar.** O script
> [`iso/build-iso.sh`](../iso/build-iso.sh) e o preseed estão escritos e
> validados em `--dry-run`, mas **nenhuma ISO foi construída nem bootada**
> (não há `xorriso` no ambiente de desenvolvimento). Isso é o **Bloco M** de
> [`docs/VALIDATION.md`](VALIDATION.md) e o maior risco em aberto do projeto.
> Passos: `make iso-lint` → `make iso-dry-run` → `make iso DISK=/dev/nvme0n1`
> → bootar em VM. Ver **`docs/ISO.md`**.

> 📓 **Para retomar do zero (ou de outra sessão):** [`docs/JOURNAL.md`](JOURNAL.md)
> — § 1 (retomada em 5 min), § 5 (threads abertas) e § 6 (armadilhas já
> pisadas). Ao terminar qualquer sessão, **registre-a lá** (Regra 14 do `AGENTS.md`).

> 📋 **Protocolo de testes pronto:** siga **[`docs/VALIDATION.md`](VALIDATION.md)**
> — roteiro preenchível (blocos A–L: VM, detecção, build, tuning, servidor,
> benchmark, Ryzen/registry/Gitea, imagem do GHCR, idempotência, reversão).
> **Basta executar os blocos e trazer os resultados preenchidos** — depois eles
> são consolidados aqui (§ 2/§ 3/§ 5/§ 6) e no `docs/TUTORIAL.md`.

**Passo 1 — ✅ CONCLUÍDO (implementado; não executado).** A variante **Ubuntu
Server + autoinstall** está escrita: `iso/autoinstall/autoinstall.yaml`
(config na raiz da ISO, ao lado de `casper/`), `--distro ubuntu|debian` com
**ubuntu como padrão**, remontagem por `xorriso -indev/-outdev -map` (setores
de boot preservados) e autoteste de templates (`--check-templates` / `make
iso-yaml`) rodando no CI. Ver `docs/ISO.md` § 4.5.

> ⚠️ **Implementado ≠ executado.** Nenhuma ISO foi gerada, instalada ou
> bootada — em nenhuma das duas distros. Isso continua sendo o **Bloco M** de
> [`docs/VALIDATION.md`](VALIDATION.md) e o maior risco em aberto.

**Passo 1.1 (AGORA) — rodar os dois caminhos da ISO contra as ISOs reais.**

Antes de qualquer VM: gerar de verdade, em uma máquina com `xorriso` e rede
(o ambiente de desenvolvimento não tem `xorriso`). É barato e pega erro de
layout/`xorriso` cedo. O `verify-iso.sh` roda sozinho no fim do build.

```bash
sudo apt install -y xorriso curl coreutils
make iso-lint && make iso-yaml     # autoteste (templates + verificador)

# 1) Ubuntu (padrão) — o caminho menos exercitado
sudo bash iso/build-iso.sh --distro ubuntu --disk /dev/vda \
  --serial-console --keep-work

# 2) Debian (legado)
sudo bash iso/build-iso.sh --distro debian --disk /dev/vda \
  --serial-console --keep-work

# 3) Reforçar a verificação (o build já roda; aqui é explícito)
make iso-verify ISO=iso/out/ai-cpu-os-ubuntu-<data>.iso DISK=/dev/vda
```

**Passo 1.2 — bootar em VM (o teste que importa).**

```bash
sudo apt install -y qemu-system-x86 qemu-utils
make iso-vm ISO=iso/out/ai-cpu-os-ubuntu-<data>.iso
# ou, direto: bash iso/test-vm.sh --iso <iso> --yes
```

O `test-vm.sh` procura dois marcadores no console serial:
`[ai-cpu-os/iso-late] pós-instalação concluído` (o instalador **achou** a
config) e `aplicação concluída com sucesso` (o primeiro boot aplicou).
Detalhes em `docs/ISO.md` § 4.6 e Bloco M de `docs/VALIDATION.md`.
> ⚠️ Não declare a ISO pronta sem bootar e instalar em VM.

**Passo 1.3 — tornar a ISO AIR-GAPPED (decidido na sessão #14).**

👉 O plano completo, com o estado de cada requisito, está em
**`docs/ISO.md` § 3.1**. As decisões são: **a ISO deve funcionar sem internet**
e **o llama.cpp é compilado no 1º boot** (nunca um binário pré-compilado — uma
ISO por família reintroduziria o risco de `SIGILL`).

```bash
# Os 5 requisitos estão implementados. NÃO há pendência de código conhecida no
# caminho da ISO — o que falta é EXECUTAR:
make iso-dry-run ISO_ARGS="--iso-source auto --iso-model auto --iso-repo auto"
make iso DISK=/dev/nvme0n1 ISO_ARGS="--serial-console"   # precisa de xorriso
make iso-vm ISO=iso/out/ai-cpu-os-ubuntu-<data>.iso      # precisa de qemu
```

⚠️ **Limites práticos:** (a) `--iso-repo auto` exige a **mesma release** da ISO
(esta máquina é 25.10, a ISO é 24.04) — buildar numa noble, usar `--iso-url` da
sua release, ou `--iso-repo CAMINHO`; (b) o GitHub **recusa arquivo de Release
acima de 2 GiB**, e a ISO air-gapped tem ~4,3–5 GB — por isso o CI gera a ISO
leve por padrão e a air-gapped é para a sua máquina. Checklist completo em
`docs/ISO.md` § 9.

**Passo 2 — validar as camadas novas em hardware real.**

Rodar `bash families/resolve.sh`, `./detect-hardware.sh` e
`sudo ./build.sh --dry-run` em **cada** máquina alvo (Xeon E5-2680 v4 e Ryzen 5
3500X) e preencher o **Bloco N** de `docs/VALIDATION.md`. Rodar também
`bash mods/apply.sh check` e `make mods-test` (Bloco O).

**Passo 3 — subir uma VM Ubuntu Server 24.04 e validar `detect-hardware.sh` +
`build.sh --dry-run` + `mods/apply.sh apply --set system --dry-run`.** Numa VM,
`--dry-run` mostra toda a sequência sem aplicar nada.

```bash
git clone <repo> && cd ai-cpu-os
chmod +x build.sh detect-hardware.sh llama-build.sh tests/*.sh
chmod +x mods/apply.sh mods/*/*.sh families/resolve.sh roles/*/*.sh
bash -n build.sh && bash -n detect-hardware.sh && bash -n llama-build.sh
./detect-hardware.sh || true          # FAMILY= e ROLE=
sudo ./build.sh --dry-run
```

**Passo 4 (ao fechar o marco de validação):** atualizar `docs/TUTORIAL.md`
com o que passou a ser testado e com os números reais de `llama-bench`
(diretriz obrigatória — Regra 9 do `AGENTS.md`).

---

## 7. Como atualizar este arquivo

Ao terminar qualquer tarefa:

1. Atualize **Data** no topo.
2. Marque na tabela da seção 3 o que mudou.
3. Registre métricas novas na seção 5.
4. Reescreva a seção 6 ("Próxima ação imediata") para o próximo passo real.
5. Se mover algo no roadmap, atualize também `docs/ROADMAP.md`.

---

## Histórico

| Data       | Mudança                                                    |
|------------|------------------------------------------------------------|
| 2026-10-07 | Criação do arquivo junto com o repositório `0.1.0-alpha`.   |
| 2026-10-07 | Commit inicial `85a083e` realizado; 26 arquivos versionados. |
| 2026-10-07 | Projeto publicado no GitHub (`main` + tag `v0.1.0-alpha`); adicionado `docs/TUTORIAL.md` e a diretriz de tutorial por marco. |
| 2026-10-07 | Adicionada a esteira de CI/CD (`validate`, `build-llama`, `container`), `Makefile`, `docker/`, `docs/CI.md` e templates. Corrigidos todos os avisos do shellcheck. |
| 2026-10-07 | 1º run do CI no GitHub: `validate` ✅ verde (4/4 jobs). `container` falhou e revelou a falta de `pkg-config` (bug também presente no build nativo) — corrigido em 3 lugares + docs. |
| 2026-10-07 | Publicada a versão **`0.2.0`** (tag `v0.2.0`, commit `4cde4bb`): marco de CI/CD. **Nenhuma validação de hardware foi feita nesta versão** — ver § 2 e § 3.2. O `build-llama` e o `container` foram disparados pela tag. |
| 2026-10-07 | 2º bug achado pelo CI: imagem quebrava com `exit code 127` (RPATH absoluto dos binários do llama.cpp). Corrigido em `b5d86bc` (ver § 3.2 e `docs/CI.md` § 8.2). PR do Dependabot ficou ✅ verde. |
| 2026-10-07 | Criado **`docs/VALIDATION.md`**: protocolo preenchível de testes em hardware (blocos A–L). É o caminho para trazer os resultados e fechar a validação real. Ver § 6. |
| 2026-10-07 | Registrado o **entregável final = ISO de instalação**; criado `iso/` (`build-iso.sh` + preseed + serviço de 1º boot) e `docs/ISO.md`. Nenhuma ISO gerada/bootada ainda. |
| 2026-10-07 | Criado **`docs/JOURNAL.md`** (diário de continuidade) + "Retomada rápida" no `AGENTS.md` + **Regra 14**. Unificado o Xeon como **quad channel** e corrigido `detect-hardware.sh` (agora conta os canais reais via `Bank Locator`). |
| 2026-10-12 | **Refatoração: FAMÍLIAS de CPU + PAPÉIS + MODS.** Criadas as camadas `families/` (8 famílias com herança + `resolve.sh` + política de AVX-512), `roles/` (papel `inference` e `builder`, substituindo `roles/inference` e `roles/builder`) e `mods/` (motor `list/info/check/apply/revert/test` + 4 mods com `revert`). O build do llama.cpp virou um **script único** dirigido pela família (`llama-build.sh`), com padrão **portátil** (`GGML_NATIVE=OFF`) e `--assume-family-isa` para cross-build. SO de referência passou a **Ubuntu Server**. CPU do Sistema A: **E5-2680 v4**. Comentários do README aplicados e removidos. Novos docs: `docs/FAMILIES.md`, `docs/MODS.md`, `mods/README.md`, `roles/README.md`. `make validate` verde (25 scripts). || 2026-10-12 | **ISO em base Ubuntu Server (autoinstall/Subiquity).** `--distro ubuntu` (padrão) com `iso/autoinstall/autoinstall.yaml` na raiz da ISO; remontagem por `xorriso -indev/-outdev -map` (setores de boot da ISO oficial preservados, sem `mtools`/`isohdpfx.bin`); `late-command.sh` compartilhado pelos dois instaladores (`AI_CURTIN=1`); flags `--role`/`--family` também na ISO; autoteste de templates (`--check-templates`/`make iso-yaml`) no CI, validando o `autoinstall.yaml` **substituído** com `yamllint`. `docs/ISO.md` reescrito (§ 4.5), Bloco M virou distro-aware. **Nenhuma ISO gerada/bootada.** |
| 2026-10-12 | **Ferramentas de validação da ISO:** `iso/verify-iso.sh` (conteúdo; modo `--dir` sem `xorriso`, o que o torna **testável no CI**) e `iso/test-vm.sh` (boot real em qemu, marcadores no console serial). Flag `--serial-console`; o build passa a **verificar a ISO ao final**; `make iso-yaml` roda o verificador **com teste negativo**; alvos `make iso-verify` e `make iso-vm`. `verify-iso.sh` já derrubou um bug real do próprio verificador. **`test-vm.sh` nunca executado (sem qemu no ambiente).** |
| 2026-10-12 | **Zen 3/Zen 4 prontos para uso + GPU como opção.** Criado o corpus `tests/families-matrix.txt` (~60 modelos reais) + `tests/test-families.sh` → o casamento CPU → família passou a ser **testado no CI**, o que é o máximo possível sem o hardware. O teste **achou 10 modelos mal atribuídos**: nenhum EPYC casava (espaço a mais no regex) e a série Ryzen 8000 (Zen 4) caía em `generic` — corrigidos. `build-llama` agora compila também para zen3, zen4 e skylake-avx512. GPU: `llama-build.sh --gpu <backend>` + `--gpu-check` + `--cmake-extra`, **explícito e nunca automático**, com registro no `AI-CPU-OS-BUILD.txt`; `detect-hardware.sh` passou a detectar GPU (informativo, linha `GPU=`); novo `docs/GPU.md` e Bloco P de `VALIDATION.md`. **Nenhum backend de GPU foi compilado/testado.** |
| 2026-10-12 | **Documentação separada por público.** `README.md` reescrito para o **usuário final** (o que é, serve para mim?, o que muda na máquina, instalação em 5 passos, uso diário, como medir, como desfazer, FAQ, tabela de tamanho de modelo) e criado **`README.technical.md`** — manual do **mantenedor** (três camadas, mapa do repo, **contratos/invariantes**, receitas de extensão, o que cada teste **prova e não prova**, CI por dentro, playbook de depuração com os bugs reais, status de validação e glossário). Regra derivada: **usuário → `README.md`; mantenedor → `README.technical.md`; regras → `AGENTS.md`; fato de hoje → `STATE.md`.** Novos guardas no CI: ambos os arquivos precisam existir e se referenciar. **De passagem, corrigido um bug real:** o `build-llama.yml` ainda usava `matrix.profile` (chave removida na refatoração) no nome do artefato — o upload falharia. |
| 2026-10-12 | **Limpeza do repo + CI verde de novo.** O `validate` **estava vermelho no `main`** e não foi visto localmente: o `--iso-repo auto` (valor **default**) abortava no caminho Debian e derrubava o passo "ISO (dry-run dos dois caminhos)". Corrigido com a **Regra 13-a** (default degrada com aviso, nunca aborta; erro fatal só para entrada do usuário). **Corolário de processo:** todo comando do CI tem de ser um alvo do `Makefile` e o CI tem de chamar o alvo — é o que impede o CI e o `make` divergirem (criado `make iso-dry-run-both`). Também: `iso.yml` estava em `actions/*@v4` com o resto do repo em `@v6`/`@v7`; runner fixado em `ubuntu-24.04` nos jobs que dependem da release (o label migra para Ubuntu 26 em 2026-10-19); `build-llama` passou a **compilar do tarball** (`--source`), provando o caminho offline com cmake real nas 7 famílias; removido o fantasma `profiles/` e a entrada obsoleta do `.gitignore`. Guardas novos no CI para ambos os invariantes. |
| 2026-10-12 | **ISO air-gapped COMPLETA: a fonte do llama.cpp também vai na mídia** (`--iso-source auto\|tarball\|none`). Era o **último** passo que exigia rede no 1º boot — e o mais demorado (compilar 20+ min). `late-command.sh` leva o tarball a `/opt/llama-src.tar.gz` e grava `LLAMA_SRC`; `firstboot.sh` exporta `AI_LLAMA_SOURCE`; `llama-build.sh` usa isso como padrão de `--source` e compila **sem `git` e sem rede**. Novo `build.sh --model-file/--llama-source` (porque `sudo` limpa o ambiente). O `verify-iso.sh` confere a corrente e reprova tarball truncado/sem `CMakeLists.txt`/sem `ggml/`. **Provas:** a corrente inteira exercitada num sandbox (late-command real + llama-build real, manifesto `Rede: não usada`) e o guarda de release recusando build cruzado. Docs: `docs/ISO.md` § 3.1 (todos os 5 itens ✅) e **novo § 9 com o checklist de fechamento**; `iso.yml` ganhou `air_gapped` + **guarda de tamanho pelo limite de 2 GiB por arquivo de Release** do GitHub. **Nenhuma ISO gerada; nenhum boot real** — não há mais pendência de código conhecida no caminho da ISO. |
| 2026-10-12 | **Repositório apt local na mídia** (`--iso-repo auto\|DIR\|none`), completando o toolchain offline (orçamento de 8 GB). Resolve o **fecho de dependências** dos pacotes que o 1º boot precisa, baixa os `.deb`, gera o índice com `dpkg-deb` (**sem `dpkg-dev`**) e os embute em `/apt-repo`. A fonte entra como **extra** (seção `sources` do curtin no Ubuntu; `apt-setup/local0/*` no Debian), preservando o `primary` oficial — o alvo nasce com `apt` normal e um repo incompleto **degrada** em vez de abortar. O build **recusa** release diferente da ISO. `late-command.sh` remove a fonte `file:///cdrom/...` do alvo. `verify-iso.sh` ganhou a seção do repositório (índice legível, todo `.deb` do índice presente, magic `!<arch>`, coerência mídia×config). **Prova real:** o `apt` do sistema aceitou um repo montado pelo código do projeto e resolveu dependência. **Falha só o item 2 do § 3.1** (`firstboot.sh` usar `--source`) para o 1º boot ficar 100% offline. Nenhuma ISO gerada; nenhum boot real. |