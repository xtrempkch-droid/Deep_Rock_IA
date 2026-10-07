# ISO — A imagem de instalação do ai-cpu-os (entregável final)

> **Última atualização:** 2026-10-07
>
> **Este é o objetivo final do projeto:** uma **ISO de instalação** de um
> sistema operacional (Debian ou Ubuntu) que já traz o ai-cpu-os embutido —
> insert → instala → o sistema nasce afinado para inferência de LLM em CPU.
>
> Implementado por [`iso/build-iso.sh`](../iso/build-iso.sh).
> Estado (o que foi testado e o que **não** foi): [`docs/STATE.md`](STATE.md).

---

## 1. Por que uma ISO é o fim do projeto

O `ai-cpu-os` começou como um conjunto de scripts ("clone e rode `build.sh`").
Isso exige que o operador saiba: instalar um Debian mínimo, clonar, rodar
com `--profile` certo, entender os avisos. A ISO elimina essa etapa — **o
sistema já nasce pronto**:

| Sem a ISO | Com a ISO |
|-----------|-----------|
| Instalar Debian manualmente | Dá boot na ISO |
| Responder o instalador | Instalação automática (preseed) |
| Clonar o repositório | Projeto já está em `/opt/ai-cpu-os` |
| Rodar `build.sh` à mão | Aplicado automaticamente no 1º boot |
| Ter o `.gguf` do lado | Idem (o modelo é baixado/fornecido depois) |

O ganho real: **reprodutibilidade**. Duas máquinas instaladas com a mesma ISO
ficam idênticas (mesmo que o hardware seja diferente, o perfil é detectado).

---

## 2. Fluxo completo (do build da ISO ao sistema afinado)

```text
 [1] MÁQUINA DE BUILD (hoje: qualquer Debian/Ubuntu com xorriso)
      │
      │  sudo iso/build-iso.sh --disk /dev/nvme0n1
      │
      ├─ descobre a ISO netinst mais recente do Debian + baixa o SHA256SUMS
      ├─ baixa e VERIFICA a ISO oficial
      ├─ extrai (xorriso)
      ├─ injeta: /ai-cpu-os/           ← o projeto inteiro
      │          /preseed/ai-cpu-os.cfg      ← preseed (respostas automáticas)
      │          /preseed/late-command.sh    ← copia o projeto no alvo
      │          /preseed/firstboot.sh       ← aplica o tuning no 1º boot
      │          /preseed/ai-cpu-os-firstboot.service
      ├─ patcha o boot (isolinux + UEFI) p/ instalar sem perguntar nada
      ├─ regenera md5sum.txt (integridade da mídia)
      └─ remonta a ISO (BIOS + UEFI, híbrida)
      ▼
 [2] ISO  ai-cpu-os-<data>.iso   (~700 MB)
      │
      │  (ggravada em pendrive: dd, ou montada numa VM)
      ▼
 [3] MÁQUINA ALVO — INSTALAÇÃO
      │  boot → isolinux/GRUB → label "ai-cpu-os-auto"
      │  → debian-installer lê /preseed/ai-cpu-os.cfg → instala SEM PERGUNTAR
      │  → late-command copia /ai-cpu-os → /target/opt/ai-cpu-os
      │  → habilita ai-cpu-os-firstboot.service (sentinela .firstboot-pending)
      ▼
 [4] PRIMEIRO BOOT  ← o hardware real está aqui, é agora que detectamos
      │  ai-cpu-os-firstboot.service roda:
      │    wait_for_network
      │    build.sh --profile <gravado na ISO, padrão auto> --yes
      │       ├─ detect-hardware.sh   → escolhe xeon/ryzen, alerta canais
      │       ├─ common/*.sh          → sysctl, THP, governor, C-states
      │       └─ profiles/<perfil>/   → llama.cpp + serviço (ou Docker/Gitea)
      │    grava .firstboot-status, remove a sentinela, (opcional) reinicia
      ▼
 [5] SISTEMA PRONTO
        xeon : llama-server + shell-ia.py
        ryzen: Docker + registry :5000 + Gitea :3000
```

---

## 3. 🔑 Decisão central: por que aplicar no **primeiro boot** (e não no `late_command`)?

Esta é a decisão de design mais importante da ISO, e ela é deliberada.

Na hora em que o `late_command` roda, estamos **dentro do ambiente do
instalador Debian**, com o sistema alvo montado em `/target` — mas **o sistema
alvo não está em execução**. As consequências:

| Problema | Detalhe |
|----------|---------|
| **Não há systemd ativo no alvo** | `systemctl enable/start` e o tuning de kernel não têm para onde se aplicar. Fazer isso num chroot é frágil e não reflete o estado real. |
| **Não há kernel do alvo rodando** | C-states (cmdline), governor e huge pages são propriedades do kernel que vai bootar — não do kernel do instalador. |
| **O hardware real seria mal detectado** | Em VM ou com drivers limitados do instalador, `detect-hardware.sh` pode não ver os canais de memória (depende de `dmidecode`/SMBIOS) nem a ISA corretamente. |
| **Compilar o llama.cpp levaria 20+ min** | E um erro no meio deixaria a instalação num estado ambíguo, com o instalador ainda "no controle". |
| **Falha silenciosa** | Um `failure` no `late_command` não invalida a instalação — o usuário ficaria com um sistema "meio configurado" sem saber. |

Aplicando no **primeiro boot**, ganhamos:

1. **O hardware certo.** `detect-hardware.sh` roda no sistema instalado, com
   o SMBIOS completo → detecta canais de memória, ISA e escolhe o perfil certos.
2. **Uma ISO serve para os dois sistemas.** Como o perfil padrão é `auto`, a
   **mesma** ISO se adapta ao Xeon (llama.cpp) e ao Ryzen (Docker/registry/
   Gitea). Isso é possível justamente porque a decisão é adiada para o boot real.
3. **Estado observável.** O primeiro boot tem log próprio
   (`/var/log/ai-cpu-os-firstboot.log`), status em `.firstboot-status` e um
   serviço systemd visível — dá para **ver** o que aconteceu, e repetir.
4. **Falha recuperável.** Se não houver rede, a sentinela é mantida e a
   aplicação **se repete no próximo boot** — em vez de deixar o sistema pela metade.

> **Resumo:** a ISO entrega o *software e a intenção* (o perfil);
> o primeiro boot entrega o *contexto* (o hardware). Cada um faz o que sabe fazer.

---

## 4. Como gerar a ISO

### 4.1 Dependências

```bash
# Obrigatórias
sudo apt install -y xorriso curl coreutils

# Recomendadas (boot híbrido BIOS+EFI e patch do UEFI)
sudo apt install -y isolinux mtools
```

### 4.2 Primeiro: simular (sempre)

```bash
bash iso/build-iso.sh --disk /dev/nvme0n1 --profile auto --dry-run
```

### 4.3 Gerar de verdade

```bash
sudo bash iso/build-iso.sh --disk /dev/nvme0n1 --profile auto
```

> ⚠️ **`--disk` é o disco que será APAGADO** na máquina onde a ISO for
> instalada. Fixá-lo evita o pior cenário (instalar no disco errado). Se você
> não passar `--disk`, é preciso aceitar explicitamente com `--allow-any-disk`.

Opções mais usadas:

| Opção | Para que serve |
|-------|----------------|
| `--profile auto` | Perfil gravado na ISO. `auto` (padrão) detecta no hardware real. |
| `--firstboot-reboot` | Reinicia automaticamente ao fim do primeiro boot (aplica C-states). |
| `--password-hash '$6$…'` | Senha do usuário (gere com `mkpasswd -m sha-512`). Se omitido, gera e **mostra** uma. |
| `--username NOME` | Usuário administrativo (padrão `ai-cpu-os`; root fica bloqueado). |
| `--iso PATH` | Usa uma ISO local (trabalhar offline). |
| `--out PATH` | Caminho da ISO de saída. |
| `--keep-work` | Mantém o diretório de trabalho para inspeção. |

### 4.4 Testar numa VM **antes** de qualquer máquina real

```bash
qemu-system-x86_64 -m 4096 -enable-kvm -cdrom iso/out/ai-cpu-os-*.iso -boot d
```

Para um teste completo (instalação automática + primeiro boot), ver
[`docs/VALIDATION.md`](VALIDATION.md) **Bloco M**.

---

## 5. O que a ISO faz com a sua máquina

| Ação | Efeito | Onde desliga |
|------|--------|--------------|
| Particiona o disco | ⚠️ **Apaga** o disco de `--disk` | Não desliga — é o objetivo |
| Cria usuário com sudo | `--username`, senha definida/hash | `--username`, `--password-hash` |
| Bloqueia o root | `passwd/root-login false` | Editar o preseed |
| Instala pacotes base | `pkgsel/include` | `--extra-packages` |
| Copia o projeto | `/opt/ai-cpu-os` | — |
| Aplica o tuning no 1º boot | sysctl, THP, governor, C-states | Não instalar/parar o serviço |

**Segurança:** a senha **nunca** é gravada em texto puro na ISO — apenas o
hash crypt (`openssl passwd -6`). O root fica bloqueado por padrão.

---

## 6. Limitações conhecidas (e o que NÃO foi validado)

> Honestidade obrigatória (Regra 6 do [`AGENTS.md`](../AGENTS.md)).

| Item | Situação |
|------|----------|
| **A ISO nunca foi construída nem bootada** | ⚠️ **O script foi escrito e validado em `--dry-run`, mas nenhuma ISO real foi gerada nem instalada.** Requer `xorriso` (ausente no ambiente de desenvolvimento). |
| Só Debian netinst | O layout é detectado (isolinux + `install.*`). Outras ISOs falham com mensagem clara. |
| Boot BIOS (isolinux) | Caminho principal, implementado. |
| Boot UEFI | Implementado, mas **best-effort**: tenta `EFI/*/grub.cfg` na ISO; se o `grub.cfg` estiver dentro de `efi.img`, exige `mtools`. **Não validado.** |
| Rede obrigatória no 1º boot | O perfil `xeon` clona o llama.cpp. Sem rede, a aplicação é adiada para o próximo boot. |
| Tamanho | ~700 MB + espaço do projeto. |
| Assinatura | A ISO gerada **não é assinada**. Verifique o SHA256 que o script imprime. |
| `md5sum.txt` regenerado | Necessário para a checagem de integridade do instalador. Deve ser confirmado num teste real. |

---

## 7. Alternativas consideradas (e por que não)

| Alternativa | Prós | Por que foi descartada |
|-------------|------|------------------------|
| **simple-cdd** | Integrado ao Debian, gera ISO com preseed | Exige espelho local / baixa muita coisa; menos controle sobre o boot e o `late_command`. Fica na lista para simplificar no futuro. |
| **live-build** | ISO oficial do Debian, live + instalador | Pesado, exige ambiente limpo (chroot) e quebra fácil; `--debian-installer live` é notoriamente chato de scriptar. |
| **Packer** | Fluxo maduro, ótimo p/ nuvem | Produz **imagem de disco/VM**, não uma ISO de instalação. É outro entregável (e está no ROADMAP como ideia). |
| **Cubic** | GUI, simples p/ Ubuntu | Só Ubuntu, **não automatizável** — contraria "tudo por script". |
| **Ubuntu autoinstall (Subiquity)** | Caminho moderno p/ Ubuntu | Mecanismo diferente (cloud-init/nocloud em vez de preseed). Planejado — ver § 8. |
| **FAI (Fully Automatic Installation)** | Muito poderoso | Curva de aprendizado alta e infraestrutura própria; overkill para 2 máquinas. |

**Por que remaster + preseed:** é o que dá **controle total** sobre o boot e o
pós-instalação, **sem infraestrutura extra** (nenhum servidor, espelho ou
rede especial), e reaproveita a lógica que o projeto já tem (`detect-hardware.sh`
decidindo o perfil). Também mantém a filosofia: tudo por script, idempotente,
auditável.

---

## 8. Roadmap da ISO

| Prioridade | Item |
|-----------|------|
| 🔴 Alta | **Construir e bootar a ISO numa VM** (Bloco M do `VALIDATION.md`) — é o maior risco não validado do projeto. |
| 🔴 Alta | **Testar o boot UEFI** (com e sem `mtools`) e o `md5sum.txt` regenerado. |
| 🟡 Média | **Variante air-gapped:** embutir o fonte do llama.cpp e os `.deb` necessários, para instalar sem internet. |
| 🟡 Média | **Variante com binário pré-compilado:** usar os `.tar.gz` da Release em vez de compilar no primeiro boot (instalação muito mais rápida, mas por perfil). |
| 🟡 Média | **Suporte a Ubuntu** (autoinstall/Subiquity) via `--distro ubuntu`. |
| 🟢 Baixa | **CI:** workflow que gera a ISO em tags e anexa à Release. |
| 💡 Ideia | **Assinatura da ISO** com `gpg` + publicação do SHA256 no release. |
| 💡 Ideia | **Imagem de VM (qcow2)** via Packer, derivada da mesma lógica. |

---

## 9. Histórico

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação: `iso/build-iso.sh` + preseed + serviço de primeiro boot + este documento. Nada executado em ambiente real ainda. |
