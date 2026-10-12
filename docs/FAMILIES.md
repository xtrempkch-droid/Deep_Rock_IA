# docs/FAMILIES.md — Suporte por FAMÍLIA de CPU

> **Por que este documento existe.** Antes, o projeto suportava *um processador*
> (um único Xeon + um único Ryzen). Isso é fechado e desperdiça tempo: a
> otimização de uma microarquitetura vale para **dezenas de modelos**. Otimizar
> o Broadwell-EP (E5-2680 v4) beneficia automaticamente o E5-2620 v4, o
> E5-2660 v4… e o mesmo tuning de Haswell-EP vale para toda a família **v3**.
>
> Aqui o suporte é organizado por **família de microarquitetura**, com
> **herança** entre famílias.

---

## 1. Os três conceitos (não misture)

| Conceito | Responde | Onde vive | Exemplo |
|---|---|---|---|
| **Família** | *Quem é o hardware* → define `-march` e ISA | `families/<id>/family.conf` | `intel-broadwell` |
| **Papel** | *Para que serve a máquina* → define o que instalar | `roles/<id>/install.sh` | `inference`, `builder` |
| **Mod** | *Uma modificação isolada e reversível* | `mods/<id>/` | `openblas-threads` |

**Regra:** a família cuida de **CPU/ISA**. O papel cuida de **software/serviço**.
Nunca coloque ISA num papel, nem serviço numa família. Assim uma máquina
`amd-zen2` + papel `builder` e uma `amd-zen2` + papel `inference` compartilham
exatamente o mesmo build do llama.cpp.

---

## 2. Famílias disponíveis

| ID | Microarquitetura | `-march` | GCC mín. | AVX-512 | Herda de |
|---|---|---|---|---|---|
| `intel-haswell` | Haswell-EP (Xeon E5 **v3**) | `haswell` | qualquer | nunca | — |
| `intel-broadwell` | Broadwell-EP (Xeon E5 **v4**) | `broadwell` | qualquer | nunca | `intel-haswell` |
| `intel-skylake-avx512` | Skylake-SP / Cascade Lake (Scalable **v5/v6**) | `skylake-avx512` | 6 | **opt-in** | `intel-broadwell` |
| `amd-zen1` | Zen / Zen+ (Ryzen **1000/2000**) | `znver1` | 6 | nunca | — |
| `amd-zen2` | Zen 2 (Ryzen **3000/4000**) | `znver2` | 9 | nunca | `amd-zen1` |
| `amd-zen3` | Zen 3 (Ryzen **5000/6000**) | `znver3` | 11 | nunca | `amd-zen2` |
| `amd-zen4` | Zen 4 (Ryzen **7000/9000**, EPYC Genoa) | `znver4` | 13 | nunca | `amd-zen3` |
| `generic` | qualquer x86-64 | *(nenhum)* | — | **auto** | — |

> Um `-march` novo demais faz o compilador **rejeitar** a flag. Por isso cada
> família declara `FAMILY_MARCH_MIN_GCC` e um `FAMILY_MARCH_FALLBACK`: o
> `resolve.sh` consulta `gcc -dumpversion` e usa o fallback (avisando) em vez de
> quebrar o build.

---

## 3. Como a família é escolhida

```mermaid
flowchart TD
    A["/proc/cpuinfo · model name"] --> B{"casa com FAMILY_MATCH_NAME<br/>de alguma família?"}
    B -- "amd-zen4" --> C["amd-zen4"]
    B -- "amd-zen2" --> D["amd-zen2"]
    B -- "intel-broadwell" --> E["intel-broadwell"]
    B -- não --> F["generic (fallback)"]
    C --> G["load_family: _base → herança → família"]
    D --> G
    E --> G
    F --> G
    G --> H["compute_isa: cruza com /proc/cpuinfo<br/>(ou assume a família, em cross-build)"]
    H --> I["FAMILY_MARCH_EFFECTIVE<br/>FAMILY_GGML_FLAGS<br/>AVX512_ENABLED"]
```

A ordem de teste é do mais específico para o mais genérico:
`amd-zen4 → amd-zen3 → amd-zen2 → amd-zen1 → intel-skylake-avx512 →
intel-broadwell → intel-haswell → generic`.

Ver a decisão sem aplicar nada:

```bash
bash families/resolve.sh                 # relatório completo
bash families/resolve.sh --quiet         # só FAMILY=<id>
bash build.sh --list-families            # tabela das famílias
./detect-hardware.sh --quiet             # FAMILY= e ROLE=
```

---

## 4. Herança: o ponto central

`FAMILY_INHERITS` monta uma cadeia carregada de `_base` até a folha, em que
**cada nível sobrescreve o anterior**:

```text
families/_base/family.conf          (padrões de todos)
   └─ intel-haswell                  -march=haswell,  AVX2, policy=never
        └─ intel-broadwell           -march=broadwell (o resto herda)
             └─ intel-skylake-avx512 -march=skylake-avx512, policy=optin
```

Consequência prática: **corrigir o tuning em `intel-haswell` corrige também
Broadwell e Skylake-SP**, a menos que a família filha declare o contrário. Foi
exatamente o pedido que originou esta camada: *"as melhorias do Xeon 2680 v4
beneficiarão o 2620 v4 e, se evoluir, servirá à família v3"*.

O `load_family()` tem proteção contra ciclo (guarda de 16 níveis) para que um
`FAMILY_INHERITS` circular não trave a máquina.

---

## 5. Política de AVX-512 (`FAMILY_AVX512_POLICY`)

O projeto **não proíbe** AVX-512 para sempre — ele impede que ele seja ligado
**por acidente**. Três políticas:

| Política | Comportamento | Usada por |
|---|---|---|
| `never` | Nunca liga, mesmo se a CPU tiver | Haswell, Broadwell, Zen 1–4 |
| `optin` | Só liga com `--allow-avx512` **e** flag presente (ou família assumida) | Skylake-SP |
| `auto` | Liga se a CPU reportar `avx512f` | `generic` |

Como o AVX-512 é um *exemplo* dessa lógica, o mesmo mecanismo serve para AMX
(`-DGGML_AMX=ON` só entra quando a flag existe).

**Regra que continua valendo (AGENTS.md, regra 12):** nunca escreva
`-mavx512*` fixo em código, script ou imagem. O caminho é sempre
família → política → verificação em runtime → opt-in explícito.

```bash
# Ligar AVX-512 numa máquina Skylake-SP (se você confirma que é o alvo):
sudo bash llama-build.sh --family intel-skylake-avx512 --allow-avx512
```

---

## 6. Cross-build: `--assume-family-isa`

Quando o build acontece em **outra** máquina (o runner do CI, por exemplo), olhar
o `/proc/cpuinfo` local é *errado*: ele descreve o construtor, não o alvo.

Foi assim que o CI caía no bug clássico: `GGML_NATIVE=ON` num runner com AVX-512
gerava um binário que sofreria **SIGILL** nos alvos reais (E5 v3/v4 e Ryzen
3500X têm apenas AVX2).

A correção tem duas partes:

1. O padrão do `llama-build.sh` é **`GGML_NATIVE=OFF`** + flags **explícitas** da
   família → o artefato fica portátil dentro da família.
2. `--assume-family-isa` faz a decisão de ISA vir do `family.conf` em vez do
   `/proc/cpuinfo` → o binário do CI corresponde ao alvo, não ao runner.

```bash
# CI/release (para outra máquina):
bash llama-build.sh --family intel-broadwell --assume-family-isa --yes
# build na própria máquina (máxima ISA possível):
bash llama-build.sh --native
```

O `llama-build.sh` grava um `AI-CPU-OS-BUILD.txt` ao lado dos binários com
família, `-march`, ISA, se o AVX-512 entrou e se o build foi nativo ou portátil —
para você auditar a portabilidade sem adivinhar.

---

## 7. Como adicionar uma família nova

```bash
mkdir -p families/amd-zen5
$EDITOR families/amd-zen5/family.conf
bash build.sh --list-families        # confira que apareceu
bash families/resolve.sh --family amd-zen5   # teste o carregamento
```

`family.conf` mínimo (tudo o resto vem de `_base` e da herança):

```bash
FAMILY_ID="amd-zen5"
FAMILY_NAME="AMD Zen 5 (Ryzen 9000, EPYC Turin)"
FAMILY_VENDOR="amd"
FAMILY_ARCH="x86_64"
FAMILY_INHERITS="amd-zen4"          # herda o tuning da geração anterior
FAMILY_MARCH="-march=znver5 -mtune=znver5"
FAMILY_MARCH_MIN_GCC="14"           # GCC precisa conhecer znver5
FAMILY_MARCH_FALLBACK="-march=znver4 -mtune=znver4"
FAMILY_ISA_REQUIRED="avx avx2 fma f16c"
FAMILY_ISA_OPTIONAL="avx512f avx512vnni"
FAMILY_AVX512_POLICY="optin"        # Zen 5 tem AVX-512: opt-in, não automático
FAMILY_MATCH_NAME="Ryzen .* (9[0-9]{3}|1[0-9]{4})|EPYC .* [0-9]{3}5"
FAMILY_CPUID_HINT="family 26 (0x1A)"
FAMILY_NOTES="..."
```

**Checklist antes de commitar uma família nova:**

1. `FAMILY_MATCH_NAME` não rouba CPUs de uma família anterior (teste vários
   nomes reais; o casamento é por ERE sobre o `model name`).
2. `FAMILY_MARCH_MIN_GCC` é o GCC em que a flag passou a existir **e** existe um
   `FAMILY_MARCH_FALLBACK` utilizável.
3. `FAMILY_AVX512_POLICY` é `never`/`optin` — `auto` só para `generic`.
4. Adicione `families/<id>/family.conf` à lista `required` do workflow
   `validate.yml` e à tabela deste documento.

---

## 8. Campos do `family.conf`

| Campo | Obrigatório | Papel |
|---|---|---|
| `FAMILY_ID` | sim | identificador (= nome da pasta) |
| `FAMILY_NAME` | sim | nome legível (aparece nos relatórios) |
| `FAMILY_VENDOR` | não | `intel` / `amd` / `generic` |
| `FAMILY_ARCH` | não | `x86_64` |
| `FAMILY_INHERITS` | não | id da família-pai (cadeia de herança) |
| `FAMILY_MARCH` | não | `-march`/`-mtune` (`""` = usa a ISA detectada) |
| `FAMILY_MARCH_MIN_GCC` | não | GCC mínimo que aceita o `-march` (`0` = qualquer) |
| `FAMILY_MARCH_FALLBACK` | não | `-march` alternativo se o GCC for antigo |
| `FAMILY_ISA_REQUIRED` | sim | flags que a família deve ter (`+flag`/`-flag` no relatório) |
| `FAMILY_ISA_OPTIONAL` | não | flags extras aproveitáveis |
| `FAMILY_AVX512_POLICY` | sim | `never` \| `optin` \| `auto` |
| `FAMILY_MATCH_NAME` | sim* | ERE casado contra o `model name` (`""` = fallback) |
| `FAMILY_CPUID_HINT` | não | documentação (family/model do CPUID) |
| `FAMILY_NOTES` | não | observações das armadilhas daquela família |

\* `generic` é a única com `FAMILY_MATCH_NAME=""` — ela é o fallback.

---

## 9. Testes

```bash
bash -n families/resolve.sh && shellcheck -x -S warning families/resolve.sh
bash families/resolve.sh --quiet                      # FAMILY=<id>
bash families/resolve.sh --family amd-zen2 --allow-avx512   # política/força
for m in "E5-2680 v4" "E5-2620 v4" "E5-2678 v3" "Ryzen 5 3500X"; do
  CPU="Intel(R) Xeon(R) CPU $m" bash -c 'source families/resolve.sh; pick_family "$CPU"; echo "$CPU → $FAMILY_ID"'
done
```

**Status de validação:** a resolução de família foi exercitada com nomes reais de
CPU (E5 v3/v4, Scalable, Ryzen 1000/3000/5000/7000, APU) — casamento correto.
**Não validado em hardware real** (o notebook de desenvolvimento é um AMD
A4-3300M, que cai no `generic`) — ver `docs/VALIDATION.md`, Bloco N.
