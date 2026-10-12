# CI — Como o GitHub compila e valida o ai-cpu-os

> **Última atualização:** 2026-10-07
>
> Este documento explica **o que** cada workflow faz e **por quê**.
> Para o fluxo manual do dia a dia, veja [`docs/TUTORIAL.md`](TUTORIAL.md).

---

## 1. O que "compilar o sistema" significa aqui

O `ai-cpu-os` é um conjunto de **scripts de sistema**, não um único binário.
Portanto "compilar" no GitHub cobre três frentes diferentes:

| Frente | Workflow | Resultado |
|--------|----------|-----------|
| **Validar** os scripts e a documentação | `validate.yml` | Erros de sintaxe/lint/regras barram o merge. |
| **Compilar** o llama.cpp para cada hardware | `build-llama.yml` | Artefatos `.tar.gz` com os binários + execução real provando que rodam. |
| **Empacotar** o runtime em container | `container.yml` | Imagem publicada no GHCR (`:latest` e `:znver2`). |
| **🎯 Gerar a ISO de instalação** | `iso.yml` | ISO remasterizada (netinst + preseed + projeto), anexada à Release. |

> ⚠️ **O que o CI NÃO consegue testar:** o tuning de kernel (governor,
> C-states, huge pages, sysctl) exige um host com privilégios e — no caso dos
> C-states — **reboot**. Isso continua sendo validação manual em VM/hardware
> físico, conforme a Regra 5 do [`AGENTS.md`](../AGENTS.md).

---

### 1.1 A ISO (`iso.yml`) — o entregável final

O workflow **`iso.yml`** não "compila" no sentido tradicional: ele **remasteriza
uma ISO oficial do Debian** para produzir a imagem de instalação do ai-cpu-os.

O que ele faz, em ordem:

1. Instala `xorriso`, `isolinux` (fornece o `isohdpfx.bin` para o boot híbrido)
   e `mtools` (patch do `grub.cfg` dentro da `efi.img`).
2. `make iso-lint` — `bash -n` + `shellcheck` nos scripts da ISO.
3. `make iso-select-test` — confere a escolha da ISO oficial no `SHA256SUMS`
   (sem rede: usa as fixtures).
4. `make iso-dry-run` — simulação completa.
5. Gera a ISO e publica o **SHA256**; grava um resumo na página da execução.
6. Em caso de **falha**, um passo de **diagnóstico** (`if: failure()`) extrai as
   linhas de erro do log e as publica como **anotações** — que são públicas.
   Antes disso, diagnosticar de fora do repositório era impossível (os logs de
   job exigem token), e foi assim que um `exit code 22` custou uma sessão.
7. Em **tags**, anexa a ISO (+ `.sha256`) à Release; em qualquer execução, deixa
   como **artefato** (7 dias).

**Sobre o disco do preseed:** o CI usa `/dev/vda` como placeholder (existe em
VMs com virtio). Isso é **deliberadamente seguro**: se alguém instalar essa ISO
gerada no CI em hardware real, o instalador **falha** (não existe `/dev/vda`)
em vez de apagar o disco errado. Para instalar de verdade, regenere a ISO
localmente com `--disk` apontando para o seu disco.

> ⚠️ **O CI prova que a ISO *constrói* — não que ela *instala*.** Bootar e
> instalar é o **Bloco M** de [`docs/VALIDATION.md`](VALIDATION.md), que exige
> uma VM. Nenhum runner instala um SO razoavelmente.

---

## 2. `validate.yml` — portão de qualidade

Dispara em **todo push para `main` e em todo Pull Request**.

### Job `lint`

> **Runner fixo em `ubuntu-24.04`** (e não `ubuntu-latest`). Motivo concreto:
> este job roda o dry-run da ISO, e o `--iso-repo auto` compara a release
> **desta máquina** com a da ISO base (24.04). Em `ubuntu-latest` o label muda
> sozinho — a partir de **2026-10-19** ele migra para Ubuntu 26 — e o resultado
> passaria a depender do ambiente, por um motivo invisível. Fixar a versão torna
> o job determinístico.
1. `bash -n` em todos os `.sh` — pega erro de sintaxe.
2. `shellcheck -x -S warning` — pega bug real (`SC2046`, `SC2155`, `SC2034`...).
3. `python3 -m compileall roles/` — valida o `shell-ia.py`.
4. `yamllint` — valida workflows, compose e templates.
5. `make families-test` — casamento CPU → família contra ~60 CPUs reais.
6. `make iso-lint` + `make iso-yaml` — scripts da ISO e templates substituídos.
7. `make iso-select-test` — escolha da ISO oficial no `SHA256SUMS`, contra
   arquivos **reais** guardados em `tests/fixtures/`. Existe porque a geração da
   ISO Ubuntu morria com **`exit code 22`** (404 do curl) sem pista alguma: o
   `SHA256SUMS` do Ubuntu marca o modo binário com `*` e lista **todas** as
   point releases — nenhuma das duas coisas aparece numa fixture inventada de
   duas linhas.
8. `make iso-dry-run-both` — dry-run dos DOIS caminhos (ubuntu e debian) **sem
   flags extras**, exatamente como o `make validate` local.

### Job `dry-run` (matriz: `xeon` e `ryzen`)
Roda `detect-hardware.sh`, depois
`sudo ./build.sh --role <papel> --dry-run --yes --skip-tests` e
`tests/smoke-test.sh --dry-run`.

**Por que isso importa:** prova que a orquestração, a passagem de argumentos e
a resolução de caminhos funcionam nos **dois** perfis — sem alterar nada.
Foi exatamente este job que motivou corrigir o `SC2046` no `build.sh`
(passagem de flags via array em vez de substituição não-citada).

### Job `project-rules` — guarda-corpo da memória do projeto

Além dos arquivos obrigatórios e das asserções negativas (`--gpu auto`,
`--prebuilt`, `COPY build/bin`), ele verifica invariantes que nasceram de falhas
reais:

| Invariante | Por quê |
|-----------|---------|
| `iso-dry-run-both` existe no `Makefile`, está no `validate` e o CI **chama** esse alvo | Um comando duplicado entre CI e `make` deixou passar a regressão do `--iso-repo auto`, que quebrou o `validate` no GitHub com o `make validate` local verde |
| Nenhum `actions/*` em major antigo (`@v1..@v4`) | O `iso.yml` ficou preso em `@v4` enquanto o resto do repo já estava em `@v6`/`@v7` — o bump do Dependabot não o alcançou |
| `upload-artifact` em `@v7` nos **dois** workflows que o usam | Sobrou um `@v6` no `main` porque o PR #3 do Dependabot trazia o bump e o alinhamento do `iso.yml` copiou o major vizinho. O guarda é **negativo e positivo**: ficou **negativo** (`@v1..@v6` reprova, varrendo todos os `*.yml`) e **positivo por arquivo** (`build-llama.yml` **e** `iso.yml`, um `grep` para cada). O positivo **não** pode contar `*.yml`: o próprio `validate.yml` cita a string dentro do comando e a contagem ficaria inflada — a perda de um dos dois passaria despercebida |
Este é o job que protege as regras do `AGENTS.md` de erosão:

- Verifica que todos os **28 arquivos obrigatórios** existem.
- Verifica que `AGENTS.md` continua referenciando `docs/TUTORIAL.md` e a
  diretriz por **marco** (Regra 9) e que o `README.md` linka o tutorial.
- Verifica que **todo** `*.sh` contém `set -euo pipefail` (Regra 7).
- Verifica que `docs/STATE.md` mantém "Próxima ação imediata",
  "Última atualização" e "Métricas de performance", e que `docs/ROADMAP.md`
  mantém as seções "Concluído"/"Em Progresso".

> **Por que um job só para isso?** Porque documentação viva se degrada em
> silêncio. Sem um teste, a diretriz do tutorial vira texto morto.
---

## 3. `build-llama.yml` — o build de verdade

Dispara **manualmente** (`workflow_dispatch`), em **tags `v*`** e
**semanalmente** (segundas 04:00 UTC). **Não** roda a cada push: um build leva
vários minutos e queimaria minutos de CI sem ganho.

### Matriz

| Perfil | Flags efetivas | Alvo |
|--------|----------------|------|
| `intel-broadwell` | `GGML_NATIVE=OFF` + `AVX2/FMA/F16C` + OpenBLAS | Broadwell-EP (14c/28t) |
| `ryzen` | as mesmas **+ `-march=znver2 -mtune=znver2 -O3`** | Zen 2 (6c/6t) |

O build **usa o próprio script do projeto**
(`llama-build.sh`), não um comando solto. Assim o CI valida
o script que o usuário vai rodar — inclusive a checagem de ISA em
`/proc/cpuinfo` e o fallback seguro.

### As três provas

1. **Binários existem** — `llama-server`, `llama-cli`, `llama-bench`.
2. **Binários executam** — `llama-bench --help`. Se as flags de ISA
   estivessem erradas, aqui viria `SIGILL` (*Illegal instruction*).
3. **Inferência real fim-a-fim** — baixa o modelo minúsculo
   `stories15M-q4_0.gguf` (~20 MB) e roda `llama-bench -p 32 -n 16`.
   Este é o teste que realmente separa "compilou" de "funciona".
   Se o link do modelo falhar, o passo vira `::warning::` e é pulado —
   não derruba o job (links de modelos mudam; ver
   [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md)).

### Artefatos e Release

Cada perfil gera `ai-cpu-os-llama-<perfil>-<ref>.tar.gz` com `bin/`,
`README.md` e um `INFO.txt` descrevendo ref, commit e flags.

- Sempre disponíveis em **Actions → run → Artifacts** (14 dias).
- Em **tags**, são anexados automaticamente à **Release** correspondente,
  usando o `gh` CLI e `GITHUB_TOKEN` — **sem actions de terceiros**, para
  reduzir a superfície de confiança da cadeia de build.

### Por que SEM cache de build

Decisão consciente: o projeto preza por **determinismo** (ver
`docs/ARCHITECTURE.md` § Princípios). Cachear diretórios de build cria falhas
sutis ("passou no CI, falhou local") e incompatibilidade com o `git clone`
do script. Como o disparo é raro, preferimos builds limpos e reprodutíveis.

---

## 4. `container.yml` — imagem de runtime no GHCR

### Variantes

| Variante | Tag | Uso |
|----------|-----|-----|
| `portable` | `:latest`, `:sha-<12>` | Serve **tanto** o Xeon quanto o Ryzen (AVX2 genérico). |
| `znver2` | `:znver2`, `:sha-<12>-znver2`, `:<tag>-znver2` | Otimizada para o Ryzen 5 3500X. |

### ⚠️ A decisão mais importante: `GGML_NATIVE=OFF`

Dentro do Docker **não podemos** usar `GGML_NATIVE=ON`. O motivo:

> O CMake detectaria a CPU da **máquina de build** — o runner do GitHub, que
> hoje pode ser Zen 3/4/5 **com AVX-512** — e geraria um binário que sofre
> `SIGILL` no Xeon E5-2680 v4 e no Ryzen 5 3500X, que só têm AVX2.

Por isso o `docker/Dockerfile` habilita `AVX2`, `FMA` e `F16C`
**explicitamente**, com `GGML_NATIVE=OFF`, e **nunca** AVX-512. A variante
`znver2` adiciona `-march=znver2` via `--build-arg`.

### Comportamento por evento

| Evento | Push? | `load`? | Smoke da imagem? |
|--------|-------|---------|------------------|
| Pull Request | ❌ | ✅ | ✅ (`llama-bench --help` dentro do container) |
| Push em `main` | ✅ (`:latest`, `:sha-*`) | ❌ | ❌ |
| Tag `v*` | ✅ (`:vX.Y.Z`) | ❌ | ❌ |

### Permissões necessárias

```yaml
permissions:
  contents: read     # ler o repositório
  packages: write    # publicar no GHCR
```

O login no GHCR usa `GITHUB_TOKEN` (fornecido automaticamente) — **nenhum
secret manual é necessário**. Se as imagens aparecerem como privadas, ajuste a
visibilidade do pacote em *GitHub → Packages → ai-cpu-os-llama → Settings*.

---

## 5. Reproduzindo localmente (`make`)

> **Regra prática:** quando um passo do CI é um comando, ele **também** tem de
> existir como alvo do `Makefile`, e o CI deve **chamar o alvo** em vez de
> repetir o comando. Motivo real: o dry-run dos dois caminhos da ISO era um
> `run:` duplicado no `validate.yml` — o CI falhava e o `make validate` local
> passava. Agora os dois rodam `make iso-dry-run-both`, e há guarda que reprova
> se alguém voltar a duplicar.

O `Makefile` existe para que você não precise adivinhar o que o CI faz:

```bash
make help         # lista os alvos
make lint         # bash -n + shellcheck + python + yamllint
make docs         # verifica documentos obrigatórios
make dry-run      # sudo ./build.sh --role auto --dry-run --yes --skip-tests
make ci           # = lint + docs + dry-run  (idêntico ao workflow 'validate')
make build-xeon   # compila o llama.cpp para o Xeon
make build-ryzen  # compila o llama.cpp para o Ryzen (znver2)
make docker       # constrói a imagem localmente
make docker-check # lint do Dockerfile (docker buildx build --check)
make iso-lint     # bash -n + shellcheck dos scripts da ISO
make iso-dry-run  # simula a geração da ISO (não baixa nada pesado)
make iso DISK=/dev/nvme0n1   # 🎯 gera a ISO de instalação (entregável final)
```

> **Regra prática (Regra 11 do `AGENTS.md`):** rode `make ci` antes de abrir
> um Pull Request. CI vermelho não se faz merge.

---

## 6. Badges

Os badges no `README.md` apontam para os workflows. Substitua `<owner>` e
`<repo>` pelos seus valores (ou o workflow `project-rules` não fará isso por
você — é só markdown):

```markdown
![validate](https://github.com/<owner>/<repo>/actions/workflows/validate.yml/badge.svg)
![build-llama](https://github.com/<owner>/<repo>/actions/workflows/build-llama.yml/badge.svg)
![container](https://github.com/<owner>/<repo>/actions/workflows/container.yml/badge.svg)
```

---

## 7. Publicando uma versão (release)

O `build-llama.yml` fecha o ciclo automaticamente:

```bash
# 1. Garanta que docs/TUTORIAL.md está atualizado (Regra 9 do AGENTS.md!)
# 2. Rode o CI localmente
make ci

# 3. Crie a tag anotada e faça push
git tag -a v0.2.0 -m "ai-cpu-os 0.2.0: <resumo>"
git push origin v0.2.0
```

O que acontece em seguida:
1. `build-llama.yml` compila os dois perfis, roda a inferência de prova e
   **cria a Release** com `--generate-notes`, anexando os dois `.tar.gz`.
2. `container.yml` publica as imagens com a tag da versão (`:v0.2.0` e
   `:v0.2.0-znver2`).

> **Não esqueça:** nenhuma versão é declarada concluída sem o
> `docs/TUTORIAL.md` coerente com o estado real (Regras 9 e 10 do `AGENTS.md`).
> O job `project-rules` ajuda, mas a coerência de conteúdo é responsabilidade
> humana.

---

## 8. Solução de problemas do CI

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| `shellcheck` falha com `SC2155` | `readonly VAR="$(cmd)"` mascara o exit code | Separe: `VAR="$(cmd)"` e depois `readonly VAR`. |
| `shellcheck` falha com `SC2046` | Substituição sem aspas dividindo argumentos | Use arrays (`mapfile`/`"${arr[@]}"`). |
| `project-rules` falha em "set -euo pipefail" | Script novo sem o cabeçalho | Adicione na 1ª linha útil. |
| `build-llama` falha com `SIGILL` | Flag de ISA indevida para o alvo | Verifique `--march`: **nunca** AVX-512 nestes hardwares. |
| `container` falha "denied" no push | Faltou `packages: write` | Confira o bloco `permissions:`. |
| `container` falha "invalid reference format" | Nome de imagem com maiúsculas | GHCR exige **minúsculas** (já tratado com `${VAR,,}`). |
| `yamllint` reclama de `on:` | Chave tratada como truthy | Já configurado em `.yamllint.yml` (`check-keys: false`). |
| Job `build-llama` não roda no push | Comportamento **intencional** | Use `workflow_dispatch` (Actions → Run workflow) ou crie uma tag. |
| `cmake` falha: `Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)` | O backend BLAS do ggml usa `find_package(PkgConfig)` e faltava `pkg-config` | Adicione `pkg-config` aos pacotes do builder (já corrigido — ver § 8.1). |
| `cmake` avisa `Could NOT find OpenSSL` | `libssl-dev` ausente | Apenas aviso: com `LLAMA_CURL=OFF` o HTTPS não é necessário (o servidor serve HTTP local). |
| Smoke da imagem falha com `exit code 127` | Loader não acha `libllama.so`/`libggml*.so` (RPATH absoluto da árvore de build) | Não copie `build/bin`: use `cmake --install` com `CMAKE_INSTALL_RPATH` + `ldconfig` (ver § 8.2). |

### 8.1 Caso real: o CI encontrou um bug de verdade

O primeiro run do workflow `container` falhou — e isso foi **útil**.

O erro real foi obtido pelas *check-run annotations* da API do GitHub (os logs
completos exigem autenticação):

```text
CMake Error at FindPackageHandleStandardArgs.cmake:230 (message):
  Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)
Call Stack:
  ggml/src/ggml-blas/CMakeLists.txt:25 (find_package)
```

**Diagnóstico:** o backend BLAS do ggml localiza o OpenBLAS via
`find_package(PkgConfig)`. O pacote `libopenblas-dev` instala a biblioteca,
mas **não** traz o `pkg-config`. Sem ele, o CMake aborta.

**Impacto descoberto:** o bug **não era exclusivo da imagem Docker** — o
`llama-build.sh` (`check_deps`) e o
`roles/inference/install.sh` tinham a mesma falha. Ou seja: **o primeiro build
real no host também teria falhado**.

**Correção aplicada em três lugares:** `docker/Dockerfile`,
`llama-build.sh` (checagem + instalação) e
`roles/inference/install.sh`. Também ajustamos o job `build-llama`
(dependências) para cobrir o caso.

**Lição registrada:** "lint verde" não significa "build comprovado". Foi
preciso o CI **executar** o build para revelar o problema — exatamente por
isso o `build-llama` roda uma inferência real, e não apenas compila.

### 8.2 Segundo caso real: `exit code 127` no smoke da imagem (RPATH)

Depois de corrigir o `pkg-config`, os builds `push` ficaram verdes — mas o PR
do Dependabot falhou de novo, desta vez no passo **"Smoke da imagem (PR)"**,
com `Process completed with exit code 127` e duração de apenas ~32 s (o build
veio inteiro do cache do GHA).

**Diagnóstico:** `exit 127` = "executável não encontrado" — que também ocorre
quando o *dynamic loader* não acha uma biblioteca compartilhada. A causa raiz
estava no `llama.cpp`:

```text
/src/CMakeLists.txt:41  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
/src/ggml/CMakeLists.txt:74  set(BUILD_SHARED_LIBS_DEFAULT ON)   # Linux
/src/build/**/cmake_install.cmake:
    file(RPATH_CHANGE OLD_RPATH "/src/build/bin:" NEW_RPATH "")
```

Ou seja: o llama.cpp compila **bibliotecas compartilhadas por padrão**
(`libllama.so`, `libggml*.so`) e os binários da árvore de build carregam
**RPATH absoluto `/src/build/bin`**. Nossa imagem fazia:

```dockerfile
COPY --from=builder /src/build/bin/ /usr/local/bin/   # ❌ quebrado
```

Os binários iam para `/usr/local/bin`, mas o RPATH continuava apontando para
`/src/build/bin` — que **não existe** no estágio runtime. Resultado: o loader
não encontrava `libllama.so` → `exit 127`.

> **Por que não apareceu antes:** o passo de smoke só roda em `pull_request`
> (`if: github.event_name == 'pull_request'`), e todos os runs verdes
> anteriores eram `push`/tag. Este foi o **primeiro** run de PR com build
> bem-sucedido — ou seja, o caminho nunca havia sido exercitado.

**Correção aplicada em `docker/Dockerfile`:**

1. Instalar via CMake com RPATH explícito:
   `-DCMAKE_INSTALL_RPATH=/usr/local/lib` + `cmake --install build --prefix /usr/local`.
2. Copiar os **artefatos instalados** (`/usr/local/bin` + `/usr/local/lib`) em
   vez da árvore de build, e rodar `ldconfig`.
3. **Sanidade no builder:** verificar que os binários *instalados* executam
   fora da árvore de build (`! ldd ... | grep -q 'not found'`).
4. **Auto-verificação no runtime:** `llama-bench --help` durante o build da
   imagem — assim a imagem **falha ao ser construída**, em vez de falhar só no
   smoke do CI.

**Resultado:** o PR do Dependabot voltou a rodar e ficou **✅ verde** — o job
`Imagem (portable)` passou em **8m28s**, com o passo "Smoke da imagem (PR)"
executando de verdade pela primeira vez. O `container` em `main` também ficou
verde (run #8).

**Lição registrada:** código que só roda num branch do fluxo (aqui, apenas em
PR) fica sem cobertura até ser exercitado. Passos condicionais precisam de um
gatilho que os ative pelo menos uma vez.

> **Por que o smoke continua apenas em PR:** com `push: true` e sem
> `load: true`, a imagem não fica no store local do runner e não há como
> executá-la ali. Em `push`/tag, a garantia vem da **auto-verificação dentro
> do próprio `Dockerfile`**, que roda em todo build de imagem.

---

## 9. Uma observação honesta sobre containers

A imagem do GHCR é conveniente (portabilidade, CI, testes), **mas não é o
melhor caminho para performance**. O projeto foi desenhado para rodar
**nativo**: governor, huge pages, C-states e sysctl são propriedades do
**host** e não existem dentro de um container. Para o máximo de tokens/s,
use o `ai-server.service` nativo (perfil `xeon`) conforme o
[`docs/TUTORIAL.md`](TUTORIAL.md) § 7.

---

## Histórico

| Data       | Mudança |
|------------|---------|
| 2026-10-07 | Criação do documento junto com os workflows `validate`, `build-llama` e `container`. |
| 2026-10-07 | 1º run real: `validate` ✅ verde. O `container` falhou por falta de `pkg-config` no builder — bug corrigido na imagem e nos scripts do perfil xeon (§ 8.1). |
| 2026-10-07 | 2º run real (PR do Dependabot): o smoke da imagem falhou com `exit 127`. Causa: RPATH absoluto `/src/build/bin` nos binários do llama.cpp (libs compartilhadas). Corrigido com `cmake --install` + `CMAKE_INSTALL_RPATH` + `ldconfig` + auto-verificação na imagem (§ 8.2). |
| 2026-10-07 | `build-llama` ✅ verde (6m04s) na tag `v0.2.0`, Release publicada com os binários; `container` ✅ verde em `main` e na tag. |
| 2026-10-07 | Correção do RPATH validada: `container` ✅ em `main` (run #8) e no PR do Dependabot (run #9, com o smoke step executando). Nenhum workflow vermelho pendente. |
| 2026-10-07 | Adicionado o workflow **`iso.yml`** (gera a ISO de instalação em tags/manual) e o **Bloco M** de validação em `docs/VALIDATION.md`. Nenhuma ISO foi construída ainda. |
