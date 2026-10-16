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
| `intel-skylake-avx512` | Intel | Skylake-SP (v5) | Gold 61xx, Silver 41xx, Bronze 31xx, W-21xx | `skylake-avx512` | **auto** |
| `intel-cascadelake-sp` | Intel | Cascade Lake-SP (v6) | Gold 52xx/62xx, Platinum 82xx | `cascadelake` | **auto** |
| `intel-icelake-sp` | Intel | Ice Lake-SP (v7) | Gold 53xx/63xx, Platinum 83xx | `icelake-server` | **auto** |
| `intel-sapphirerapids-sp` | Intel | Sapphire Rapids (v8) | Gold 54xx/64xx, Max 94xx, W-24xx/34xx | `sapphirerapids` | **auto** + AMX |
| `intel-emeraldrapids-sp` | Intel | Emerald Rapids (v9) | Gold 55xx/65xx, Platinum 85xx | `emeraldrapids` | **auto** + AMX |
| `intel-graniterapids-sp` | Intel | Granite Rapids (Xeon 6, P-cores) | 6980P, 6780P | `graniterapids` (¹) | **auto** + AMX |
| `amd-zen1` | AMD | Zen / Zen+ | Ryzen 1000/2000, EPYC Naples | `znver1` | nunca |
| `amd-zen2` | AMD | Zen 2 | **Ryzen 3500X**, Ryzen 3000/4000, EPYC Rome | `znver2` | nunca |
| `amd-zen3` | AMD | Zen 3 | Ryzen 5000/6000, EPYC Milan | `znver3` | nunca |
| `amd-zen4` | AMD | Zen 4 | Ryzen 7000/8000, EPYC Genoa/Siena | `znver4` (¹) | **auto** |
| `amd-zen5` | AMD | Zen 5 | Ryzen 9000, Ryzen AI 300, EPYC Turin | `znver5` (¹) | **auto** |
| `generic` | — | Qualquer x86-64 | fallback | (vazio) | auto |

(¹) `-march` com exigência de GCC: `znver4` ≥ 13, `znver5`/`graniterapids` ≥ 14.
Em distros com GCC mais antigo, o `resolve.sh` cai automaticamente para o
fallback da família e **avisa**.

> 🎯 **AVX-512 é o padrão nas famílias que o têm** (decisão do dono,
> 2026-10-16): política `auto` — liga quando a CPU reporta a flag (verificação
> em runtime). `--no-avx512` desliga e troca o `-march` pelo fallback sem
> AVX-512, para comparar com AVX2.

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
