# docs/GPU.md — usar GPU (opção, sempre explícita)

> **Última atualização:** 2026-10-12
>
> **Resumo:** o `ai-cpu-os` é um projeto de inferência **100% em CPU** — isso
> não mudou. Este documento existe porque **deixar a porta aberta é melhor do
> que fingir que ela não existe**: se alguém quiser usar uma GPU, o caminho é
> explícito, documentado e registrado. O que nunca acontece é a GPU entrar em
> silêncio.

---

## 1. Por que a GPU é opcional e não padrão

Todo o tuning do projeto pressupõe CPU. Olhe o que ele mexe:

| Tuning do ai-cpu-os | Faz sentido com GPU? |
|---|---|
| Banda de memória / canais / `numa_balancing` | **Pouco.** O gargalo passa a ser a **VRAM** e o barramento (PCIe). |
| `C-states` rasos (wake-up ~1µs) | **Pouco.** Reduz latência de despacho, mas o trabalho pesado saiu da CPU. |
| Governor `performance` | **Pouco.** Ajuda tokenização/prompt, não o matmul na GPU. |
| Huge pages / THP | **Pouco.** Importante para os pesos em RAM; se foram para a VRAM, não. |
| `OPENBLAS_NUM_THREADS=1` | **Indiferente** — a BLAS deixa de ser o caminho quente. |

Ou seja: nada aqui *atrapalha* a GPU, mas também quase nada *ajuda*. Prometer
ganho de GPU com o discurso de CPU deste projeto seria enganoso. Daí a escolha:
**opt-in com aviso**, em vez de default silencioso.

---

## 2. Como ligar (nada é automático)

```bash
# 1) Ver o que existe nesta máquina (somente leitura, não compila nada):
bash llama-build.sh --gpu-check

# 2) Compilar com um backend EXPLÍCITO:
bash llama-build.sh --gpu vulkan      # cuda | rocm | vulkan | sycl | metal
```

Backends e a flag de CMake correspondente:

| Backend (`--gpu`) | Flag aplicada | Serve para |
|---|---|---|
| `cuda` | `-DGGML_CUDA=ON` | NVIDIA |
| `rocm` | `-DGGML_HIP=ON` | AMD (ROCm instalado) |
| `vulkan` | `-DGGML_VULKAN=ON` | **NVIDIA, AMD e Intel** — o mais portátil |
| `sycl` | `-DGGML_SYCL=ON` | Intel (oneAPI) |
| `metal` | `-DGGML_METAL=ON` | macOS / Apple Silicon |

**Não existe `--gpu auto`.** Escolher backend automaticamente é exatamente o
tipo de mágica que faz um build "funcionar" na máquina errada. Se você não sabe
qual usar: rode `--gpu-check` e leia a seção 4.

Faltou uma flag que o seu caso exige? Use `--cmake-extra` (repassada ao CMake,
separada por espaços):

```bash
# Exemplo real: RX 580 é Polaris (gfx803)
bash llama-build.sh --gpu rocm --cmake-extra "-DAMDGPU_TARGETS=gfx803"
```

O build **registra** o que fez, em `AI-CPU-OS-BUILD.txt`, ao lado dos binários:

```text
Família:   intel-broadwell (Intel Xeon E5 v4 (Broadwell-EP))
March:     -march=broadwell -mtune=broadwell
ISA:       +avx +avx2 +fma +f16c
GPU:       vulkan (-DGGML_VULKAN=ON)     ← sem esta linha, é build 100% CPU
```

Isso existe por um motivo prático: sem esse registro, alguém compara um
`llama-bench` com GPU contra os números de CPU de `docs/STATE.md` e conclui
qualquer coisa. **Não compare.** São medições de coisas diferentes.

---

## 3. O que muda no uso (e nas suas expectativas)

### O novo limite é a VRAM

Em CPU, a pergunta era "cabe na RAM?". Com GPU, passa a ser **"cabe na VRAM?"**.
Um modelo 7B Q4 (~4 GB) precisa de ~4 GB de VRAM livre para rodar inteiro na
GPU. Se não couber, **não é tudo ou nada**: dá para descarregar só parte das
camadas.

```bash
# Empurra até 999 camadas para a GPU (o llama.cpp corta no que couber):
llama-bench -m modelo.gguf -ngl 999

# Escolher quantas cabem de fato: suba aos poucos e veja o tempo de carga
llama-bench -m modelo.gguf -ngl 20
```

`-ngl N` (número de camadas na GPU) é a alavanca central. `-ngl 0` = tudo na
CPU (o comportamento padrão do projeto).

### O que continua valendo

- **O projeto inteiro continua funcionando**: mods, papéis, famílias, serviço
  `ai-server`. Você só trocou *onde o matmul roda*.
- **RAM e disco** continuam importando (o modelo é lido do disco uma vez).
- **A porta de serviço** (`:8080`), o `shell-ia.py` e o resto: sem mudança.

### Para usar no serviço (`ai-server`)

O build com GPU é o primeiro passo; o serviço precisa passar o `-ngl`. Não
automatizamos isso de propósito (é opt-in), mas é um drop-in só:

```bash
sudo systemctl edit ai-server
# [Service]
# ExecStart=
# ExecStart=/usr/local/bin/llama-server -m /opt/models/seu.gguf --host 0.0.0.0 \
#           --port 8080 -t 14 -ngl 999
sudo systemctl daemon-reload && sudo systemctl restart ai-server
```

---

## 4. Casos concretos (incluindo o hardware deste projeto)

### AMD RX 580 8 GB (a GPU da máquina `builder` deste projeto)

Situação real e sem enfeite:

- É **Polaris** (gfx803). O **ROCm oficial deixou o Polaris de lado** a partir
  do ROCm 4; o suporte que existiu era comunitário e hoje é trabalhoso.
- A via realista nesta GPU é **Vulkan** (`--gpu vulkan`), via Mesa/RADV, que
  costuma funcionar bem para inferência.
- ⚠️ **O `docs/HARDWARE.md` deste projeto registra que ela apresenta artefatos
  de tela sob carga.** Ela foi escolhida para *saída de vídeo*, e essa
  observação continua valendo: use-a para computação só se aceitar o risco, e
  nunca na máquina `inference`.
- Com 8 GB de VRAM, cabe um modelo ~7B Q4 inteiro, ou um maior com `-ngl`
  parcial.

```bash
bash llama-build.sh --gpu vulkan          # caminho recomendado nesta GPU
bash llama-build.sh --gpu rocm --cmake-extra "-DAMDGPU_TARGETS=gfx803"   # alternativa
```

### NVIDIA

`--gpu cuda` (precisa do toolkit CUDA). É o caminho mais bem testado a
montante, no llama.cpp — mas **não** foi testado por este projeto: ver § 6.

### Intel

`--gpu sycl` (oneAPI) ou `--gpu vulkan` (mais simples de montar).

---

## 5. Como reverter

Não há estado a desfazer: a GPU é escolha de **build**, não de sistema.

```bash
# Voltar ao build 100% CPU (é só não passar --gpu):
bash llama-build.sh --family <sua-família>

# O registro diz qual era qual:
cat /opt/llama.cpp/build/bin/AI-CPU-OS-BUILD.txt
```

Se você mexeu no `ai-server` para passar `-ngl`, remova o drop-in:

```bash
sudo systemctl revert ai-server     # desfaz o systemctl edit
sudo systemctl restart ai-server
```

As **mods** aplicadas (`mods/apply.sh`) são independentes disso e continuam
valendo — use `mods/apply.sh revert <id>` se quiser desfazê-las por outros
motivos.

---

## 6. O que este projeto NÃO garante (leia antes de confiar)

Honestidade obrigatória (Regra 6 do `AGENTS.md`):

| Item | Situação |
|---|---|
| **Qualquer backend de GPU** | ⚠️ **Nunca foi compilado nem executado por este projeto.** O caminho está escrito e as flags são as do llama.cpp, mas não há medição, nem teste, nem validação. |
| Desempenho | Desconhecido. Não existe benchmark de GPU em `docs/STATE.md` — e não invente um. |
| `--gpu-check` | ⚠️ Escrito e executado apenas para *relatar* o que existe na máquina de desenvolvimento (que tem GPUs antigas, sem backend utilizável). |
| Números de `docs/STATE.md` | ❌ **Não valem** para um build com GPU. |
| O tuning de CPU | Não é desligado com GPU; ele apenas rende pouco. Nada quebra. |
| Hardware alvo do projeto | O Xeon E5-2680 v4 **não tem GPU**, e a RX 580 pertence à outra máquina. Ou seja: **nem os dois sistemas de referência exercitam este caminho.** |

Consequência prática, dita sem rodeio: **a opção está aberta e documentada, não
validada.** Se você usar, você é a validação — e o convite é registrar o
resultado em `docs/VALIDATION.md` (Bloco P) para que o próximo não comece do
zero.

---

## 7. Por que assim (e não "suporte a GPU" no papel de um papel)

Uma alternativa tentadora era criar `roles/gpu-inference`. Descartada por ora:
seria um papel inteiro (serviço, dependências, validação) sustentado por **zero
medição** — e papéis existem para o que o projeto realmente opera.

A forma escolhida — flag explícita + aviso + registro + este documento — dá a
quem quer usar:

1. um caminho **que funciona hoje** (as flags são as do llama.cpp);
2. **avisos honestos** sobre o que deixa de valer;
3. **rastro** para ninguém comparar medições incomparáveis;
4. e zero risco de a GPU entrar em cena por acidente.

Se um dia houver medição real e alguém usar isso de forma contínua, o passo
seguinte é promover o caminho a um papel (`roles/`) com números e testes
próprios — aí sim com fundamento.
