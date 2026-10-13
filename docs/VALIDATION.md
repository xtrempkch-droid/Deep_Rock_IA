# VALIDATION — Protocolo de testes em hardware (para trazer resultados depois)

> **Para que serve este documento:** é um **roteiro de testes preenchível**.
> Você executa os blocos no hardware real, **anota os resultados nos campos
> `_(preencher)_`** e, quando terminar, traz o documento de volta para que os
> números sejam consolidados em `docs/STATE.md` e o `docs/TUTORIAL.md` seja
> atualizado (Regras 2, 3 e 9 do [`AGENTS.md`](../AGENTS.md)).
>
> **Estado atual:** o CI comprova que o código **compila e roda**; este
> protocolo mede o que o CI **não** consegue — tuning de kernel, detecção real
> de hardware e **tokens/s**.
>
> **Criado em:** 2026-10-07 · **Versão a validar:** `v0.2.0`
> (commit `566583c`) · **Documento de referência:** [`docs/STATE.md`](STATE.md)

---

## Como usar (leia antes de começar)

1. **Não precisa fazer tudo de uma vez.** Os blocos são independentes; faça os
   que puder e marque o status.
2. **Prefira `--dry-run` primeiro.** Ele mostra o que seria feito sem alterar
   nada. Só depois rode sem `--dry-run`.
3. **Anote na hora.** Preencha os campos `_(preencher)_` conforme for rodando;
   não confie na memória.
4. **Guarde as saídas brutas.** Salve os logs num arquivo local (não precisa
   commitar):
   ```bash
   mkdir -p ~/ai-cpu-os-resultados && cd ~/ai-cpu-os-resultados
   ./detect-hardware.sh   > hardware.txt 2>&1
   llama-bench ...        > bench-<sistema>-<threads>.txt 2>&1
   sudo cp /var/log/ai-cpu-os-build.log .
   journalctl -u ai-server --no-pager > ai-server.log
   ```
5. **Ao terminar**, use o [template de relatório](#template-de-relatório-copiar-e-colar)
   no fim deste arquivo.

### Quadro de status (preencha)

| Bloco | Descrição | Sistema | Status |
|-------|-----------|---------|--------|
| A | Validação em VM Debian 12 (sem risco) | VM | ☐ não feito · ☐ ok · ☐ falhou |
| B | Detecção de hardware | Xeon | ☐ não feito · ☐ ok · ☐ falhou |
| C | Build do llama.cpp | Xeon | ☐ não feito · ☐ ok · ☐ falhou |
| D | Tuning de kernel (+ reboot) | Xeon | ☐ não feito · ☐ ok · ☐ falhou |
| E | `llama-server` + `shell-ia.py` | Xeon | ☐ não feito · ☐ ok · ☐ falhou |
| F | **Benchmark antes/depois** | Xeon | ☐ não feito · ☐ ok · ☐ falhou |
| G | Alerta de single channel | Ryzen | ☐ não feito · ☐ ok · ☐ falhou |
| H | Docker + registry + Gitea | Ryzen | ☐ não feito · ☐ ok · ☐ falhou |
| I | `build-runner.sh` (build + push) | Ryzen | ☐ não feito · ☐ ok · ☐ falhou |
| J | Imagem do GHCR nos dois alvos | Xeon+Ryzen | ☐ não feito · ☐ ok · ☐ falhou |
| K | Idempotência (rodar 2×) | Ambos | ☐ não feito · ☐ ok · ☐ falhou |
| L | Reversão do tuning | Ambos | ☐ não feito · ☐ ok · ☐ falhou |
| **M** | **🎯 Gerar e bootar a ISO de instalação** | VM | ☐ não feito · ☐ ok · ☐ falhou |

---

## Bloco 0 — Preparação

### 0.1 O que ter em mãos

| Item | Detalhe |
|------|---------|
| Sistema | Debian 12 (Bookworm) minimal, acesso `root`/`sudo` |
| Rede | Internet (download de pacotes e do modelo) |
| Disco | ~10 GB livres |
| Kernel | ≥ 5.1 (Debian 12 traz 6.1) |
| Acesso | Como você vai colar os resultados de volta (SSH, etc.) |

### 0.2 Capturar a "fotografia" do sistema (antes de qualquer coisa)

```bash
mkdir -p ~/ai-cpu-os-resultados && cd ~/ai-cpu-os-resultados
{ echo "### DATA: $(date -Is)"; echo "### HOST: $(hostname)"; \
  echo "### KERNEL: $(uname -r)"; echo "### DISTRO:"; \
  grep PRETTY_NAME /etc/os-release; } | tee contexto.txt
```

| Campo | Valor |
|-------|-------|
| Data/hora do início | _(preencher)_ |
| Máquina (hostname) | _(preencher)_ |
| Modelo da placa-mãe | _(preencher)_ |
| Kernel (`uname -r`) | _(preencher)_ |
| Distro | _(preencher)_ |
| Commit/tag testado | _(preencher)_ — esperado: `566583c` / `v0.2.0` |

### 0.3 Clonar e preparar

```bash
git clone https://github.com/xtrempkch-droid/Deep_Rock_IA.git ai-cpu-os
cd ai-cpu-os
git log --oneline -1                      # anote o commit
chmod +x build.sh detect-hardware.sh mods/*/*.sh \
         roles/*/*.sh roles/inference/shell-ia.py tests/*.sh
```

| Campo | Valor |
|-------|-------|
| Commit clonado | _(preencher)_ |
| `chmod` deu erro? | _(preencher: não / sim → qual arquivo)_ |

---

## ⚠️ Riscos e avisos (leia antes dos blocos B–F)

| Aviso | Detalhe |
|-------|---------|
| **Sem AVX-512** | O Xeon E5-2680 v4 e o Ryzen 5 3500X **não** têm AVX-512. Se aparecer `SIGILL`, alguma flag está errada. |
| **Reboot necessário** | O Bloco D altera a **cmdline do kernel** (C-states). Só vale após reiniciar. |
| **Consumo de energia** | Governor `performance` + C-states rasos deixam a CPU quente mesmo ociosa. |
| **Single channel (Ryzen)** | Se confirmar, o problema é físico (slots). Anote como está antes de mudar. |
| **16 GB (Xeon)** | Modelos acima de ~7B Q4 não cabem. |
| **RX 580** | Apenas saída de vídeo. **Nunca** computação (artefatos sob carga). |

---

## Bloco A — Validação em VM Debian 12 (sem risco)

> **Objetivo:** capturar erros de runtime (nomes de pacote, caminhos,
> permissões) sem tocar em hardware de produção. É o mesmo que o CI faz, mas
> na sua mão.

### A.1 Sintaxe e lint

```bash
bash -n build.sh detect-hardware.sh
for f in mods/*/*.sh roles/inference/*.sh roles/builder/*.sh tests/*.sh; do
  bash -n "$f" || echo "FALHOU: $f"
done
python3 -m compileall -q roles/ && echo "python OK"
make lint          # se shellcheck/yamllint estiverem instalados
```

| Campo | Valor |
|-------|-------|
| Todos passaram? | _(preencher)_ |
| Erros encontrados | _(preencher)_ |

### A.2 Detecção

```bash
./detect-hardware.sh
./detect-hardware.sh --quiet     # deve imprimir FAMILY=... e ROLE=...
```

| Campo | Valor |
|-------|-------|
| Perfil detectado na VM | _(preencher)_ |
| `--quiet` imprimiu `FAMILY=` e `ROLE=`? | _(preencher)_ |

### A.3 Simulação (dry-run) dos dois perfis

```bash
sudo ./build.sh --role inference  --dry-run --yes --skip-tests
sudo ./build.sh --role builder --dry-run --yes --skip-tests
sudo ./build.sh --role auto  --dry-run --yes --skip-tests
bash tests/smoke-test.sh --dry-run --role inference
```

| Campo | Valor |
|-------|-------|
| Dry-run executou sem `[ERROR]`? | _(preencher)_ |
| O que apareceu de errado | _(preencher)_ |

### A.4 (Opcional) Aplicar de verdade na VM

```bash
sudo ./build.sh --role auto --yes
sudo reboot        # se o C-states foi alterado
bash tests/smoke-test.sh --role auto
```

| Campo | Valor |
|-------|-------|
| Rodou ponta a ponta? | _(preencher)_ |
| Saída do smoke-test (PASS/FAIL/SKIP) | _(preencher)_ |

---

## Bloco B — Xeon: detecção de hardware

> Rode **como root** para o `dmidecode` funcionar (canais de memória).

```bash
sudo ./detect-hardware.sh | tee ~/ai-cpu-os-resultados/hardware-xeon.txt
sudo dmidecode -t memory | grep -E 'Locator|Size|Speed'
lsblk -d -o NAME,SIZE,ROTA,TRAN,MODEL
```

**O que registrar:**

| Campo | Esperado | Medido |
|-------|----------|--------|
| Modelo da CPU | Xeon E5-2680 v4 | _(preencher)_ |
| Núcleos / Threads | 12 / 24 | _(preencher)_ |
| AVX2 | SIM | _(preencher)_ |
| FMA / F16C | SIM / SIM | _(preencher)_ |
| **AVX-512** | **NÃO** | _(preencher)_ |
| AMX | NÃO | _(preencher)_ |
| RAM total | 16 GB | _(preencher)_ |
| Canais de memória | dual (ou quad, conforme placa) | _(preencher)_ |
| Disco | NVMe | _(preencher)_ |
| Perfil escolhido | `xeon` | _(preencher)_ |

**Critério de sucesso:** AVX-512 = NÃO · perfil = `xeon` · nenhum alerta
inesperado.

| Campo | Valor |
|-------|-------|
| Avisos emitidos pelo script | _(preencher)_ |
| Bloco OK? | _(preencher)_ |

---

## Bloco C — Xeon: build do llama.cpp

> **Caminho rápido (recomendado):** use o binário que o CI já compilou.
> **Caminho completo:** compile no próprio Xeon.

### C.1 Caminho rápido — usar o artefato da Release

Baixe de *Actions → build-llama → Artifacts* ou da Release
`v0.2.0`: <https://github.com/xtrempkch-droid/Deep_Rock_IA/releases/tag/v0.2.0>

```bash
mkdir -p /opt/llama.cpp && cd /opt/llama.cpp
tar -xzf ~/Downloads/ai-cpu-os-llama-xeon-*.tar.gz --strip-components=1
./bin/llama-bench --help | head
./bin/llama-server --help | head
```

| Campo | Valor |
|-------|-------|
| Baixou o artefato? | _(preencher)_ |
| `llama-bench --help` funcionou? | _(preencher — se falhar com erro de lib, ver TROUBLESHOOTING § "Container/Imagem Docker")_ |

### C.2 Caminho completo — compilar no Xeon

```bash
sudo bash llama-build.sh --jobs 6 --yes | tee ~/ai-cpu-os-resultados/build-xeon.log
```

> **Atenção:** o script **instala `pkg-config`** se estiver faltando (bug
> corrigido — ver `docs/CI.md` § 8.1). Se aparecer
> `Could NOT find PkgConfig`, é **regressão**: anote.

```bash
# Confirmar o que foi compilado
/opt/llama.cpp/build/bin/llama-bench --help | head
```

| Campo | Valor |
|-------|-------|
| Tempo de build | _(preencher)_ |
| `--jobs` usado | _(preencher; sugestão: 6 para não estourar 16 GB)_ |
| Apareceu erro de `PkgConfig`? | _(preencher: não esperado)_ |
| Apareceu `SIGILL`? | _(preencher: não esperado)_ |
| Binários gerados | _(preencher)_ |
| Bloco OK? | _(preencher)_ |

---

## Bloco D — Xeon: tuning de kernel

> ⚠️ Este bloco altera **sysctl**, **governor**, **THP** e a **cmdline do
> kernel** (C-states). A parte de C-states só vale **após reboot**.

### D.1 Capturar o estado ANTES (importante para o Bloco F)

```bash
sudo ./detect-hardware.sh > /dev/null   # sanity
{
  echo "=== ANTES ==="
  sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_ratio \
         vm.dirty_background_ratio kernel.numa_balancing \
         net.core.rmem_max net.core.wmem_max 2>&1
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>&1
  cat /sys/kernel/mm/transparent_hugepage/enabled 2>&1
  grep -i Huge /proc/meminfo
  cat /proc/cmdline
} | tee ~/ai-cpu-os-resultados/tuning-antes.txt
```

| Campo | Valor medido |
|-------|--------------|
| `vm.swappiness` | _(preencher)_ |
| `vm.vfs_cache_pressure` | _(preencher)_ |
| `kernel.numa_balancing` | _(preencher)_ |
| `net.core.rmem_max` | _(preencher)_ |
| Governor cpu0 | _(preencher)_ |
| THP | _(preencher)_ |
| Huge pages | _(preencher)_ |

### D.2 Aplicar

```bash
sudo ./build.sh --role inference --yes | tee ~/ai-cpu-os-resultados/build-xeon-total.log
```

Responda **sim** à pergunta sobre a cmdline do kernel (C-states).

### D.3 Conferir DEPOIS (sem reboot)

```bash
{
  echo "=== DEPOIS ==="
  sysctl vm.swappiness vm.vfs_cache_pressure kernel.numa_balancing net.core.rmem_max
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  cat /sys/kernel/mm/transparent_hugepage/enabled
} | tee ~/ai-cpu-os-resultados/tuning-depois.txt
```

| Campo | Esperado | Medido |
|-------|----------|--------|
| `vm.swappiness` | 10 | _(preencher)_ |
| `vm.vfs_cache_pressure` | 50 | _(preencher)_ |
| `kernel.numa_balancing` | 0 (se single-socket) | _(preencher)_ |
| `net.core.rmem_max` | 134217728 | _(preencher)_ |
| Governor cpu0 | `performance` | _(preencher)_ |
| THP | `always` ou `madvise` | _(preencher)_ |

### D.4 C-states (requer reboot)

```bash
grep -o 'max_cstate=[0-9]*' /etc/default/grub || echo "não adicionado ⚠️"
sudo reboot
# depois do reboot:
cat /proc/cmdline | tr ' ' '\n' | grep max_cstate
ls /sys/devices/system/cpu/cpu0/cpuidle/state*/name | xargs -I{} sh -c 'echo -n "{}: "; cat {}'
```

| Campo | Esperado | Medido |
|-------|----------|--------|
| Parâmetro na cmdline | `intel_idle.max_cstate=1` | _(preencher)_ |
| C-states presentes após reboot | parar em C1 | _(preencher)_ |
| Reboot foi necessário? | sim | _(preencher)_ |

| Campo | Valor |
|-------|-------|
| Bloco OK? | _(preencher)_ |
| Algo inesperado | _(preencher)_ |

---

## Bloco E — Xeon: `llama-server` + `shell-ia.py`

### E.1 Instalar serviço, usuário e modelo

```bash
# Com download do modelo sugerido (~1.1 GB):
sudo bash roles/inference/install.sh --auto-model --yes \
  | tee ~/ai-cpu-os-resultados/install-xeon.log

# OU com um modelo seu (caminho local, sem download):
sudo bash roles/inference/install.sh --model-path /opt/models/SEU-MODELO.gguf --yes
```

| Campo | Valor |
|-------|-------|
| Modelo usado | _(preencher)_ |
| Tamanho do arquivo | _(preencher)_ |
| Download automático funcionou? | _(preencher; se falhou, baixe manualmente e ajuste `/etc/default/ai-server`)_ |

### E.2 Subir e testar o servidor

```bash
sudo systemctl enable --now ai-server
systemctl status ai-server --no-pager
curl -s http://127.0.0.1:8080/health; echo
free -h
sudo journalctl -u ai-server -n 30 --no-pager
```

| Campo | Valor |
|-------|-------|
| Serviço subiu? | _(preencher)_ |
| `/health` respondeu? | _(preencher)_ |
| RAM usada com o modelo carregado | _(preencher)_ |
| Algum erro no journal? | _(preencher)_ |

### E.3 Conversar pelo shell-IA

```bash
# Prompt único
python3 roles/inference/shell-ia.py -p "quanta RAM livre tem nesta máquina?"

# Interativo
python3 roles/inference/shell-ia.py
#  você> liste os arquivos em /opt/models
#  você> procure por "swappiness" em /etc/sysctl.d
```

**Testar o sandbox (importante):**

```bash
# Deve FUNCIONAR (está na whitelist):
python3 roles/inference/shell-ia.py -p "rode o comando: uptime"

# Deve ser BLOQUEADO pelo sandbox (fora da whitelist / caminho proibido):
python3 roles/inference/shell-ia.py -p "leia o arquivo /etc/shadow"
python3 roles/inference/shell-ia.py -p "rode o comando: rm -rf /tmp/x"
```

| Teste | Resultado esperado | Medido |
|-------|--------------------|--------|
| Respondeu à pergunta | resposta coerente | _(preencher)_ |
| `list_dir` / `read_file` | executa e realimenta o modelo | _(preencher)_ |
| `run_command` (na whitelist) | executa | _(preencher)_ |
| Comando fora da whitelist | mensagem `ERRO: comando ... não está na whitelist` | _(preencher)_ |
| Leitura em `/etc` | mensagem `ERRO (sandbox): ... fora das raízes permitidas` | _(preencher)_ |

| Campo | Valor |
|-------|-------|
| Bloco OK? | _(preencher)_ |
| Latência percebida (sensação) | _(preencher)_ |

---

## Bloco F — Xeon: **benchmark antes/depois** (o mais importante)

> **Regra do projeto:** medir, não adivinhar. Esta é a tabela que vai para
> `docs/STATE.md` § 5.

### F.1 Medir DEPOIS (tuning aplicado)

```bash
MODEL=/opt/models/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf      # ajuste se preciso

for T in 12 24; do
  echo "### threads=$T"
  /opt/llama.cpp/build/bin/llama-bench -m "$MODEL" -p 512 -n 128 -t "$T" \
    | tee ~/ai-cpu-os-resultados/bench-xeon-depois-t${T}.txt
done
```

### F.2 Medir ANTES (baseline "cru")

Faça isto **na ordem que preferir**:

- **Opção 1 (recomendada, sem risco):** reverta o tuning temporariamente
  (ver [Bloco L](#bloco-l--reversão)), meça, e reaplique.
- **Opção 2 (mais fácil):** rode o benchmark **antes** do Bloco D, usando o
  mesmo binário do Bloco C.

```bash
# Repetir com o tuning revertido:
for T in 12 24; do
  /opt/llama.cpp/build/bin/llama-bench -m "$MODEL" -p 512 -n 128 -t "$T" \
    | tee ~/ai-cpu-os-resultados/bench-xeon-antes-t${T}.txt
done
```

### F.3 Tabela de resultados (preencha)

| Sistema | Modelo | Threads | pp512 antes (t/s) | pp512 depois (t/s) | tg128 antes (t/s) | tg128 depois (t/s) | Δ tg128 |
|---------|--------|---------|-------------------|--------------------|-------------------|--------------------|---------|
| xeon | _(preencher)_ | 12 | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ |
| xeon | _(preencher)_ | 24 | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ |
| ryzen | _(preencher)_ | 6 | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ |

> **Dica:** cole as linhas `| ... | pp512 | t/s |` cruas do `llama-bench` no
> relatório final — assim, se houver dúvida, os números originais estão lá.

| Campo | Valor |
|-------|-------|
| `-t` melhor no Xeon | _(preencher: 12 ou 24?)_ |
| Havia conteúdo do modelo em swap? (`free -h`) | _(preencher)_ |
| Observações | _(preencher)_ |

---

## Bloco G — Ryzen: alerta de single channel

```bash
cd ~/ai-cpu-os     # no Ryzen
sudo bash roles/builder/install.sh        # leia o ALERTA e confirme
sudo dmidecode -t memory | grep -E 'Locator|Size|Speed'
```

**O que investigar:** em placas AM4, o dual channel normalmente exige os slots
**A2 + B2** (2º e 4º a partir do soquete).

| Slot (`Locator`) | Pente (Size) | Instalado? |
|------------------|--------------|------------|
| _(preencher)_ | _(preencher)_ | _(preencher)_ |
| _(preencher)_ | _(preencher)_ | _(preencher)_ |
| _(preencher)_ | _(preencher)_ | _(preencher)_ |
| _(preencher)_ | _(preencher)_ | _(preencher)_ |

| Campo | Valor |
|-------|-------|
| Estava em single channel? | _(preencher)_ |
| O script alertou? | _(preencher: esperado sim)_ |
| Você moveu os pentes? | _(preencher)_ |
| Canais após a mudança | _(preencher)_ |

---

## Bloco H — Ryzen: Docker + registry + Gitea

```bash
sudo bash roles/builder/install.sh --yes | tee ~/ai-cpu-os-resultados/install-ryzen.log
```

### H.1 Docker

```bash
docker --version && docker compose version
systemctl is-active docker
sudo docker info | grep -iE 'storage|registry' | head
cat /etc/docker/daemon.json
```

| Campo | Valor |
|-------|-------|
| Versões | _(preencher)_ |
| Docker ativo? | _(preencher)_ |
| `insecure-registries` configurado? | _(preencher)_ |
| Precisou relogar para o grupo `docker`? | _(preencher)_ |

### H.2 Registry privado

```bash
curl -s http://localhost:5000/v2/ ; echo
curl -s http://localhost:5000/v2/_catalog ; echo
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
```

| Campo | Valor |
|-------|-------|
| Respondeu em `:5000`? | _(preencher)_ |
| Container `registry` rodando? | _(preencher)_ |

### H.3 Gitea

```bash
cd roles/builder && docker compose -f gitea-compose.yml up -d
docker logs --tail 20 gitea
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/
```

| Campo | Valor |
|-------|-------|
| Web em `:3000` (HTTP 200)? | _(preencher)_ |
| Criou o admin no primeiro acesso? | _(preencher)_ |
| Clonou um repo via SSH `:2222`? | _(preencher — comando abaixo)_ |

```bash
# Teste de clone via SSH (porta 2222)
git clone ssh://git@localhost:2222/SEU-USUARIO/SEU-REPO.git
```

---

## Bloco I — Ryzen: `build-runner.sh` (build + push)

```bash
# 1. Um repo de teste com Dockerfile
mkdir -p /tmp/app-teste && cd /tmp/app-teste
printf 'FROM debian:12-slim\nCMD ["echo","oi do ai-cpu-os"]\n' > Dockerfile

# 2. Build + push para o registry local
bash ~/ai-cpu-os/roles/builder/build-runner.sh \
  --context /tmp/app-teste \
  --tag localhost:5000/teste/app:1.0 \
  --push

# 3. (2º build = testa o cache)
bash ~/ai-cpu-os/roles/builder/build-runner.sh \
  --context /tmp/app-teste \
  --tag localhost:5000/teste/app:1.0 \
  --push

# 4. Confirmar o que foi publicado
curl -s http://localhost:5000/v2/_catalog ; echo
curl -s http://localhost:5000/v2/teste/app/tags/list ; echo

# 5. Rodar a imagem publicada
docker run --rm localhost:5000/teste/app:1.0
```

| Campo | Valor |
|-------|-------|
| 1º build (tempo) | _(preencher)_ |
| 2º build (tempo, com cache) | _(preencher)_ |
| Push funcionou? | _(preencher)_ |
| Apareceu o repo no `_catalog`? | _(preencher)_ |
| `docker run` executou? | _(preencher)_ |
| Testou o garbage collection? | _(preencher)_ |

```bash
# Garbage collection (liberar espaço)
docker exec -it registry registry garbage-collect -m /etc/docker/registry/config.yml
```

---

## Bloco J — Imagem do GHCR nos dois alvos

> Valida o fix do **RPATH** (`docs/CI.md` § 8.2) em hardware real.

```bash
# As imagens podem estar privadas; se o pull der "denied":
#   echo $GH_TOKEN | docker login ghcr.io -u SEU-USUARIO --password-stdin

docker pull ghcr.io/xtrempkch-droid/ai-cpu-os-llama:latest
docker pull ghcr.io/xtrempkch-droid/ai-cpu-os-llama:znver2     # otimizada p/ Zen 2

# Sanidade (o fix do RPATH):
docker run --rm --entrypoint llama-bench ghcr.io/xtrempkch-droid/ai-cpu-os-llama:latest --help | head

# Execução real (ajuste o caminho do modelo):
docker run --rm -p 127.0.0.1:8081:8080 -v /opt/models:/models:ro \
  ghcr.io/xtrempkch-droid/ai-cpu-os-llama:latest \
  -m /models/SEU-MODELO.gguf --threads 24
curl -s http://127.0.0.1:8081/health; echo
```

| Teste | Xeon | Ryzen |
|-------|------|-------|
| Pull de `:latest` | _(preencher)_ | _(preencher)_ |
| Pull de `:znver2` | _(preencher)_ | _(preencher)_ |
| `llama-bench --help` no container | _(preencher)_ | _(preencher)_ |
| Serviu um modelo (health OK) | _(preencher)_ | _(preencher)_ |
| Tokens/s no container | _(preencher)_ | _(preencher)_ |

| Campo | Valor |
|-------|-------|
| A imagem estava pública ou privada? | _(preencher)_ |
| Comparação container × nativo (tok/s) | _(preencher — esperado: nativo ≥ container)_ |

---

## Bloco K — Idempotência (rodar duas vezes)

> Requisito do projeto: rodar de novo **não pode** quebrar nada.

```bash
sudo ./build.sh --role auto --yes   # 2ª execução
```

**Procurar na saída:** mensagens tipo
`Sem alterações em ... (idempotente)` / `já está em ... (idempotente)`.

| Campo | Valor |
|-------|-------|
| A 2ª execução completou? | _(preencher)_ |
| Reportou "idempotente"? | _(preencher)_ |
| Algum arquivo foi reescrito sem necessidade? | _(preencher — se sim, é bug: reporte)_ |
| Bloco OK? | _(preencher)_ |

---

## Bloco L — Reversão

> Confirma que o tuning é reversível (e serve para o "baseline" do Bloco F).

```bash
sudo rm -f /etc/sysctl.d/99-ai-tuning.conf /etc/sysctl.d/99-ai-hugepages.conf
sudo sysctl --system

sudo systemctl disable --now ai-cpu-governor.service ai-cpu-hugepages.service
echo schedutil | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# C-states: remover o parâmetro de /etc/default/grub e:
sudo update-grub && sudo reboot

# Serviço de inferência (se quiser parar)
sudo systemctl disable --now ai-server
```

| Campo | Valor |
|-------|-------|
| Sysctl voltou ao padrão? | _(preencher)_ |
| Governor voltou? | _(preencher)_ |
| Backup `*.bak.*` foi criado? | _(preencher)_ |
| Alguma etapa falhou? | _(preencher)_ |

---

## Bloco M — 🎯 ISO de instalação (entregável final)

> **Este é o bloco que define o fim do projeto.** Ver [`docs/ISO.md`](ISO.md)
> para as decisões de design e as limitações conhecidas.
>
> ⚠️ **Faça tudo em VM.** A ISO **apaga o disco** indicado em `--disk`.
> Só depois de validar em VM use em hardware real.

### M.0 ✅ RESULTADO EXECUTADO — sessão #21 (2026-10-13), caminho Ubuntu

> **Este bloco foi EXECUTADO pela primeira vez.** Ubuntu Server 24.04
> air-gapped, gerado num container `ubuntu:24.04` e instalado numa **VM com
> KVM** (`-cpu host`, host Xeon E5-2676 v3). Toolchain do host: `xorriso` 1.5.6
> + `qemu` 8.2 (container) / 10.2 (host).

| Passo (M.1–M.5) | Resultado |
|-----------------|-----------|
| `make iso-lint` / autoteste de templates | ✅ |
| `verify-iso.sh` sobre a ISO real | ✅ **PASS=41 FAIL=0** |
| Build da ISO (`--role auto --family auto --serial-console` + fonte/modelo/repo) | ✅ **exit 0** |
| Download da ISO base + SHA256 | ✅ (`ubuntu-24.04.5-live-server-amd64.iso`) |
| Caminho **offline** (fonte/modelo/repo na mídia) | ✅ usado no 1º boot, sem rede |
| `test-vm.sh` (boot + instalação + 1º boot) | ✅ **exit 0**, 2 marcadores |
| Instalação automática (sem perguntas) | ✅ |
| `.firstboot-status` no alvo | ✅ **`status=ok`** |
| Papel/família detectados no alvo | ✅ `inference` / `intel-haswell` |
| llama.cpp compilado no alvo (do tarball) | ✅ `/opt/llama.cpp/build/bin/llama-server` |
| Modelo/instalação no alvo | ✅ `/opt/models/…gguf`, `/opt/apt-repo` |
| Tamanho / SHA256 da ISO | 5,2 GiB / `c59da479…` (ver `STATE.md` § 5) |
| Tempo (4 vCPU) | instalação+1º boot ~13 min |

> ✅ **O que isto prova:** a ISO **existe**, **boota**, **instala sozinha** e o
> **1º boot aplica**. O critério de conclusão do projeto foi cumprido **para o
> caminho Ubuntu, em VM**.
>
> 🔴 **O que NÃO foi feito neste bloco:**
> - **Debian/preseed** (`--distro debian`) — M.2/M.4/M.5 **não executados**.
> - **Hardware físico** (Xeon E5-2680 v4 e Ryzen 5 3500X) — o passo 5.
> - **Boot UEFI** (`--boot-mode uefi`).
> - Medição de tokens/s (`llama-bench`) no alvo.
>
> **8 bugs reais** foram achados/corrigidos para chegar até aqui (xorriso
> `-rm --`/`-boot_image replay`/`-map`; GRUB `--id`; repo apt no chroot do
> curtin; marcadores; SIGPIPE; aspas do `-find`). Detalhes: `JOURNAL.md` § 4
> (sessão #21) e `STATE.md` § 3.3.

### M.1 Preparar a máquina de build (Debian/Ubuntu com xorriso)

```bash
# Obrigatórias
sudo apt install -y xorriso curl coreutils
# Só para --distro debian (boot UEFI dentro de efi.img + boot híbrido)
sudo apt install -y isolinux mtools

make iso-lint        # bash -n + shellcheck + autoteste dos templates
make iso-yaml        # só o autoteste (templates + verificador, com teste negativo)
make iso-dry-run     # simulação completa, não baixa nem altera nada
```

O `make iso-yaml` é o mais barato de rodar: ele monta uma árvore com os
templates e o projeto reais, roda o `verify-iso.sh` sobre ela **e** confirma
que o verificador reprova quando falta o `autoinstall.yaml` (teste negativo).
Um verificador que nunca falha não vale nada.

| Campo | Valor |
|-------|-------|
| `make iso-lint` passou? | _(preencher)_ |
| Autoteste dos templates (`autoinstall.yaml` YAML válido) OK? | _(preencher)_ |
| `verify-iso.sh` aprovou a árvore de teste (`FAIL=0`)? | _(preencher)_ |
| Teste negativo reprovou sem o `autoinstall.yaml`? | _(preencher)_ |
| `make iso-dry-run` sem erros? | _(preencher)_ |

> **Registre as duas distros.** O caminho `ubuntu` é o padrão e o menos
> exercitado; o `debian` é o legado. Ambos precisam do mesmo bloco abaixo.

### M.2 Gerar a ISO

```bash
# --disk é o disco que será apagado NA MÁQUINA QUE INSTALAR a ISO.
# Para testar em VM, use o disco virtual dela (ex.: /dev/vda).
# --serial-console torna a instalação e o 1º boot observáveis sem tela: é o que
# o iso/test-vm.sh usa (recomendado em qualquer teste em VM).

# 1) Ubuntu (padrão) — autoinstall/Subiquity
sudo bash iso/build-iso.sh --distro ubuntu --disk /dev/vda \
  --serial-console --keep-work

# 2) Debian (legado) — preseed/d-i
sudo bash iso/build-iso.sh --distro debian --disk /dev/vda \
  --serial-console --keep-work
```

No fim do build, o `verify-iso.sh` roda **sozinho** (mesmo caminho do M.3).
Use `--no-verify` só se quiser pulá-lo.

O script imprime, no fim: caminho da ISO, **SHA256**, o Volume ID, e a
**senha gerada** (se você não passou `--password-hash`). **Anote a senha.**

| Campo | Ubuntu | Debian |
|-------|--------|--------|
| Download da ISO oficial funcionou? | _(preencher)_ | _(preencher)_ |
| SHA256 da ISO oficial conferiu? | _(preencher — esperado: sim)_ | _(preencher — esperado: sim)_ |
| Tempo total do build | _(preencher)_ | _(preencher)_ |
| Caminho da ISO gerada | _(preencher)_ | _(preencher)_ |
| SHA256 da ISO gerada | _(preencher)_ | _(preencher)_ |
| Mensagens de WARN | _(preencher)_ | _(preencher)_ |

> Se o `xorriso -indev/-outdev -map` reclamar de algum caminho, cole a mensagem
> — é o ponto mais provável de ajuste no caminho Ubuntu (§ 4.5 de `docs/ISO.md`).

### M.3 Verificar o conteúdo da ISO (sem instalar)

**Caminho recomendado — o verificador do projeto:**

```bash
# Não boota nada: confere a config, o projeto embutido, os tokens, o YAML do
# autoinstall, o layout de storage, a entrada de boot e o Volume ID.
make iso-verify ISO=iso/out/ai-cpu-os-ubuntu-*.iso DISK=/dev/vda

# Mesma checagem sobre uma árvore já extraída (não precisa de xorriso nem root):
bash iso/verify-iso.sh --dir iso/work/stage --distro ubuntu --disk /dev/vda
```

Ele imprime uma linha `[PASS]/[FAIL]/[SKIP]` por item e um resumo
(`PASS=n FAIL=n SKIP=n`). **Qualquer `FAIL` invalida a ISO** — não perca tempo
bootando antes de zerar.

**Conferência manual (opcional, para quem quiser ver com os próprios olhos):**

```bash
# Os 3 primeiros valem para as DUAS distros:
xorriso -indev iso/out/ai-cpu-os-*.iso -find /preseed -type f -exec echo
xorriso -indev iso/out/ai-cpu-os-*.iso -find /ai-cpu-os -maxdepth 1 -exec echo

# Ubuntu: a config automática é o autoinstall.yaml NA RAIZ (ao lado de casper/)
xorriso -indev iso/out/ai-cpu-os-ubuntu*.iso -extract /autoinstall.yaml /tmp/ && \
  grep -E 'layout:|late-commands:' -A2 /tmp/autoinstall.yaml
xorriso -indev iso/out/ai-cpu-os-ubuntu*.iso -extract /boot/grub/grub.cfg /tmp/ && \
  grep -A4 'ai-cpu-os-auto' /tmp/grub.cfg

# Debian: a config é o preseed, e o menu é o do isolinux
xorriso -indev iso/out/ai-cpu-os-debian*.iso -extract /isolinux/isolinux.cfg /tmp/ && \
  grep -A3 'ai-cpu-os-auto' /tmp/isolinux.cfg
```

| Campo | Ubuntu | Debian |
|-------|--------|--------|
| `iso-verify.sh` com `FAIL=0`? | _(preencher)_ | _(preencher)_ |
| `/preseed` contém os 4 arquivos? | _(preencher)_ | _(preencher)_ |
| `/ai-cpu-os` presente? | _(preencher)_ | _(preencher)_ |
| Menu de boot com `ai-cpu-os-auto`? | _(preencher)_ | _(preencher)_ |
| Config automática no lugar certo? | `/autoinstall.yaml` na raiz | `/preseed/ai-cpu-os.cfg` |

> No Ubuntu, confira também que o `storage:` gerado tem **um** dos dois formatos:
> `layout: {name: direct}` (sem `--disk`) ou
> `layout: {name: direct, match: {path: /dev/vda}}` (com `--disk`).

### M.4 Boot e instalação em VM (o teste que importa)

**Caminho A — automatizado (precisa de `qemu-system-x86` + `qemu-utils`):**

```bash
# Cria o disco virtual, boota a ISO, espera a instalação e o primeiro boot,
# e diz se os marcadores apareceram. NÃO toca no seu disco real.
bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-*.iso --yes

# Opções úteis:
#   --boot-mode uefi     testa o caminho UEFI (requer o pacote 'ovmf')
#   --ram 8192           mais memória para o paper 'inference'
#   --timeout-min 150    para máquinas lentas (ou sem KVM)
#   --no-install         só confirma que a ISO boota (smoke rápido)
#   --keep               mantém disco e VM para inspecionar depois
#   --dry-run            só mostra o comando do qemu
```

**Caminho B — manual:**

```bash
qemu-system-x86_64 -m 4096 -enable-kvm \
  -drive file=/tmp/alvo.qcow2,if=virtio,format=qcow2 \
  -cdrom iso/out/ai-cpu-os-*.iso -boot d

# Gravar em pendrive (⚠️ destrutivo — confira o /dev/sdX!)
# sudo dd if=iso/out/ai-cpu-os-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**O que observar:**

1. Aparece o menu com **"Instalar ai-cpu-os (automatico)"** e ele é o
   **padrão** (10 s)?
2. O instalador roda **sem perguntar nada**?
3. A instalação termina e a VM reinicia?
4. No primeiro boot, o serviço `ai-cpu-os-firstboot` roda?

| Campo | Ubuntu | Debian |
|-------|--------|--------|
| Boot BIOS | _(preencher)_ | _(preencher)_ |
| Boot UEFI | _(preencher)_ | _(preencher — se falhar, ver docs/ISO.md § 6)_ |
| Entrada automática foi o padrão? | _(preencher)_ | _(preencher)_ |
| Instalou sem perguntas? | _(preencher)_ | _(preencher)_ |
| Erros do instalador | _(preencher)_ | _(preencher)_ |

### M.5 Pós-instalação: primeiro boot (dentro do sistema instalado)

**Caminho A — automatizado (`iso/test-vm.sh`).** Se você gerou a ISO com
`--serial-console`, o script boota a VM, espera e **procura os marcadores** no
console serial. Não precisa de tela nem de login:

```bash
bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-*.iso --yes
# marcadores usados:
#   instalador:  "[ai-cpu-os/iso-late] pós-instalação concluído"
#   primeiro boot: "aplicação concluída com sucesso"
```

**Caminho B — manual (login na VM).** Como o `--serial-console` também habilita
`serial-getty@ttyS0`, dá para logar pelo console serial sem tela:

```bash
# Faça login com o usuário criado (padrão: ai-cpu-os) e a senha anotada.
systemctl status ai-cpu-os-firstboot --no-pager
cat /var/log/ai-cpu-os-firstboot.log
cat /opt/ai-cpu-os/.firstboot-status
cat /opt/ai-cpu-os/ISO-INFO.txt
cat /var/log/ai-cpu-os-build.log
cat /proc/cmdline   # deve conter max_cstate=1 se o tuning rodou
sysctl vm.swappiness kernel.numa_balancing
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# E o que a ISO prometeu (papel + família), gravado no alvo:
cat /opt/ai-cpu-os/.iso-config
```

| Campo | Valor |
|-------|-------|
| O serviço rodou sozinho? | _(preencher)_ |
| `test-vm.sh` encontrou o marcador de instalação? | _(preencher)_ |
| `test-vm.sh` encontrou o marcador de primeiro boot? | _(preencher)_ |
| Papel/família do `.iso-config` | _(preencher — em VM, provavelmente `inference` + `generic`)_ |
| `.firstboot-status` = `ok`? | _(preencher)_ |
| Sentinela `.firstboot-pending` removida? | _(preencher)_ |
| Tuning aplicado (governor/sysctl)? | _(preencher)_ |
| Compilou o llama.cpp? (papel `inference`) | _(preencher — pode levar 10-20 min)_ |
| Funcionou sem rede? (teste proposital) | _(preencher — deve adiar para o próximo boot)_ |

### M.6 Critério de "pronto"

O bloco M só é **✅** quando:

- [ ] A ISO gera sem erro e o SHA256 é registrado.
- [ ] `make iso-verify ISO=...` passa (`FAIL=0`).
- [ ] Boota em BIOS **e** o instalador não faz nenhuma pergunta.
- [ ] Instala e o primeiro boot aplica o ai-cpu-os sozinho (ou o `test-vm.sh`
      vê os dois marcadores).
- [ ] Em VM, ao menos o `inference` (llama.cpp) ou o `builder` (Docker) funciona.
- [ ] A senha gerada permite login e `sudo`.

| Campo | Valor |
|-------|-------|
| Bloco M OK? | _(preencher)_ |
| O que **não** foi validado | _(preencher)_ |

---

## Bloco N — 🧬 Famílias de CPU e papéis (2026-10-12)

> Objetivo: provar que o **casamento CPU → família → ISA** acerta em cada máquina
> alvo e que o `-march`/flags resultantes são os esperados.
> Ver [`docs/FAMILIES.md`](FAMILIES.md).

### N.1 Resolução automática (em cada alvo)

| Máquina | Comando | `FAMILY=` obtido | Esperado | ✅/❌ |
|---|---|---|---|---|
| Xeon E5-2680 v4 | `bash families/resolve.sh --quiet` | _(preencher)_ | `intel-broadwell` | _(_ |
| Ryzen 5 3500X | `bash families/resolve.sh --quiet` | _(preencher)_ | `amd-zen2` | _(_ |

### N.2 Relatório completo e `-march`

```bash
bash families/resolve.sh
bash build.sh --list-families
./detect-hardware.sh --quiet      # FAMILY= e ROLE=
```

| Máquina | `-march` efetivo | ISA (presentes/ausentes) | AVX-512 | Papel detectado |
|---|---|---|---|---|
| Xeon E5-2680 v4 | _(preencher)_ | _(preencher)_ | `no` | `inference` |
| Ryzen 5 3500X | _(preencher)_ | _(preencher)_ | `no` | `builder` |

### N.3 Fallback de compilador (GCC antigo)

Em um ambiente com GCC abaixo de `FAMILY_MARCH_MIN_GCC` (ex.: AMD com GCC 12),
o `-march=znver4` deve cair para `znver3` **com aviso**, sem quebrar o build:

```
Resultado: _(preencher)_
```

### N.4 Provas de que a AVX-512 não liga sozinha

```bash
bash families/resolve.sh --quiet                       # AVX512=no em broadwell
AI_ALLOW_AVX512=1 bash families/resolve.sh --family intel-broadwell --quiet
bash families/resolve.sh --family generic --quiet       # policy=auto
```

| Comando | AVX-512 ligou? | Esperado |
|---|---|---|
| `intel-broadwell` (política `never`) | _(preencher)_ | **não**, mesmo com `--allow-avx512` |
| `intel-skylake-avx512` sem opt-in | _(preencher)_ | não |
| `intel-skylake-avx512 --allow-avx512` | _(preencher)_ | sim (só com a flag presente) |

### N.5 Critério de "pronto" para o Bloco N

- [ ] `FAMILY=` correto nos dois alvos.
- [ ] `-march` igual ao da tabela de `docs/FAMILIES.md`.
- [ ] Nenhum caminho liga AVX-512 sem opt-in explícito.
- [ ] `make families` e `./detect-hardware.sh` sem erro.

### N.6 Casamento CPU → família sem o hardware (o que já dá para provar)

Este é o **único** jeito de exercitar famílias que você não possui (Zen 3, Zen 4,
Skylake-avx512). O corpus tem ~60 modelos reais e roda a mesma função do build:

```bash
make families-test                  # ou: bash tests/test-families.sh
bash tests/test-families.sh --verbose
```

| Campo | Valor |
|-------|-------|
| PASS/FAIL do corpus | _(preencher — esperado: PASS=60 FAIL=0)_ |
| Algum modelo caiu onde não devia? | _(preencher)_ |
| Você adicionou o SEU modelo ao corpus? | _(preencher — recomendado)_ |

> Este teste **não** substitui o N.1–N.4: ele prova a *regra de seleção*, não a
> ISA nem o `-march` em execução. Ver `docs/FAMILIES.md` § 9.3.

---

## Bloco O — 🔧 Mods portáveis (2026-10-12)

> Objetivo: provar que uma **mod** aplica, é **idempotente** e **reverte** de
> verdade, e que o catálogo funciona em Ubuntu e Debian.
> Ver [`docs/MODS.md`](MODS.md).

### O.1 Catálogo e requisitos

```bash
bash mods/apply.sh list
bash mods/apply.sh check
bash mods/apply.sh info openblas-threads
```

| Comando | Resultado | ✅/❌ |
|---|---|---|
| `list` mostra as 4 mods com risco/reboot/conjunto | _(preencher)_ | _(_ |
| `check` avalia todos os `MOD_REQUIRES` | _(preencher)_ | _(_ |

### O.2 Ciclo apply → idempotência → revert (por mod)

| Mod | `apply` OK | 2º `apply` = idempotente (sem duplicar) | `revert` OK | Sistema voltou ao estado anterior | ✅/❌ |
|---|---|---|---|---|---|
| `kernel-tuning` | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(_ |
| `hugepages` | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(_ |
| `governor` | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(_ |
| `openblas-threads` | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(preencher)_ | _(_ |

Evidências úteis (cole os valores):

```bash
# kernel-tuning
sysctl -n vm.swappiness ; cat /proc/cmdline
# hugepages
cat /sys/kernel/mm/transparent_hugepage/enabled ; sysctl -n vm.nr_hugepages
# governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
# openblas-threads
grep -A3 'openblas-threads' /etc/environment
```

### O.3 MODS no Ubuntu **e** no Debian

| Distro | `apply --set system --dry-run` | `mods/apply.sh test` | Observações |
|---|---|---|---|
| Ubuntu Server 24.04 | _(preencher)_ | _(preencher)_ | _(preencher)_ |
| Debian 12 | _(preencher)_ | _(preencher)_ | _(preencher)_ |

### O.4 O que o `test` em container NÃO prova (registrar sempre)

- Efeito real de **sysctl** (o container só mostra a escrita do arquivo).
- Efeito de **governor** e **C-states** (não há `cpufreq` no container).
- **Reboot** e persistência via GRUB.
- Mods com requisito `cpuflag:` (a CPU do container não é a do alvo).

### O.5 Critério de "pronto" para o Bloco O

- [ ] As 4 mods aplicam e revertem sem erro.
- [ ] Rodar `apply` duas vezes não duplica nenhum bloco.
- [ ] `revert` devolve o sistema ao estado original (conferido por `sha256sum`
      dos arquivos tocados, antes e depois).
- [ ] `mods/apply.sh test` passa (container Ubuntu).

---

## Bloco P — 🎮 GPU (opcional, explícito) — 2026-10-12

> Objetivo: se você quiser usar uma GPU, registrar o que foi feito e o que foi
> medido — **sem** contaminar os números de CPU. Ver [`docs/GPU.md`](GPU.md).
>
> ⚠️ **Nada deste bloco foi executado por este projeto.** Ele existe para que a
> primeira pessoa que usar GPU tenha onde registrar, em vez de começar do zero.

### P.1 Diagnóstico (somente leitura, seguro)

```bash
make gpu-check                  # ou: bash llama-build.sh --gpu-check
./detect-hardware.sh --quiet    # a linha GPU= aparece
```

| Campo | Valor |
|-------|-------|
| GPUs listadas | _(preencher)_ |
| Backends que parecem disponíveis | _(preencher)_ |
| `detect-hardware.sh` mostrou a linha `GPU=`? | _(preencher)_ |

### P.2 Build com backend explícito

```bash
# Escolha UM backend. Vulkan é o mais portátil; ROCm não cobre Polaris (RX 580).
bash llama-build.sh --gpu vulkan
# casos que exigem flag extra:
bash llama-build.sh --gpu rocm --cmake-extra "-DAMDGPU_TARGETS=gfx803"
```

| Campo | Valor |
|-------|-------|
| Backend usado | _(preencher: cuda/rocm/vulkan/sycl/metal)_ |
| Build concluiu? | _(preencher)_ |
| `AI-CPU-OS-BUILD.txt` registrou a GPU? | _(preencher — deve ter uma linha `GPU:`)_ |

### P.3 Medição (rotulada como GPU!)

```bash
llama-bench -m modelo.gguf -ngl 999      # tudo o que couber na VRAM
llama-bench -m modelo.gguf -ngl 0        # só CPU, para comparar o MESMO build
```

| Campo | Valor |
|-------|-------|
| VRAM da GPU | _(preencher)_ |
| Modelo e quantização | _(preencher)_ |
| `-ngl` máximo que coube | _(preencher)_ |
| tokens/s com `-ngl 999` | _(preencher)_ |
| tokens/s com `-ngl 0` (mesmo build) | _(preencher)_ |

> ⚠️ **Não copie estes números para `docs/STATE.md` § "Métricas de performance".**
> Aquela seção é de inferência **em CPU**. A comparação honesta é com o `-ngl 0`
> do *mesmo* build.

### P.4 Critério de "pronto" para o Bloco P

- [ ] `--gpu-check` roda sem erro (somente leitura).
- [ ] O build com backend concluiu e o registro `GPU:` está no `AI-CPU-OS-BUILD.txt`.
- [ ] Há medição **rotulada** de GPU, separada das de CPU.
- [ ] Nada em `docs/STATE.md` foi misturado com CPU.

---

## Consolidação (só depois de testar)

Quando trouxer os resultados, estes arquivos devem ser atualizados
(as regras do `AGENTS.md` exigem):

| Arquivo | O que atualizar |
|---------|-----------------|
| [`docs/STATE.md`](STATE.md) **§ 2** | trocar ❌ por ✅ na tabela "Hardware: o que foi testado" |
| [`docs/STATE.md`](STATE.md) **§ 3** | coluna "Testado em hardware" de cada script |
| [`docs/STATE.md`](STATE.md) **§ 4** | riscos/problemas encontrados |
| [`docs/STATE.md`](STATE.md) **§ 5** | **as métricas do Bloco F** (tabela de tokens/s) |
| [`docs/STATE.md`](STATE.md) **§ 6** | nova "Próxima ação imediata" |
| [`docs/TUTORIAL.md`](TUTORIAL.md) | substituir os `pendente` das seções 7.6 e 8 por números reais (Regra 9) |
| [`docs/ROADMAP.md`](ROADMAP.md) | mover os itens de validação de "Em Progresso" para "Concluído" |
| [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | todo problema novo que aparecer |

---

## Template de relatório (copiar e colar)

Ao voltar, cole isto (preenchido) — é o formato mais fácil de consolidar:

```text
RELATÓRIO DE VALIDAÇÃO — ai-cpu-os
Commit/tag testado:
Data:
Sistema (Xeon/Ryzen/VM):
Placa-mãe:
BIOS/UEFI (versão, se souber):
Kernel:
Distro:

--- Blocos executados ---
A (VM):        [não feito | ok | falhou]  observações:
B (detecção):  [não feito | ok | falhou]  observações:
C (build):     [não feito | ok | falhou]  tempo:   observações:
D (tuning):    [não feito | ok | falhou]  reboot:   observações:
E (servidor):  [não feito | ok | falhou]  modelo:   observações:
F (benchmark): [não feito | ok | falhou]  (ver tabela abaixo)
G (memória):   [não feito | ok | falhou]  canais:   observações:
H (docker):    [não feito | ok | falhou]  observações:
I (build-run): [não feito | ok | falhou]  observações:
J (imagem):    [não feito | ok | falhou]  observações:
K (idempot.):  [não feito | ok | falhou]  observações:
L (reversão):  [não feito | ok | falhou]  observações:
M (ISO):       [não feito | ok | falhou]  observações:

--- Benchmark (Bloco F) ---
Cole as linhas cruas do llama-bench (antes e depois):

--- Saída do detect-hardware.sh (num sistema real) ---
Cole aqui (ou anexe o arquivo):

--- Problemas encontrados ---
1.
2.

--- O que NÃO foi testado ---

--- Observações gerais ---
```

---

## Histórico

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação do protocolo (blocos A–L) para a versão `v0.2.0`; nenhum resultado preenchido ainda. |
| 2026-10-07 | Adicionado o **Bloco M** — geração e boot da ISO de instalação (entregável final do projeto). |
| 2026-10-12 | Adicionados os **Blocos N e O** — famílias de CPU/papéis (casamento, `-march`, política de AVX-512) e mods portáveis (apply/idempotência/revert em Ubuntu e Debian). Nenhum resultado preenchido ainda. |
| 2026-10-12 | **N.6** — casamento CPU → família pelo corpus (`make families-test`), que é como Zen 3/Zen 4 são exercitados sem hardware. Novo **Bloco P** — GPU opcional: diagnóstico, build explícito, medição **rotulada** e a proibição de misturar com os números de CPU. |
