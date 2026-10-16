# STATE — Estado atual do projeto ai-cpu-os

> **⚠️ Documento vivo. Atualize SEMPRE ao terminar uma tarefa (regra do AGENTS.md).**
> **Última atualização:** 2026-10-16 (🔑 **senha de usuário/root na webui** —
> hash crypt antes da linha de comando, root habilitável e bloqueado por
> padrão — e 🧬 **14 famílias de CPU com AVX-512 por padrão** nas famílias que
> o têm. Ver `JOURNAL.md` sessões #26/#27)

---

## 1. Versão

- **Versão do projeto:** `0.3.0-dev` — marco **FAMÍLIAS de CPU + PAPÉIS + MODS**
  (a `0.2.0` foi o marco de CI/CD). **Nenhuma validação nova de hardware** foi
  feita nesta refatoração — ver § 2.
- **Commit de referência:** `1d14cbb` (último commit verde antes da refatoração)
- **Sistema operacional alvo:** **Ubuntu Server 22.04+/24.04+** (referência do
  projeto); Debian 12+ continua suportado como base das mods.
- **Suporte de hardware:** por **família de microarquitetura** (14 famílias, com
  herança — incluindo Xeon Scalable v5–v9/Xeon 6, EPYC Naples→Turin e Zen 5,
  com **AVX-512 como padrão** nas famílias que o têm, decisão do dono de
  2026-10-16) — ver [`docs/FAMILIES.md`](FAMILIES.md). O modelo “um perfil por
  processador” foi descontinuado.

---

## 2. Hardware: o que foi testado e o que não

| Sistema | Hardware                        | Família / papel | Testado em hardware real? |
|---------|---------------------------------|-----------------|---------------------------|
| A       | Intel Xeon E5-2680 v4, 16 GB    | `intel-broadwell` / `inference` | ❌ **NÃO** |
| B       | AMD Ryzen 5 3500X, 64 GB        | `amd-zen2` / `builder` | ❌ **NÃO** |
| VM      | qemu/KVM, Xeon E5-2676 v3 (host) | `intel-haswell` / `inference` (auto) | ✅ **SIM** (2026-10-13) |

> **Nada foi executado em hardware físico ainda** (Xeon E5-2680 v4 e Ryzen 5
> 3500X). O que mudou: a **ISO foi bootada e instalada numa VM** (qemu+KVM) e o
> **1º boot aplicou o ai-cpu-os** com a família `intel-haswell` detectada
> corretamente (a CPU do host é um E5-2676 v3, Haswell-EP). O caminho
> build → ISO → instalação offline → 1º boot está **provado**; o que falta é
> rodar os Blocos A–O do `VALIDATION.md` **no hardware alvo** (medir desempenho,
> confirmar o efeito dos ajustes).

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
| `iso/build-iso.sh` (gerador da ISO)   | ✅      | ✅ shellcheck      | ✅ **executado (2026-10-13)** — ver § 3.3 |
| `iso/check-iso.sh` (ISO baixada, sem xorriso) | ✅ | ✅ shellcheck | ✅ **20 asserções, fixtures byte a byte**; ❌ nunca rodou contra um artifact real do GitHub |
| `iso/write-pendrive.sh` (grava o pendrive) | ✅ | ✅ shellcheck | ⚠️ 16 asserções gravando num **ARQUIVO**; ❌ **nenhum pendrive físico gravado** |
| `webui/server.py` + `webui/index.html` (interface web) | ✅ | ⚠️ py_compile | ⚠️ **34 asserções pela API**; ❌ **nunca aberta num navegador** |
| `iso/preseed/*` (preseed, 1º boot)    | ✅      | ⚠️ (templating)    | ✅ **bootado em VM (Ubuntu)**; Debian/preseed ❌ |
| `docs/ISO.md`                         | ✅      | ⚠️ (revisão manual)| ❌                  |
| `docs/JOURNAL.md` (continuidade)      | ✅      | ⚠️ (revisão manual)| ☐ **em uso contínuo** |

Legenda: ✅ sim · ❌ não · ⚠️ parcial

> **Lint:** todos os scripts passam em `shellcheck -x -S warning` sem
> nenhum aviso (verificado localmente em 2026-10-07 com shellcheck 0.11.0).
> O CI (`validate`) passa a garantir isso a cada push/PR.

### 3.1 Status do CI/CD

| Workflow      | Estado | Evidência |
|---------------|--------|-----------|
| `validate`    | ✅ **verde** | Runs históricos: #1 (main, `6da0c35`) e #2 (4/4 jobs), tag `v0.2.0` e PR do Dependabot. **#57 vermelho** (o teste `iso-lock` dependia da otimização `exec` do bash, não garantida) → corrigido na sessão #32 e **confirmado no #58 (`0041c0e`): 4/4 jobs, passo 17 em 0 s**. |
| `build-llama` | ✅ **verde (build real!)** | Run #1 na tag `v0.2.0` (`4cde4bb`): **6m04s** · Run #2 (manual, `main`): ✅ — os dois perfis compilam, os binários executam e a **inferência real** roda. |
| `container`   | ✅ **verde** | Runs #3/#4/#5/#7, **#8 (correção do RPATH)** e **#9 (PR do Dependabot)**: ✅ — imagens publicadas no GHCR. O job do PR passou em 8m28s **incluindo o passo "Smoke da imagem (PR)"**. |

> **PRs do Dependabot** (verificado pela API em 2026-10-12):
> - **PR #1** (`bump the actions group`, 5 updates): **✅ mesclado** em
>   2026-10-09.
> - **PR #2** (`debian:12-slim` → `13-slim` no `docker/`): **✅ mesclado**
>   (`63eebff`), com os dois smokes de imagem verdes.
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

### 3.3 🎉 A ISO gerada E bootada (2026-10-13) — o critério de conclusão foi cumprido

Primeira vez que a ISO **existe** e **roda**, de ponta a ponta, numa máquina com
`xorriso` + `qemu`/KVM (Ubuntu 26.04): construída **dentro de um container
`ubuntu:24.04`** (resolve o "release de outra base" do repo apt), bootada numa VM
com `-cpu host` (Xeon Haswell-EP).

| Item | Resultado |
|------|-----------|
| Build da ISO (`--distro ubuntu`, air-gapped: fonte + modelo + repo) | ✅ **exit 0** |
| `verify-iso.sh` (conteúdo) | ✅ **PASS=41 FAIL=0** |
| `test-vm.sh` (boot + instalação + 1º boot) | ✅ **TESTVM_EXIT=0** |
| Marcadores no console serial (late-command + firstboot) | ✅ **os dois encontrados** |
| Instalação automática (sem perguntas) | ✅ |
| Rebooting → 1º boot aplicou o ai-cpu-os | ✅ **`.firstboot-status: status=ok`** |
| Papel/família detectados no alvo | ✅ `inference` / `intel-haswell` |
| llama.cpp compilado **no alvo, sem rede** (do tarball da mídia) | ✅ `/opt/llama.cpp/build/bin/llama-server` |
| Modelo embutido usado sem rede | ✅ `/opt/models/Qwen2.5-Coder-1.5B-…gguf` (1,1 GB) |
| Tamanho / SHA256 da ISO | **5.568.126.112 B (5,2 GiB)** / `c59da4794f7c9aa9058668bd8b425b022bcda136563b7d080df5c59ef502322a` |
| Tempo: build (cache quente) / instalação+1º boot | ~4 min / **~13 min** (24 vCPU do host, KVM) |

**8 bugs reais, todos invisíveis até EXECUTAR** (nenhum era pego por lint/dry-run):

1. `xorriso … -rm X -commit -end` — o `-rm` engolia `-commit`/`-end` como
   caminhos → `SORRY` → **exit 32** com a ISO já escrita. Correção: `-rm X --`.
2. `-boot_image any keep` não copia a imagem **UEFI oculta** do Ubuntu → a ISO
   saía ~6 MB menor, o `efi.img` virava 1 bloco e o MBR protetor apontava além
   do fim (exit 32). Correção: `-boot_image any replay`.
3. O caminho Ubuntu mapeia só o que muda (`-map`): **faltavam** `/apt-repo`,
   `/models` e `/llama-src.tar.gz` na ISO (o `--iso-repo auto` dizia "air-gapped"
   com a mídia sem conteúdo). Correção: 3 `-map`.
4. `verify-iso.sh`: o `xorriso` cita os caminhos de `-find` entre aspas simples →
   comparação de igualdade quebrava → **408 falsos "repositório incompleto"**.
5. `verify-iso.sh`: `printf … | grep -q` com `set -o pipefail` → SIGPIPE (141) →
   falsos "a fonte não tem CMakeLists". Correção: here-string `<<<`.
6. **GRUB**: `set default="ai-cpu-os-auto"` casa por **id** ou título, e a
   `menuentry` **não tinha `--id`** → o GRUB caía na entrada 0 (interativa) e a
   **instalação automática nunca acontecia**. Correção: `menuentry … --id`.
7. **Repositório apt local**: o curtin roda `apt-get update` **dentro de um
   chroot no alvo**, onde **`/cdrom` não existe** → `file:///cdrom/apt-repo`
   derrubava o `apt-config` (exit 100). Correção: o repo vai para o **alvo**
   (`/opt/apt-repo`) pelo late-command e é usado no 1º boot (fora do apt do
   instalador). Também passou a gerar `Release`.
8. **Marcadores**: o `log()` do late-command vai para o log do subiquity e o
   firstboot logava só no journal → o `test-vm.sh` **nunca via** os marcadores.
   Correção: repetir no `/dev/console` e `journal+console` no unit.

> ⚠️ **O que isto NÃO prova:** desempenho, o efeito de cada ajuste e o
> comportamento no Xeon/Ryzen reais (Blocos A–O do `VALIDATION.md`). E há um
> resíduo air-gapped em investigação (§ 5.3).

---

## 4. Problemas conhecidos no momento

1. **Risco em hardware físico não medido.** O caminho ISO foi provado em VM; o
   que falta é executar os Blocos A–O em cada máquina real. Risco residual:
   nome de pacote/ajuste que só o hardware alvo revela.
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
11. **✅ A ISO foi CONSTRUÍDA E BOOTADA (2026-10-13).** Ver § 3.3. O maior
    risco em aberto **deixou de ser a geração** e passou a ser a validação em
    **hardware físico** (Blocos A–O do `VALIDATION.md`). O caminho Ubuntu é o
    validado; o **Debian/preseed continua não exercitado**. Resíduo air-gapped
    em investigação (§ 5.3 do `JOURNAL.md`).
12. **O boot UEFI da ISO é best-effort.** O patch do `grub.cfg` dentro da
    `efi.img` exige `mtools` e nunca foi testado. O caminho BIOS (isolinux)
    é o principal. Ver `docs/ISO.md` § 6.
13. **O `md5sum.txt` regenerado nunca foi validado** por um instalador real
    (o debian-installer usa esse arquivo para checar a integridade da mídia).

---

## 5. Métricas de performance medidas

> Nenhuma métrica de **inferência** real ainda (tokens/s). Preencher após rodar
> `llama-bench` nos dois sistemas. Formato sugerido:

| Sistema | Modelo                                | Threads | Antes (tok/s) | Depois (tok/s) | Δ     |
|---------|---------------------------------------|---------|---------------|----------------|-------|
| xeon    | Qwen2.5-Coder-1.5B-Q4_K_M             | 24      | *(pendente)*  | *(pendente)*   | —     |
| ryzen   | Qwen2.5-Coder-1.5B-Q4_K_M             | 6       | *(pendente)*  | *(pendente)*   | —     |

### Métricas da ISO (2026-10-13, VM qemu/KVM)

| Métrica | Valor |
|---------|-------|
| Tamanho da ISO (air-gapped: fonte + modelo + repo) | **5.568.126.112 B (5,2 GiB)** |
| SHA256 | `c59da4794f7c9aa9058668bd8b425b022bcda136563b7d080df5c59ef502322a` |
| ISO base | `ubuntu-24.04.5-live-server-amd64.iso` |
| Tempo de build (cache quente; 1º build inclui ~4 GB de download) | ~4 min |
| Instalação + 1º boot (4 vCPU, KVM, `-cpu host`) | **~13 min** |
| Tamanho do alvo após 1º boot (qcow2) | ~6,3 GiB |
| Repositório apt local embutido | 406 pacotes · 329 MB |
| Modelo embutido | `Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf` (1,1 GB) |
| Compilação do llama.cpp no alvo (do tarball, sem rede) | ✅ `/opt/llama.cpp/build/bin/llama-server` |

Tempo de build do llama.cpp: *(pendente em hardware real)*

---

## 6. Próxima ação imediata

> **👉 ESTA É A SEÇÃO REFERENCIADA PELO `AGENTS.md`.**

**✅ Recém-fechado (sessão #32, 2026-10-16).** O `validate` **#57** estava
vermelho no `main` e a causa **não** era o `--disk auto` do commit vizinho (o
`tests/test-iso-lock.sh` estava idêntico ao do run verde #56): o **detentor da
trava** no teste era `bash -c '…; sleep 30' &` e o teste matava o PID do job
contando que o bash **trocasse de identidade** pelo último comando (*exec*) —
uma otimização que **não é garantida** (basta um `BASH_ENV` com `trap` para
desligá-la; aí o `sleep` é um filho que herda o fd 9 e a trava sobrevive ao
`kill`). O teste foi reescrito (**10 → 13 asserções**): detentor determinístico
(`sleep 300 9>&- &` + `wait` + `flock -w 20`), pré-voo que exige a trava livre e
aponta **quem** a segura, e todo `FALHOU` vira **anotação** (`::error::`, o único
canal público sem token). **Confirmado: `validate` #58 (`0041c0e`) verde — 4/4
jobs, o passo 17 em 0 s.**

**✅ Recém-fechado (sessão #31, 2026-10-16).** O "Modo 1" (a ISO não instalar
sozinha em outro PC) **era um bug real**: `--disk auto` — a mitigação que a
própria documentação recomendava — ia **literal** para o autoinstall
(`match: {path: auto}`), um caminho inventado, e o Subiquity parava **sem erro
visível**. Agora `--disk auto` não fixa o disco de verdade, o formato é validado
e o default do CI virou `auto`. Ver `docs/IMPLANTAR-EM-OUTRO-PC.md`.

**✅ Recém-fechado (sessão #29, 2026-10-16).** O `main` local foi
**sincronizado** com o GitHub (estava 7 commits atrás **e** com trabalho local
não commitado — preservado em `backup/local-sessao26-pre-sync`). E foi corrigido
um **erro real**: a "correção" do SIGILL do `build-llama` (sessão #28) **não
funcionava** — `matrix.exec != 'false'` num `if:` do GitHub compara **booleano ×
string** e **nunca** dá falso, então os passos de execução rodavam no runner sem
a ISA das famílias AVX-512/AMX (`exit 132`, o run do próprio commit da correção
ficou vermelho). Agora o valor vai por `env:` e a decisão é no `bash`, com
guarda no `project-rules`. **Falta o próximo `build-llama` (manual) confirmar
verde.** O trabalho local único (`flock` de instância única + `download_to` no
`build-iso.sh`, com `make iso-lock-test`) foi reaplicado sobre a base nova, e o
`make avx512-test` passou a cobrir as 14 famílias (61 asserções).

**Passo 0 — ✅ CONCLUÍDO (histórico, 2026-10-07).** O CI estava verde no
GitHub: `validate` (4/4 jobs),
`build-llama` (compilou os dois perfis + inferência real em 6m04s) e
`container` (imagem publicada no GHCR). A Release `ai-cpu-os v0.2.0` foi
publicada com os binários `.tar.gz` dos dois perfis. Ver § 3.1.

**Passo 1 — ✅ CONCLUÍDO E PROVADO (2026-10-13).** A **ISO foi gerada, bootada
e instalada numa VM**, e o **1º boot aplicou o ai-cpu-os** (família detectada:
`intel-haswell`). O critério de conclusão do projeto (§ 1 do `AGENTS.md`) foi
cumprido. Ver **§ 3.3** para os números e os **8 bugs reais** que só a execução
revelou. Reprodução:

```bash
# (a) gerar a ISO air-gapped DENTRO de um container 24.04 (resolve o
#     "release do repo apt" e o root exigido pelo build-iso.sh):
docker run --rm -v "$PWD":/work -w /work -e DEBIAN_FRONTEND=noninteractive \
  ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq \
    xorriso curl ca-certificates coreutils xz-utils tar gzip python3-yaml >/dev/null && \
    bash iso/build-iso.sh --distro ubuntu --disk /dev/vda --serial-console \
      --role auto --family auto --iso-source auto --iso-model auto \
      --iso-repo auto --yes'

# (b) bootar/instalar em VM (host com qemu + /dev/kvm):
bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-<data>.iso \
  --ram 6144 --cpus 4 --timeout-min 90 --keep --yes
```

> 📓 **Para retomar do zero (ou de outra sessão):** [`docs/JOURNAL.md`](JOURNAL.md)
> — § 1 (retomada em 5 min), § 5 (threads abertas) e § 6 (armadilhas já
> pisadas). Ao terminar qualquer sessão, **registre-a lá** (Regra 14 do `AGENTS.md`).

**Passo 1-b — ✅ CONCLUÍDO (2026-10-15). Interface web local (`webui/`).**
Existe agora um jeito de gerar/conferir a ISO **sem decorar flags**:

```bash
make ui          # → http://127.0.0.1:8787
make ui-test     # prova a API e as salvaguardas (34 asserções; sem navegador)
```

A página mostra o hardware detectado + espaço livre + ferramentas presentes,
monta o `make iso` com o que o usuário escolher, imprime o log **ao vivo** (SSE),
lista as ISOs de `iso/out` e **lista os pendrives** mostrando o comando
`sudo make pendrive …` pronto para copiar (a UI **nunca** pede senha).
É **só biblioteca padrão** (a máquina do usuário pode ser limitada) e escuta
**apenas `127.0.0.1`**. Sem `xorriso`, ela **recusa** gerar com o motivo
explícito e aponta o GitHub Actions (Regra 13-a). Nova **Regra 16** no
`AGENTS.md`; `make ci-guards-test` passou de 22 para **31** casos provados.
`webui/` **fica fora da ISO** (`--exclude=./webui`).
⚠️ **Não provado:** a UI **nunca foi aberta num navegador de verdade** — os
testes exercitam a API. Nada aqui é afirmação sobre o visual.

**Passo 1-d — ✅ Modo 1 RESOLVIDO (sessão #31, 2026-10-16); modos 2 e 3 seguem
abertos.** Dos **3 modos sinalizados** na sessão #30 de a instalação automática
não acontecer, o **modo 1** (o mais provável no mundo real) foi **corrigido** e
tem teste:

- **`--disk auto` estava QUEBRADO** — e era justamente a mitigação que a
  documentação recomendava. O valor ia **literal** para o YAML e virava
  `match: {path: auto}`: um caminho inventado, que não casa com disco nenhum.
  Agora `auto|any|none` significam **não fixar o disco** (`layout: {name: direct}`).
- **Formato do disco validado** (`^/dev/[a-zA-Z0-9]+$`) → `rc 2` em vez de ISO
  quebrada.
- **Aviso** quando o `--disk` informado não existe nesta máquina (na hora **e**
  no resumo final, recomendando `--disk auto`).
- **Default do CI = `auto`**: o artefato do GitHub Actions passa a instalar em
  VM **e** em hardware real (era `/dev/vda`, que só existe em VM).

Teste: **`make iso-disk-test`** (16 asserções) + 3 guardas no CI com violação
plantada (`make ci-guards-test`: 40 → **43**).

**🗺️ Para implantar em OUTRO PC:** existe agora um roteiro dedicado —
[`docs/IMPLANTAR-EM-OUTRO-PC.md`](IMPLANTAR-EM-OUTRO-PC.md) — com o checklist da
máquina de destino, os 3 modos de falha, o que medir e **o que trazer de volta**
quando algo falhar. Ele registra também o que está provado e o que **não** está.

**Passo 1-c — (histórico, sessão #30) ⚠️ SINALIZADO:**
"a ISO pode não instalar automaticamente". Auditei o gatilho do autoinstall
inteiro (evidência lida da ISO 24.04.5 oficial por HTTP Range) e **não achei
defeito novo**: `/boot/grub/grub.cfg` existe, é o único menu e é ele que ambos
(BIOS/UEFI) usam; `/EFI/boot/grub.cfg` **não existe** (por isso o código confia
na delegação — confirmado), e o `--id ai-cpu-os-auto` (bug #6, já corrigido e
conferido pelo `verify-iso.sh`) continua no lugar. Ficam **3 modos sinalizados**
de a automação falhar, detalhados em `docs/TROUBLESHOOTING.md` § "SINALIZADO":
**(1)** `--disk` fixado que não existe no alvo (o **default do CI é `/dev/vda`**
— em hardware real pode não existir → Subiquity cai em erro e o `verify-iso` não
pega); **(2)** **UEFI nunca bootado** (`--boot-mode uefi` exige `ovmf`);
**(3)** **Debian/preseed nunca executado**.

**Passo 2 (AGORA) — validar em HARDWARE FÍSICO (Xeon E5-2680 v4 e Ryzen 5 3500X).**

O que falta não é código: é rodar os blocos preenchíveis de
[`docs/VALIDATION.md`](VALIDATION.md) **nas duas máquinas reais** e trazer os
resultados. Prioridades:

- **Bloco M** (ISO): repetir o passo 1 no Xeon/Ryzen e ver o efeito do tuning;
  **gerar também `--distro debian`** (o caminho preseed **nunca foi testado**).
- **Bloco N**: `bash families/resolve.sh`, `./detect-hardware.sh` e
  `sudo ./build.sh --dry-run` em cada máquina.
- **Bloco O**: `bash mods/apply.sh check` e `make mods-test`.
- **Blocos A–L**: tuning, servidor, `llama-bench` (tokens/s), Ryzen/registry/Gitea.
- ⚠️ **UEFI**: o boot UEFI da ISO nunca foi testado (`--boot-mode uefi` no
  `test-vm.sh`; precisa de `ovmf`). Ver `docs/ISO.md` § 6.

**Passo 3 (dívida técnica nova, achada na execução):**

- **Resíduo air-gapped em investigação.** O `llama-build.sh` usa
  `-DLLAMA_CURL=OFF` (runtime sem downloads), mas o build do llama.cpp ainda
  tenta baixar o **UI** do HuggingFace (`-- UI: downloading … llama-ui …`) — o
  download do `.sha256` falhou na VM e o build seguiu, então parece
  **best-effort**; **confirmar** que a ISO é 100% offline (ex.: uma flag
  `-DLLAMA_BUILD_UI=OFF`/`-DLLAMA_UI=OFF` conforme a versão do llama.cpp).
  Ver `JOURNAL.md` § 5.3.
- **Marcadores de teste:** agora o late-command/firstboot ecoam no console; se
  o formato do console serial mudar, revisar `test-vm.sh` (marcadores) e o unit.

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
| 2026-10-16 | 🧷 **`validate` #57 vermelho: o teste da trava dependia do `exec` do bash (sessão #32).** O `tests/test-iso-lock.sh` matava o detentor da trava contando que o `bash -c '…; sleep 30'` **trocasse de identidade** pelo último comando; essa otimização **não é garantida** (um `BASH_ENV` com `trap` já a desliga) e então o `sleep`, como filho, herda o fd 9: a trava sobrevivia ao `kill` e a asserção final falhava com o gerador **correto** (sintoma no CI: `exit code 2`, passo de 6 s = 5 s de laço de espera estourando). Detentor reescrito (`sleep 300 9>&- &` + `wait` + `flock -w 20`), pré-voo que exige a trava livre e diz **quem** a segura, e todo `FALHOU` vira **anotação** `::error::`. Asserções 10 → **13**; `make validate` verde e `validate` **#58** (`0041c0e`) **verde** no CI (passo 17 em 0 s). Ver `JOURNAL.md` sessão #32. | O `main` local estava 7 commits atrás e com trabalho não commitado (preservado em `backup/local-sessao26-pre-sync`). A correção do #28 (`matrix.exec != 'false'` no `if:`) **nunca pulava o passo**: no GitHub, booleano × string vira número (`false`→0, `'false'`→NaN) e o `!=` dá sempre true — daí o `exit 132` (SIGILL) em icelake-sp/sapphirerapids-sp/emeraldrapids-sp/graniterapids-sp **no próprio commit da correção**. Agora o valor vai por `env:` e a decisão é no `bash`; guarda no `project-rules` + violação plantada. Recuperados do trabalho local de 14/10: `flock` de instância única + `download_to()` (confere o `.part`, `--speed-time`) no `build-iso.sh` (`make iso-lock-test`, 10 asserções) e `make avx512-test` (37 → **61** asserções, 14 famílias). `ci-guards` 35 → **40**. Ver `JOURNAL.md` sessão #29. |
| 2026-10-16 | 🧬 **14 famílias + AVX-512 por padrão.** Adicionadas as famílias de servidor `intel-cascadelake-sp` (v6), `intel-icelake-sp` (v7), `intel-sapphirerapids-sp` (v8), `intel-emeraldrapids-sp` (v9), `intel-graniterapids-sp` (Xeon 6 P) e `amd-zen5` (Ryzen 9000/Ryzen AI 300/EPYC Turin). **Decisão do dono:** nas famílias cujas CPUs têm AVX-512, a política virou `auto` — o AVX-512 é o padrão quando a CPU reporta a flag (verificação em runtime mantida; hardcode segue proibido). Novo `--no-avx512` (desliga e troca o `-march` pelo fallback sem AVX-512, via `FAMILY_MARCH_HAS_AVX512`). Corpus: 85 CPUs reais. Ver `JOURNAL.md` sessão #26. |
| 2026-10-13 | 🎉 **A ISO foi gerada E bootada pela primeira vez** (VM qemu/KVM, Ubuntu 24.04): instalou sozinha, reiniciou e o 1º boot aplicou o ai-cpu-os (`status=ok`, família `intel-haswell`), com llama.cpp compilado no alvo sem rede. **8 bugs reais** só visíveis ao executar (xorriso `-rm`/`-boot_image`/`-map`, GRUB sem `--id`, apt do curtin em chroot sem `/cdrom`, marcadores fora do console, aspas do `-find`, SIGPIPE). Novo § 3.3. Ver `JOURNAL.md` sessão #21. |
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