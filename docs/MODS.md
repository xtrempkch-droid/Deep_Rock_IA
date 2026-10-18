# docs/MODS.md — Modificações portáveis

> **Por que existe.** Nem todo mundo quer (ou pode) aplicar o sistema inteiro.
> As **mods** são modificações pequenas, isoladas, **reversíveis** e
> documentadas que **qualquer pessoa pode aplicar e testar no seu próprio
> sistema operacional** — Ubuntu, Debian ou derivado — sem adotar o projeto
> todo e sem depender de uma CPU específica.

---

## 1. Os três comandos que importam

```bash
bash mods/apply.sh list                    # o catálogo
bash mods/apply.sh info <id>               # o que faz, risco, requisitos, ganho
sudo bash mods/apply.sh apply <id>         # aplica (idempotente)
sudo bash mods/apply.sh revert <id>        # desfaz, voltando ao padrão da distro
```

Sempre dá para olhar antes de aplicar:

```bash
sudo bash mods/apply.sh apply openblas-threads --dry-run
```

E o conjunto de base que o `build.sh` usa:

```bash
sudo bash mods/apply.sh apply --set system --dry-run
make mods-check        # os requisitos das mods estão satisfeitos aqui?
make mods-test         # sintaxe + dry-run idempotente em container Ubuntu
```

---

## 2. Anatomia de uma mod

```text
mods/<id>/
├── mod.conf    metadados (nome, risco, requisitos, famílias, ganho esperado)
├── apply.sh    aplica   — idempotente, aceita --dry-run/--yes
└── revert.sh   desfaz   — volta o sistema ao estado anterior
```

### `mod.conf`

```bash
MOD_ID="openblas-threads"
MOD_NAME="OpenBLAS com 1 thread"
MOD_DESC="Define OPENBLAS_NUM_THREADS=1 para o llama.cpp não brigar com o ggml."
MOD_RISK="low"                 # low | medium | high
MOD_REBOOT="no"                # precisa reiniciar para valer?
MOD_REQUIRES="path:/etc/environment"   # ver § 4
MOD_FAMILIES="any"             # any | lista/prefixos: "intel- amd-zen2"
MOD_ROLES="inference"          # any | inference | builder
MOD_SETS="portable"            # system | portable  (conjuntos aplicáveis)
MOD_ORDER="40"                 # ordem dentro do conjunto
MOD_GAIN="Evita oversubscription de threads; reduz jitter de latência."
```

**Regras de ouro de uma mod:**

1. **Idempotente** — rodar duas vezes não pode duplicar nada (use um bloco com
   marcadores `# >>> ai-cpu-os: <id> >>>`).
2. **Reversível** — se não der para desfazer, não é mod.
3. **`--dry-run`** — mostra exatamente o que faria, sem fazer.
4. **Nunca editar arquivo do sistema à mão sem backup** (`cp -a` com timestamp).
5. **Nunca aplicar em massa um mod `high`** sem confirmação explícita.

---

## 3. Catálogo

| ID | O que faz | Risco | Reboot | Conjunto | Papéis |
|---|---|---|---|---|---|
| `kernel-tuning` | sysctl de VM/memória, C-states rasos na cmdline, confere io_uring | medium | **sim** | `system` | any |
| `hugepages` | `transparent_hugepage` + huge pages estáticas opcionais | medium | **sim** | `system` | any |
| `governor` | `scaling_governor=performance` via serviço systemd | medium | no | `system` | any |
| `openblas-threads` | `OPENBLAS_NUM_THREADS=1` para não competir com o ggml | **low** | no | `portable` | inference |
| `network` | grava o netplan persistente (`99-ai-cpu-os.yaml`), tira o netplan do instalador/cloud-init do caminho e desliga a rede do cloud-init — **conserta a máquina que subia sem IP** | medium | no | `network` | any |
| `apt-sources` | diagnostica e conserta o `apt` de uma máquina **já instalada**: remove fontes que não existem (`file://` sem o diretório, `cdrom:` que a mídia deixou, `.sources` sem `URIs:`) com backup `.ai-cpu-os.bak`, grava a lista **oficial** da distro se nada sobrar e **valida com `apt-get update`** — **conserta a máquina em que TODO `apt-get update` falha** | medium | no | `apt` | any |

Conjuntos: **`system`** = o que o `build.sh` aplica (tuning de base);
**`portable`** = seguras em qualquer máquina, aplicáveis uma a uma;
**`network`** = só a conectividade, **nunca** aplicado automaticamente (mudar a
rede de um servidor é decisão do dono da máquina — e `apply --set system` roda
no build). **`apt`** = só as fontes de pacotes, com a mesma regra: reescrever o
`sources.list` de alguém não pode ser efeito colateral de aplicar tuning.

> Mods `high` (ex.: desativar C-states por completo, trocar o scheduler) **não**
> entram em nenhum conjunto automático: são sempre um `apply <id>` deliberado.

---

## 4. Requisitos (`MOD_REQUIRES`)

Avaliados pelo motor antes de aplicar (e mostrados por `check`):

| Token | Significado |
|---|---|
| `root` | precisa de `EUID 0` |
| `systemd` | `/run/systemd/system` existe |
| `linux>=5.1` | versão do kernel (comparação `sort -V`) |
| `cmd:docker` | o binário existe no `PATH` |
| `path:/etc/sysctl.d` | o caminho existe |
| `cpuflag:avx512f` | a flag está em `/proc/cpuinfo` |

Requisito não satisfeito **não interrompe** o `apply` — ele avisa e deixa a mod
decidir (é comum uma mod funcionar parcialmente e degradar com elegância).

---

## 5. Fronteiras de segurança

- Uma mod **nunca** deve presumir AVX-512/AMX: se precisar, use
  `cpuflag:` nos requisitos (ver `docs/FAMILIES.md` § 5).
- Mods que mexem em **kernel/GRUB** exigem reboot e são sempre `medium`+.
- O `mods/apply.sh test` roda as mods em **container Ubuntu sem `--privileged`**
  e apenas em `--dry-run`: ele valida sintaxe, execução e idempotência — nunca
  finge ter validado o efeito real na sua máquina.
- O que o container **não** prova: efeito de sysctl/governor/C-states e qualquer
  mod que dependa de hardware real. Isso está registrado em `docs/VALIDATION.md`
  (Bloco O) como **não validado**.

---

## 6. Como escrever uma mod nova

```bash
mkdir -p mods/meu-ajuste
$EDITOR mods/meu-ajuste/mod.conf
$EDITOR mods/meu-ajuste/apply.sh     # chmod +x, set -euo pipefail, --dry-run
$EDITOR mods/meu-ajuste/revert.sh    # desfaz exatamente o que apply fez
bash mods/apply.sh list              # apareceu?
bash mods/apply.sh info meu-ajuste   # metadados + requisitos
bash mods/apply.sh apply meu-ajuste --dry-run
bash mods/apply.sh revert meu-ajuste --dry-run
bash mods/apply.sh test meu-ajuste   # container (se docker disponível)
```

Estrutura mínima de um `apply.sh` (copie a de `mods/openblas-threads/`):

```bash
#!/usr/bin/env bash
set -euo pipefail
DRY_RUN=0
# ... parse de --dry-run/--yes, checagem de root ...
# 1. já está aplicado? -> sai 0 (idempotência)
# 2. dry-run? -> imprime o que faria e sai
# 3. backup -> aplica -> confirma
```

Depois: adicione a mod à tabela do § 3 **e** à lista `required` do workflow
`validate.yml` (regra do projeto: o CI precisa saber que ela existe).
