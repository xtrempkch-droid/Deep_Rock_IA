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

### A ISO Debian NÃO instala sozinha: para no `boot:` ou pede o idioma para sempre

- **Sintoma:** a ISO Debian boota mas a instalação automática **nunca
  acontece**. Dois quadros distintos, ambos *mudos* (nenhuma mensagem de erro):
  1. a tela fica em `boot:` esperando uma tecla (e o `timeout` não resolve);
  2. o instalador abre em `[!!] Select a language` e fica ali **para sempre** —
     mesmo com a interface já traduzida para o idioma pedido.
- **Causa raiz (cinco bugs independentes, todos precisam de correção):**
  1. **`prompt 1` no `isolinux.cfg`.** Nesse modo o isolinux mostra o prompt e
     **espera tecla**; o `timeout` só vale com `prompt 0`. O sintoma é cruel: a
     VM fica parada, o disco **não é tocado** (o qcow2 continua com 193 KB) e o
     console serial fica com **zero byte**.
  2. **O preseed tem de estar no `initrd`, não no `/cdrom`.** O script
     `S30initrd-preseed` do initramfs faz literalmente
     `if [ -e /preseed.cfg ]; then preseed_location file:///preseed.cfg; fi` —
     ele lê a **raiz do initramfs**. Um `preseed/file=/cdrom/...` só é aplicado
     muito depois, quando o udeb `file-preseed` instala, e aí o
     `localechooser` já perguntou tudo. `inject_preseed_initrd()` anexa um
     segundo arquivo `cpio` (newc) ao `initrd.gz` com `/preseed.cfg`.
  3. **`localechooser/languagelist` ≠ `debian-installer/language`.** A pergunta
     que aparece na tela é a **lista** (`localechooser/languagelist`), e o
     `localechooser` só a pula quando o idioma preseedado está entre as
     **escolhas** da lista. A lista é montada por **nível de exibição**
     (`language_display_level()`): em **console serial** o nível é **0**, e no
     nível 0 só existe `en`. Com `language=pt` na cmdline o debconf já exibe
     tudo em português — e **mesmo assim** `has_choice … pt` falha, o `seen`
     não é propagado e a pergunta é feita.
  4. **`grub-installer/bootdev` é pergunta crítica e não tinha resposta.** Ela é
     feita **no fim** (depois de copiar o sistema inteiro): sem preseed, o
     instalador espera para sempre com a instalação já pronta. Agora o
     `build-iso.sh` gera `d-i grub-installer/bootdev string <DISCO>` (ou
     `default` quando o disco não foi fixado).
  5. **`ROOT_PASSWORD_HASH="$6$sal$hash"` entre aspas DUPLAS.** Um hash crypt
     tem `$`, e aspas duplas fazem o shell **expandir** `$6`. Sob `set -u` o
     `late-command.sh` morria com **exit 2 antes de copiar arquivo nenhum** — e a
     única mensagem visível era `Failed to run preseeded command "sh
     /preseed/late-command.sh" … exit code 2`, com `/opt` vazio no alvo. Todos
     os marcadores literais do template passaram a usar **aspas simples**, e o
     autoteste (`--check-templates`) agora **avalia** a linha gerada com
     `sh -u -c` provando que o hash chega byte a byte (`sh -n` não pega isso).
- **Solução:** (1) `prompt 0`; (2) `inject_preseed_initrd` + `preseed/file=/preseed.cfg`
  nas três entradas Debian (isolinux + 2 do GRUB/UEFI); (3) `d-i localechooser/languagelist
  select @@LANG@@` na preseed, **além** de `d-i debian-installer/language`, e
  `language=`/`country=`/`locale=`/`keymap=` na cmdline (`debian_locale_args()`,
  via `env2debconf`, porque o `localechooser` roda **antes** de a mídia ser
  montada); (4) `@@GRUB_BOOTDEV@@` → `d-i grub-installer/bootdev string …`;
  (5) aspas simples em todos os valores literais do `late-command.sh`.
- **Como diagnosticar:** boote o kernel+initrd direto, sem a ISO:
  ```bash
  qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \
    -kernel vmlinuz -initrd initrd-dbg.gz -cdrom a.iso \
    -append "auto=true priority=critical preseed/file=/preseed.cfg console=ttyS0,115200 --- quiet" \
    -serial file:dbg.log -display none
  ```
  trocando `S30initrd-preseed` por uma versão que faça `echo … >/dev/console`
  e imprima `db_get` de `debian-installer/language`, `localechooser/languagelist`
  e o `seen` de cada um. Foi assim que a causa apareceu: os valores **estavam**
  no db (`language=pt`, `seen=true`) e o `preseed_location` retornava **0** —
  o problema não era o preseed, era a pergunta ser outra.
- **Lição:** "preseed aplicado" não significa "pergunta respondida". Quando um
  instalador insiste numa pergunta com o preseed correto, descubra **qual
  template** ele está realmente exibindo (`db_get`/`grep` no fonte do
  componente) antes de mexer no preseed.
- **Lição 2:** um valor **literal** vindo do build (`@@MARCADOR@@`) nunca vai
  entre aspas duplas num template de shell. `$6$…` de um hash crypt é o caso
  mais cruel porque *parece* uma variável válida; `set -u` transforma isso em
  morte silenciosa. E a checagem tem de ser por **execução** (`sh -u -c '…'`
  comparando o valor), não por inspeção: `sh -n` passa com o bug dentro.
- **Lição 3:** o `late-command.sh` ganhou um `trap` de `EXIT` que imprime no
  `/dev/console` — sem ele, a falha só existia no log do instalador (tty4) e o
  sintoma era um `exit code 2` sem causa.

### A ISO Debian instala, mas o **primeiro boot** falha (ou não reinicia)

- **Sintoma A:** a instalação termina, a máquina **não reinicia** e fica no
  menu principal do `debian-installer` (a tela com `2 shell / 3 shell / 4 log`).
  O log mostra `Menu item 'finish-install' succeeded but requested to be left
  unconfigured` — e, do lado do d-i, isso é **`exit 10` = "backed up"**: a
  sequência `finish-install.d` é **abortada** e todos os hooks seguintes
  (`94save-logs`, `95umount`, **`99reboot`**) nunca rodam.
- **Causa A:** `finish-install.d/20final-message` faz
  `db_input critical finish-install/reboot_in_progress` e trata um `db_go` que
  devolva "back" como `exit 10`. Em **console serial** isso acontece sempre —
  preseedar `d-i finish-install/reboot_in_progress note` **não** foi suficiente.
- **Solução A:** o `late-command.sh` (que roda no hook `07preseed`, portanto
  **antes** do `20`) substitui o hook por um no-op **e**, no fim, faz o
  reinício por conta própria (`sync`, `umount /target`, `reboot -f`); o
  `iso/verify-iso.sh` confere as duas coisas. **Substituir o hook sozinho não
  basta** — o `20final-message` pertence ao udeb `finish-install`, que é
  desempacotado **depois** do `07preseed`, então no momento do patch o arquivo
  ainda não existe. O `reboot -f` é o que reinicia de fato; o patch fica como
  cinto de segurança.

- **Sintoma B:** o sistema instalado sobe, mas o `ai-cpu-os-firstboot` falha
  (`status=failed`, `rc=100`) e nada é aplicado.
- **Causa B:** o próprio instalador grava `deb cdrom:[Debian …]` no
  `sources.list` do alvo (`apt-cdrom-setup`). Depois da instalação a mídia não
  existe mais e **todo** `apt-get update` falha com *"o repositório cdrom://…
  não tem um arquivo Release"*. O papel `inference` roda `apt-get update` antes
  de instalar qualquer dependência → rc=100.
- **Solução B:** o `late-command.sh` remove **só** as linhas
  `deb … cdrom:` (o espelho oficial continua intacto) e roda o `apt-get update`
  uma vez para confirmar.

- **Sintoma C:** o usuário da ISO **não consegue administrar** a máquina:
  `sudo: comando não encontrado` (embora ele esteja no grupo `sudo`).
- **Causa C:** `sudo` **não** faz parte de uma instalação padrão do Debian (é
  diferente do Ubuntu). Com o root bloqueado (sem `--root-password-hash`) o
  sistema ficava **sem nenhum acesso administrativo**.
- **Solução C:** `sudo` entrou em `EXTRA_PACKAGES` (e em
  `DEFAULT_REPO_PACKAGES`, para o repositório local da mídia cobri-lo).

> **Como investigar isso rápido:** depois da instalação, dê boot no disco com
> `-netdev user,hostfwd=tcp:127.0.0.1:2222-:22` e entre por SSH
> (`ssh -p 2222 <usuário>@127.0.0.1`): `systemctl status ai-cpu-os-firstboot`,
> `/opt/ai-cpu-os/.firstboot-status` e `/var/log/ai-cpu-os-firstboot.log`
> dizem exatamente onde parou. Foi assim que os três itens acima apareceram
> (sessão #35) — nenhum deles é visível pelo console serial.

### A ISO foi gerada mas a verificação diz "AUSENTE" em arquivos que existem

- **Sintoma:** `[ERROR] A ISO gerada NÃO passou na verificação` com uma lista
  enorme de `[FAIL] ... AUSENTE`, às vezes incluindo coisas que você sabe que
  estão lá (ex.: *"rede auto sem o netplan"*, quando o netplan está na ISO).
- **Causa (medida, sessão #36):** o verificador extraía o **modelo inteiro**
  (1,1 GB com `--iso-model auto`) só para conferir o `magic` GGUF. Como o
  diretório temporário era `mktemp -d` → **`/tmp`**, que em muitas máquinas é
  **tmpfs** (RAM), o espaço acabava **no meio** da verificação. Do primeiro
  erro de espaço em diante, **toda** extração falhava — e cada falha virava um
  `[FAIL] AUSENTE` que culpava a ISO por um problema de disco.
  Confira você mesmo: `df -h /tmp` (se for `tmpfs` com poucos GB, é isso).
- **Correção:**
  - o modelo agora é conferido lendo **só o primeiro bloco** (LBA do arquivo +
    `dd bs=2048 count=1`), e o tamanho vem do **metadado** do ISO9660 — nada é
    extraído;
  - o diretório de trabalho passou a ser escolhido pelo **espaço livre**
    (`$TMPDIR` → `/tmp` → diretório da ISO → atual), e há a flag `--tmp DIR`;
  - sem conseguir ler, o verificador diz **`[SKIP]`** (limitação do ambiente)
    em vez de `[FAIL]` (que acusa a ISO).
- **Teste:** `make iso-space-test` — usa um modelo **esparso de 2 GB** e prova
  que ele não é copiado, que um `magic` errado continua sendo reprovado e que
  `--tmp` inválido degrada em vez de explodir.
- **Se você já tem uma ISO assim:** ela provavelmente está **boa**. Rode
  `bash iso/verify-iso.sh --iso SUA.iso --distro ubuntu --tmp /var/tmp` e veja
  se o resultado muda.

### O build avisa "Release incompatível" e a ISO sai SEM repositório local

- **Sintoma:** ao gerar a ISO com `--iso-repo auto`, o log diz
  *"Release incompatível: a ISO é Ubuntu X e esta máquina é Y"* e
  *"Seguindo SEM repositório local"*. A ISO é gerada, mas **instalar nela
  depende de rede** — e sem rede a instalação deixa de instalar o
  `openssh-server` e os pacotes.
- **É proteção, não defeito:** `.deb` de outra release não casam com a base da
  ISO e produzem uma instalação quebrada (pior que não ter repositório).
- **Causas e saídas:**
  1. Você está gerando a ISO de uma release **diferente** da sua máquina.
     Saídas: gerar numa máquina da mesma release (ou container/VM), ou usar uma
     ISO base da **sua** release (`--iso /caminho/ubuntu-<sua-versao>-....iso`,
     baixada de `releases.ubuntu.com/<sua-versao>/`).
  2. Você passou `--iso <arquivo>` e o build **não reconhecia** a versão do
     arquivo (bug corrigido na sessão #36: ele usava o default 24.04). Se você
     vir esse aviso com o nome do arquivo já na versão certa, atualize o projeto.
- **Como conferir que está OK:** o log tem de dizer `Release confere: <codename>`
  e depois `[dry-run] baixaria o fecho de dependências de: … openssh-server …`.
- **Verificação barata antes de queimar 3 GB de build:**
  ```bash
  bash iso/build-iso.sh --distro ubuntu --iso /caminho/base.iso --disk auto \
      --iso-repo auto --iso-source none --iso-model none --dry-run --yes \
    | grep -E 'Release (confere|incompatível)|baixaria o fecho'
  ```
- ⚠️ `--iso-repo-allow-mismatch` existe para **teste**, nunca para produção.

### `sudo apt-get update` falha SEMPRE: "não possui um arquivo Release"

- **Sintoma:** a máquina instalada não acha o repositório — como se não houvesse
  link. Todo `apt-get update` termina em erro, e por isso **nada** se instala
  (nem `openssh-server`).
- **Diagnóstico (1 comando):** veja QUEM é a fonte que falha —
  ```bash
  grep -rn . /etc/apt/sources.list /etc/apt/sources.list.d/
  apt-get update 2>&1 | grep -E '^(Err|E:)' | head
  ```
- **Causa A (a mais comum, e é bug nosso):** a ISO **antiga** gravava
  ```text
  /etc/apt/sources.list.d/ai-cpu-os-local.list
      deb [trusted=yes] file:///opt/apt-repo ./
  ```
  **sem verificar se `/opt/apt-repo` existia no alvo.** Quando a cópia do
  repositório falhava, o apt passava a falhar em **toda** atualização. Teste:
  `ls /opt/apt-repo/Release` — se não existir, é este o caso.
- **Causa B:** `deb cdrom:[…]` no `sources.list` — o `debian-installer` grava
  a mídia como fonte e, depois da instalação, ela não existe mais.
- **Causa C:** não é o `sources` e sim **rede**: `Temporary failure resolving` /
  `Network is unreachable` = falta default route ou DNS (ver a seção da rede).
- **Solução (a partir da sessão #36):** a mod dedicada conserta sozinha —
  ```bash
  sudo bash mods/apt-sources/apply.sh        # ou: make apt-fix
  sudo bash mods/apt-sources/apply.sh --dry-run   # só o diagnóstico
  ```
  Ela remove as fontes que apontam para o nada (com backup
  `.ai-cpu-os.bak`), grava a lista **oficial** da distro se nada sofrer, e
  **valida com `apt-get update`**. Para desfazer: `mods/apt-sources/revert.sh`.
- **Correção na ORIGEM (para não acontecer de novo):** o `late-command.sh` só
  declara o repositório local depois de checar `Release`+`Packages`, conferir a
  **release** e **provar com `apt-get update`**. Se falhar, a fonte **não** é
  gravada: melhor um alvo sem repositório local do que com o apt quebrado.

### A máquina instalada responde a `ping` mas **não aceita SSH** (nem nada)

- **Sintoma:** a instalação terminou, a máquina está na rede (aparece no
  `arp`/DHCP e responde `ping`), mas `ssh: Connection refused` — e **nenhum**
  outro serviço responde.
- **Como diagnosticar em 1 minuto (sem chutar):** varra as portas. `RST` em
  tudo = a máquina está viva e **não há listener**; `timeout` em tudo =
  firewall. Exemplo real (sessão #36):
  ```bash
  sudo nmap -Pn -p- --min-rate 3000 192.168.0.113
  # → Ports: Ignored State: closed (65535)   ← nenhum serviço escutando
  ```
- **Causa:** `sshd` **não foi instalado**. A ISO pede o SSH ao instalador
  (`ssh: install-server: true` no Ubuntu, `openssh-server` no `pkgsel` do
  Debian), mas **os dois falham em silêncio quando não há rede durante a
  instalação** — e aí a máquina nasce sem **nenhum** acesso remoto. Numa
  máquina sem teclado e sem tela, ela está perdida: é o pior modo de falha do
  projeto.
- **Como saber se a instalação teve rede:** se `packages:` também falhou, não
  há `git`/`build-essential` no alvo; e o `firstboot` deixa
  `.firstboot-status` com `status=failed`.
- **Solução (a partir da sessão #36):** o `late-command.sh` **verifica** o
  `sshd` no alvo, tenta instalar e, se não conseguir, escreve um aviso no
  `/etc/motd` e em `/root/LEIA-SSH.md` (quem chega no console descobre o que
  fazer em 5 s). O `build.sh` faz a mesma verificação **no primeiro boot**
  (`ensure_ssh`). O `verify-iso.sh` e o CI cobram as duas coisas.
- **Solução para uma máquina já instalada assim** (precisa de console):
  ```bash
  apt-get update && apt-get install -y openssh-server
  systemctl enable --now ssh
  ip -4 addr show          # descubra o IP
  ```
- **Prevenção:** gerar a ISO com `--iso-repo auto` leva os `.deb` na mídia, e
  aí a instalação **não depende de rede** nem para o SSH. O build agora avisa
  explicitamente quando a ISO sai sem repositório local.
- **Detalhe de rede que engana:** um cabo direto entre duas máquinas **não tem
  servidor DHCP**. Sem DHCP a máquina instalada fica sem IP (mesmo com a placa
  UP) e "não aparece na rede". Suba um DHCP no lado que investiga
  (`dnsmasq --interface=… --dhcp-range=…`) e observe o lease — foi assim que a
  máquina foi encontrada em `192.168.0.113`.

### O `test-vm.sh` estoura o timeout no **primeiro boot** (parece travado)

- **Sintoma:** a instalação termina e o sistema instalado sobe, mas o console
  serial fica **em silêncio** e o `test-vm.sh` falha com *"timeout esperando o
  firstboot"*. O disco parece parado (`stat -c %b` no qcow2 não muda).
- **Causa 1 (a que custou duas sessões):** até a sessão #35 a espera por rede
  do `firstboot.sh` fazia `getent hosts …` **sem teto**: com DNS que não
  responde, cada sonda bloqueia dezenas de segundos e o laço de 24 tentativas
  passava de **40 min** — imóvel, sem log e com `%CPU` do qemu em **0**.
  Correção: `timeout 5` em cada sonda (teto total ~2 min).
- **Causa 2:** se o log **mostra** `[ NN%] Building CXX…`, aí é só compilação
  (com **8 vCPU** são ~4 min; com 2–4 vCPU e cache frio, muito mais). O
  `test-vm.sh` tem `--timeout-min 60` por padrão. O qcow2 não cresce durante o
  build (clusters já alocados), então `stat -c %b` engana.
- **Como confirmar em 10 s** (sem esperar): boote o disco à mão com a porta
  encaminhada e olhe o processo:
  ```bash
  qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 4 \
    -drive file=alvo.qcow2,if=virtio,format=qcow2 -display none \
    -serial file:serial.log -monitor none \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net0 &
  ssh -p 2222 ai-cpu-os@127.0.0.1 'ps -eo pid,etimes,%cpu,args --sort=-%cpu | head -3'
  # cc1plus a 99% = build em andamento; 0% e sem filho = travado de verdade
  ```
- **Solução:** `--cpus 8` e **`--keep`** — sem ele o script **apaga o disco**
  ao abortar e você perde a evidência (aconteceu no t6). Para encurtar o
  1º boot, gere a ISO com `--iso-source` apontando para um `.tar.gz` do
  llama.cpp (não clona do GitHub) ou use `--role builder` (não compila nada).

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

### O sistema instalado sobe **sem rede** (a placa fica DOWN)

- **Sintoma:** a ISO instala normalmente, mas depois do boot não há IP; é
  preciso rodar `ip link set enp5s0 up` + `dhclient enp5s0` (ou
  `netplan apply` com um arquivo escrito à mão) **em todo boot**.
- **Causa (medida numa instalação real, sessão #28):** o **Subiquity não grava
  uma configuração de rede persistente** no alvo quando o `autoinstall.yaml`
  não tem a chave `network:`. O instalador usa DHCP para si mesmo e não deixa
  o netplan correspondente em `/etc/netplan` — o sistema instalado nasce sem
  configuração de rede.
- **Solução (a partir da sessão #28):** a rede virou parte da preparação da
  ISO, exatamente como a senha:
  `--network auto|dhcp|static|none` (+ `--network-ip`,
  `--network-gateway`, `--network-dns`, `--network-interface` no modo
  `static`). O build escreve o **mesmo** netplan no `autoinstall.yaml` e em
  `/preseed/ai-cpu-os-netplan.yaml`, e o `late-command.sh` o instala em
  `/etc/netplan/99-ai-cpu-os.yaml`, move o netplan do instalador/cloud-init
  para `.ai-cpu-os.bak` e desliga a rede do cloud-init
  (`/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg`). O padrão é
  DHCP — não é preciso passar nada.
- **Se a sua ISO é anterior a essa mudança (a máquina JÁ está instalada):**
  **não precisa reinstalar.** O projeto está em `/opt/ai-cpu-os` na máquina, e
  a mod `network` faz exatamente este reparo:

```bash
sudo bash /opt/ai-cpu-os/mods/network/apply.sh          # DHCP (padrão)
ip -br addr                                             # confira: já tem IP?

# IP fixo (ex.: o servidor de inferência)
sudo bash /opt/ai-cpu-os/mods/network/apply.sh --mode static \
  --interface enp5s0 --ip 192.168.1.50/24 --gateway 192.168.1.1
```

  Ela grava `/etc/netplan/99-ai-cpu-os.yaml` (0600), **move** o netplan do
  instalador/cloud-init para `*.ai-cpu-os.bak` (duas definições do mesmo
  adaptador fazem o netplan **recusar** a configuração) e escreve
  `/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg`. Valida com
  `netplan generate` **antes** de aplicar — se a config nova for inválida, não
  aplica (a rede atual continua de pé). Para desfazer:
  `sudo bash /opt/ai-cpu-os/mods/network/revert.sh` (restaura os backups).
  Ver `docs/MODS.md` § 3 e `make network-test`.
  ⚠️ **Se a placa não se chama `en*`/`eth*`** (Wi-Fi `wlp*`/`wlx*`, nome fora do
  padrão), o netplan acima não casa nada e o sintoma continua igual — a mod
  **avisa** e sugere a placa real. Passe `--interface <nome>`; para conferir os
  nomes: `ip -br link`. Depois: `ip -br addr`.
- **Não tem o projeto na máquina?** Copie `mods/network/` + `mods/apply.sh`
  (ou clone o repositório) e rode o mesmo comando. Alternativa manual, sem
  nada disso: crie `/etc/netplan/99-rede.yaml` com `dhcp4: true` e rode
  `sudo netplan apply`.
- **Prefere reinstalar?** Uma ISO nova já nasce com a rede configurada (o
  caminho é testado por `make iso-yaml`/`make network-test`/`make ci-guards-test`).
- **Diagnóstico no alvo:**

```bash
ip -br addr                      # a placa está UP? tem IP?
ls -l /etc/netplan/              # existe 99-ai-cpu-os.yaml?
sudo netplan generate            # o YAML é válido?
systemctl status systemd-networkd cloud-init
```

- **Teste que guarda isso:** `make iso-yaml` exercita os modos `auto`,
  `static` e `none`; `make iso-verify-test`/`make ci-guards-test` provam que o
  verificador reprova quando um dos três elos some.
- ✅ **PROVADO em VM (sessão #33, 2026-10-17):** uma ISO com `--network auto`
  foi instalada e o alvo pegou IP por DHCP **sozinho**
  (`systemd-networkd: ens3: DHCPv4 address 10.0.2.15/24 … acquired`), com
  `/etc/netplan/99-ai-cpu-os.yaml` intacto e o cloud-init desligado. **Falta** o
  modo `static` e o hardware físico.

---

## Serviço de inferência (ai-server)

### `ai-server` fica em loop: `error: invalid argument: --no-mmap`

- **Sintoma:** `systemctl status ai-server` mostra `activating` eternamente;
  o journal repete `error: invalid argument: --no-mmap` seguido de
  `Main process exited, code=exited, status=1/FAILURE` e um novo restart.
- **Causa:** o llama.cpp **removeu** `--no-mmap` do upstream (o projeto usava a
  flag para não mapear o modelo em memória). A unit `ai-server.service` fixava
  a flag, então qualquer build de uma versão recente do llama.cpp quebra.
- **Solução (já no código):** a unit usa `${LLAMA_EXTRA_ARGS}` e o
  `roles/inference/install.sh` **pergunta ao binário recém-compilado** qual
  sintaxe vale — grava `--no-mmap` (versões antigas), `--load-mode none`
  (versões novas) ou nada. Para conferir:
  `grep LLAMA_EXTRA_ARGS /etc/default/ai-server`.
- **Se a sua ISO é anterior:** edite `/etc/default/ai-server`, acrescente
  `LLAMA_EXTRA_ARGS=--load-mode none` (ou deixe vazio) e rode
  `sudo systemctl daemon-reload && sudo systemctl restart ai-server`.
  Confira antes com `llama-server --help | grep -E 'no-mmap|load-mode'`.
- **Teste que guarda isso:** `make ci-guards-test` (proíbe `--no-mmap` fixo na
  unit e exige a detecção no `install.sh`).

### Arquivos com **0 byte** depois do primeiro boot (`ai-server.service` "masked")

- **Sintoma:** depois de instalar, `systemctl is-enabled ai-server` responde
  **`masked`** (e não `enabled`), `/etc/default/ai-server` está vazio,
  `llama-server` tem 0 byte e `.firstboot-status` também. O log do firstboot
  diz `aplicação concluída com sucesso`.
- **Causa:** o disco não foi descarregado. O `firstboot` grava dezenas de
  arquivos (binários do llama.cpp, units, env) e o sistema foi desligado logo
  depois — num teste de VM, o `iso/test-vm.sh` matava o qemu assim que via o
  marcador; num servidor real, uma queda de energia faz o mesmo. Um **unit com
  0 byte** é interpretado pelo systemd como *masked* (é assim que se mascara
  um serviço), o que torna o sintoma especialmente confuso.
- **Solução (já no código):** o `firstboot.sh` faz `sync` **antes** de remover
  a sentinela (o status precisa estar durável antes de "marcar como feito") e o
  `test-vm.sh` espera 15 s antes de encerrar o qemu.
- **Se aconteceu com você:** rode o build de novo, que é idempotente:
  `sudo bash /opt/ai-cpu-os/build.sh --role auto --family auto --yes`.
  Se `llama-server` estiver com 0 byte, apague o build antes
  (`sudo rm -rf /opt/llama.cpp/build`) — arquivos `.o` de 0 byte fazem o `make`
  achar que está tudo compilado e só o **link** falha, com
  `undefined reference to 'main'`.
- **Teste que guarda isso:** `make ci-guards-test` (exige o `sync` no
  `firstboot.sh` e a espera no `test-vm.sh`).

### `shell-ia.py` responde `RESULT: …` ou `ERRO: ferramenta desconhecida`

- **Sintoma:** ao usar o shell-IA com um modelo pequeno, a resposta final é
  literalmente `RESULT: factorial` + `ERRO: ferramenta desconhecida: factorial`,
  em vez de uma resposta em português.
- **Causa (duas, ambas corrigidas):** (1) ao esgotar as rodadas de ferramentas,
  o código devolvia `messages[-1]` — que é a linha do **protocolo**, não a
  resposta do modelo; (2) o log dizia "ferramenta 'X' executada" **mesmo quando
  X não existia**, e a mensagem de erro não listava as ferramentas válidas, o
  que fazia um modelo pequeno repetir o nome inventado até esgotar as rodadas.
- **Solução (já no código):** ao esgotar, o script pede uma resposta final em
  texto (`Limite de ferramentas atingido. Responda … SEM emitir TOOL`); nome
  inválido gera `warn` e a mensagem lista as ferramentas reais.
- **Nota:** um modelo de 1,5B ainda **inventa** nomes de ferramenta com
  frequência. Se acontecer muito, use um modelo maior — isso não é bug do
  script.
- **Teste que guarda isso:** `make ci-guards-test`.

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
