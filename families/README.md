# families/ — Suporte por FAMÍLIA de CPU (e não por processador único)

> **Por que existe:** manter suporte a **um** processador é fechado e desperdiça
> tempo. Uma família compartilha microarquitetura, ISA e comportamento de
> memória — então **otimizar a família beneficia todos os modelos dela**.
>
> Exemplo real: as otimizações para o **Xeon E5-2680 v4** beneficiam o
> **E5-2620 v4** (mesma família Broadwell-EP) **e também** a família **v3**
> (Haswell-EP), que é a sua base — por isso a **herança** entre famílias.
>
> Mesma ideia na AMD: o que funciona para um **Ryzen 3500X** (Zen 2) beneficia
> **todos** os Zen 2 (Ryzen 3000/4000, EPYC Rome).

---

## 1. Conceito: família, não modelo

| Camada | O que é | Exemplo |
|--------|---------|---------|
| **Família** (`families/<id>/family.conf`) | Microarquitetura. Define `-march`, ISA, política de AVX-512 e dicas de tuning | `intel-broadwell` |
| **Modelo** | O CPU concreto. **Não** tem arquivo próprio — é apenas um caso da família | E5-2680 v4, E5-2620 v4 |
| **Herança** (`FAMILY_INHERITS`) | Uma família pode estender outra, herdando e sobrescrevendo | `broadwell` herda de `haswell` |

> **Regra prática:** se você quer adicionar suporte a um CPU novo, pergunte
> *"é uma família nova?"*. Se for apenas outro modelo da mesma
> microarquitetura, **não crie nada** — ele já é coberto.

---

## 2. Famílias disponíveis

| Família | Vend. | Microarquitetura | Exemplos de CPU | `-march` | AVX-512 |
|---------|-------|------------------|-----------------|----------|---------|
| `intel-haswell` | Intel | Haswell-EP (v3) | E5-2678 v3, **E5-2680 v3**, E5-2620 v3 | `haswell` | nunca |
| `intel-broadwell` | Intel | Broadwell-EP (v4) | **E5-2680 v4**, E5-2620 v4, E5-2650 v4 | `broadwell` | nunca |
| `intel-skylake-avx512` | Intel | Skylake/Cascade (v5/v6) | E5-**v5**, Gold/Silver/Platinum | `skylake-avx512` | **opt-in** |
| `amd-zen1` | AMD | Zen / Zen+ | Ryzen 1000/2000 | `znver1` | nunca |
| `amd-zen2` | AMD | Zen 2 | **Ryzen 3500X**, Ryzen 3000/4000, EPYC Rome | `znver2` | nunca |
| `amd-zen3` | AMD | Zen 3 | Ryzen 5000/6000 | `znver3` | nunca |
| `amd-zen4` | AMD | Zen 4 | Ryzen 7000/9000, EPYC Genoa | `znver4` (¹) | nunca |
| `generic` | — | Qualquer x86-64 | fallback | (vazio) | auto |

(¹) `znver4` exige GCC ≥ 13. Em distros mais antigas (ex.: Debian 12, GCC 12) o
`resolve.sh` cai automaticamente para `znver3` e **avisa**.

> `generic` é o **fallback**: usa a detecção de ISA em tempo de execução, sem
> `-march` específico. É o que permite "outras máquinas" usarem o projeto.

---

## 3. Como funciona a resolução

```text
/proc/cpuinfo (nome do CPU)
        │
        ▼
  families/resolve.sh  ── casa o nome contra FAMILY_MATCH_NAME de cada família
        │
        ├─ nenhuma casa? → `generic`
        └─ casa? → carrega a cadeia de herança:
                       _base  →  haswell  →  broadwell   (exemplo)
                                (cada nível sobrescreve o anterior)
        │
        ▼
  Decide AVX-512 conforme FAMILY_AVX512_POLICY:
        never  → sempre desligado (a família não tem AVX-512)
        optin  → ligado SOMENTE com --allow-avx512 / AI_ALLOW_AVX512=1
        auto   → ligado se a CPU tiver a flag (usado por `generic`)
        │
        ▼
  Exporta FAMILY_ID, FAMILY_MARCH, FAMILY_ISA_FINAL, FAMILY_AVX512_ENABLED…
```

### Uso direto

```bash
bash families/resolve.sh                 # relatório legível (família + ISA + flags)
bash families/resolve.sh --quiet         # só "FAMILY=<id>" (para consumo por script)
bash families/resolve.sh --allow-avx512  # liga AVX-512 nas famílias com policy=optin
```

---

## 4. ⚠️ Política de AVX-512 (importante)

| Família | Política | Por quê |
|---------|----------|---------|
| Haswell-EP, Broadwell-EP | `never` | **Não têm AVX-512.** Habilitar = `SIGILL` (crash). |
| Todos os Zen (1–4) | `never` | **Nenhum Zen 1–4 tem AVX-512.** |
| Skylake/Cascade | `optin` | **Têm** AVX-512, mas é opt-in (consumo/térmico altos). |
| `generic` | `auto` | Liga se a CPU reportar a flag — cobre máquinas novas. |

**Como ligar (famílias com AVX-512):**

```bash
bash families/resolve.sh --allow-avx512
# ou
AI_ALLOW_AVX512=1 bash build.sh --family auto
```

> A ideia é **deixar a porta aberta** para máquinas que têm AVX-512 (e até AMX),
> **sem** quebrar as que não têm. O `-march` só é aplicado se a CPU tiver as
> flags — verificado em `/proc/cpuinfo` **em tempo de execução** (Regra 8).

---

## 5. Adicionar uma família nova

1. `mkdir families/<id>/`
2. Crie `families/<id>/family.conf` (copie de uma existente), ajustando:
   `FAMILY_ID`, `FAMILY_NAME`, `FAMILY_MATCH_NAME`, `FAMILY_MARCH`,
   `FAMILY_ISA_REQUIRED`, `FAMILY_AVX512_POLICY` e, se fizer sentido,
   `FAMILY_INHERITS`.
3. Teste: `bash families/resolve.sh` (ele deve listar a nova família).
4. Rode `make validate` (o CI verifica os `family.conf`).
5. Atualize a tabela do § 2 acima e o `docs/FAMILIES.md`.

> **Não** crie uma família por modelo. Só quando a **microarquitetura** muda
> (ou seja: quando o `-march`/ISA correto muda).

---

## 6. Estrutura de um `family.conf`

```sh
FAMILY_ID="intel-broadwell"
FAMILY_NAME="Intel Xeon E5 v4 (Broadwell-EP)"
FAMILY_VENDOR="intel"
FAMILY_ARCH="x86_64"
FAMILY_INHERITS="intel-haswell"            # opcional
FAMILY_MARCH="-march=broadwell -mtune=broadwell"
FAMILY_MARCH_MIN_GCC="4"                   # opcional (com FAMILY_MARCH_FALLBACK)
FAMILY_MARCH_FALLBACK=""                   # opcional
FAMILY_ISA_REQUIRED="avx2 fma f16c"
FAMILY_ISA_OPTIONAL=""
FAMILY_AVX512_POLICY="never"               # never | optin | auto
FAMILY_MATCH_NAME="E5-[0-9]{4} ?v4|Broadwell"
FAMILY_CPUID_HINT="family 6 / model 79"
FAMILY_NOTES="..."
```

Os arquivos são **shell puro** e são lidos com `source` — nada de parser YAML.
Isso mantém a filosofia do projeto: **zero dependências** no alvo.
