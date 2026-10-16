# TROUBLESHOOTING — Problemas conhecidos e soluções

> **Última atualização:** 2026-10-07

Formato: **Sintoma → Causa provável → Solução.** Adicione novos casos aqui
sempre que resolver um problema real (regra do `AGENTS.md`).

---

## Compilação do llama.cpp

### `SIGILL` (Illegal instruction) ao rodar o binário

- **Causa:** binário compilado com ISA que a CPU não suporta (ex.: AVX-512
  em Xeon E5-2680 v4 ou Ryzen 5 3500X).
- **Solução:** recompile com `-DGGML_NATIVE=ON` (sem forçar
  `-mavx512*`). Verifique:
  ```bash
  grep -o -m1 -E 'avx512|amx' /proc/cpuinfo || echo "sem AVX-512/AMX — correto"
  ```
  O `llama-build.sh` já valida as flags; rode-o novamente.

### Erro de CMake: `GGML_BLAS_VENDOR` desconhecido

- **Causa:** versão antiga do llama.cpp/CMake sem essa variável, ou OpenBLAS
  não instalado.
- **Solução:** instale `libopenblas-dev` e atualize o CMake (`cmake --version`
  ≥ 3.16). Como fallback, remova `-DGGML_BLAS` (perde-se pouco em AVX2
  puro).

### CMake falha: `Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)`

- **Sintoma:** o `cmake -B build ...` aborta com o stack apontando para
  `ggml/src/ggml-blas/CMakeLists.txt` → `find_package(PkgConfig)`.
- **Causa:** o backend BLAS do ggml localiza o OpenBLAS via `pkg-config`.
  O pacote `libopenblas-dev` instala a biblioteca, **mas não** o `pkg-config`.
- **Solução:**
  ```bash
  sudo apt install -y pkg-config
  ```
  Os scripts do projeto já instalam isso automaticamente (corrigido após o CI
  detectar o problema — ver `docs/CI.md` § 8.1).
- **Não confunda** com o aviso `Could NOT find OpenSSL`: aquele é apenas
  informativo (com `LLAMA_CURL=OFF` o HTTPS não é usado pelo servidor).

### Build muito lento / OOM no Xeon (16 GB)

- **Causa:** `make -j24` consome muita RAM em arquivos pesados.
- **Solução:** reduza paralelismo: `cmake --build build -j 6`. No Ryzen,
  `-j 6` é natural.

### `fatal error: ggml.h: No such file` ou `-lopenblas` não encontrado

- **Solução:**
  ```bash
  sudo apt install -y libopenblas-dev build-essential cmake git
  ```

---

## Container / Imagem Docker

### A imagem executa mas falha com `exit code 127` ("executable file not found")

- **Sintoma:** `docker run --rm --entrypoint llama-bench <imagem> --help`
  retorna **127**. Também pode aparecer como
  `error while loading shared libraries: libllama.so: cannot open shared object file`.
- **Causa:** o llama.cpp compila bibliotecas **compartilhadas** por padrão e os
  binários da árvore de build carregam **RPATH absoluto** (`/src/build/bin`).
  Copiar `build/bin/` para `/usr/local/bin` faz o loader procurar as libs num
  caminho que não existe na imagem final.
- **Solução:** não copie `build/bin` diretamente. Instale via CMake com RPATH
  explícito e rode `ldconfig`:
  ```dockerfile
  RUN cmake -B build ... -DCMAKE_INSTALL_RPATH=/usr/local/lib \
   && cmake --build build -j "$(nproc)" \
   && cmake --install build --prefix /usr/local
  COPY --from=builder /usr/local/bin/ /usr/local/bin/
  COPY --from=builder /usr/local/lib/ /usr/local/lib/
  RUN ldconfig
  ```
  Para diagnosticar:
  ```bash
  docker run --rm --entrypoint sh <imagem> -c 'ldd /usr/local/bin/llama-bench'
  docker run --rm --entrypoint sh <imagem> -c 'readelf -d /usr/local/bin/llama-bench | grep -i rpath'
  ```
- **Histórico:** este bug foi descoberto pelo CI (ver `docs/CI.md` § 8.2).

---

## Kernel / Tuning

### Governor não muda para `performance`

- **Causa:** driver de cpufreq `powersave`/`intel_pstate` sem suporte, ou
  caminho diferente.
- **Solução:**
  ```bash
  cpupower frequency-info
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
  ```
  Se `performance` não estiver na lista, tente `cpupower frequency-set -g performance`.
  Em `intel_pstate` com modo `active`, o governor é passivo — ajuste via
  `cpupower` e/ou `intel_pstate=passive` na cmdline.

### `intel_idle.max_cstate=1` não surte efeito

- **Causa:** parâmetro só vale na **cmdline do kernel** — precisa reboot.
- **Solução:**
  1. Edite `GRUB_CMDLINE_LINUX_DEFAULT` em `/etc/default/grub`, acrescente
     `intel_idle.max_cstate=1`.
  2. `sudo update-grub`
  3. Reboot.
  4. Confirme: `cat /proc/cmdline` e
     `cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name` (deve parar em
     `C1`).

### THP não fica em `always`

- **Causa:** alguns kernels/distros usam `madvise` por padrão e o runtime
  pode reverter.
- **Solução:**
  ```bash
  echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
  ```
  Para persistir, adicione ao `mods/hugepages/hugepages.sh` (já faz isso) ou use
  `systemd-tmpfiles`/unit própria. Se `always` causar problemas, use
  `madvise` + `MADV_HUGEPAGE` explícito.

### Huge pages estáticas "somem" após reboot

- **Causa:** `nr_hugepages` não é persistente por si.
- **Solução:** o `hugepages.sh` grava a reserva num service/`sysctl.d`
  (`vm.nr_hugepages`). Confirme com `grep Huge /proc/meminfo`.

---

## Detecção de hardware

### `dmidecode` não mostra canais de memória (ou falha)

- **Causa:** algumas BIOS/placas (ex.: JGINYUE) reportam DMI incompleto;
  `dmidecode` precisa de root.
- **Solução:** rode como root. Se ainda falhar, o script usa heurística
  (conta DIMMs populados e agrupa por `Locator`). Para confirmar manualmente,
  consulte o manual da placa. Alternativa: `sudo lshw -class memory`.

### Falso "single channel" no Ryzen

- **Causa:** heurística baseada em `Locator`; pode errar se a BIOS nomear
  slots de forma não padrão.
- **Solução:** confirme à mão — na maioria das MSI B550, dual channel exige
  slots `A2` + `B2`. Se realmente está em single channel, **mova os pentes**.

---

## Docker / Registry (perfil Ryzen)

### `docker push` para `localhost:5000` falha com TLS/HTTPS

- **Causa:** o Docker exige TLS para registries por padrão.
- **Solução:** o `registry-setup.sh` adiciona `localhost:5000` em
  `/etc/docker/daemon.json` → `insecure-registries`. Se não pegou:
  ```bash
  sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
  { "insecure-registries": ["localhost:5000"] }
  JSON
  sudo systemctl restart docker
  ```

### `Cannot connect to the Docker daemon`

- **Solução:** `sudo systemctl enable --now docker` e adicione seu usuário ao
  grupo: `sudo usermod -aG docker "$USER"` (relogue).

### Registry enche o disco (blobs acumulam)

- **Causa:** `registry:2` não faz garbage collection automática.
- **Solução:** rode GC ocasionalmente:
  ```bash
  docker exec -it registry registry garbage-collect /etc/docker/registry/config.yml
  docker exec -it registry registry garbage-collect -m /etc/docker/registry/config.yml
  ```

---

## Gitea

### Gitea não sobe / `port is already allocated`

- **Causa:** portas 3000 ou 2222 ocupadas.
- **Solução:** `ss -ltnp | grep -E ':3000|:2222'` e ajuste as portas no
  `gitea-compose.yml`.

### Não consigo clonar via SSH na porta 2222

- **Causa:** URL SSH padrão usa porta 22.
- **Solução:**
  ```bash
  git clone ssh://git@<host>:2222/<user>/<repo>.git
  ```
  Ou configure `~/.ssh/config` com `Port 2222`.

---

## shell-IA (perfil Xeon)

### Erro de conexão com o llama-server

- **Causa:** serviço não está de pé.
- **Solução:**
  ```bash
  sudo systemctl status ai-server
  sudo systemctl restart ai-server
  curl -s http://127.0.0.1:8080/health
  ```

### Modelo não carrega / OOM

- **Causa:** modelo grande demais para 16 GB.
- **Solução:** use ≤ 7B em Q4_K_M (ex.: Qwen2.5-Coder-1.5B ou 7B Q4).
  Monitore: `watch -n1 free -h`.

### Comando bloqueado pela whitelist

- **Causa:** sandbox funcionando como esperado.
- **Solução:** edite a `WHITELIST` no topo de `roles/inference/shell-ia.py`
  conscientemente. Evite adicionar comandos destrutivos.

---

## ISO / Remasterização

### ⚠️ SINALIZADO: a instalação automática pode não acontecer

> **Estado:** o **Modo 1 está RESOLVIDO** (2026-10-16, sessão #31). Os modos
> **2 (UEFI)** e **3 (Debian)** continuam **abertos**. O gatilho do autoinstall
> foi auditado inteiro e **nenhum defeito novo foi confirmado** (sessão #30).
> Abaixo: o que **está** provado, o que foi corrigido e o que **não** foi.

**Evidência (lida da ISO oficial 24.04.5 por **HTTP Range**, sem baixar 3 GB):**

| Fato verificado na ISO | Consequência |
|---|---|
| `/boot/grub/grub.cfg` **existe** (573 B) e é o **único** menu | o `set default="ai-cpu-os-auto"` + `menuentry … --id ai-cpu-os-auto` (bug #6 da sessão #21, já corrigido) valem para **BIOS e UEFI** |
| `/EFI/boot/grub.cfg` **NÃO existe** (só `bootx64.efi`, `grubx64.efi`, `mmx64.efi`) | a branch *"o UEFI delegará para /boot/grub/grub.cfg"* é o caminho **normal**, não uma exceção |
| **entry 0** do menu de fábrica = `"Try or Install Ubuntu Server"` (interativo) | é exatamente o que o GRUB sobe quando o `set default` não casa → daí a criticidade do `--id` |

**Modo 1 — disco fixado que não existe no alvo. ✅ RESOLVIDO (sessão #31).**
O `storage` do autoinstall fixava `layout: {name: direct, match: {path: /dev/vda}}`
(era o `default` do `iso.yml`). Numa máquina real (NVMe `/dev/nvme0n1`, SATA
`/dev/sda`) **nenhum disco casa** → o Subiquity **não instala sozinho** (aborta
ou fica parado), **sem erro visível**. O `verify-iso.sh` **não** pegava: ele
confere o *conteúdo* da mídia, não se o caminho existe na máquina do alvo.

E a mitigação que a documentação recomendava — `--disk auto` — **não
funcionava**: o valor era usado **literalmente** e o YAML saía com
`match: {path: auto}`, um caminho inventado que também não casa com disco
nenhum. **A mitigação documentada reproduzia o próprio bug.**

| Antes | Agora |
|---|---|
| `--disk auto` → `match: {path: auto}` | `--disk auto\|any\|none` → **não fixa o disco** (`layout: {name: direct}`) |
| `--disk sda` (sem `/dev/`) aceito calado | formato validado (`^/dev/[a-zA-Z0-9]+$`) → **rc 2** |
| `--disk /dev/naoexiste` gerava ISO em silêncio | **AVISO** na hora e no resumo final ("gere de novo com `--disk auto`") |
| default do CI = `/dev/vda` | default do CI = **`auto`** → o artefato instala em VM **e** em hardware real |

*Teste que guarda isso:* `make iso-disk-test` (16 asserções) — a semântica do
YAML gerado (com/sem disco), o `auto`, o formato inválido, o disco ausente e o
consentimento (`--allow-any-disk`). Com guardas no CI e violação plantada em
`make ci-guards-test`.

**Modo 2 — UEFI nunca foi bootado.** O `test-vm.sh --boot-mode uefi` exige
`ovmf` e nunca rodou. A prova de que o UEFI herda o menu patchado é **indireta**
(o UEFI usa o mesmo `/boot/grub/grub.cfg`, já que `/EFI/boot/grub.cfg` não
existe) — ver a tabela acima. **Não confirmado por boot.** Se um `grubx64.efi`
trouxer menu próprio embutido, o UEFI sobe a entrada 0 (interativa) e a
instalação automática **não acontece, sem erro nenhum**.
*Como confirmar:* `bash iso/test-vm.sh --iso … --boot-mode uefi --yes` (precisa de `ovmf`).

**Modo 3 — Debian/preseed nunca foi executado.** O caminho `--distro debian`
(`isolinux` + `preseed/file=`) **nunca foi bootado** — só o Ubuntu foi.
*Auditado e **descartado** como bug:* o `prompt 1` que o `patch_isolinux`
escreve **não** desliga o `timeout` (a doc do syslinux diz que `PROMPT` **não**
cancela `TIMEOUT`; com vários labels, o `default` sobe sozinho após o timeout).

### O build da ISO morre com `exit code 22` (e nenhuma mensagem)

- **Sintoma:** `bash iso/build-iso.sh ...` termina com **`exit code 22`** logo
  no começo, sem dizer o que falhou. No GitHub, o passo "Gerar a ISO" fica
  vermelho com essa única informação.
- **Causa:** `22` **não é um código do projeto** — é do **`curl`**, que o usa
  quando o servidor responde HTTP ≥ 400 sob `-f`/`--fail`. Ou seja: algum
  download tomou 404. O caso real foi a **ISO Ubuntu**: o
  `releases.ubuntu.com/24.04/SHA256SUMS` marca o modo binário com `*` antes do
  nome (`*ubuntu-24.04.5-live-server-amd64.iso`), como faz o `md5sum -b`. Sem
  remover o `*`, a URL montada era
  `.../24.04/*ubuntu-24.04.5-live-server-amd64.iso` → **404** → `exit 22`.
  O `SHA256SUMS` do Debian **não** usa esse marcador — por isso o caminho
  Debian funcionava e o Ubuntu não.
- **Como identificar:** a URL exata aparece nas linhas de `INFO` do log
  (`Baixando <url>`). Confirme à mão:
  `curl -sIL -o /dev/null -w '%{http_code}\n' '<a-url>'` → 404 confirma.
- **Solução:** já corrigida em `iso/build-iso.sh` (as funções
  `pick_iso_entry`/`normalize_iso_name` removem o `*` e o prefixo `./`). Se
  reaparecer, **não** procure no código do projeto: olhe a URL no log.
- **Teste que guarda isso:** `make iso-select-test` — roda as mesmas funções
  contra `SHA256SUMS` **reais** guardados em `tests/fixtures/`.

### A ISO quebra "do nada" ao mudar de ponto de release (Ubuntu)

- **Sintoma:** funcionava na 24.04.3 e parou quando saiu a 24.04.5.
- **Causa:** o `SHA256SUMS` do Ubuntu lista **todas** as point releases
  (24.04.3, .4, .5…) **e** as variantes desktop/wsl. Pegar a **primeira**
  entrada casada baixa a versão mais **velha** — e um padrão sem âncora
  (`netinst\.iso$`) casa `debian-edu-*` e `debian-mac-*`.
- **Solução:** já corrigida: os padrões são **ancorados** e a escolha é a de
  **maior versão** (`sort -V | tail -1`), não a primeira.

### `Pacote pedido está AUSENTE no repositório: X` (com `--iso-repo auto`)

- **Sintoma:** o build morre no fim com uma lista de pacotes "ausentes" — e
  alguns deles são pacotes banais (`gnupg`, `jq`, `git`) que **existem** no
  Ubuntu.
- **Causa:** `apt-get download a b c` **aborta o LOTE INTEIRO** se UM dos nomes
  não tiver candidato — não baixa nem os válidos. Medido:

  ```
  apt-get download git PACOTE-QUE-NAO-EXISTE jq   →  rc=100, ZERO arquivos
  ```

  O fecho do `apt-cache depends --recurse` inclui pacotes **virtuais** (sem
  candidato), e **quais são depende da release do host**: no runner do CI havia
  pelo menos um, e o script baixava em lotes de 25 com `|| true` — então cada
  lote que continha a isca perdia até 25 pacotes em silêncio. Os três
  "ausentes" eram só os **pedidos** que caíram no lote da isca; o resto do
  fecho era perdido sem aviso.
- **Por que só apareceu no CI:** na máquina de desenvolvimento não havia isca
  nenhuma no fecho, então o download funcionava. É um bug **dependente do
  ambiente** — o que o torna pior.
- **Solução:** já corrigida em `iso/build-iso.sh`:
  `packages_with_candidate()` descarta nomes sem candidato **antes** de baixar,
  e o lote que falha mesmo assim é refeito **um a um** (o `apt-get` não derruba
  o vizinho), com os nomes que falharam **reportados** no log. Se ainda faltar
  algo, o build **refaz só os ausentes** uma vez (`Acquire::Retries`), porque
  uma falha transitória de rede é indistinguível de "pacote não existe" no log.
- **Teste que guarda isso:** `make iso-repo-test` — reproduz o caso inteiro
  offline, com `apt-get`/`apt-cache` substituídos por stubs.

### `Pacote pedido não entrou no repositório local: git` — mesmo com o retry

- **Sintoma:** o fix acima está no código, e o build **ainda** morre com um
  único pacote banal faltando (`git`), desta vez dizendo *"não entrou no
  repositório local"*. Antes de 2026-10-15 a mensagem dizia *"está AUSENTE no
  repositório"* — frase **falsa**: o pacote existe no Ubuntu, o que não entrou
  foi o `.deb` na pasta que estamos montando. A redação foi corrigida
  justamente porque a antiga mandou uma sessão caçar um bug inexistente.
- **Como identificar:** no resumo do run, o intervalo entre as duas mensagens
  `Repositório incompleto` é de **segundos**, não de minutos. Um download
  real de fecho leva **minutos**; poucos segundos significa que o `apt-get
  download` **falhou na hora** — logo não é "a rede caiu no meio".
- **Causa medida (run #16, 2026-10-14):** a segunda tentativa repetia o
  `apt-get download` **com a mesma lista de pacotes** e com `Acquire::Retries`,
  que **não conserta uma lista inválida**. Quando o espelho responde **404**
  (a versão que a lista cita já saiu do `archive` — típico em virada de *point
  release*), repetir com a lista velha reproduz o erro **idêntico**, quantas
  vezes for. Pior: a saída do `apt` era descartada (`>/dev/null 2>&1`), então
  **a causa nunca aparecia em lugar nenhum** — nem no log, nem na anotação.
- **Solução (2026-10-15):** `iso/build-iso.sh` agora, na 2ª tentativa,
  (a) roda **`apt-get update`** antes de repetir — **índice fresco** é o que
  resolve o caso do 404 — e (b) baixa **um a um logando a resposta do `apt`**
  (`log_warn "  <pacote>: <erro do apt>"`). Se falhar de novo, a **causa** vai
  para o log **e** para a anotação pública.
- **Como ver a causa sem token:** o `iso.yml` publica anotações com o padrão
  `PAT`. Foram acrescentados `Refazendo o download`, `Ainda faltando` e
  `falhou:` a esse padrão — sem isso, a informação ficaria presa no log do job,
  que **exige token** (403 para quem não está logado).
- **Como consultar rápido:**
  `curl -s .../check-runs/<job_id>/annotations` (as anotações são **públicas**).
- **Teste que guarda isso:** `make ci-guards-test` — plantas que (a) removem o
  `apt-get update` da 2ª tentativa e (b) fazem o retry voltar a descartar a
  saída do `apt`. As duas têm de reprovar o job.

### A ISO Debian é REPROVADA pelo verificador, mas está correta

- **Sintoma:** no caminho Debian com `--iso-repo`, o build **gera** a ISO e o
  `verify-iso.sh` a reprova com **2 problemas**, um deles dizendo
  *"o repositório está na mídia mas o autoinstall NÃO o usa"*.
- **Causa:** **falso positivo do verificador.** A checagem de coerência do
  repositório procurava o marcador `cdrom/apt-repo` dentro do
  **`/autoinstall.yaml`** — que **não existe** numa ISO Debian (o Debian usa
  preseed). Resultado: "a config não usa o repo" (mentira) e, por
  consequência, a mensagem de repositório inútil. O repo estava na mídia e a
  preseed **o usava** — via `d-i apt-setup/local0/repository`.
- **Solução:** a checagem passou a ser **distro-aware**: Ubuntu confere a seção
  `sources` do curtin no autoinstall; Debian confere
  `apt-setup/local0/repository` na preseed. O modo de falha que a checagem
  existe para pegar (config sem a fonte extra → instalação dependente de rede)
  continua coberto nos dois caminhos.
- **Lição:** o verificador tinha um viés de distro. Ao adicionar uma checagem,
  pergunte **em qual base** ela faz sentido — e cubra a outra.

### `openssl não encontrado e --password-hash não foi informado`

- **Sintoma:** o build aborta logo na seção *Dependências*, num ambiente limpo.
- **Causa:** o build gera o hash da senha aleatória com `openssl passwd -6`, mas
  o `openssl` **não** estava na lista de ferramentas que o workflow `iso`
  instalava — ele existia no runner **por acaso**. Numa imagem limpa (ex.: um
  container `ubuntu:24.04`) ele não existe.
- **Solução:** `openssl`, `gzip` e `ca-certificates` passaram a ser instalados
  explicitamente pelo workflow. Regra geral: **dependência implícita do runner é
  dependência que desaparece** quando o runner muda.
- **Alternativa:** passe `--password-hash '$6$…'` (gerado com
  `mkpasswd -m sha-512`).

---

## Gravar o pendrive

### `make pendrives` não lista o meu pendrive

- **Causa:** a listagem mostra só o que é **removível** (`RM=1` ou barramento
  de cartão/pendrive) **e** do tipo `disk`. Um pendrive aparece como `disk`
  (com `sdb1` = partição); `sr0` (DVD) tem `RM=1` mas é `rom`.
- **Solução:** confira o que o kernel vê:
  `lsblk -o NAME,TYPE,RM,TRAN,SIZE,MODEL`. Se o seu dispositivo for um **HD
  externo por USB**, ele é removível e aparece — cuidado: é justamente o caso
  que a trava do tamanho avisa (dispositivo muito maior que a ISO).

### Recusa dizendo "disco que contém o sistema em execução"

- **Causa:** trava funcionando. O alvo contém a raiz (`/`) montada.
- **Solução:** é para ser impossível mesmo. Se você realmente precisa gravar
  nesse disco, o sistema tem de estar rodando de **outro** dispositivo (ou de
  uma live ISO).

### Recusa dizendo "NÃO é removível" (mas é um pendrive)

- **Causa:** o kernel não marca `RM=1` para aquele dispositivo (comum em alguns
  adaptadores USB-SATA/NVMe e em VMs, que expõem disco como não removível).
- **Solução:** se **tem certeza**, `--allow-internal` libera — e ele exige
  digitar o **caminho completo** do dispositivo, o que é proposital.

### `cmp` acusa diferença depois de gravar

- **Causa:** normalmente o **dispositivo é menor que a ISO** com o tamanho
  anunciado (pendrives falsos que se declaram de 64 GB); ou a ISO estava
  truncada.
- **Solução:** confira o `sha256sum` da ISO (`iso/out/*.iso.sha256`) e o
  tamanho real do dispositivo (`lsblk -b`). **Não boote** — o resultado seria
  uma instalação truncada.

---

## Baixar a ISO do CI

### Baixei a ISO e o `check-iso` diz que não é ISO 9660

- **Sintoma:** `make iso-check ISO=arquivo.iso` reprova com
  *"não é uma ISO 9660: esperava CD001"*.
- **Causa:** **o artifact do GitHub é um `.zip`.** Você baixou o artifact, não
  a ISO: o arquivo dentro dele é que é a imagem. Renomear para `.iso` **não**
  resolve — o conteúdo continua sendo um zip.
- **Solução:** descompacte o artifact e use o `.iso` de dentro:
  `unzip ai-cpu-os-iso-ubuntu.zip`. O `make iso-check` explica isso na própria
  mensagem de erro, justamente porque é o erro mais comum do caminho.

### `make iso-check` diz que o SHA256 divergiu

- **Causa:** download interrompido, ou você editou/renomeou o arquivo (o
  `.sha256` mudou de linha de base). Como o SHA256 é do **conteúdo**, qualquer
  alteração de um byte denuncia.
- **Solução:** baixe de novo o `.iso` **e** o `.iso.sha256` juntos, e rode o
  check sobre o par novo. **Não grave** um arquivo com SHA256 divergente.

### A ISO air-gapped não aparece para download

- **Causa:** era uma limitação **do projeto**, já corrigida: o mesmo booleano
  gateava o artifact **e** a Release, e o limite de 2 GiB (que é de **asset de
  Release**) escondia a ISO de ~4 GB. O artifact **não** tem esse limite.
- **Solução:** atualize o `main` e rode o workflow de novo — o artifact sobe
  sempre. Se você estiver numa versão antiga e precisar da ISO agora, gere na
  sua máquina (precisa de `xorriso`).

---

## CI / Guardas

### Plantei a violação e o guarda do CI não reprovou

- **Sintoma:** você altera o arquivo para violar a regra de propósito, roda o
  job `project-rules` e ele passa verde.
- **Causa:** o guarda está escrito na forma `! grep -q X arquivo`. O `set -e` do
  bash **ignora o exit status de um comando invertido com `!`** (está na doc do
  `set`: *"...or if the command's return value is being inverted with !"*). O
  guarda **detecta** a violação e **não faz nada** — segue para o próximo
  comando. Seis guardas deste repositório estavam assim.
- **Como detectar:** `make ci-guards-test` planta cada violação numa cópia
  temporária e **exige** que o job falhe. Ele também detecta a forma proibida
  (meta-guarda) e uma árvore de trabalho suja.
- **Solução:** escreva guardas negativos como
  `if cmd; then echo "::error::..."; exit 1; fi`.

---

## Geral

### `build.sh` falha dizendo que não está como root

- **Solução:** use `sudo ./build.sh ...`. Para simular sem aplicar:
  `./build.sh --role auto --dry-run` (dry-run não precisa de root para
  inspecionar, mas a detecção de RAM pode precisar).

### Rodar duas vezes quebrou algo (esperado idempotente)

- **Causa:** bug de idempotência — **reporte!**
- **Solução:** verifique logs com timestamp; os scripts só escrevem se o
  valor estiver diferente. Abra uma issue com o trecho de log.

---

## Histórico

| Data       | Mudança                                            |
|------------|----------------------------------------------------|
| 2026-10-07 | Documento inicial de troubleshooting (`0.1.0-alpha`). |
