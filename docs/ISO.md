# ISO — A imagem de instalação do ai-cpu-os (entregável final)

> **Última atualização:** 2026-10-20 (sessão #42)
>
> **Este é o objetivo final do projeto:** uma **ISO de instalação** de um
> sistema operacional que já traz o ai-cpu-os embutido — insert → instala → o
> sistema nasce afinado para inferência de LLM em CPU.
>
> Implementado por [`iso/build-iso.sh`](../iso/build-iso.sh). Estado (o que foi
> testado e o que **não** foi): [`docs/STATE.md`](STATE.md).
>
> **Base ÚNICA: Ubuntu Server** (ADR-001 em [`docs/DECISIONS.md`](DECISIONS.md)).
> O caminho **Debian/preseed foi REMOVIDO** na sessão #42: `--distro debian`
> **aborta** com exit 2 citando o ADR, e o diretório `iso/preseed/` não existe
> mais (os scripts do instalador moram em `iso/common/`).
>
> | `--distro` | Base | Instalador | Config | Status |
> |---|---|---|---|---|
> | `ubuntu` **(o único)** | Ubuntu Server live | Subiquity/autoinstall | `autoinstall.yaml` na raiz da ISO | ✅ gerada, instalada e bootada em VM (#21); **hardware físico ainda pendente** |
> | `debian` | — | — | — | ❌ **removido** (ADR-001); existiu até a sessão #41 e chegou a ser instalado em VM (#35) e em metal (#37) |
>
> ⚠️ **Em transição (planejado, ainda não implementado):** identidade do
> sistema derivada do papel (ADR-002: `ai-inference`/`ai-builder`) e chat da
> frota **`ai-talk`** (ADR-003, contrato em [`docs/CHAT.md`](CHAT.md)).
> ⚠️ **Após a remoção do caminho Debian, nenhuma ISO foi gerada nem bootada** —
> as provas de comportamento (#21/#35/#37) são anteriores a ela.

---

## 1. Por que uma ISO é o fim do projeto

O `ai-cpu-os` começou como um conjunto de scripts ("clone e rode `build.sh`").
Isso exige que o operador saiba: instalar um SO mínimo, clonar, rodar
com o papel certo, entender os avisos. A ISO elimina essa etapa — **o
sistema já nasce pronto**:

| Sem a ISO | Com a ISO |
|-----------|-----------|
| Instalar o SO manualmente | Dá boot na ISO |
| Responder o instalador | Instalação automática (autoinstall) |
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
      │          /autoinstall.yaml      ← respostas automáticas (Subiquity)
      │          /ai-cpu-os-boot/late-command.sh  ← copia o projeto no alvo
      │          /ai-cpu-os-boot/firstboot.sh     ← aplica as mods no 1º boot
      │          /ai-cpu-os-boot/ai-cpu-os-firstboot.service
      │          /ai-cpu-os-boot/ai-cpu-os-netplan.yaml  ← rede do alvo
      ├─ ajusta o boot p/ instalar sem perguntar nada
      │    entrada GRUB 'ai-cpu-os-auto' com o parâmetro `autoinstall`
      │    (setores de boot originais PRESERVADOS via -indev/-outdev)
      └─ remonta a ISO (BIOS + UEFI)
      ▼
 [2] ISO  ai-cpu-os-ubuntu-<data>.iso   (~2,7 GB)
      │
      │  (gravada em pendrive: dd, ou montada numa VM)
      ▼
 [3] MÁQUINA ALVO — INSTALAÇÃO
      │  boot → GRUB → entrada "ai-cpu-os-auto"
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

Na hora em que o `late-commands:` do autoinstall roda,
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
| 3 | Toolchain de build **na mídia** | `--iso-repo auto` monta um repositório apt local (índice `Packages.gz` + `Release` gerados com `dpkg-deb`), que o **late-command carrega para o alvo** em `/opt/apt-repo` | ✅ **implementado e bootado** |
| 4 | Pacotes do instalador **na mídia** | O mesmo repositório, carregado ao alvo — o 1º boot instala sem rede | ✅ **implementado e bootado** |
| 5 | **Modelo** na mídia | `--iso-model auto\|<caminho>\|none` embute o `.gguf`; o late-command copia para `/opt/models` e o 1º boot usa via `AI_MODEL_FILE` | ✅ **implementado** |
| 6 | O sistema saber que está offline | `OFFLINE=1` no `.iso-config` | ❌ **descartado** (ver nota) |
| 7 | **Chat da frota** `ai-talk` (planejado) | `talk/` vai na ISO (stdlib, sem download); chave/peers decididos na geração ou depois, localmente | ❌ **só desenho** (ADR-003/`docs/CHAT.md`) |

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

**Como o repositório local é usado (MUDOU na sessão #21 — era BUG):**

A ideia original era declarar o repositório como fonte **extra** do curtin
(seção `sources` do autoinstall). **Isso não funciona.** Ao bootar a ISO de
verdade, o curtin roda `apt-get update` **dentro de um chroot no alvo**, onde
**`/cdrom` não está montado** — então `file:///cdrom/apt-repo` é inalcançável e
o `apt-config` **aborta** com exit 100 ("does not have a Release file"). O
repositório **estava** na mídia (com `Release`), mas o chroot não o via.

Correção adotada: o **late-command.sh** copia o repositório da mídia para o
**alvo** (`/opt/apt-repo`) e grava a fonte lá
(`/etc/apt/sources.list.d/ai-cpu-os-local.list`). Assim:

| Antes (bug) | Agora |
|-------------|-------|
| Fonte no apt do **instalador** (`file:///cdrom/...`), invisível no chroot → `apt-config` falha | Repo no **alvo** (`/opt/apt-repo`); o apt do instalador **não** o usa, e o instalador usa a rede (degradando, como planejado) |
| O alvo nascia com uma fonte que morreria (mídia removida) | O alvo carrega o repo no disco — **o 1º boot instala sem rede**, e o `apt` funciona depois |
| --- | O índice ganhou um arquivo **`Release`** (o apt exige, mesmo em repo flat vindo da mídia) |

O `primary` continua sendo o espelho oficial (o alvo nasce com a configuração
normal; com rede, ele também funciona).

> ✅ **Os 5 requisitos estão implementados E o caminho foi bootado (sessão #21).**
> O 1º boot inteiro rodou **sem rede**: o llama.cpp compilou do tarball da mídia,
> o modelo veio de `/opt/models` e o repositório de `/opt/apt-repo`.
>
> ⚠️ **Um valor DEFAULT não pode quebrar o build.** Decisão registrada na
> sessão #18: `--iso-repo` nasce `auto`, então qualquer pedido que não possa ser
> atendido **degrada com aviso** em vez de abortar — a ISO continua válida. Erro
> fatal fica reservado para **entrada do usuário** (`--iso-repo DIR` inexistente
> ou sem `.deb`), que é corrigível.
>
> ⚠️ **Honestidade sobre o que foi provado.** Gerada e **bootada em VM**
> (sessão #21): `verify-iso.sh` **PASS=41/FAIL=0**; `test-vm.sh` **exit 0** (a
> ISO bootou, instalou sozinha e o 1º boot aplicou o ai-cpu-os). **O que
> continua NÃO provado:** o **boot UEFI**, o hardware físico com **Ubuntu** e
> os Blocos A–O do `VALIDATION.md`. O caminho **Debian/preseed** foi executado
> em VM (#35) e em metal (#37) **antes** de ser **removido** (ADR-001, sessão
> #42) — não é mais uma pendência. Resta também um resíduo do air-gapped em
> investigação (§ 6).
>
> ℹ️ **O CI consegue gerar a ISO de verdade** (tem `xorriso`): o workflow `iso`
> baixa a ISO base, remasteriza e roda o `verify-iso.sh` no fim. Mas há um limite
> prático: o GitHub **recusa arquivo de Release acima de 2 GiB**, e uma ISO com
> modelo + repositório fica em ~5,2 GB (medido). Por isso o padrão do CI é a ISO
> leve (`air_gapped: false`) e o workflow **pula o upload** avisando quando a ISO
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

> **Dependências:** veja a lista completa em § 4.8 (o que é obrigatório no
gerador e o que é só para o teste em VM).

### 4.2 Primeiro: simular (sempre)

```bash
# Simule com o MESMO --disk que você vai usar (a simulação já avisa se o
# disco não existe nesta máquina):
bash iso/build-iso.sh --distro ubuntu --disk /dev/nvme0n1 --dry-run
```

### 4.3 Gerar de verdade

```bash
# Instalação no SEU disco (o mais seguro quando a máquina é esta).
# Informe o PAPEL para a futura identidade ai-inference/ai-builder:
sudo bash iso/build-iso.sh --distro ubuntu --role inference --disk /dev/nvme0n1

# A máquina de build/registry/Gitea:
sudo bash iso/build-iso.sh --distro ubuntu --role builder --disk /dev/nvme0n1

# ISO GENÉRICA, para instalar em OUTRA máquina (ou quando você não sabe qual
# será o disco do alvo): o instalador escolhe o maior disco disponível.
sudo bash iso/build-iso.sh --distro ubuntu --disk auto

# O caminho Debian foi REMOVIDO (ADR-001): `--distro debian` agora aborta
# com exit 2 e uma mensagem apontando docs/DECISIONS.md.
```

> ⚠️ **`--disk` é o disco que será APAGADO** na máquina onde a ISO for
> instalada. Fixá-lo evita o pior cenário (instalar no disco errado). Se você
> não passar `--disk`, é preciso aceitar explicitamente com `--allow-any-disk`.

> 🎯 **Qual escolher?** Se a ISO vai instalar **na máquina em que você está
> gerando**, fixe o disco (`--disk /dev/nvme0n1`) — é a proteção contra apagar
> o disco errado. Se a ISO vai para **outro PC**, use **`--disk auto`**: um
> caminho fixado que não existe no alvo (`/dev/vda` numa máquina real, por
> exemplo) faz o instalador **não achar nenhum disco que case** e a instalação
> automática **não acontece** — sem mensagem de erro. `auto`, `any` e `none` são
> sinônimos de "não fixe o disco"; o build **avisa** quando o `--disk` informado
> não existe aqui, e **recusa** (rc 2) um valor que não é um dispositivo de
> bloco.

Opções mais usadas:

| Opção | Para que serve |
|-------|----------------|
| `--distro ubuntu` | Base do SO: **`ubuntu` (o único valor aceito, autoinstall)**. Qualquer outro valor — inclusive `debian` — **aborta** com exit 2 (ADR-001). |
| `--role auto\|inference\|builder` | Papel gravado na ISO. `auto` (padrão) detecta no hardware real. **Com papel concreto, a próxima fase deriva o usuário/hostname** (`ai-inference`/`ai-builder`, ADR-002); `auto` mantém `ai-cpu-os` + aviso. |
| `--username` / `--hostname` | Vencem qualquer padrão (inclusive a futura identidade por papel). |
| `--family auto` | Família gravada na ISO. `auto` (padrão) detecta no hardware real. |
| `--firstboot-reboot` | Reinicia automaticamente ao fim do primeiro boot (aplica C-states). |
| `--hostname NOME` | Hostname do sistema instalado (padrão: igual ao usuário). |
| `--password-hash '$6$…'` | Senha do usuário (gere com `mkpasswd -m sha-512`). Se omitido, gera e **mostra** uma. |
| `--root-password-hash '$6$…'` | Senha do **root** (hash crypt). Se omitido, o root fica **bloqueado** (padrão). |
| `--username NOME` | Usuário administrativo (padrão `ai-cpu-os`; root fica bloqueado). |
| `--network auto` | Rede do sistema **instalado**: `auto`/`dhcp` (padrão = DHCP), `static` ou `none`. Ver a subseção "Rede do sistema instalado" em § 4.3. |
| `--network-ip`, `--network-gateway`, `--network-dns`, `--network-interface` | Valores do modo `static` (IP aceita `192.168.1.50/24`; DNS padrão `1.1.1.1,8.8.8.8`). |
| `--iso PATH` | Usa uma ISO local (trabalhar offline). |
| `--out PATH` | Caminho da ISO de saída. |
| `--keep-work` | Mantém o diretório de trabalho para inspeção. |
| `--check-templates` | **Autoteste:** substitui os templates e valida o YAML gerado. Não gera ISO, não precisa de disco nem root (é o `make iso-yaml`). |

#### Rede do sistema instalado (o alvo subia SEM DHCP)

**Sintoma real (sessão #28):** a ISO instalou, mas o sistema instalado subiu com
a placa de rede **DOWN** — era preciso `ip link set … up` + `dhclient` na mão a
cada boot. A causa não era o hardware: **o Subiquity não grava uma configuração
de rede persistente no alvo quando o `autoinstall.yaml` não traz a chave
`network:`**. O instalador usa DHCP para si mesmo, mas não deixa o netplan
correspondente no sistema instalado.

**A correção (mesmo padrão da senha):** a intenção de rede é decidida **na
geração da ISO** e vai escrita na mídia em três lugares coerentes:

| Onde | O que é gravado |
|------|-----------------|
| `autoinstall.yaml` → `network:` | O netplan que o **instalador** usa (DHCP ou IP fixo). |
| `/ai-cpu-os-boot/ai-cpu-os-netplan.yaml` | O **mesmo** YAML, para ser copiado ao alvo (uma fonte de verdade só). |
| `late-command.sh` → `/etc/netplan/99-ai-cpu-os.yaml` | O netplan **persistente** do sistema instalado. |

O `late-command.sh` também:

- move para `.ai-cpu-os.bak` o netplan deixado pelo instalador/cloud-init
  (`00-installer-config.yaml`, `50-cloud-init.yaml`, `01-netcfg.yaml`) — duas
  definições do mesmo adaptador fazem o netplan recusar a configuração;
- grava `/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg`
  (`network: {config: disabled}`) para o cloud-init não reescrever o netplan a
  cada boot;
- usa `optional: true`, para o boot não esperar uma placa que não tem cabo.

O antigo caminho Debian alimentava o `netcfg` do d-i; ele foi removido
(ADR-001), então `--network` tem hoje **um** consumidor: o autoinstall.

Modos:

| `--network` | O que faz | Quando usar |
|-------------|-----------|-------------|
| `auto` (padrão) / `dhcp` | DHCP em todas as placas `en*`/`eth*`. | Servidor numa rede com DHCP. |
| `static` | IP fixo (`--network-ip`, `--network-gateway`; DNS opcional). | Servidor de inferência com IP fixo. |
| `none` | **Não** grava configuração (comportamento antigo). | Só se você configura a rede por outro meio. |

```bash
# DHCP (padrão) — o caso normal
sudo bash iso/build-iso.sh --disk /dev/nvme0n1

# IP fixo, com a placa nomeada (mais previsível)
sudo bash iso/build-iso.sh --disk /dev/nvme0n1 \
  --network static --network-interface enp5s0 \
  --network-ip 192.168.1.50/24 --network-gateway 192.168.1.1 \
  --network-dns "1.1.1.1,8.8.8.8"
```

O `iso/verify-iso.sh` confere a coerência dos três elos (modo gravado × bloco
do autoinstall × netplan da mídia) — é o tipo de erro que o build não vê
sozinho. O `make iso-yaml` exercita os modos `auto`, `static` e `none` nos dois
layouts de disco.

> ⚠️ **Ainda não validado em hardware/VM depois desta mudança**: o que está
> provado é que o YAML gerado é válido e coerente (`make iso-yaml`) e que o
> verificador reprova quando um dos elos desaparece (`make ci-guards-test`).
> Falta bootar uma ISO nova e confirmar que o alvo pega IP sozinho.

> ✅ **PROVADO em VM (sessão #33, 2026-10-17).** Uma ISO gerada com `--network
> auto` (DHCP) foi instalada numa VM qemu/KVM e o sistema instalado pegou IP
> **sem nenhum comando manual**, no journal do alvo:
>
> ```text
> systemd-networkd[634]: ens3: Configuring with /run/systemd/network/10-netplan-all-en.network
> systemd-networkd[634]: ens3: DHCPv4 address 10.0.2.15/24, gateway 10.0.2.2 acquired
> ```
>
> O netplan instalado (`/etc/netplan/99-ai-cpu-os.yaml`, 0600) era exatamente o
> gerado pelo build, e `/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg`
> existia. Login por SSH funcionou com a chave do usuário. **Continua sem prova
> em hardware físico e sem prova do modo `static`** (só o `auto` foi bootado).

> 🔧 **Máquina já instalada (ISO anterior): não precisa reinstalar.**
> `sudo bash /opt/ai-cpu-os/mods/network/apply.sh` aplica no próprio sistema o
> mesmo netplan que a ISO nova traz — e move o netplan do instalador/cloud-init
> para `.bak`. Ver `docs/MODS.md` § 3 e `docs/TROUBLESHOOTING.md` § "sobe sem
> rede".

#### Como a ISO base é escolhida (e o bug que isso já causou)

O build **não** confia numa URL fixa: baixa o `SHA256SUMS` oficial, escolhe a
entrada e só então baixa a ISO, conferindo o `sha256`.

São **dois** detalhes que só aparecem com o arquivo real na mão, e que já
quebraram a geração da ISO Ubuntu (o build morria com **`exit code 22`** do
`curl` e mais nada — 404 na URL, sem dizer qual):

1. O `SHA256SUMS` do **Ubuntu** marca o modo binário com **`*`** antes do nome
   (`*ubuntu-24.04.5-live-server-amd64.iso`), igual ao `md5sum -b`. Sem remover
   o `*`, a URL fica `.../24.04/*ubuntu-24.04.5-…iso` → **404**.
2. O `SHA256SUMS` do Ubuntu lista **todas** as point releases (24.04.3, .4,
   .5…) e as variantes **desktop/wsl**. Pegar a **primeira** entrada casada
   baixaria a versão mais **velha**.

Hoje: o padrão é **ancorado** (`^ubuntu-[0-9][^ ]*-live-server-amd64[.]iso$`,
o que exclui `*-desktop-*` e `*-wsl-*`) e a escolha é a de **maior versão**
(`sort -V | tail -1`). Os nomes passam por `normalize_iso_name` (remove `*` e o
prefixo `./`) e há uma checagem final que **falha com mensagem clara** se o nome
não for um nome de arquivo simples — em vez de deixar o `curl` devolver 404.

Quem guarda isso é `make iso-select-test`, que roda as **mesmas funções**
contra `SHA256SUMS` reais em `tests/fixtures/` (sem rede). Ver
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) § "ISO / Remasterização".

#### Como os `.deb` do repositório local são baixados (`--iso-repo auto`)

O fecho de dependências vem de `apt-cache depends --recurse` e é baixado com
`apt-get download`. Duas armadilhas já custaram uma sessão cada:

1. **`apt-get download a b c` aborta o LOTE INTEIRO** se um dos nomes não tiver
   candidato (pacote virtual, que **varia com a release do host**): não baixa
   nem os que são válidos. Medido:

   ```
   apt-get download git PACOTE-QUE-NAO-EXISTE jq   →  rc=100, ZERO arquivos
   ```

2. Baixar em **lotes de 25** (com `|| true`) é 5× mais rápido que um a um
   (medido), mas transformava a armadilha acima em perda silenciosa de **até 25
   pacotes por lote**. Os "pedidos ausentes" que o build reportava eram só a
   ponta: o resto do fecho sumia sem aviso.

Hoje o script faz as duas coisas: `packages_with_candidate()` descarta os nomes
sem candidato **antes** de baixar (rápido, barato, resolve o caso comum) e o
lote que **mesmo assim** falhar é refeito **um a um** (isola a falha no nome
ruim, sem perder os vizinhos), com os nomes que falharam **reportados** no log.

Quem guarda isso é `make iso-repo-test`, que reproduz o caso inteiro **offline**
(com `apt-cache`/`apt-get` substituídos por stubs) — inclusive o modo lote.

#### O verificador confere o conteúdo (uma base só)

O `iso/verify-iso.sh` confere a **coerência** entre a mídia e a configuração de
instalação. Com a base única (ADR-001) existe **um** arquivo de config
(`/autoinstall.yaml`, na raiz da ISO) e **um** lugar para a fonte extra (a seção
`sources` do curtin). O modo de falha que a checagem existe para pegar — config
**sem** a fonte extra → instalação dependente de rede — continua coberto, e
agora também há uma checagem de que o `late-commands:` chama
`/cdrom/ai-cpu-os-boot/late-command.sh` (o caminho novo dos templates).

> 📌 **História, para quem for mexer:** o verificador já foi distro-aware porque
> conferir só o autoinstall reprovava uma ISO **Debian** correta (o repo estava
> na mídia e a preseed o usava) — foi o `2 problema(s)` do run #10. Com a
> remoção do Debian a checagem ficou com um caminho só, e o teste
> `make iso-verify-test` foi reescrito para cobrir o novo contrato.

Quem guarda é `make iso-verify-test`.

### 4.3.1 Não tenho `xorriso` (ou a máquina é modesta)

Gerar a ISO exige `xorriso`, ~6 GB livres e paciência: ela baixa a base
(~2,6 GB), o modelo (~1,1 GB, se `--iso-model auto`) e os pacotes, e remasteriza.
Numa máquina modesta isso não roda — **e não precisa**: quem gera a ISO pode ser
**outra máquina**.

Caminho completo, sem instalar nada pesado na sua:

```bash
# 1. Navegador: Actions → workflow "iso" → Run workflow
#    (marque air_gapped para a ISO que se basta)

# 2. Baixe o artifact da execução (o .zip) e EXTRAIA — dentro está o .iso
#    e o .iso.sha256. (Renomear o .zip para .iso não funciona.)

# 3. Confira o arquivo baixado (não precisa de xorriso, nem de root):
make iso-check ISO=~/Downloads/ai-cpu-os-ubuntu.iso

# 4. Grave no pendrive:
make pendrives
sudo make pendrive DEVICE=/dev/sdb
```

O `iso/check-iso.sh` responde às três perguntas que importam **antes** de
gravar, usando só `dd`/`od`/`sha256sum`:

| Confere | Como |
|---|---|
| Está íntegro? | tamanho plausível + **SHA256** (lê o `.sha256` baixado ao lado) |
| É ISO 9660? | assinatura **`CD001`** no setor 16 (LBA 16) |
| É **deste** projeto e boota? | **Volume ID** `AI_CPU_OS_*` + assinatura de boot **MBR `0x55AA`** |

> ✅ **Não é substituto do `verify-iso.sh`** — e os dois são complementares:
> aquele abre a ISO e confere o **conteúdo** (config, projeto embutido,
> marcadores, repositório apt), e para isso precisa de `xorriso`. Este prova
> apenas que **o arquivo chegou inteiro e é o arquivo certo**.

> ⚠️ **O artifact do GitHub é um `.zip`.** Se você gravar o artifact direto num
> pendrive, ele **não boota**. O `make iso-check` detecta exatamente isso (falta
> o `CD001`) e a mensagem diz para descompactar.

> 🔓 **Acesso:** o download do artifact pelo navegador exige estar logado no
> GitHub (é o seu repositório). O `artifact-url` que o próprio workflow expõe
> (`${{ steps.upload.outputs.artifact-url }}`) também exige sessão.

### 4.3.2 Autor de flag nenhuma: a interface web local

Tudo o que está nesta seção (§ 4.2 a § 4.3.1) tem uma página local equivalente,
para quem não quer decorar flag:

```bash
make ui          # → http://127.0.0.1:8787   (só biblioteca padrão)
make ui-test     # prova a API e as salvaguardas (34 asserções)
```

A página mostra o **hardware detectado**, o **espaço livre** e **quais
ferramentas existem** na máquina; a partir daí monta o `make iso` com distro,
disco, papel, família e payload que você escolher, roda e imprime o log **ao
vivo** (SSE). Ela também:

- **lista as ISOs** de `iso/out` com botões para conferir o **conteúdo**
  (`verify-iso.sh`, exige `xorriso`) e um caminho para conferir uma ISO
  **baixada** (`check-iso.sh`, **sem** `xorriso` — § 4.3.1);
- **lista os pendrives** e mostra o comando `sudo make pendrive DEVICE=/dev/sdX`
  pronto para copiar. A UI **nunca** pede senha de sudo: gravar disco exige
  root, e senha de sudo não passa por uma página. (As **senhas do usuário e do
  root da ISO** são outra coisa: o formulário as aceita e o servidor as vira
  hash crypt antes da linha de comando — § 4.7.)

Três invariantes que valem repetir aqui:

| Invariante | Por quê |
|---|---|
| **Só biblioteca padrão** do Python 3 | A máquina que gera a ISO pode ser limitada: `pip install` não pode ser pré-requisito |
| **Só `127.0.0.1`** | Expor na rede uma página que gera ISO e escolhe disco de particionamento |
| **Recusa com o motivo** quando falta `xorriso` | Regra 13-a: degradar com aviso explícito e apontar o GitHub Actions — nunca falhar em silêncio |

> 📄 Os invariantes completos (lista branca de ações, sem rota de escrita, sem
> CDN, `webui/` **fora da ISO**) estão na **Regra 16** do `AGENTS.md` e na § 4.7
> do `README.technical.md`. Cada um tem guarda no CI, provado por violação
> plantada (`make ci-guards-test`).

> ⚠️ **Não validado:** a interface é exercitada **pela API** — **nunca foi
> aberta num navegador de verdade**. Ver § 6.

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

**c) Remontagem por `-indev/-outdev -map` + `-boot_image replay`, não por
extração + mkisofs.** Em vez de extrair a árvore e remontar, partimos da ISO
oficial e apenas **sobrescrevemos** o que muda: `/boot/grub/grub.cfg`,
`/autoinstall.yaml`, `/ai-cpu-os-boot/…`, `/ai-cpu-os`, `/models`,
`/llama-src.tar.gz` e `/apt-repo`. Assim os setores de boot (El Torito BIOS,
imagem EFI e MBR híbrido) ficam **byte a byte** iguais aos do Ubuntu — sem
`mtools`, sem `isohdpfx.bin` e sem o risco de gerar uma ISO que não boota.

> ⚠️ **Três pegadinhas do `xorriso` que só apareceram na 1ª ISO de verdade**
> (sessão #21; detalhes no `JOURNAL.md` § 6):
> 1. **`-boot_image any replay`** (e **não** `keep`): a imagem UEFI do Ubuntu é
>    uma imagem El Torito **oculta** (fora da árvore ISO9660). O `keep` mantém a
>    *referência* do catálogo, mas a imagem não é copiada → a ISO saía ~6 MB
>    menor, o `efi.img` virava 1 bloco e o MBR protetor apontava além do fim
>    (**exit 32**, e UEFI quebrado). O `replay` reexecuta o que o
>    `-report_system_area cmd` propõe (re-anexa a partição EFI).
> 2. **`-rm X --`** (`--` fecha a lista de caminhos): sem ele, o `-commit`/`-end`
>    seguinte são lidos como caminhos a remover → `SORRY` → **exit 32**.
> 3. **`-map` é seletivo**: o que fica no `stage` e não for mapeado **não entra**
>    na ISO — foi assim que o modelo/fonte/repo sumiram na 1ª tentativa.

O `md5sum.txt` original fica obsoleto com essas alterações e é **removido** na
remontagem (o Subiquity não o usa no autoinstall).

**d) Tuning sempre no primeiro boot.** O `autoinstall.yaml` traz só o usuário,
o locale, o particionamento e os pacotes; o `late-commands:` chama
`iso/common/late-command.sh` com `AI_CURTIN=1`, para ele usar
`curtin in-target --`. O mesmo script serve o `build.sh` rodado à mão — ver § 3.

---

### 4.5.1 Como a variante Debian funcionava (HISTÓRICO — caminho REMOVIDO)

> 🗑️ **REMOVIDO (ADR-001, sessão #42).** `iso/preseed/` não existe mais e
> `--distro debian` aborta. Esta seção fica **só como registro** do que foi
> aprendido na sessão #35 — o conhecimento vale como classe de bug (instalador
> automático não pode parar pedindo entrada), não como código. O runtime
> Debian (`build.sh`/`mods/`) continua suportado.

O Debian **não** tem autoinstall: quem respondia as perguntas era o
`debian-installer` (d-i) lendo um **preseed**. Cada elo da cadeia abaixo — e
cada linha da tabela — travou a instalação de verdade (sessão #35; ver
`TROUBLESHOOTING.md`). Nada disto existe mais no código:

```text
isolinux.cfg / grub.cfg     prompt 0 + preseed/file=/preseed.cfg + idioma na cmdline
        │
        ▼
initrd.gz  ←  /preseed.cfg na RAIZ (inject_preseed_initrd anexa um 2º cpio)
        │      é o S30initrd-preseed que lê: `if [ -e /preseed.cfg ]`
        ▼
d-i aplica o preseed  →  localechooser, netcfg, partman, pkgsel…
        │                 (idioma/teclado vêm da cmdline via env2debconf,
        │                  porque o localechooser roda ANTES da mídia montar)
        ▼
d-i preseed/late_command  →  sh /preseed/late-command.sh  (copia o projeto)
```

| Elo | O que o `build-iso.sh` faz | Por que |
|---|---|---|
| Boot | `prompt 0`, `timeout 100`, `default ai-cpu-os-auto` | com `prompt 1` o isolinux mostra `boot:` e **espera tecla** (o `timeout` não vale) — a VM fica parada e o serial sai **vazio** |
| Console | `serial 0 115200` + `console 0` quando `--serial-console` | sem isso não existe menu nenhum para um teste headless |
| Cmdline | `auto=true priority=critical preseed/file=/preseed.cfg language=… country=… locale=… keymap=…` | `localechooser`/`kbd-chooser` rodam **antes** de a mídia ser montada; `env2debconf` mapeia esses nomes via `/etc/preseed_aliases` |
| initrd | `inject_preseed_initrd()` anexa um `cpio` (newc) com `/preseed.cfg`, `/preseed/ai-cpu-os.cfg` e `/preseed/late-command.sh` | o d-i só lê `/preseed.cfg` **na raiz do initramfs**; `preseed/file=/cdrom/…` seria aplicado quando o udeb `file-preseed` instala — tarde demais |
| Preseed | `d-i localechooser/languagelist select @@LANG@@` **além** de `d-i debian-installer/language` | a pergunta exibida é a **lista** (`localechooser/languagelist`), e ela só é pulada se o idioma estiver nas **escolhas** da lista — em console serial a lista é nível 0 e só tem `en` |
| Boot loader | `d-i grub-installer/bootdev string <DISCO>` (ou `default` sem disco fixado) | é pergunta **crítica** feita no **fim** da instalação: sem resposta o instalador espera para sempre com o sistema já copiado |
| late_command | `sh /preseed/late-command.sh` (o script autodetecta `/cdrom`, `/media/cdrom`, `/hd-media`, `/media/usb`) | o ponto de montagem muda entre BIOS/UEFI e entre netinst/ISO completa |
| Valores literais | todos os marcadores do `late-command.sh` em **aspas simples** | aspas duplas expandem o `$` de um hash crypt (`$6$…`); sob `set -u` o script morre com `exit 2` antes de copiar qualquer arquivo — e o `sh -n` **não** detecta |
| Fim da instalação | o `late-command.sh` faz `sync` + `umount /target` + **`reboot -f`** no fim, *e* substitui `finish-install.d/20final-message` por um no-op | a nota final do d-i pode devolver "back": o `finish-install` interpreta como `exit 10` e **aborta** a sequência — a máquina para no menu em vez de reiniciar. O patch sozinho **não basta** (o `20final-message` vem do udeb `finish-install`, desempacotado **depois** do hook `07preseed`); quem reinicia de fato é o `reboot -f`, e o patch é o cinto de segurança |
| `apt` do alvo | remove `deb … cdrom:` do `sources.list` do alvo e roda `apt-get update` uma vez | o instalador grava a mídia como fonte; depois ela não existe e **todo** `apt-get update` falha (o 1º boot abortava com `rc=100`) |
| Pacotes | `EXTRA_PACKAGES` inclui **`sudo`** | o Debian **não** traz `sudo` numa instalação padrão: sem ele, e com o root bloqueado, o usuário da ISO não administra nada |

> **O `md5sum.txt` do Debian era regenerado** depois do patch (o d-i confere a
> mídia); no Ubuntu ele é removido.

---

### 4.5.2 ⚡ O que muda quando a ISO NÃO tem repositório local (e não há rede)

> 🗑️ Esta seção descreve o que acontecia no **caminho Debian**, removido no
> ADR-001. Fica como registro do que foi medido na sessão #38, com uma VM numa
> rede local **sem internet** (DHCP funciona, o espelho não responde): sem
> `--iso-repo`, a instalação Debian **parava** em telas interativas. Foram três
> telas, cada uma com uma causa:

| Tela | Causa | Correção |
|---|---|---|
| `[!!] Configure the network` | `netcfg` reprova o DHCP quando não há **gateway** (rede isolada) | não é bug do projeto: com DHCP de verdade (gateway presente) passa |
| `[!] Please check the specified mirror` | o `apt-setup` **sempre** tentava o espelho de rede; sem internet ele para e pede outro | `d-i apt-setup/use_mirror boolean false` — a mídia é a fonte |
| `[!!] Select and install software — Installation step failed` | o `pkgsel` chama `aptfailed` (`exit $ret`) quando `tasksel`/`apt-get install` falham | sem repo local: `pkgsel/include` vazio + `pkgsel/run_tasksel false` + `pkgsel/upgrade none` |

Com `--iso-repo auto`, além disso: o `Release` do repositório passou a trazer o
**`Codename` real** (vale igual para o caminho Ubuntu) (antes era `./`, e o `late-command` recusava o repositório
por "outra release" — o alvo ficava **sem a fonte local** e o 1º boot dependia
de rede).

**Resultado medido, sem internet nenhuma** (`--iso-repo auto --iso-source auto`):

```
[ai-cpu-os/iso-late] reiniciando
[ai-cpu-os/firstboot] aplicação concluída com sucesso (papel auto, família auto)

. firstboot-status: status=ok
AI-CPU-OS-BUILD.txt:
  Família:   intel-haswell (Intel Xeon E5 v3 (Haswell-EP))
  llama.cpp: tarball local llama-src.tar.gz
  Rede:      não usada (fonte local)
```

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

### 4.7 O passo final: gravar num pendrive

É para isto que a ISO existe — e é o passo **mais perigoso** do projeto: `dd` no
dispositivo errado apaga o disco errado, sem desfazer.

```bash
make pendrives                          # o que está plugado? (só removíveis)
sudo make pendrive DEVICE=/dev/sdb      # grava (pede para digitar o nome)
```

**As travas, em ordem de importância** (a lista completa está em
`iso/write-pendrive.sh`, no cabeçalho):

| Trava | Por quê |
|---|---|
| Recusa o disco que contém `/` | Nada sobrescreve o sistema em uso |
| Recusa disco **não removível** (SATA/NVMe) | Só passa com `--allow-internal`, que exige o caminho **completo** do dispositivo |
| Exige **disco inteiro** (`TYPE=disk`) | Um `sr0` (DVD) tem `RM=1` e passaria como “removível”; partição e loop também não servem |
| Recusa se houver partição **montada** | Gravar com o pendrive montado corrompe |
| Confere a assinatura **`CD001`** | Prova que o arquivo é uma ISO 9660 |
| Confere que a ISO **cabe** | E **avisa** se o dispositivo for muito maior — sinal clássico de alvo errado |
| Exige digitar o **nome** do dispositivo | `--yes` pula a pergunta, **nunca** as travas 1–6 |
| **Lê de volta e compara byte a byte** (`cmp -n`) | Gravar sem conferir é fé, não engenharia. `conv=fsync` antes de conferir |

> 💡 **É uma ISO 9660 híbrida** (boota por BIOS **e** UEFI). Se preferir gravar
> com outra ferramenta (Rufus, balenaEtcher, Ventoy, `dd` puro), funciona — a
> ferramenta é conveniência + segurança, não um formato proprietário. O que
> importa é apontar para o **dispositivo** (ex.: `/dev/sdb`), nunca para uma
> partição dele (`/dev/sdb1`).

> 🧪 **Como isso é testado sem pendrive:** `make pendrive-test`. O teste grava
> num **ARQUIVO** (nunca num dispositivo) e exercita as funções de trava com um
> `lsblk` simulado — incluindo os casos que **devem** ser recusados.

### 4.8 Dependências

```bash
# Obrigatórias
sudo apt install -y xorriso curl coreutils

# (o caminho Debian precisava de isolinux e mtools; ele foi REMOVIDO no
#  ADR-001, então essas duas dependências não existem mais)

# Só para o teste de VM
sudo apt install -y qemu-system-x86 qemu-utils
sudo apt install -y ovmf     # apenas para --boot-mode uefi

# Só para gravar no pendrive (util-linux traz lsblk/findmnt; dd e cmp são base)
sudo apt install -y util-linux
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
| Root | bloqueado por padrão; habilitável com `--root-password-hash` (hash crypt): o late-command roda `chpasswd -e` no alvo | omitir `--root-password-hash` |
| Instala pacotes base | `packages:` do autoinstall | `--extra-packages` |
| Copia o projeto | `/opt/ai-cpu-os` | — |
| Grava papel e família | `.iso-config` (lidos no 1º boot) | `--role`, `--family` |
| Aplica o tuning no 1º boot | mods `system`: sysctl, THP, governor, C-states | `--skip-mods` no `build.sh` |

**Segurança:** as senhas **nunca** são gravadas em texto puro na ISO — apenas o
hash crypt (`openssl passwd -6` / `crypt`). O **root fica bloqueado por
padrão**; com `--root-password-hash`, o login de root é habilitado com a senha
como hash (nunca texto puro: o late-command usa `chpasswd -e`).

---

## 6. Limitações conhecidas (e o que NÃO foi validado)

> Honestidade obrigatória (Regra 6 do [`AGENTS.md`](../AGENTS.md)).

| Item | Situação |
|------|----------|
| **A ISO Ubuntu foi construída, bootada e instalada** | ✅ **FEITO (sessão #21)**: gerada dentro de um container `ubuntu:24.04`, instalada numa VM com KVM, e o **1º boot aplicou o ai-cpu-os** (família `intel-haswell`) compilando o llama.cpp do tarball da mídia, **sem rede**. Ver `STATE.md` § 3.3. ⚠️ Falta **hardware físico (Ubuntu)** e **UEFI**. ⚠️ **Depois de remover o caminho Debian (sessão #42) nenhuma ISO foi gerada nem bootada.** |
| 🖥️ **A interface web (`make ui`)** | ⚠️ **Nunca aberta num navegador** — nem por quem escreveu. O `make ui-test` (34 asserções) exercita a **API**: lista branca, validadores, SSE, recusa sem `xorriso`, ausência de rota de escrita, bind em `127.0.0.1`. **Tudo que for visual é afirmação não verificada.** Ver § 4.3.2. |
| 🖥️ **A UI numa máquina COM `xorriso`** | ⚠️ Só o caminho de **recusa** foi provado (esta máquina não tem `xorriso`). O caminho feliz — job roda, o SSE mostra o progresso real até o fim e a ISO nova aparece na lista — **não** foi exercitado ponta a ponta. |
| **Caminho Ubuntu (`--distro ubuntu`)** | ✅ **EXECUTADO (sessão #21)**: ISO gerada, instalada numa VM (KVM) e o 1º boot aplicou o ai-cpu-os sem rede. Ver `STATE.md` § 3.3. |
| **`iso/verify-iso.sh`** | ✅ Exercitado de verdade: roda no `make iso-lint` sobre uma árvore montada com os templates e o projeto **reais**, incluindo um **teste negativo** (reprova quando falta a config). E o caminho `--iso` (com `xorriso`) foi executado na sessão #21: **PASS=41/FAIL=0**. |
| **`iso/test-vm.sh`** | ✅ **Executado (sessão #21)**: `exit 0` — bootou, instalou sozinho e o 1º boot aplicou. ⚠️ Nesta máquina de desenvolvimento **não há `qemu`**: só roda onde houver qemu + `/dev/kvm`. |
| **`--serial-console`** | ✅ **Validado (sessão #21)**: foi o que tornou a instalação e o 1º boot observáveis sem tela. Sem ele, o `test-vm.sh` não vê os marcadores (o script avisa exatamente isso). |
| Layout da ISO base | A base tem de ter `casper/` (recusado com mensagem clara se não existir). Outras ISOs falham de propósito em vez de gerar algo quebrado. |
| Boot BIOS | El Torito preservado do original e **bootou numa VM** (#21). |
| Boot UEFI | Imagem EFI preservada + patch do `grub.cfg` do UEFI. **Não validado.** |
| **Rede no 1º boot** | ✅ **Não é necessária E foi provado (sessão #21)**: numa VM, o 1º boot compilou o llama.cpp do tarball da mídia e usou o modelo e o repositório local, sem rede. A rede **é usada** se estiver disponível (para atualizar pacotes) e é **obrigatória na máquina que GERA a ISO**. |
| **Modelo na mídia** | ✅ Implementado (`--iso-model`) e **validado num boot real** (o `late-command` copiou para `/opt/models` e o `firstboot` usou via `AI_MODEL_FILE`, sem rede). |
| **Repositório apt na mídia** | ✅ Implementado (`--iso-repo`) e **validado (era bug)**: a seção `sources` do Subiquity **não funciona** (o curtin roda `apt-get update` num chroot sem `/cdrom`). O repo é carregado ao alvo (`/opt/apt-repo`) pelo late-command e usado no 1º boot. |
| **Fonte do llama.cpp na mídia** | ✅ Implementado (`--iso-source`) e **validado num boot real**: `/opt/llama.cpp/build/bin/llama-server` foi compilado do tarball, sem rede. |
| **Resíduo air-gapped (a investigar)** | ⚠️ O `llama-build.sh` usa `-DLLAMA_CURL=OFF` (runtime), mas o **build** ainda tenta baixar o **UI** do llama.cpp do HuggingFace (`-- UI: downloading … llama-ui …`). Na VM o `.sha256` falhou e o build **seguiu** (parece *best-effort*). **Confirmar** que a ISO é 100% offline (provável flag `-DLLAMA_BUILD_UI=OFF`/`-DLLAMA_UI=OFF` conforme a versão). |
| **Release da ISO × máquina de build** | `--iso-repo auto` só monta o repositório se a release casar com a da ISO. **Solução prática (sessão #21):** gere a ISO **dentro de um container da mesma release** (ex.: `docker run ubuntu:24.04 …`) — o `--iso-repo auto` passa a casar e o build não exige sudo no host. |
| **Debian/preseed** | 🗑️ **REMOVIDO (ADR-001, sessão #42).** Chegou a ser executado em VM (#35) e em metal (#37); o aprendizado ficou em § 4.5.1/§ 4.5.2. O runtime Debian (`build.sh`/`mods/`) continua suportado. |
| **Boot UEFI** | ⚠️ **Nunca testado.** O `-boot_image replay` restaurou a imagem EFI oculta do Ubuntu; falta bootar de fato com `--boot-mode uefi` (precisa de `ovmf`). |
| Tamanho | **5,2 GiB medido** (air-gapped: base 4,1 GB + repo 329 MB + modelo 1,1 GB + fonte 37 MB). |
| Assinatura | A ISO gerada **não é assinada**. Verifique o SHA256 que o script imprime. |
| `md5sum.txt` | **Removido** da ISO gerada (ficaria obsoleto; o Subiquity não o usa). |
| Efeito real das mods na ISO | O autoteste valida a *geração*; que sysctl/governor/C-states **funcionam** no alvo depende do Bloco O de `VALIDATION.md` (ainda em hardware físico). |

---

## 7. Alternativas consideradas (e por que não)

| Alternativa | Prós | Por que foi descartada |
|-------------|------|------------------------|
| **simple-cdd** | Integrado ao Debian, gera ISO com preseed | Exige espelho local / baixa muita coisa; menos controle sobre o boot e o `late_command`. Descartado junto com o caminho Debian (ADR-001). |
| **live-build** | ISO oficial do Debian, live + instalador | Pesado, exige ambiente limpo (chroot) e quebra fácil; `--debian-installer live` é notoriamente chato de scriptar. Descartado junto com o caminho Debian (ADR-001). |
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
| ✅ **FEITO** | **Construir e bootar a ISO numa VM** (Bloco M) — **concluído na sessão #21** (Ubuntu, em VM com KVM). Ver § 9 e o `STATE.md` § 3.3. |
| ✅ **FEITO** | **Rodar o caminho Ubuntu contra uma ISO real** — feito; os bugs de layout/`xorriso` que só apareciam aí foram corrigidos (`replay`, `-map`, `-rm --`, GRUB `--id`). |
| ✅ **FEITO** | **Os 5 requisitos do § 3.1:** fonte, modelo e repositório na mídia; o 1º boot roda **sem rede** (provado). |
| ✅ **FEITO** | **Remover o caminho Debian** (`--distro debian`/preseed) — ADR-001, **sessão #42**: scripts compartilhados movidos para `iso/common/`, `iso/preseed/` apagado, `verify-iso.sh`/`Makefile`/CI/`webui/`/testes limpos, `--distro debian` **aborta** com `exit 2` citando o ADR. |
| 🔴 Alta (P1) | **Identidade do sistema derivada do papel** — ADR-002: `inference`→`ai-inference`, `builder`→`ai-builder`, `auto`→`ai-cpu-os` + aviso; testes offline. |
| 🔴 Alta (P2/P3) | **`ai-talk`** — ADR-003/`docs/CHAT.md`: transporte + CLI + teste offline; depois ISO/duas VMs + ponte opcional com o `llama-server`. |
| 🔴 Alta | **Validar a ISO em HARDWARE FÍSICO** (Xeon E5-2680 v4 e Ryzen 5 3500X): repetir instalação + 1º boot e medir (`llama-bench`). Blocos A–O do `VALIDATION.md`. |
| 🟡 Média | **Fechar o resíduo air-gapped:** confirmar/desligar o download do **UI** do llama.cpp no build (ver § 6). |
| 🟡 Média | **Testar o boot UEFI** (`make iso-vm VM_ARGS="--boot-mode uefi"`). |
| 🟢 Baixa | **Testar a ISO no CI:** `validate` pode rodar `verify-iso.sh --dir` sobre a árvore do stage (já roda, via `make iso-yaml`). Um teste de VM no CI exigiria KVM e 30+ min — fica para runner self-hosted. |
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
| 1 | `make iso-yaml` | qualquer máquina | que os templates substituídos são YAML válido e que o verificador **sabe reprovar** (teste negativo) |
| 2 | `make iso-dry-run ISO_ARGS="--iso-source auto --iso-model auto --iso-repo auto"` | qualquer máquina | que a orquestração inteira acontece, sem baixar nada |
| 3 | **Gerar a ISO** (`make iso DISK=…` ou o workflow `iso` com `air_gapped: true`) | máquina com `xorriso` + rede | ⭐ que a ISO **existe** e que o `verify-iso.sh` aprova o conteúdo dela **de verdade** (inclusive rodando `xorriso` para dentro) |
| 4 | **Bootar e instalar em VM** (`make iso-vm`) | máquina com `qemu` + KVM | ⭐⭐ o **comportamento**: instala sozinho e o 1º boot aplica |
| 5 | Aplicar em hardware real | Xeon / Ryzen | desempenho e o efeito dos ajustes (Blocos A–P do `VALIDATION.md`) |

**Os passos 0–2 não provam nada sobre a ISO existir.** São baratos e pegam
regressão cedo, mas a ISO pode estar quebrada com eles verdes. Só o passo 3
cria o artefato, e só o passo 4 diz se ele **funciona**.

> ✅ **Passos 3 e 4 CONCLUÍDOS no caminho Ubuntu (2026-10-13, sessão #21).** A
> ISO foi gerada (build `exit 0`), aprovada pelo `verify-iso.sh`
> (**PASS=41/FAIL=0**) e **bootada/instalada numa VM** (`test-vm.sh` `exit 0`; o
> 1º boot aplicou o ai-cpu-os). Detalhes e os números em
> [`docs/STATE.md`](STATE.md) § 3.3 e `JOURNAL.md` § 4 (sessão #21). **Pendentes:**
> o **hardware real (Ubuntu)** e o **UEFI** (passo 5). O caminho Debian foi
> **removido** (ADR-001); ⚠️ **depois dessa remoção (sessão #42) nenhuma ISO
> foi gerada nem bootada de novo.**

### 9.1 Gerando a ISO na sua máquina (container) ou no CI

**Sem `xorriso`/`qemu` no host** (comum): `build-iso.sh` exige **root** + `xorriso`,
e `--iso-repo auto` exige a **mesma release** da ISO. O caminho prático que
resolve os dois: gerar a ISO **dentro de um container da mesma release** (root
grátis + release casando):

```bash
docker run --rm -v "$PWD":/work -w /work -e DEBIAN_FRONTEND=noninteractive \
  ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq \
    xorriso curl ca-certificates coreutils xz-utils tar gzip python3-yaml >/dev/null && \
    bash iso/build-iso.sh --distro ubuntu --disk /dev/vda --serial-console \
      --role auto --family auto --iso-source auto --iso-model auto \
      --iso-repo auto --yes'
```

**Ou pelo CI** (Actions → `iso` → Run workflow):

```bash
#   distro: ubuntu (padrão) · role/family: auto · disk: /dev/vda
#   air_gapped: true   ← para provar o caminho offline completo
```

O que o workflow faz: baixa a ISO base → instala `xorriso` → roda
`make iso-lint` → `make iso-dry-run` → **gera a ISO** → o próprio build roda
o `verify-iso.sh` → mede o tamanho → publica o resumo (com os WARN).

> 🔴 **Limite que muda o plano: 2 GiB por arquivo de Release.** O GitHub
> **recusa** anexar um arquivo maior que isso a uma Release, e a ISO air-gapped
> medida ficou em **5,2 GB**. Consequências:
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
| O instalador faz **perguntas** (Subiquity interativo) | o GRUB subiu a entrada errada: a `menuentry` precisa de `--id ai-cpu-os-auto` para o `set default` casar (era bug — § 4.5) |
| **Silêncio total** no console serial (nem boot) | capture a tela por QMP (`screendump`) — pode ser o boot (BIOS/UEFI) quebrado por `xorriso` (§ 4.5) |
| `apt-config` **exit 100** / "does not have a Release file" | o repo local foi declarado no apt do **instalador**; ele tem de ir para o **alvo** via late-command (§ 3.1) |
| Instala, mas o 1º boot **pede rede** | repositório incompleto → aumente `--iso-repo-packages` |
| 1º boot trava/demora muito | é a compilação do llama.cpp; confira `/var/log/ai-cpu-os-firstboot.log` |
| O `test-vm.sh` **não vê** os marcadores | a ISO foi gerada **sem** `--serial-console`, ou o processo loga só no journal (use `/dev/console` + `journal+console` — § 4.5/§ 6) |
| Sobra de marcador `@@TOKEN@@` | bug no `build-iso.sh` → rode `make iso-verify` |

### 9.4 Antes de considerar a ISO "fechada"

- [x] `make validate` verde (local — feito na sessão #21 **e** no CI)
- [x] ISO **gerada** (passo 3) — Ubuntu ✅
- [x] `verify-iso.sh` aprovado sobre a ISO real (`PASS=41/FAIL=0`)
- [x] ISO **bootada e instalada** numa VM (passo 4, Ubuntu) — ✅ sessão #21
- [x] 1º boot aplicado, `status=ok`
- [x] O **tamanho** e o **SHA256** anotados em `docs/STATE.md` § 5
- [x] Sessão registrada no `docs/JOURNAL.md` (#21)
- [ ] **Repetir em hardware físico** (Xeon/Ryzen) — Bloco M do `VALIDATION.md`
- [x] ~~Caminho Debian gerado e bootado~~ — **não é mais escopo**: removido (ADR-001)
- [ ] **Boot UEFI** testado
- [ ] Fechar o **resíduo air-gapped** do UI do llama.cpp (§ 6)

> ⚠️ **A Regra 13 do `AGENTS.md` é explícita:** não declare a ISO pronta sem
> tê-la bootado e instalado em VM. Verificação de conteúdo **não** substitui
> boot. (Feito para o **Ubuntu em VM**; VM ≠ hardware real.)

---

## 10. Histórico

| Data | Mudança |
|------|---------|
| 2026-10-20 | 🗑️ **O caminho Debian foi REMOVIDO (ADR-001, sessão #42).** `iso/preseed/` deixou de existir (scripts compartilhados foram para `iso/common/`), `--distro debian` **aborta** com exit 2 citando o ADR, `verify-iso.sh` ficou com uma base só e o layout da mídia passou a ser **`/ai-cpu-os-boot/`**. O CI reprova se `preseed/` voltar. `make validate` verde (ci-guards 93). ⚠️ Nenhuma ISO gerada/bootada depois da remoção. |
| 2026-10-20 | 🧭 **Base única: Ubuntu Server (ADR-001).** O caminho Debian/preseed passou a **DEPRECADO**; `--distro debian` emitia aviso. Planejados: identidade pelo papel (ADR-002) e chat da frota `ai-talk` (ADR-003, `docs/CHAT.md`). O topo e o roadmap foram atualizados para refletir o que já foi executado (#21 Ubuntu em VM; #35/#37 Debian em VM/metal) e o que **não** foi (hardware Ubuntu, UEFI). |
| 2026-10-13 | 🎉 **A ISO foi GERADA e BOOTADA pela primeira vez** (sessão #21): air-gapped, construída num container `ubuntu:24.04` e instalada numa VM com KVM. `verify-iso.sh` **PASS=41/FAIL=0**; `test-vm.sh` **exit 0** (instalou sozinha; o 1º boot aplicou o ai-cpu-os, `.firstboot-status=ok`, família `intel-haswell`; llama.cpp compilado do tarball da mídia). **8 bugs reais corrigidos:** `xorriso` (`-rm --`, `-boot_image replay`, `-map` do modelo/fonte/repo, aspas do `-find`), SIGPIPE no verificador, GRUB sem `--id` (→ instalação interativa), repo apt no chroot do curtin (→ carregar ao alvo `/opt/apt-repo` + `Release`), marcadores fora do console. Atualiza § 3.1, § 4.5, § 6, § 8, § 9 e este § 10. |
| 2026-10-07 | Criação: `iso/build-iso.sh` + preseed + serviço de primeiro boot + este documento. Nada executado em ambiente real ainda. |
| 2026-10-12 | **Variante Ubuntu (autoinstall/Subiquity) adicionada como base padrão** (`--distro ubuntu`), com `iso/autoinstall/autoinstall.yaml`, remontagem por `-indev/-outdev -map` (setores de boot preservados), `late-command.sh` compartilhado entre os dois instaladores (`AI_CURTIN=1`), flags `--role`/`--family` no lugar de `--profile` e autoteste de templates (`--check-templates` / `make iso-yaml`) rodando no CI. **Continuamos sem ter construído nem bootado nenhuma ISO.** |
| 2026-10-12 | **Ferramentas de validação:** `iso/verify-iso.sh` (conteúdo, com modo `--dir` sem xorriso) e `iso/test-vm.sh` (boot real em qemu, com marcadores no console serial). `--serial-console` torna a instalação e o 1º boot observáveis sem tela. O build agora **verifica a ISO ao final** e o `make iso-yaml` roda o verificador **incluindo um teste negativo** (verificador que nunca falha não vale nada). |
| 2026-10-12 | **Decidido: ISO air-gapped + compilar no 1º boot (nunca binário pré-colado).** Ver § 3.1. Primeiro passo implementado: `llama-build.sh --source <dir|tar.gz>` compila de um fonte **local** sem rede e sem `git` (substitui o `git clone`), registrando a origem em `AI-CPU-OS-BUILD.txt`. O restante (repo apt local, `--offline` no `build-iso.sh`, política do modelo) segue como plano. **Nada disso foi exercitado numa ISO real.** |
| 2026-10-12 | **O modelo vai na mídia** (decisão: ~1 GB de mídia é preço justo por uma ISO que se basta). Implementado `--iso-model auto\|<caminho>\|none` no `build-iso.sh` (com validação de magic `GGUF` e de tamanho antes de montar a ISO), cópia para `/opt/models` no `late-command.sh`, `MODEL_FILE` no `.iso-config`, `AI_MODEL_FILE` no `firstboot.sh` e **`--model-file` no papel `inference`** (instala um `.gguf` local sem rede — inclusive conferindo o magic). O `verify-iso.sh` passou a checar a corrente toda e a reprovar modelo inválido/pequeno. Guardas no CI, inclusive **negativos** (nada de `--prebuilt`; nada de `COPY build/bin`). **Nenhuma ISO gerada; nenhum boot real.** |
| 2026-10-12 | **A fonte do llama.cpp vai na mídia** (`--iso-source auto\|<tarball>\|none`): fecha o **último** passo que exigia rede no 1º boot, e o mais demorado. A corrente **late-command → `LLAMA_SRC` → `firstboot` → `AI_LLAMA_SOURCE` → `llama-build.sh`** foi exercitada ponta a ponta num sandbox (manifesto: `Rede: não usada`). Novo § 9 "Fechando a ISO" com o checklist e o achado do **limite de 2 GiB por arquivo de Release** (que muda o que o CI pode publicar). **Nenhuma ISO gerada; nenhum boot real.** |
| 2026-10-12 | **O repositório apt vai na mídia** (orçamento de 8 GB acordado). `--iso-repo auto\|DIR\|none` baixa os `.deb` (pacotes + fecho de dependências, sem recomendados), gera o índice com `dpkg-deb` (**sem depender do `dpkg-dev`**) e o embute em `/apt-repo`; a fonte entra como **extra** (seção `sources` do curtin no Ubuntu; `apt-setup/local0/*` no Debian) para o `primary` continuar sendo o arquivo oficial e o alvo nascer com a configuração normal. O build **recusa** repositório de outra release. O `verify-iso.sh` ganhou a seção do repositório: índice legível, todo `.deb` do índice presente na mídia, magic `!<arch>` e coerência entre mídia e configuração. **Prova real:** o `apt` do sistema aceitou um repositório montado pelo código do projeto e resolveu a dependência. **Nenhuma ISO gerada; nenhum boot real.** |
