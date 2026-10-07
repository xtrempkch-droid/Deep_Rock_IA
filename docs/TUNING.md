# TUNING — Cada otimização explicada

> **Última atualização:** 2026-10-07

Este é o documento central de "por quê". Cada otimização aplicada pelos
scripts é listada com: **o que faz**, **o valor aplicado**, **por que
funciona** e **o risco/efeito colateral**. Onde aplicável, aponta o script
responsável.

> ⚠️ **Aviso geral:** tuning de kernel aumenta o consumo de energia. Governor
> `performance` + C-states rasos mantêm a CPU quente mesmo ociosa.

---

## 1. Governor de CPU: `performance`

- **Script:** `common/governor.sh`
- **Valor:** `performance` em `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`.
- **O que faz:** trava cada núcleo na maior frequência permitida, sem
  escalonamento dinâmico.
- **Por que importa:** com `powersave`/`ondemand`, um núcleo que acabou de
  "acordar" leva milhares de ciclos para subir de frequência. Durante um
  `matmul` de LLM, isso introduz latência variável (jitter) que se soma a
  cada token.
- **Custo:** CPU permanece em alta frequência mesmo ociosa → mais watts e
  calor. Recomenda-se mantê-lo apenas no servidor dedicado.
- **Idempotência:** verifica o valor atual antes de escrever.

---

## 2. Desativação de C-states profundos

- **Script:** `common/governor.sh` (orienta) + edição do GRUB.
- **Valor:** `intel_idle.max_cstate=1` (Intel/Xeon) — limita a C1.
- **O que faz:** impede a CPU de entrar em estados de baixo consumo (C3+),
  que têm latência de retorno alta.
- **Por que importa:** sair de C6 pode custar **~100 µs**; sair de C1 custa
  **~1 µs**. Em inferência com trabalho contínuo, evitar C-states profundos
  reduz a "latência de acordar" por token.
- **Como aplicar:** o parâmetro vai na **cmdline do kernel** (GRUB). O script
  documenta/edita `GRUB_CMDLINE_LINUX_DEFAULT` e exige **reboot** para valer.
  ⚠️ **Teste em VM antes** (regra do `AGENTS.md`).
- **Custo:** consumo em repouso sobe bastante.

---

## 3. Transparent Huge Pages (THP)

- **Script:** `common/hugepages.sh`
- **Valor:** `always` (configurável; fallback para `madvise`).
- **O que faz:** permite que o kernel use páginas de 2 MiB em vez de 4 KiB
  de forma automática.
- **Por que importa:** o trabalhão de inferência toca grandes regiões de
  memória (pesos). Com 4 KiB, a TLB (Translation Lookaside Buffer) transborda
  e cada acesso vira um *page walk* — stall. Com 2 MiB, o mesmo range cabe em
  ~512× menos entradas de TLB.
- **Risco:** `always` pode aumentar RSS e causar fragmentação/latência em
  cargas que alocam muito e liberam (ex.: JVM). Para LLM (alocação única e
  longa), é benéfico. Use `madvise` se quiser conservadorismo.
- **Verificação:**
  ```bash
  cat /sys/kernel/mm/transparent_hugepage/enabled
  ```

---

## 4. Huge pages estáticas (opcional)

- **Script:** `common/hugepages.sh`
- **O que faz:** reserva um pool de páginas de 2 MiB (`nr_hugepages`) que só
  pode ser usado via `mmap(MAP_HUGETLB)`.
- **Por que importa:** garante que o buffer de pesos tenha páginas grandes
  disponíveis e *não seja* quebrado em 4 KiB por fragmentação.
- **Trade-off:** memória reservada é **intocável** por outros processos. Em
  um servidor com 16 GB, reserve com parcimônia (ex.: 4 GB → 2048 páginas de
  2 MiB).
- **Aplicação em runtime:** o processo precisa usar `madvise(MADV_HUGEPAGE)`
  ou `MAP_HUGETLB`. O `shell-ia.py` orienta; o llama.cpp beneficia-se via THP
  `madvise` no `mmap` do modelo.

---

## 5. `vm.swappiness=10`

- **Script:** `common/kernel-tuning.sh` → `/etc/sysctl.d/99-ai-tuning.conf`
- **O que faz:** torna o kernel muito menos propenso a mover páginas anônimas
  para swap.
- **Por que importa:** durante a inferência, o modelo (GB) deve permanecer
  residente. Se o kernel paginar parte dele, o primeiro token sofre I/O de
  disco. `swappiness=10` mantém o modelo na RAM.
- **Nota:** o padrão costuma ser 60 (desktop). 10 é conservador para
  servidor.

---

## 6. `vm.vfs_cache_pressure=50`

- **Valor:** `50`.
- **O que faz:** torna o kernel mais relutante em descartar dentries/inodes em
  cache.
- **Por que importa:** se você recarrega o mesmo `.gguf` ou acessa o mesmo
  diretório de modelos com frequência, manter o cache reduz I/O repetido.
- **Trade-off:** usa mais RAM para cache (ok, temos 16–64 GB).

---

## 7. `vm.dirty_ratio=15` e `vm.dirty_background_ratio=5`

- **O que faz:**
  - `dirty_background_ratio=5`: kernel começa a escrever em background quando
    5% da RAM está "suja".
  - `dirty_ratio=15`: processos **bloqueiam** na escrita quando 15% da RAM
    está suja.
- **Por que importa:** evita picos gigantes de escrita em disco (write stall).
  Em um box que também serve builds/containers (Ryzen), isso suaviza o I/O e
  evita "engasgos".

---

## 8. `kernel.numa_balancing=0` (apenas single-socket)

- **Script:** `common/kernel-tuning.sh` (condicional!)
- **O que faz:** desliga o *automatic NUMA balancing*.
- **Por que importa:** em máquinas com **um único socket NUMA**, o
  balanceamento automático gasta tempo reagindo a page faults e **migrando
  páginas** sem benefício (não há outro nó para ir). Desligar remove esse
  overhead.
- **Condição:** aplicado **somente** se `numactl --hardware` ou
  `/sys/devices/system/node/` indicar 1 nó. Em multi-socket, mantemos ligado.

---

## 9. Buffers de rede (`net.core.rmem_max` / `wmem_max`)

- **Valor:** `134217728` (128 MiB) para ambos.
- **O que faz:** aumenta o teto dos buffers de socket.
- **Por que importa:**
  - No **Xeon**, o `llama-server` responde via HTTP; streams grandes (respostas
    longas) se beneficiam de buffer maior, menos syscalls de retry.
  - No **Ryzen**, o `docker push` para o registry (e pulls) trafegam por
    socket local; buffers maiores melhoram throughput em blobs de muitos MB.
- **Trade-off:** permite mais memória por conexão; ok em servidor dedicado.

---

## 10. `io_uring` (verificação)

- **Script:** `common/kernel-tuning.sh`
- **O que faz:** verifica se o kernel tem suporte a `io_uring` (kernel ≥ 5.1)
  e informa.
- **Por que importa:** `io_uring` é o mecanismo moderno de I/O assíncrono de
  baixa latência; reduzir syscalls no carregamento/streaming do modelo
  ajuda quando se lê o `.gguf` em disco. O script **não** modifica o I/O path
  do llama.cpp (isso é feito em código), mas garante que o kernel suporta e
  documenta a disponibilidade.
- **Verificação:**
  ```bash
  grep -i io_uring /proc/kallsyms | head -1
  # ou testar disponibilidade via ausência de erro em ferramenta que usa io_uring
  ```

---

## 11. Flags de compilação do llama.cpp

- **Script:** `profiles/<perfil>/llama-build.sh`

### Perfil Xeon (Haswell-EP, AVX2 apenas)

```bash
cmake -B build \
  -DGGML_NATIVE=ON \
  -DGGML_AVX2=ON \
  -DGGML_FMA=ON \
  -DGGML_F16C=ON \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
```

- `GGML_NATIVE=ON`: usa a ISA real da CPU (não assume flags inexistentes).
- `GGML_AVX2=ON`: habilita path de 256-bit.
- `GGML_FMA=ON`: multiplicação-acumulação fundida (menos instruções por GEMM).
- `GGML_F16C=ON`: conversão half→float em hardware.
- `GGML_BLAS=ON` + `OpenBLAS`: delega GEMMs grandes a um BLAS otimizado em
  AVX2.

### Perfil Ryzen (Zen 2, AVX2 apenas)

Mesmas flags + `-march=znver2 -mtune=znver2 -O3`:

```bash
cmake -B build \
  -DGGML_NATIVE=ON \
  -DGGML_AVX2=ON \
  -DGGML_FMA=ON \
  -DGGML_F16C=ON \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS \
  -DCMAKE_C_FLAGS="-march=znver2 -mtune=znver2 -O3"
```

- `-march=znver2`: instruções específicas do Zen 2; alinhamento de cache.
- **Nunca** `-mavx512f` — a CPU não tem AVX-512.
- O script **valida as flags em `/proc/cpuinfo` antes** e faz *fallback*
  seguro (desabilita flags ausentes) se algo não bater.

---

## 12. Threads de inferência (`-t`)

- **Xeon:** `-t 24` (1 por thread lógica). Em muitos casos, `-t 12` (1 por
  núcleo físico) supera 24 por evitar contenção de AVX2 entre threads
  irmãs. **Meça ambos.**
- **Ryzen:** `-t 6` (6 núcleos físicos, sem SMT).
- **Regra de bolso:** o gargalo é banda de memória; adicionar threads além do
  ponto de saturação de banda **piora** tokens/s.

---

## 13. Referências rápidas de verificação

```bash
# Governor atual
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
# THP
cat /sys/kernel/mm/transparent_hugepage/enabled
# Huge pages reservadas
grep Huge /proc/meminfo
# sysctl aplicados
sysctl vm.swappiness vm.vfs_cache_pressure kernel.numa_balancing
# C-states ativos
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
```

---

## Histórico

| Data       | Mudança                                        |
|------------|------------------------------------------------|
| 2026-10-07 | Documento inicial de tuning (`0.1.0-alpha`).   |
