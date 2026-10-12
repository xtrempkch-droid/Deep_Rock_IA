# ISO — A imagem de instalação do ai-cpu-os (entregável final)

> **Última atualização:** 2026-10-12
>
> **Este é o objetivo final do projeto:** uma **ISO de instalação** de um
> sistema operacional que já traz o ai-cpu-os embutido — insert → instala → o
> sistema nasce afinado para inferência de LLM em CPU.
>
> Implementado por [`iso/build-iso.sh`](../iso/build-iso.sh). Estado (o que foi
> testado e o que **não** foi): [`docs/STATE.md`](STATE.md).
>
> **Duas bases de SO** (`--distro`):
>
> | `--distro` | Base | Instalador | Config | Status |
> |---|---|---|---|---|
> | `ubuntu` **(padrão)** | Ubuntu Server live | Subiquity/autoinstall | `autoinstall.yaml` na raiz da ISO | ⚠️ escrito, **nunca executado** |
> | `debian` (legado) | Debian netinst | debian-installer | `preseed/ai-cpu-os.cfg` | ⚠️ escrito, `--dry-run` validado, **nunca executado** |

---

## 1. Por que uma ISO é o fim do projeto

O `ai-cpu-os` começou como um conjunto de scripts ("clone e rode `build.sh`").
Isso exige que o operador saiba: instalar um SO mínimo, clonar, rodar
com o papel certo, entender os avisos. A ISO elimina essa etapa — **o
sistema já nasce pronto**:

| Sem a ISO | Com a ISO |
|-----------|-----------|
| Instalar o SO manualmente | Dá boot na ISO |
| Responder o instalador | Instalação automática (autoinstall/preseed) |
| Clonar o repositório | Projeto já está em `/opt/ai-cpu-os` |
| Rodar `build.sh` à mão | Aplicado automaticamente no 1º boot |
| Ter o `.gguf` do lado | Idem (o modelo é baixado/fornecido depois) |

O ganho real: **reprodutibilidade**. Duas máquinas instaladas com a mesma ISO
ficam idênticas (mesmo que o hardware seja diferente, papel e família são
detectados no primeiro boot).

---

## 2. Fluxo completo (do build da ISO ao sistema afinado)

```text
 [1] MÁQUINA DE BUILD (qualquer Debian/Ubuntu com xorriso + curl)
      │
      │  sudo iso/build-iso.sh --distro ubuntu --disk /dev/nvme0n1
      │
      ├─ descobre a ISO oficial da versão atual + baixa o SHA256SUMS
      ├─ baixa e VERIFICA a ISO oficial
      ├─ injeta: /ai-cpu-os/            ← o projeto inteiro
      │          /autoinstall.yaml      ← respostas automáticas (Ubuntu)   [ou]
      │          /preseed/ai-cpu-os.cfg ← respostas automáticas (Debian)
      │          /preseed/late-command.sh    ← copia o projeto no alvo
      │          /preseed/firstboot.sh       ← aplica as mods no 1º boot
      │          /preseed/ai-cpu-os-firstboot.service
      ├─ ajusta o boot p/ instalar sem perguntar nada
      │    ubuntu: entrada GRUB 'ai-cpu-os-auto' com o parâmetro `autoinstall`
      │            (setores de boot originais PRESERVADOS via -indev/-outdev)
      │    debian: label isolinux + grub.cfg do UEFI (preseed/file=…)
      └─ remonta a ISO (BIOS + UEFI)
      ▼
 [2] ISO  ai-cpu-os-<distro>-<data>.iso   (~2,7 GB Ubuntu / ~700 MB Debian)
      │
      │  (gravada em pendrive: dd, ou montada numa VM)
      ▼
 [3] MÁQUINA ALVO — INSTALAÇÃO
      │  boot → GRUB/isolinux → entrada "ai-cpu-os-auto"
      │  → instalador lê a config automática → instala SEM PERGUNTAR
      │  → late-command copia /ai-cpu-os → /target/opt/ai-cpu-os
      │  → habilita ai-cpu-os-firstboot.service (sentinela .firstboot-pending)
      ▼
 [4] PRIMEIRO BOOT  ← o hardware real está aqui, é agora que detectamos
      │  ai-cpu-os-firstboot.service roda:
      │    wait_for_network
      │    build.sh --role <gravado na ISO, padrão auto> --family <padrão auto> --yes
      │       ├─ detect-hardware.sh   → FAMILY= e ROLE= (+ alerta de canais)
      │       ├─ mods/ (--set system) → sysctl, THP, governor, C-states
      │       └─ roles/<papel>/      → llama.cpp + serviço (ou Docker/Gitea)
      │    grava .firstboot-status, remove a sentinela, (opcional) reinicia
      ▼
 [5] SISTEMA PRONTO
        inference: llama-server + shell-ia.py
        builder  : Docker + registry :5000 + Gitea :3000
```

---

## 3. 🔑 Decisão central: por que aplicar no **primeiro boot** (e não no `late_command`)?

Esta é a decisão de design mais importante da ISO, e ela é deliberada.

Na hora em que o `late_command` (Debian) ou o `late-commands:` (Ubuntu) roda,
estamos **dentro do ambiente do instalador**, com o sistema alvo montado em
`/target` — mas **o sistema alvo não está em execução**. As consequências:

| Problema | Detalhe |
|----------|---------|
| **Não há systemd ativo no alvo** | `systemctl enable/start` e o tuning de kernel não têm para onde se aplicar. Fazer isso num chroot é frágil e não reflete o estado real. |
| **Não há kernel do alvo rodando** | C-states (cmdline), governor e huge pages são propriedades do kernel que vai bootar — não do kernel do instalador. |
| **O hardware real seria mal detectado** | Em VM ou com drivers limitados do instalador, `detect-hardware.sh` pode não ver os canais de memória (depende de `dmidecode`/SMBIOS) nem a ISA corretamente. |
| **Compilar o llama.cpp levaria 20+ min** | E um erro no meio deixaria a instalação num estado ambíguo, com o instalador ainda "no controle". |
| **Falha silenciosa** | Um `failure` no late-command não invalida a instalação — o usuário ficaria com um sistema "meio configurado" sem saber. |

Aplicando no **primeiro boot**, ganhamos:

1. **O hardware certo.** `detect-hardware.sh` roda no sistema instalado, com
   o SMBIOS completo → detecta canais de memória, ISA, **família** e **papel**
   corretos.
2. **Uma ISO serve para os dois sistemas.** Como os padrões são `--role auto`
   e `--family auto`, a **mesma** ISO se adapta ao Xeon (llama.cpp) e ao Ryzen
   (Docker/registry/Gitea). Isso é possível justamente porque a decisão é
   adiada para o boot real.
3. **Estado observável.** O primeiro boot tem log próprio
   (`/var/log/ai-cpu-os-firstboot.log`), status em `.firstboot-status` e um
   serviço systemd visível — dá para **ver** o que aconteceu, e repetir.
4. **Falha recuperável.** Se não houver rede, a sentinela é mantida e a
   aplicação **se repete no próximo boot** — em vez de deixar o sistema pela metade.

> **Resumo:** a ISO entrega o *software e a intenção* (papel + família);
> o primeiro boot entrega o *contexto* (o hardware). Cada um faz o que sabe fazer.

---

### 3.1 Decisões firmadas: **air-gapped** e **compilar no 1º boot** (sessão #14)

Duas decisões tomadas explicitamente, e elas estão **acopladas** — uma implica a
outra. Ambas já estão registradas no `JOURNAL.md` § 5.3.

**① A ISO deve funcionar SEM internet (air-gapped).**

Motivo: a máquina alvo pode estar numa rede isolada — ou sem rede nenhuma. A
ISO precisa estar pronta para isso. Não é "funciona se houver rede": é
"**funciona porque não precisa**".

**② O llama.cpp é COMPILADO no 1º boot — nunca um binário pré-compilado.**

Mesmo sendo mais demorado. As razões não são estéticas:

| Razão | Detalhe |
|-------|---------|
| **O binário nasce para a máquina certa** | Compilando **no alvo**, o `-march` vem da família realmente detectada. Desaparece o risco de `SIGILL` e a necessidade do compromisso de "portabilidade" (§ 4.1 do `README.technical.md`). |
| **O fonte é pinado e auditável** | A ISO carrega um tarball de uma versão específica; o que será compilado é exatamente o que está na mídia. Nada muda no meio da instalação, e nada vem da rede sem aviso. |
| **Uma ISO serve para TODAS as famílias** | Um binário pré-compilado exigiria **uma ISO por família** — e reintroduziria justamente o problema de portabilidade que o projeto combate. |
| **Coerente com a decisão do § 3** | Se o tuning já é adiado para o 1º boot, compilar no mesmo momento é a mesma lógica: fazer cada coisa onde existe a informação. |

**O que o air-gapped exige — e o estado de CADA item:**

| # | Requisito | Como | Estado |
|---|-----------|------|--------|
| 1 | Fonte do llama.cpp **na mídia** | `llama-build.sh --source <tar.gz>` (não usa rede nem `git`) | ✅ **implementado** |
| 2 | Nenhum `git clone` no 1º boot | `--iso-source auto\|<tarball>\|none` embute o tarball do llama.cpp; o late-command o leva a `/opt/llama-src.tar.gz`, o `firstboot.sh` exporta `AI_LLAMA_SOURCE` e o `llama-build.sh` compila **do tarball** (sem `git`, sem rede) | ✅ **implementado** |
| 3 | Toolchain de build **na mídia** | `--iso-repo auto` monta um repositório apt local (índice `Packages.gz` gerado com `dpkg-deb`), adicionado como fonte **extra** | ✅ **implementado** |
| 4 | Pacotes do instalador **na mídia** | O mesmo repositório cobre o `packages:` do autoinstall/preseed | ✅ **implementado** |
| 5 | **Modelo** na mídia | `--iso-model auto\|<caminho>\|none` embute o `.gguf`; o late-command copia para `/opt/models` e o 1º boot usa via `AI_MODEL_FILE` | ✅ **implementado** |
| 6 | O sistema saber que está offline | `OFFLINE=1` no `.iso-config` | ❌ **descartado** (ver nota) |

> ℹ️ **Sobre o item 6:** ele era "o sistema precisa saber que está offline". Com o
> repositório na mídia, o modo `--offline` deixou de ter função: nada é baixado e
> nada precisa saber disso. Se um dia voltar a fazer sentido, é uma flag no
> `build.sh`, não um requisito da ISO.

**Orçamento de mídia:** acordado em **até 8 GB**. Composição estimada:

| Parte | Tamanho |
|-------|---------|
| ISO base do Ubuntu Server | ~2,6 GB |
| Modelo `.gguf` (Qwen2.5-Coder-1.5B Q4_K_M) | ~1,1 GB |
| Repositório apt (toolchain + deps dos papéis) | ~300–600 MB |
| Fonte do llama.cpp (tarball) | ~30–50 MB |
| Projeto + config | < 5 MB |
| **Total** | **~4,3–5 GB** |

O build **avisa** se o repositório passar de 6 GB, mas não bloqueia: quem decide
o tamanho é você. Nenhuma ISO foi gerada, então todos estes números são
estimativas.

**A decisão sobre o modelo (item 5) foi tomada:** ele **vai na mídia**. O custo
de ~1 GB é aceito em troca de uma ISO que funciona sozinha; a alternativa
(modelo por pendrive) obrigaria um passo manual depois da instalação. A mesma
lógica vale para os pacotes do item 3/4: dentro de um orçamento de 8 GB, ~500 MB
de `.deb` é o preço de uma instalação que não pede internet.

**Por que o repositório local entra como fonte EXTRA (e não como `primary`):**

| Se fosse `primary` | Sendo fonte extra |
|--------------------|-------------------|
| O `sources.list` do sistema **instalado** apontaria para `file:///cdrom/...`, que deixa de existir quando a mídia sai — `apt update` quebrado no dia a dia. | O `primary` continua sendo o arquivo oficial: o alvo nasce com a configuração normal. |
| Um repositório **incompleto** aborta a instalação. | Um repositório incompleto **degrada** (usa a rede, se houver) em vez de quebrar. |

A linha da fonte extra é removida do alvo no `late-command.sh` (ela morreria de
qualquer forma), preservando o espelho oficial.

> ✅ **Os 5 requisitos estão implementados.** O único passo que ainda usava rede
> era o `git clone` do llama.cpp no 1º boot — era o mais demorado. Com o tarball
> na mídia, o **primeiro boot inteiro roda sem internet**: pacotes do repositório
> local, modelo em `/opt/models`, fonte em `/opt/llama-src.tar.gz`.
>
> ⚠️ **Um valor DEFAULT não pode quebrar o build.** Decisão registrada na
> sessão #18: `--iso-repo` nasce `auto`, então qualquer pedido que não possa ser
> atendido **degrada com aviso** em vez de abortar — a ISO continua válida. Erro
> fatal fica reservado para **entrada do usuário** (`--iso-repo DIR` inexistente
> ou sem `.deb`), que é corrigível.
>
> ⚠️ **Honestidade sobre o que foi provado.** O que está **verificado de verdade**:
> o índice gerado é **aceito pelo próprio `apt`** (foi rodado `apt-get update`
> contra um repositório montado pelo código do projeto, com resolução de
> dependência entre dois pacotes de teste), o autoteste de templates passa nos
> dois casos (com e sem repositório), e o `verify-iso.sh` **reprova** os cinco
> modos de falha testados (índice corrompido, `.deb` ausente, `.deb` que é HTML
> de erro, repo sem fonte no autoinstall, fonte no autoinstall sem repo).
>
> A **corrente da fonte foi exercitada de ponta a ponta** num sandbox: o
> `late-command.sh` **real** (com os caminhos redirecionados) copiou o tarball
> para `/opt/llama-src.tar.gz` e gravou `LLAMA_SRC=` no `.iso-config`; e o
> `llama-build.sh` **real**, com `AI_LLAMA_SOURCE` no ambiente, compilou do
> tarball e registrou no manifesto `llama.cpp: tarball local llama-src.tar.gz` /
> `Rede: não usada (fonte local)` — e, **sem** a variável, voltou a clonar
> (provando que o comportamento offline é causado por ela, não por acaso).
> O verificador reprova tarball truncado, tarball sem `CMakeLists.txt` e tarball
> sem `ggml/`. **O que continua não provado:** nada disso aconteceu num boot
> real — os scripts rodaram num sandbox com o sistema de arquivos redirecionado.
> O que **não** foi provado: **nenhuma ISO foi gerada nem bootada**, então os
> pontos que dependem do Subiquity/debian-installer (aceitar a seção `sources`,
> montar a mídia em `/cdrom`, `apt-setup/local0/*`) são **suposições
> documentadas**, com o sintoma de falha anotado abaixo. Ver § 6.
>
> ℹ️ **O CI consegue gerar a ISO de verdade** (tem `xorriso`): o workflow `iso`
> baixa a ISO base, remasteriza e roda o `verify-iso.sh` no fim. Mas há um limite
> prático: o GitHub **recusa arquivo de Release acima de 2 GiB**, e uma ISO com
> modelo + repositório fica em ~4,3–5 GB. Por isso o padrão do CI é a ISO leve
> (`air_gapped: false`) e o workflow **pula o upload** avisando quando a ISO
> passa do limite. A ISO air-gapped completa é para ser gerada na sua máquina.

> 💡 **Sintoma para procurar no primeiro teste em VM:** se o instalador reclamar
> de **assinatura** ou não achar o repositório, o problema é a fonte extra (a
> linha `deb [trusted=yes] file:///cdrom/apt-repo ./`). Se ele instalar tudo mas
> ainda pedir rede, o repositório está incompleto — aumente a lista com
> `--iso-repo-packages`.

**Requisito importante para gerar o repositório:** os `.deb` precisam ser da
**mesma release** da ISO (o build **recusa** se não for, comparando o codename de
`/etc/os-release` com o da URL da ISO). Baixar de outra release produz versões
que não casam com a base e a instalação quebra. Na prática: rode o build numa
máquina da mesma release da ISO (ou numa VM dela), ou passe
`--iso-repo CAMINHO` com `.deb` já baixados corretamente.

---

## 4. Como gerar a ISO

> **Dependências:** veja a lista completa em § 4.7 (o que é obrigatório, o que só
o Debian precisa e o que é só para o teste de VM).

### 4.2 Primeiro: simular (sempre)

```bash
bash iso/build-iso.sh --distro ubuntu --disk /dev/nvme0n1 --dry-run
```

### 4.3 Gerar de verdade

```bash
sudo bash iso/build-iso.sh --distro ubuntu --disk /dev/nvme0n1

# legado (Debian netinst + preseed)
sudo bash iso/build-iso.sh --distro debian --disk /dev/nvme0n1
```

> ⚠️ **`--disk` é o disco que será APAGADO** na máquina onde a ISO for
> instalada. Fixá-lo evita o pior cenário (instalar no disco errado). Se você
> não passar `--disk`, é preciso aceitar explicitamente com `--allow-any-disk`.

Opções mais usadas:

| Opção | Para que serve |
|-------|----------------|
| `--distro ubuntu` | Base do SO: `ubuntu` (padrão, autoinstall) ou `debian` (preseed). |
| `--role auto` | Papel gravado na ISO. `auto` (padrão) detecta no hardware real. |
| `--family auto` | Família gravada na ISO. `auto` (padrão) detecta no hardware real. |
| `--firstboot-reboot` | Reinicia automaticamente ao fim do primeiro boot (aplica C-states). |
| `--hostname NOME` | Hostname do sistema instalado (padrão: igual ao usuário). |
| `--password-hash '$6$…'` | Senha do usuário (gere com `mkpasswd -m sha-512`). Se omitido, gera e **mostra** uma. |
| `--username NOME` | Usuário administrativo (padrão `ai-cpu-os`; root fica bloqueado). |
| `--iso PATH` | Usa uma ISO local (trabalhar offline). |
| `--out PATH` | Caminho da ISO de saída. |
| `--keep-work` | Mantém o diretório de trabalho para inspeção. |
| `--check-templates` | **Autoteste:** substitui os templates e valida o YAML gerado. Não gera ISO, não precisa de disco nem root (é o `make iso-yaml`). |

#### Como a ISO base é escolhida (e o bug que isso já causou)

O build **não** confia numa URL fixa: baixa o `SHA256SUMS` oficial, escolhe a
entrada e só então baixa a ISO, conferindo o `sha256`.

São **dois** detalhes que só aparecem com o arquivo real na mão, e que já
quebraram a geração da ISO Ubuntu (o build morria com **`exit code 22`** do
`curl` e mais nada — 404 na URL, sem dizer qual):

1. O `SHA256SUMS` do **Ubuntu** marca o modo binário com **`*`** antes do nome
   (`*ubuntu-24.04.5-live-server-amd64.iso`), igual ao `md5sum -b`. O do
   **Debian** não usa marcador. Sem remover o `*`, a URL fica
   `.../24.04/*ubuntu-24.04.5-…iso` → **404**. Era por isso que o caminho
   Debian funcionava e o Ubuntu não.
2. O `SHA256SUMS` do Ubuntu lista **todas** as point releases (24.04.3, .4,
   .5…) e as variantes **desktop/wsl**. Pegar a **primeira** entrada casada
   baixaria a versão mais **velha**.

Hoje: os padrões são **ancorados** (`^ubuntu-[0-9][^ ]*-live-server-amd64[.]iso$`
e `^debian-[0-9][^ ]*-amd64-netinst[.]iso$`, o que exclui `debian-edu-*`,
`debian-mac-*`, `*-desktop-*` e `*-wsl-*`) e a escolha é a de **maior versão**
(`sort -V | tail -1`). Os nomes passam por `normalize_iso_name` (remove `*` e o
prefixo `./`) e há uma checagem final que **falha com mensagem clara** se o nome
não for um nome de arquivo simples — em vez de deixar o `curl` devolver 404.

Quem guarda isso é `make iso-select-test`, que roda as **mesmas funções**
contra `SHA256SUMS` reais em `tests/fixtures/` (sem rede). Ver
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) § "ISO / Remasterização".

### 4.4 Testar numa VM **antes** de qualquer máquina real

```bash
qemu-system-x86_64 -m 4096 -enable-kvm -cdrom iso/out/ai-cpu-os-*.iso -boot d
```

Para um teste completo (instalação automática + primeiro boot), ver
[`docs/VALIDATION.md`](VALIDATION.md) **Bloco M**.

> 💡 Recomendado: `make iso-lint` antes de gerar. Ele roda o autoteste dos
> templates — inclusive validando com `yamllint` o `autoinstall.yaml` **já
> substituído**, que é o único estado em que esse arquivo é YAML de verdade.

### 4.5 Como a variante Ubuntu funciona (e por que assim)

Três decisões que explicam o formato do caminho `--distro ubuntu`:

**a) `autoinstall.yaml` na raiz da ISO, não `nocloud`.** A documentação do
Subiquity oferece dois caminhos: cloud-config via o datasource NoCloud
(`ds=nocloud;s=/cdrom/…`) ou um arquivo `autoinstall.yaml` na própria mídia, no
mesmo diretório que contém `casper/`. Escolhemos o segundo porque ele:

- dispensa o cabeçalho `#cloud-config` e a chave de topo `autoinstall:`;
- dispensa o **escape do `;`** na linha `linux` do GRUB (fonte clássica de ISO
  que "não instala e não explica por quê");
- não depende de datasource nenhum — é o arquivo, lido direto.

**b) Sem a chave de topo `autoinstall:`.** O Subiquity aceita as duas formas,
mas só a forma "sem chave de topo" é válida em **22.04 e 24.04**. É escolha de
compatibilidade entre os dois LTS.

**c) Remontagem por `-indev/-outdev -map`, não por extração + mkisofs.** Em vez
de extrair a árvore e remontar (como o caminho Debian faz), partimos da ISO
oficial e apenas **sobrescrevemos** o que muda: `/boot/grub/grub.cfg`,
`/autoinstall.yaml`, `/preseed/…` e `/ai-cpu-os`. Assim os setores de boot
(El Torito BIOS, imagem EFI e MBR híbrido) ficam **byte a byte** iguais aos do
Ubuntu — sem `mtools`, sem `isohdpfx.bin` e sem o risco de gerar uma ISO que não
boota.

O `md5sum.txt` original fica obsoleto com essas alterações e é **removido** na
remontagem (o Subiquity não o usa no autoinstall).

**d) Tuning sempre no primeiro boot.** O `autoinstall.yaml` traz só o usuário,
o locale, o particionamento e os pacotes; o `late-commands:` chama o MESMO
`iso/preseed/late-command.sh` usado pelo Debian, passando `AI_CURTIN=1` para ele
usar `curtin in-target --` em vez do `in-target` do d-i. Um script, dois
instaladores — ver § 3.

---

### 4.6 Validar a ISO (as duas ferramentas do projeto)

O projeto traz duas ferramentas — e elas cobrem coisas **diferentes**:

| Ferramenta | O que prova | Precisa de |
|---|---|---|
| `iso/verify-iso.sh` | **Conteúdo:** a config está no lugar certo, o projeto foi embutido, não sobrou marcador, o YAML é válido/coerente, a entrada de boot existe | `xorriso` **ou** só uma árvore extraída (`--dir`) |
| `iso/test-vm.sh` | **Comportamento:** a ISO boota, instala sozinha e o primeiro boot aplica o ai-cpu-os | `qemu-system-x86` + `qemu-utils` (+ `/dev/kvm`, recomendado) |

```bash
# Conteúdo (segundos; roda sozinho no fim de todo build)
make iso-verify ISO=iso/out/ai-cpu-os-ubuntu-*.iso DISK=/dev/vda
bash iso/verify-iso.sh --dir iso/work/stage        # árvore extraída, sem xorriso

# Comportamento (10-60 min; é o teste que importa de verdade)
bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-*.iso --yes
```

**Por que `--dir` existe:** o `xorriso` não é obrigatório para verificar, e
assim a mesma checagem roda em qualquer lugar — inclusive no CI, sobre a árvore
que o próprio `build-iso.sh` gera (`make iso-yaml`). Isso é o que torna o
verificador **testável** em vez de "escrito e nunca executado".

**Observação sem tela (`--serial-console`).** Para o `test-vm.sh` enxergar algo,
a ISO precisa mandar o console para serial, tanto na entrada de boot dela quanto
**no sistema instalado** (via um ajuste de GRUB no late-command). Sem isso, a
saída vai para a tela virtual e ninguém a vê. O `test-vm.sh` espera dois
marcadores:

| Marcador | Significa |
|---|---|
| `[ai-cpu-os/iso-late] pós-instalação concluído` | o instalador rodou o late-command e **achou** a config automática |
| `aplicação concluída com sucesso` | o `ai-cpu-os-firstboot` aplicou as mods e instalou o papel |

Se o primeiro marcador não aparecer, o problema é a **config** (rode
`verify-iso.sh`); se o segundo não aparecer, o problema é o **primeiro boot**
(veja se o `console=ttyS0` entrou na cmdline do sistema instalado).

### 4.7 Dependências

```bash
# Obrigatórias
sudo apt install -y xorriso curl coreutils

# Só para --distro debian (boot UEFI dentro de efi.img + boot híbrido via MBR)
sudo apt install -y isolinux mtools

# Só para o teste de VM
sudo apt install -y qemu-system-x86 qemu-utils
sudo apt install -y ovmf     # apenas para --boot-mode uefi
```

> **Rede:** `curl` é usado para baixar a ISO base, o modelo (`--iso-model auto`)
> e os `.deb` do repositório (`--iso-repo auto`). Isso acontece na **máquina que
> gera a ISO** — que pode ter rede. O que a ISO air-gapped garante é que o
> **alvo** não precise dela. Se a máquina de build também estiver offline, use
> `--iso CAMINHO`, `--iso-model CAMINHO` e `--iso-repo DIR`; com
> `--iso-model none --iso-repo none` a ISO sai sem modelo e sem repositório.

> **Release:** `--iso-repo auto` exige que a máquina de build seja da **mesma
> release** da ISO base (o build recusa se não for — ver § 3.1). `dpkg-deb`
> (do pacote `dpkg`) é usado para gerar o índice; não é preciso `dpkg-dev`.

---

## 5. O que a ISO faz com a sua máquina

| Ação | Efeito | Onde desliga |
|------|--------|--------------|
| Particiona o disco | ⚠️ **Apaga** o disco de `--disk` | Não desliga — é o objetivo |
| Cria usuário com sudo | `--username`, senha definida/hash | `--username`, `--password-hash` |
| Bloqueia o root | Ubuntu: root sem senha/login; Debian: `passwd/root-login false` | `autoinstall.yaml` / preseed |
| Instala pacotes base | Ubuntu: `packages:`; Debian: `pkgsel/include` | `--extra-packages` |
| Copia o projeto | `/opt/ai-cpu-os` | — |
| Grava papel e família | `.iso-config` (lidos no 1º boot) | `--role`, `--family` |
| Aplica o tuning no 1º boot | mods `system`: sysctl, THP, governor, C-states | `--skip-mods` no `build.sh` |

**Segurança:** a senha **nunca** é gravada em texto puro na ISO — apenas o
hash crypt (`openssl passwd -6`). No Ubuntu o root não recebe senha (login por
root desabilitado); no Debian o root fica bloqueado por padrão.

---

## 6. Limitações conhecidas (e o que NÃO foi validado)

> Honestidade obrigatória (Regra 6 do [`AGENTS.md`](../AGENTS.md)).

| Item | Situação |
|------|----------|
| **Nenhuma ISO foi construída nem bootada** | ⚠️ **Os dois caminhos estão escritos e passam no autoteste de templates; o Debian foi exercitado em `--dry-run`. Nenhuma ISO real foi gerada, instalada ou bootada.** Requer `xorriso` (ausente no ambiente de desenvolvimento). |
| **Caminho Ubuntu (`--distro ubuntu`)** | ⚠️ Escrito na sessão #10 e validado no autoteste (`autoinstall.yaml` final passa no `yamllint` + verificador) — mas **nunca executado** contra uma ISO real do Ubuntu. |
| **`iso/verify-iso.sh`** | ✅ Exercitado de verdade: roda no `make iso-lint` sobre uma árvore montada com os templates e o projeto **reais**, incluindo um **teste negativo** (reprova quando falta a config). O caminho `--iso` (com xorriso) ainda **não** foi executado. |
| **`iso/test-vm.sh`** | ⚠️ **Nunca executado**: não há `qemu` no ambiente de desenvolvimento. O comando do qemu só foi conferido em `--dry-run`. |
| **`--serial-console`** | ⚠️ Nunca validado num boot real. Se o `console=ttyS0` não entrar na cmdline do sistema instalado, o `test-vm.sh` não verá o primeiro boot (o script avisa exatamente isso). |
| Layout da ISO base | Ubuntu exige `casper/` (recusado com mensagem clara se não existir); Debian exige `isolinux/`. Outras ISOs falham de propósito em vez de gerar algo quebrado. |
| Boot BIOS | Ubuntu: El Torito preservado do original. Debian: `isolinux` + `isohdpfx.bin`. **Não validado.** |
| Boot UEFI | Ubuntu: imagem EFI preservada + patch do `grub.cfg` do UEFI. Debian: **best-effort** (tenta `EFI/*/grub.cfg`; se estiver dentro de `efi.img`, exige `mtools`). **Não validado.** |
| **Rede no 1º boot** | ✅ **Não é mais necessária** (com os padrões de payload ligados): pacotes do repositório local, modelo em `/opt/models` e fonte em `/opt/llama-src.tar.gz` vêm todos da mídia. ⚠️ **Ainda assim, rede é usada se estiver disponível** para atualizar pacotes — e a rede **é obrigatória na máquina que GERA a ISO** (para baixar base, modelo, deps e fonte), ou use `--iso/--iso-model/--iso-repo/--iso-source` com arquivos locais. |
| **Modelo na mídia** | ✅ Implementado: `--iso-model auto|<caminho>|none`. Um `.gguf` inválido é recusado **antes** de montar a ISO (magic `GGUF` + tamanho), e o verificador reprova modelo pequeno na mídia. ⚠️ **Nunca validado num boot real** — o `late-command` nunca copiou um modelo de verdade, e o `firstboot` nunca passou `AI_MODEL_FILE` num sistema instalado. |
| **Repositório apt na mídia** | ✅ Implementado: `--iso-repo auto|<dir>|none` + validação de release. O índice gerado é **aceito pelo `apt`** (testado de verdade, com resolução de dependência) e o `verify-iso.sh` reprova os 5 modos de falha testados. ⚠️ **Não validado no instalador**: que o Subiquity aceite a seção `sources` e que o debian-installer honre `apt-setup/local0/*` são **suposições documentadas** — o primeiro teste em VM deve confirmar. |
| **Fonte do llama.cpp na mídia** | ✅ Implementado: `--iso-source auto|<tarball>|none`. A corrente foi exercitada num sandbox (late-command real copiando + `llama-build.sh` real compilando do tarball, com o manifesto dizendo `Rede: não usada`). ⚠️ **Nunca rodou num boot real.** |
| **Release da ISO × máquina de build** | `--iso-repo auto` só monta o repositório se a release **casar** com a da ISO. Quando não casa (esta máquina é 25.10, a ISO padrão é 24.04), ele **pula o repositório com aviso** e a ISO sai valendo, mas o alvo passa a precisar de rede. Saídas para ter o repo: buildar na release certa, `--iso-url` da sua release, ou `--iso-repo CAMINHO`. |
| Tamanho | ~2,7 GB (Ubuntu) / ~700 MB (Debian) + espaço do projeto. |
| Assinatura | A ISO gerada **não é assinada**. Verifique o SHA256 que o script imprime. |
| `md5sum.txt` | Debian: regenerado. Ubuntu: **removido** (ficaria obsoleto; o Subiquity não o usa). |
| Efeito real das mods na ISO | O autoteste valida a *geração*; que sysctl/governor/C-states **funcionam** no alvo depende do Bloco O de `VALIDATION.md`. |

---

## 7. Alternativas consideradas (e por que não)

| Alternativa | Prós | Por que foi descartada |
|-------------|------|------------------------|
| **simple-cdd** | Integrado ao Debian, gera ISO com preseed | Exige espelho local / baixa muita coisa; menos controle sobre o boot e o `late_command`. Fica na lista para simplificar no futuro. |
| **live-build** | ISO oficial do Debian, live + instalador | Pesado, exige ambiente limpo (chroot) e quebra fácil; `--debian-installer live` é notoriamente chato de scriptar. |
| **Packer** | Fluxo maduro, ótimo p/ nuvem | Produz **imagem de disco/VM**, não uma ISO de instalação. É outro entregável (e está no ROADMAP como ideia). |
| **Cubic** | GUI, simples p/ Ubuntu | Só Ubuntu, **não automatizável** — contraria "tudo por script". |
| **Ubuntu autoinstall (Subiquity)** | Caminho moderno p/ Ubuntu | **Adotado** como base padrão — ver § 4.5. A preocupação original ("mecanismo diferente, via cloud-init") foi resolvida usando `autoinstall.yaml` na mídia em vez de `nocloud`. |
| **FAI (Fully Automatic Installation)** | Muito poderoso | Curva de aprendizado alta e infraestrutura própria; overkill para 2 máquinas. |

**Por que remaster + config automática na mídia:** é o que dá **controle total**
sobre o boot e o pós-instalação, **sem infraestrutura extra** (nenhum servidor,
espelho ou rede especial), e reaproveita a lógica que o projeto já tem
(`detect-hardware.sh` decidindo família e papel). Também mantém a filosofia:
tudo por script, idempotente, auditável.

---

## 8. Roadmap da ISO

| Prioridade | Item |
|-----------|------|
| 🔴 Alta | **Construir e bootar a ISO numa VM** (Bloco M do `VALIDATION.md`) — é o maior risco não validado do projeto. Com as ferramentas de § 4.6 o caminho é `make iso` (com `ISO_ARGS=--serial-console`) → `make iso-verify` → `make iso-vm`. |
| 🔴 Alta | **Rodar o caminho Ubuntu contra uma ISO real**, para achar erro de layout/`xorriso` antes do teste em VM. |
| ✅ Feito | **Os 5 requisitos do § 3.1 estão implementados:** fonte do llama.cpp (`--iso-source`), modelo (`--iso-model`) e repositório apt (`--iso-repo`) na mídia + o caminho offline do papel (`--model-file`). O 1º boot não precisa mais de rede. |
| 🔴 Alta | **Bootar a ISO numa VM** (Bloco M) — é o que falta para declarar o projeto terminado. Não há mais nenhuma pendência de **código** conhecida no caminho da ISO. |
| 🟡 Média | **Confirmar o aceite do instalador** para a fonte extra de apt (seção `sources` / `apt-setup/local0`) — é a única suposição não verificada do caminho offline. Sintoma: erro de assinatura, ou instalar mas pedir rede. |
| 🟡 Média | **Testar o boot UEFI** (`make iso-vm VM_ARGS="--boot-mode uefi"`). |
| 🟢 Baixa | **Testar a ISO no CI:** `validate` pode rodar `verify-iso.sh --dir` sobre a árvore do stage (já roda, via `make iso-yaml`). Um teste de VM no CI exigiria KVM e 30+ min — fica para runner self-hosted. |
| ~~🟡 Média~~ | ~~Variante air-gapped~~ → **decidida e virou requisito** (linha 🔴 Alta acima). O que era "variante" agora é o caminho planejado. |
| ❌ Descartado | **Variante com binário pré-compilado:** usar os `.tar.gz` da Release em vez de compilar no 1º boot. **Descartado na sessão #14** — seria mais rápido, mas exigiria uma ISO por família e reintroduziria o risco de portabilidade. Ver § 3.1. |
| 💡 Ideia | **Assinatura da ISO** com `gpg` + publicação do SHA256 no release. |
| 💡 Ideia | **Imagem de VM (qcow2)** via Packer, derivada da mesma lógica. |

---

## 9. Fechando a ISO: o checklist

A ISO tem **duas provas distintas** (ver o § 1.2 do `README.technical.md`) e
elas se concluem em lugares diferentes. Este é o caminho, na ordem, com o
que cada passo **prova** e onde ele roda.

| # | Passo | Onde | Prova |
|---|-------|------|-------|
| 0 | `make validate` | qualquer máquina | que os scripts não têm erro de sintaxe/lint e que o corpus de CPUs casa |
| 1 | `make iso-yaml` | qualquer máquina | que os templates substituídos são YAML/preseed válidos e que o verificador **sabe reprovar** (teste negativo) |
| 2 | `make iso-dry-run ISO_ARGS="--iso-source auto --iso-model auto --iso-repo auto"` | qualquer máquina | que a orquestração inteira acontece, sem baixar nada |
| 3 | **Gerar a ISO** (`make iso DISK=…` ou o workflow `iso` com `air_gapped: true`) | máquina com `xorriso` + rede | ⭐ que a ISO **existe** e que o `verify-iso.sh` aprova o conteúdo dela **de verdade** (inclusive rodando `xorriso` para dentro) |
| 4 | **Bootar e instalar em VM** (`make iso-vm`) | máquina com `qemu` + KVM | ⭐⭐ o **comportamento**: instala sozinho e o 1º boot aplica |
| 5 | Aplicar em hardware real | Xeon / Ryzen | desempenho e o efeito dos ajustes (Blocos A–P do `VALIDATION.md`) |

**Os passos 0–2 não provam nada sobre a ISO existir.** São baratos e pegam
regressão cedo, mas a ISO pode estar quebrada com eles verdes. Só o passo 3
cria o artefato, e só o passo 4 diz se ele **funciona**.

### 9.1 O passo 3 nesta máquina não roda (e o CI resolve)

O ambiente de desenvolvimento não tem `xorriso` nem `qemu`, e tem só 2
núcleos. Por isso o **GitHub Actions é o caminho prático** para o passo 3:

```bash
# No site do repositório: Actions → iso → Run workflow
#   distro: ubuntu (padrão) · role/family: auto · disk: /dev/vda
#   air_gapped: true   ← para provar o caminho offline completo
```

O que o workflow faz: baixa a ISO base → instala `xorriso` → roda
`make iso-lint` → `make iso-dry-run` → **gera a ISO** → o próprio build roda
o `verify-iso.sh` → mede o tamanho → publica o resumo (com os WARN).

> 🔴 **Limite que muda o plano: 2 GiB por arquivo de Release.** O GitHub
> **recusa** anexar um arquivo maior que isso a uma Release, e uma ISO com
> modelo + repositório fica em ~4,3–5 GB. Consequências:
>
> * o padrão do workflow é `air_gapped: false` (ISO leve, ~2,7 GB);
> * com `air_gapped: true`, o CI **prova o caminho completo** (o
>   `verify-iso.sh` roda sobre a ISO real) mas **pula o upload**, com aviso
>   no resumo — não adianta esperar download;
> * a **ISO air-gapped completa é para ser gerada na sua máquina** e levada
>   por pendrive/`scp`.
>
> Isso não é uma limitação do projeto: é do canal de distribuição. Se um dia
> fizer falta publicar, os caminhos são um runner self-hosted (o artefato
> fica na sua infraestrutura) ou publicar a ISO em outro lugar e guardar só
> o SHA256 na Release.

### 9.2 O passo 4 precisa de qemu — e o que olhar

```bash
sudo apt install -y qemu-system-x86 qemu-utils   # + ovmf para UEFI
make iso-vm ISO=iso/out/ai-cpu-os-ubuntu-<data>.iso
```
Gere a ISO com `--serial-console`: é o que faz o `test-vm.sh` **ver** a
instalação e o primeiro boot (ele julga por marcadores no console serial).
Sem essa flag, o teste headless não enxerga nada — e o script avisa.

Os dois marcadores que provam o sucesso são:
`[ai-cpu-os/iso-late] pós-instalação concluído` (o instalador **achou** a
config) e `aplicação concluída com sucesso` (o 1º boot **aplicou**).

### 9.3 Se o passo 4 falhar, o que cada sintoma significa

| Sintoma na VM | Onde olhar |
|---------------|------------|
| O instalador faz perguntas | a config não chegou na ISO, ou o menu não a escolheu → `make iso-verify` |
| Erro de **assinatura** de pacote | a fonte extra de apt (seção `sources` / `apt-setup/local0`) → § 3.1 |
| Instala, mas o 1º boot pede rede | repositório incompleto → aumente `--iso-repo-packages` |
| 1º boot trava/demora muito | é a compilação do llama.cpp; confira `/var/log/ai-cpu-os-firstboot.log` |
| O `test-vm.sh` não vê nada do 1º boot | a ISO foi gerada **sem** `--serial-console` |
| Sobra de marcador `@@TOKEN@@` | bug no `build-iso.sh` → rode `make iso-verify` |

### 9.4 Antes de considerar a ISO "fechada"

- [ ] `make validate` verde (local ou no CI)
- [ ] ISO **gerada** (passo 3) — não basta o dry-run
- [ ] `verify-iso.sh` aprovado sobre a ISO real (o build já roda)
- [ ] ISO **bootada e instalada** numa VM (passo 4) — é o critério de conclusão
- [ ] 1º boot aplicado, com `systemctl status ai-cpu-os-firstboot` e o log limpos
- [ ] O **tamanho** e o **SHA256** anotados em `docs/STATE.md`
- [ ] Sessão registrada no `docs/JOURNAL.md`

> ⚠️ **A Regra 13 do `AGENTS.md` é explícita:** não declare a ISO pronta sem
> tê-la bootado e instalado em VM. Verificação de conteúdo **não** substitui
> boot.

---

## 10. Histórico

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação: `iso/build-iso.sh` + preseed + serviço de primeiro boot + este documento. Nada executado em ambiente real ainda. |
| 2026-10-12 | **Variante Ubuntu (autoinstall/Subiquity) adicionada como base padrão** (`--distro ubuntu`), com `iso/autoinstall/autoinstall.yaml`, remontagem por `-indev/-outdev -map` (setores de boot preservados), `late-command.sh` compartilhado entre os dois instaladores (`AI_CURTIN=1`), flags `--role`/`--family` no lugar de `--profile` e autoteste de templates (`--check-templates` / `make iso-yaml`) rodando no CI. **Continuamos sem ter construído nem bootado nenhuma ISO.** |
| 2026-10-12 | **Ferramentas de validação:** `iso/verify-iso.sh` (conteúdo, com modo `--dir` sem xorriso) e `iso/test-vm.sh` (boot real em qemu, com marcadores no console serial). `--serial-console` torna a instalação e o 1º boot observáveis sem tela. O build agora **verifica a ISO ao final** e o `make iso-yaml` roda o verificador **incluindo um teste negativo** (verificador que nunca falha não vale nada). |
| 2026-10-12 | **Decidido: ISO air-gapped + compilar no 1º boot (nunca binário pré-colado).** Ver § 3.1. Primeiro passo implementado: `llama-build.sh --source <dir|tar.gz>` compila de um fonte **local** sem rede e sem `git` (substitui o `git clone`), registrando a origem em `AI-CPU-OS-BUILD.txt`. O restante (repo apt local, `--offline` no `build-iso.sh`, política do modelo) segue como plano. **Nada disso foi exercitado numa ISO real.** |
| 2026-10-12 | **O modelo vai na mídia** (decisão: ~1 GB de mídia é preço justo por uma ISO que se basta). Implementado `--iso-model auto\|<caminho>\|none` no `build-iso.sh` (com validação de magic `GGUF` e de tamanho antes de montar a ISO), cópia para `/opt/models` no `late-command.sh`, `MODEL_FILE` no `.iso-config`, `AI_MODEL_FILE` no `firstboot.sh` e **`--model-file` no papel `inference`** (instala um `.gguf` local sem rede — inclusive conferindo o magic). O `verify-iso.sh` passou a checar a corrente toda e a reprovar modelo inválido/pequeno. Guardas no CI, inclusive **negativos** (nada de `--prebuilt`; nada de `COPY build/bin`). **Nenhuma ISO gerada; nenhum boot real.** |
| 2026-10-12 | **A fonte do llama.cpp vai na mídia** (`--iso-source auto\|<tarball>\|none`): fecha o **último** passo que exigia rede no 1º boot, e o mais demorado. A corrente **late-command → `LLAMA_SRC` → `firstboot` → `AI_LLAMA_SOURCE` → `llama-build.sh`** foi exercitada ponta a ponta num sandbox (manifesto: `Rede: não usada`). Novo § 9 "Fechando a ISO" com o checklist e o achado do **limite de 2 GiB por arquivo de Release** (que muda o que o CI pode publicar). **Nenhuma ISO gerada; nenhum boot real.** |
| 2026-10-12 | **O repositório apt vai na mídia** (orçamento de 8 GB acordado). `--iso-repo auto\|DIR\|none` baixa os `.deb` (pacotes + fecho de dependências, sem recomendados), gera o índice com `dpkg-deb` (**sem depender do `dpkg-dev`**) e o embute em `/apt-repo`; a fonte entra como **extra** (seção `sources` do curtin no Ubuntu; `apt-setup/local0/*` no Debian) para o `primary` continuar sendo o arquivo oficial e o alvo nascer com a configuração normal. O build **recusa** repositório de outra release. O `verify-iso.sh` ganhou a seção do repositório: índice legível, todo `.deb` do índice presente na mídia, magic `!<arch>` e coerência entre mídia e configuração. **Prova real:** o `apt` do sistema aceitou um repositório montado pelo código do projeto e resolveu a dependência. **Nenhuma ISO gerada; nenhum boot real.** |
