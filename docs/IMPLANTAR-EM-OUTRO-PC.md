# Implantar e testar o ai-cpu-os em **outro** PC

> **Para quem é este documento:** quem gerou a ISO (ou pegou o artefato do CI)
> numa máquina e vai **instalar/validar em outra**. Ele existe porque metade das
> falhas do projeto só aparecem **na máquina de destino** — e a mensagem que
> chega não diz o motivo.
>
> 📌 **Registro da tentativa:** o que foi feito, o que foi provado e o que
> **não** foi está no § 5 deste arquivo e nas sessões do `docs/JOURNAL.md`.
> Este documento é o **roteiro prático**; o diário é a **memória**.

---

## 1. Antes de sair da máquina que gera: gere com `--disk auto`

Se a ISO vai instalar em **outro** PC, **não** fixe o disco:

```bash
sudo bash iso/build-iso.sh --distro ubuntu --disk auto --serial-console \
     --role auto --family auto --iso-source auto --iso-model auto --iso-repo auto
```

Por quê: o `storage` do autoinstall sai como
`layout: {name: direct, match: {path: /dev/vda}}` se o disco for fixado. Numa
máquina real (NVMe `/dev/nvme0n1`, SATA `/dev/sda`) **nenhum disco casa** e o
instalador **não instala sozinho — sem mensagem de erro**. Com `--disk auto` o
layout é `layout: {name: direct}` e o Subiquity escolhe o maior disco.

O build **avisa** se você fixar um disco que não existe na máquina que gera:

```text
[WARN ] O disco fixado /dev/vda NÃO existe nesta máquina.
[WARN ] Se ele também não existir no ALVO, o Subiquity não acha disco que case
[WARN ] e a instalação automática NÃO acontece. Se a ISO é para outro PC, use
[WARN ] --disk auto (o instalador escolhe o maior disco) ou o --disk do alvo.
```

> ✅ **O default do CI (`iso.yml`) já é `auto`** desde 2026-10-16: o artefato do
> GitHub Actions instala em VM **e** em hardware real sem regerar nada.

---

## 2. Checklist na máquina de DESTINO

Rode na ordem. Cada item diz **o que confirma** e **o que fazer se falhar**.

### 2.1 A mídia está íntegra?

```bash
make iso-check ISO=~/Downloads/ai-cpu-os-ubuntu.iso
```

Esperado: tamanho plausível, SHA256 batendo, `CD001`, Volume ID `AI_CPU_OS_*`.
O modo de falha mais comum: o navegador entregar o **artifact (`.zip`)** em vez
do `.iso` — o `make iso-check` detecta e diz.

### 2.2 Boot: a ISO entrou sozinha na instalação?

⚠️ **Sem `--serial-console` você não vê nada** — a instalação e o 1º boot não
têm tela. Se a ISO foi gerada sem a flag, o teste automatizado não enxerga nada
(e o `test-vm.sh` avisa exatamente isso).

Com console serial (VM ou cabo/BIOS redirecionando para `ttyS0`):

| Marcador esperado | Significa |
|---|---|
| `[ai-cpu-os/iso-late]` | o `late-command.sh` rodou (fim da instalação) |
| `[ai-cpu-os/firstboot]` | o **1º boot** aplicou o tuning |
| `status=ok` | o `build.sh` do alvo terminou bem |

### 2.3 O 1º boot aplicou o ai-cpu-os?

```bash
systemctl status ai-cpu-os-firstboot
cat /var/log/ai-cpu-os-firstboot.log
cat /opt/ai-cpu-os/AI-CPU-OS-BUILD.txt     # família, -march, ISA, AVX-512
```

### 2.4 A inferência funciona?

```bash
llama-server --version        # ou: /opt/llama.cpp/build/bin/llama-server --help
systemctl status ai-server
curl -s localhost:8080/v1/models
```

---

## 3. Os 3 modos em que a automação **não** acontece

Se a instalação parou na tela do instalador (ou o 1º boot não rodou), é um
destes. Detalhes e evidência em `docs/TROUBLESHOOTING.md` § "SINALIZADO".

| # | Modo | Estado | Como reconhecer |
|---|---|---|---|
| 1 | **Disco fixado que não existe no alvo** | ✅ **corrigido** (2026-10-16) | A ISO saiu com `--disk /dev/vda` e o alvo não tem `/dev/vda`. **Regenere com `--disk auto`.** |
| 2 | **UEFI nunca bootado** | ⚠️ **aberto** | Boota mas sobe o **menu** (entrada 0 = "Try or Install Ubuntu Server"). Teste: `bash iso/test-vm.sh --iso … --boot-mode uefi --yes` (precisa de `ovmf`). |
| 3 | ~~**Debian/preseed nunca executado**~~ | 🗑️ **fora de escopo** | O caminho Debian foi **removido** (ADR-001, sessão #42): `--distro debian` aborta. |

---

## 4. Como medir e registrar

O que importa medir (e o que **não** vale):

```bash
# tokens/s do llama.cpp, com o modelo embutido:
llama-bench -m /opt/models/<modelo>.gguf -t $(nproc)
```

> ⚠️ **Compare só o que é comparável.** O `AI-CPU-OS-BUILD.txt` registra a
> família, o `-march` e se o AVX-512 entrou. Duas medições com ISA diferente
> **não** são comparáveis. Ver `docs/GPU.md` se houver GPU (com GPU, os números
> de `docs/STATE.md` não valem).

Preencha o **Bloco M** de `docs/VALIDATION.md` (é o protocolo da ISO) e, se
mudou algo no projeto, registre a sessão em `docs/JOURNAL.md` (Regra 14).

---

## 5. Registro da tentativa (o que está provado e o que não está)

> Honestidade obrigatória (Regra 6 do `AGENTS.md`).

### 5.1 O que motivou esta rodada

| Relato (do dono, testando) | O que foi feito |
|---|---|
| "a criação da ISO ubuntu apresentou **travamento**; teste será feito em outra máquina" | `download_to()`: `--connect-timeout` + `--speed-limit/--speed-time` (aborta conexão **estagnada**, não conexão lenta) e **confere que o `.part` existe e não está vazio** antes do `mv` |
| "`mv: cannot stat '…/models/…gguf.part': No such file or directory`" | Duas causas: (a) **dois builds ao mesmo tempo** no mesmo `--work-dir` (um renomeia o `.part` que o outro ainda escreve) → **trava `flock`** de instância única; (b) o `mv` às cegas → checagem antes. Teste: `make iso-lock-test` (13) |
| "modo 1: a ISO pode não instalar automaticamente em outro PC" | `--disk auto` (que era **quebrado**) agora funciona; formato do disco validado; **aviso** de disco inexistente; **default do CI = `auto`**. Teste: `make iso-disk-test` (16) |
| "olhe o suporte a AVX-512 e mude o padrão das famílias" | As famílias que **têm** AVX-512 passaram a `auto` (liga sozinho); `--no-avx512` desliga. Teste: `make avx512-test` (61) |

### 5.2 Provado (por teste automatizado, nesta máquina)

```
make validate  →  TUDO VERDE
  bash -n            40 scripts
  shellcheck         OK
  families           85 asserções
  avx512             61      ← política AVX-512 das 14 famílias
  iso-selection      13      ← escolha da ISO oficial no SHA256SUMS
  iso-repo-filter    16      ← filtro/fallback do repositório apt
  verify-repo-distro  6      ← verificador distro-aware
  ci-guards          43      ← cada guarda provado por violação plantada
  iso-lock           13      ← trava de instância única (flock real)
  iso-disk           16      ← --disk auto / inválido / ausente
  write-pendrive     16      ← travas do gravador (alvo = arquivo)
  check-iso          20      ← ISO baixada (fixtures byte a byte)
  webui              38      ← API + salvaguardas da interface web
  iso-dry-run-both   OK      ← ubuntu + debian
```

### 5.3 ⚠️ **NÃO** provado (não trate como ok)

- 🔴 **Nenhuma ISO bootada nesta rodada.** Os testes acima são de **conteúdo e
  lógica**, não de instalação real.
- 🔴 **Modo 2 (UEFI) continua sem execução.** O Modo 3 (Debian/preseed) saiu de escopo — o caminho foi removido (ADR-001).
- 🔴 **Nenhum pendrive físico gravado** e **nenhum hardware real** validado
  (Blocos A–O de `docs/VALIDATION.md` em branco).
- ⚠️ A **interface web nunca foi aberta num navegador** — os testes exercitam
  a API.
- ⚠️ O **aviso de disco inexistente** foi provado por teste; **não** foi provado
  contra um alvo real com disco diferente.

---

## 6. Se algo falhar no outro PC: o que trazer de volta

Traga **estes três** e o diagnóstico fica muito mais rápido:

```bash
# 1. O resumo da instalação no console serial (últimas ~100 linhas)
# 2. O estado do serviço e o log do 1º boot
systemctl status ai-cpu-os-firstboot --no-pager
cat /var/log/ai-cpu-os-firstboot.log

# 3. Como a ISO foi gerada (disco fixado? payload embutido?)
cat /opt/ai-cpu-os/.iso-config      # ROLE, FAMILY, DISTRO, MODEL_FILE, LLAMA_SRC
cat /opt/ai-cpu-os/AI-CPU-OS-BUILD.txt
```

> 💡 **Sem tela e sem serial, não há diagnóstico.** É o que a `--serial-console`
> existe para evitar — a sessão #21 desta máquina só achou o bug do GRUB porque
> capturou o **framebuffer** (`screendump` por QMP). Ver `docs/JOURNAL.md` § 6.
