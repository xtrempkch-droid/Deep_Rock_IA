# TROUBLESHOOTING — Problemas conhecidos e soluções

> **Última atualização:** 2026-10-07

Formato: **Sintoma → Causa provável → Solução.** Adicione novos casos aqui
sempre que resolver um problema real (regra do `AGENTS.md`).

---

## Compilação do llama.cpp

### `SIGILL` (Illegal instruction) ao rodar o binário

- **Causa:** binário compilado com ISA que a CPU não suporta (ex.: AVX-512
  em Xeon E5-2678 v3 ou Ryzen 5 3500X).
- **Solução:** recompile com `-DGGML_NATIVE=ON` (sem forçar
  `-mavx512*`). Verifique:
  ```bash
  grep -o -m1 -E 'avx512|amx' /proc/cpuinfo || echo "sem AVX-512/AMX — correto"
  ```
  O `llama-build.sh` já valida as flags; rode-o novamente.

### Erro de CMake: `GGML_BLAS_VENDOR` desconhecido

- **Causa:** versão antiga do llama.cpp/CMake sem essa variável, ou OpenBLAS
  não instalado.
- **Solução:** instale `libopenblas-dev` e atualize o CMake (`cmake --version`
  ≥ 3.16). Como fallback, remova `-DGGML_BLAS` (perde-se pouco em AVX2
  puro).

### CMake falha: `Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)`

- **Sintoma:** o `cmake -B build ...` aborta com o stack apontando para
  `ggml/src/ggml-blas/CMakeLists.txt` → `find_package(PkgConfig)`.
- **Causa:** o backend BLAS do ggml localiza o OpenBLAS via `pkg-config`.
  O pacote `libopenblas-dev` instala a biblioteca, **mas não** o `pkg-config`.
- **Solução:**
  ```bash
  sudo apt install -y pkg-config
  ```
  Os scripts do projeto já instalam isso automaticamente (corrigido após o CI
  detectar o problema — ver `docs/CI.md` § 8.1).
- **Não confunda** com o aviso `Could NOT find OpenSSL`: aquele é apenas
  informativo (com `LLAMA_CURL=OFF` o HTTPS não é usado pelo servidor).

### Build muito lento / OOM no Xeon (16 GB)

- **Causa:** `make -j24` consome muita RAM em arquivos pesados.
- **Solução:** reduza paralelismo: `cmake --build build -j 6`. No Ryzen,
  `-j 6` é natural.

### `fatal error: ggml.h: No such file` ou `-lopenblas` não encontrado

- **Solução:**
  ```bash
  sudo apt install -y libopenblas-dev build-essential cmake git
  ```

---

## Kernel / Tuning

### Governor não muda para `performance`

- **Causa:** driver de cpufreq `powersave`/`intel_pstate` sem suporte, ou
  caminho diferente.
- **Solução:**
  ```bash
  cpupower frequency-info
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
  ```
  Se `performance` não estiver na lista, tente `cpupower frequency-set -g performance`.
  Em `intel_pstate` com modo `active`, o governor é passivo — ajuste via
  `cpupower` e/ou `intel_pstate=passive` na cmdline.

### `intel_idle.max_cstate=1` não surte efeito

- **Causa:** parâmetro só vale na **cmdline do kernel** — precisa reboot.
- **Solução:**
  1. Edite `GRUB_CMDLINE_LINUX_DEFAULT` em `/etc/default/grub`, acrescente
     `intel_idle.max_cstate=1`.
  2. `sudo update-grub`
  3. Reboot.
  4. Confirme: `cat /proc/cmdline` e
     `cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name` (deve parar em
     `C1`).

### THP não fica em `always`

- **Causa:** alguns kernels/distros usam `madvise` por padrão e o runtime
  pode reverter.
- **Solução:**
  ```bash
  echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
  ```
  Para persistir, adicione ao `common/hugepages.sh` (já faz isso) ou use
  `systemd-tmpfiles`/unit própria. Se `always` causar problemas, use
  `madvise` + `MADV_HUGEPAGE` explícito.

### Huge pages estáticas "somem" após reboot

- **Causa:** `nr_hugepages` não é persistente por si.
- **Solução:** o `hugepages.sh` grava a reserva num service/`sysctl.d`
  (`vm.nr_hugepages`). Confirme com `grep Huge /proc/meminfo`.

---

## Detecção de hardware

### `dmidecode` não mostra canais de memória (ou falha)

- **Causa:** algumas BIOS/placas (ex.: JGINYUE) reportam DMI incompleto;
  `dmidecode` precisa de root.
- **Solução:** rode como root. Se ainda falhar, o script usa heurística
  (conta DIMMs populados e agrupa por `Locator`). Para confirmar manualmente,
  consulte o manual da placa. Alternativa: `sudo lshw -class memory`.

### Falso "single channel" no Ryzen

- **Causa:** heurística baseada em `Locator`; pode errar se a BIOS nomear
  slots de forma não padrão.
- **Solução:** confirme à mão — na maioria das MSI B550, dual channel exige
  slots `A2` + `B2`. Se realmente está em single channel, **mova os pentes**.

---

## Docker / Registry (perfil Ryzen)

### `docker push` para `localhost:5000` falha com TLS/HTTPS

- **Causa:** o Docker exige TLS para registries por padrão.
- **Solução:** o `registry-setup.sh` adiciona `localhost:5000` em
  `/etc/docker/daemon.json` → `insecure-registries`. Se não pegou:
  ```bash
  sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
  { "insecure-registries": ["localhost:5000"] }
  JSON
  sudo systemctl restart docker
  ```

### `Cannot connect to the Docker daemon`

- **Solução:** `sudo systemctl enable --now docker` e adicione seu usuário ao
  grupo: `sudo usermod -aG docker "$USER"` (relogue).

### Registry enche o disco (blobs acumulam)

- **Causa:** `registry:2` não faz garbage collection automática.
- **Solução:** rode GC ocasionalmente:
  ```bash
  docker exec -it registry registry garbage-collect /etc/docker/registry/config.yml
  docker exec -it registry registry garbage-collect -m /etc/docker/registry/config.yml
  ```

---

## Gitea

### Gitea não sobe / `port is already allocated`

- **Causa:** portas 3000 ou 2222 ocupadas.
- **Solução:** `ss -ltnp | grep -E ':3000|:2222'` e ajuste as portas no
  `gitea-compose.yml`.

### Não consigo clonar via SSH na porta 2222

- **Causa:** URL SSH padrão usa porta 22.
- **Solução:**
  ```bash
  git clone ssh://git@<host>:2222/<user>/<repo>.git
  ```
  Ou configure `~/.ssh/config` com `Port 2222`.

---

## shell-IA (perfil Xeon)

### Erro de conexão com o llama-server

- **Causa:** serviço não está de pé.
- **Solução:**
  ```bash
  sudo systemctl status ai-server
  sudo systemctl restart ai-server
  curl -s http://127.0.0.1:8080/health
  ```

### Modelo não carrega / OOM

- **Causa:** modelo grande demais para 16 GB.
- **Solução:** use ≤ 7B em Q4_K_M (ex.: Qwen2.5-Coder-1.5B ou 7B Q4).
  Monitore: `watch -n1 free -h`.

### Comando bloqueado pela whitelist

- **Causa:** sandbox funcionando como esperado.
- **Solução:** edite a `WHITELIST` no topo de `profiles/xeon/shell-ia.py`
  conscientemente. Evite adicionar comandos destrutivos.

---

## Geral

### `build.sh` falha dizendo que não está como root

- **Solução:** use `sudo ./build.sh ...`. Para simular sem aplicar:
  `./build.sh --profile auto --dry-run` (dry-run não precisa de root para
  inspecionar, mas a detecção de RAM pode precisar).

### Rodar duas vezes quebrou algo (esperado idempotente)

- **Causa:** bug de idempotência — **reporte!**
- **Solução:** verifique logs com timestamp; os scripts só escrevem se o
  valor estiver diferente. Abra uma issue com o trecho de log.

---

## Histórico

| Data       | Mudança                                            |
|------------|----------------------------------------------------|
| 2026-10-07 | Documento inicial de troubleshooting (`0.1.0-alpha`). |
