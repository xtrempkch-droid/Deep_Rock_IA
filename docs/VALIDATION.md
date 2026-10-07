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
chmod +x build.sh detect-hardware.sh common/*.sh \
         profiles/*/*.sh profiles/xeon/shell-ia.py tests/*.sh
```

| Campo | Valor |
|-------|-------|
| Commit clonado | _(preencher)_ |
| `chmod` deu erro? | _(preencher: não / sim → qual arquivo)_ |

---

## ⚠️ Riscos e avisos (leia antes dos blocos B–F)

| Aviso | Detalhe |
|-------|---------|
| **Sem AVX-512** | O Xeon E5-2678 v3 e o Ryzen 5 3500X **não** têm AVX-512. Se aparecer `SIGILL`, alguma flag está errada. |
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
for f in common/*.sh profiles/xeon/*.sh profiles/ryzen/*.sh tests/*.sh; do
  bash -n "$f" || echo "FALHOU: $f"
done
python3 -m compileall -q profiles/ && echo "python OK"
make lint          # se shellcheck/yamllint estiverem instalados
```

| Campo | Valor |
|-------|-------|
| Todos passaram? | _(preencher)_ |
| Erros encontrados | _(preencher)_ |

### A.2 Detecção

```bash
./detect-hardware.sh
./detect-hardware.sh --quiet     # deve imprimir apenas "PROFILE=..."
```

| Campo | Valor |
|-------|-------|
| Perfil detectado na VM | _(preencher)_ |
| `--quiet` imprimiu `PROFILE=`? | _(preencher)_ |

### A.3 Simulação (dry-run) dos dois perfis

```bash
sudo ./build.sh --profile xeon  --dry-run --yes --skip-tests
sudo ./build.sh --profile ryzen --dry-run --yes --skip-tests
sudo ./build.sh --profile auto  --dry-run --yes --skip-tests
bash tests/smoke-test.sh --dry-run --profile xeon
```

| Campo | Valor |
|-------|-------|
| Dry-run executou sem `[ERROR]`? | _(preencher)_ |
| O que apareceu de errado | _(preencher)_ |

### A.4 (Opcional) Aplicar de verdade na VM

```bash
sudo ./build.sh --profile auto --yes
sudo reboot        # se o C-states foi alterado
bash tests/smoke-test.sh --profile auto
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
| Modelo da CPU | Xeon E5-2678 v3 | _(preencher)_ |
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
sudo bash profiles/xeon/llama-build.sh --jobs 6 --yes | tee ~/ai-cpu-os-resultados/build-xeon.log
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
sudo ./build.sh --profile xeon --yes | tee ~/ai-cpu-os-resultados/build-xeon-total.log
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
sudo bash profiles/xeon/install.sh --auto-model --yes \
  | tee ~/ai-cpu-os-resultados/install-xeon.log

# OU com um modelo seu (caminho local, sem download):
sudo bash profiles/xeon/install.sh --model-path /opt/models/SEU-MODELO.gguf --yes
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
python3 profiles/xeon/shell-ia.py -p "quanta RAM livre tem nesta máquina?"

# Interativo
python3 profiles/xeon/shell-ia.py
#  você> liste os arquivos em /opt/models
#  você> procure por "swappiness" em /etc/sysctl.d
```

**Testar o sandbox (importante):**

```bash
# Deve FUNCIONAR (está na whitelist):
python3 profiles/xeon/shell-ia.py -p "rode o comando: uptime"

# Deve ser BLOQUEADO pelo sandbox (fora da whitelist / caminho proibido):
python3 profiles/xeon/shell-ia.py -p "leia o arquivo /etc/shadow"
python3 profiles/xeon/shell-ia.py -p "rode o comando: rm -rf /tmp/x"
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
sudo bash profiles/ryzen/install.sh        # leia o ALERTA e confirme
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
sudo bash profiles/ryzen/install.sh --yes | tee ~/ai-cpu-os-resultados/install-ryzen.log
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
cd profiles/ryzen && docker compose -f gitea-compose.yml up -d
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
bash ~/ai-cpu-os/profiles/ryzen/build-runner.sh \
  --context /tmp/app-teste \
  --tag localhost:5000/teste/app:1.0 \
  --push

# 3. (2º build = testa o cache)
bash ~/ai-cpu-os/profiles/ryzen/build-runner.sh \
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
sudo ./build.sh --profile auto --yes   # 2ª execução
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
