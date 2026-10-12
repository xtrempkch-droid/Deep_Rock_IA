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
| 2 | Nenhum `git clone` no 1º boot | `firstboot.sh` passa `--source` em vez de `--ref` | ⬜ a fazer |
| 3 | Toolchain de build **na mídia** | Repositório apt local (`.deb` + `dpkg-scanpackages`) embutido na ISO | ⬜ a fazer |
| 4 | Pacotes do instalador **na mídia** | O mesmo repositório local, com o espelho do Subiquity apontando para `file:///…` | ⬜ a fazer |
| 5 | **Modelo** na mídia | Hoje `--auto-model` baixa da HuggingFace; offline exige o `.gguf` na ISO **ou** nenhum modelo | ⬜ **decisão pendente** (ver abaixo) |
| 6 | O sistema saber que está offline | `late-command.sh` grava `OFFLINE=1` no `.iso-config` | ⬜ a fazer |

**Custo estimado:** ~300–500 MB de `.deb` + ~30–50 MB do fonte. O modelo
sugerido (Qwen2.5-Coder-1.5B Q4_K_M) acrescenta ~1,1 GB — ou seja, a ISO vai
para ~3,1–3,3 GB **sem** modelo e ~4,2–4,4 GB **com** modelo (estimativas, não
medições).

> ⚠️ **Honestidade:** só o item **1** está pronto, e ele foi exercitado **fora do
> alvo** (`--dry-run` + extração real de tarball com as ferramentas de build
> simuladas). A compilação real de um fonte do llama.cpp por esse caminho ainda
> **não** foi executada. Os itens 2–6 são **plano**, não fato: **hoje a ISO
> exige rede no primeiro boot.** Ver § 6.

> 💡 **A pergunta que falta decidir:** embutir o modelo na ISO (mídia maior, mas
> liga e já funciona sozinha) ou deixá-lo de fora (mídia menor; o usuário copia o
> `.gguf` por pendrive)? O meio-termo natural é embutir **um** modelo pequeno por
> padrão, com `--iso-model CAMINHO` para trocar. Ver § 8.

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
| **Rede no 1º boot** | ⚠️ **Ainda é obrigatória.** O papel `inference` clona o llama.cpp do GitHub e pode baixar o modelo (`--auto-model`). **Decidido (sessão #14) que a ISO deve ser air-gapped** — o plano e o estado de cada requisito estão no § 3.1. Hoje, sem rede, a aplicação é adiada para o próximo boot (a sentinela é mantida). |
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
| � Alta | **ISO air-gapped** (decisão da sessão #14 — ver § 3.1): (a) `firstboot.sh` passar `--source` em vez de `--ref`; (b) repositório apt local com o toolchain de build e os pacotes do instalador; (c) `OFFLINE=1` no `.iso-config`; (d) flag `--offline` no `build-iso.sh` que monta tudo isso. |
| 🟡 Média | **Decidir a política do modelo** para a ISO offline (em § 3.1, item 5): embutir um `.gguf` pequeno por padrão, `--iso-model CAMINHO`, ou nenhum modelo. |
| 🟡 Média | **Testar o boot UEFI** (`make iso-vm VM_ARGS="--boot-mode uefi"`). |
| 🟢 Baixa | **Testar a ISO no CI:** `validate` pode rodar `verify-iso.sh --dir` sobre a árvore do stage (já roda, via `make iso-yaml`). Um teste de VM no CI exigiria KVM e 30+ min — fica para runner self-hosted. |
| ~~🟡 Média~~ | ~~Variante air-gapped~~ → **decidida e virou requisito** (linha 🔴 Alta acima). O que era "variante" agora é o caminho planejado. |
| ❌ Descartado | **Variante com binário pré-compilado:** usar os `.tar.gz` da Release em vez de compilar no 1º boot. **Descartado na sessão #14** — seria mais rápido, mas exigiria uma ISO por família e reintroduziria o risco de portabilidade. Ver § 3.1. |
| 💡 Ideia | **Assinatura da ISO** com `gpg` + publicação do SHA256 no release. |
| 💡 Ideia | **Imagem de VM (qcow2)** via Packer, derivada da mesma lógica. |

---

## 9. Histórico

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação: `iso/build-iso.sh` + preseed + serviço de primeiro boot + este documento. Nada executado em ambiente real ainda. |
| 2026-10-12 | **Variante Ubuntu (autoinstall/Subiquity) adicionada como base padrão** (`--distro ubuntu`), com `iso/autoinstall/autoinstall.yaml`, remontagem por `-indev/-outdev -map` (setores de boot preservados), `late-command.sh` compartilhado entre os dois instaladores (`AI_CURTIN=1`), flags `--role`/`--family` no lugar de `--profile` e autoteste de templates (`--check-templates` / `make iso-yaml`) rodando no CI. **Continuamos sem ter construído nem bootado nenhuma ISO.** |
| 2026-10-12 | **Ferramentas de validação:** `iso/verify-iso.sh` (conteúdo, com modo `--dir` sem xorriso) e `iso/test-vm.sh` (boot real em qemu, com marcadores no console serial). `--serial-console` torna a instalação e o 1º boot observáveis sem tela. O build agora **verifica a ISO ao final** e o `make iso-yaml` roda o verificador **incluindo um teste negativo** (verificador que nunca falha não vale nada). |
| 2026-10-12 | **Decidido: ISO air-gapped + compilar no 1º boot (nunca binário pré-colado).** Ver § 3.1. Primeiro passo implementado: `llama-build.sh --source <dir|tar.gz>` compila de um fonte **local** sem rede e sem `git` (substitui o `git clone`), registrando a origem em `AI-CPU-OS-BUILD.txt`. O restante (repo apt local, `--offline` no `build-iso.sh`, política do modelo) segue como plano. **Nada disso foi exercitado numa ISO real.** |
