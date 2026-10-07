# STATE — Estado atual do projeto ai-cpu-os

> **⚠️ Documento vivo. Atualize SEMPRE ao terminar uma tarefa (regra do AGENTS.md).**
> **Última atualização:** 2026-10-07 (criação inicial)

---

## 1. Versão

- **Versão do projeto:** `0.1.0-alpha`
- **Commit de referência:** tag `v0.1.0-alpha` (commit inicial — todos os arquivos gerados)
- **Sistema operacional alvo testado:** Debian 12 Bookworm (a confirmar)

---

## 2. Hardware: o que foi testado e o que não

| Sistema | Hardware                        | Perfil   | Testado em hardware real? |
|---------|---------------------------------|----------|---------------------------|
| A       | Intel Xeon E5-2678 v3, 16 GB    | `xeon`   | ❌ **NÃO**                |
| B       | AMD Ryzen 5 3500X, 64 GB        | `ryzen`  | ❌ **NÃO**                |

> **Nada foi executado em hardware físico ainda.** Todos os scripts foram
> escritos e revisados estaticamente (sintaxe `bash -n`, revisão de lógica),
> mas **não validados em execução real**. Trate esta versão como esqueleto
> funcional, não como release.

---

## 3. Status dos scripts

| Script                                | Escrito | Revisado (sintaxe) | Testado em hardware |
|---------------------------------------|:-------:|:------------------:|:-------------------:|
| `build.sh`                            | ✅      | ✅                 | ❌                  |
| `detect-hardware.sh`                  | ✅      | ✅                 | ❌                  |
| `common/kernel-tuning.sh`             | ✅      | ✅                 | ❌                  |
| `common/hugepages.sh`                 | ✅      | ✅                 | ❌                  |
| `common/governor.sh`                  | ✅      | ✅                 | ❌                  |
| `profiles/xeon/install.sh`            | ✅      | ✅                 | ❌                  |
| `profiles/xeon/llama-build.sh`        | ✅      | ✅                 | ❌                  |
| `profiles/xeon/shell-ia.py`           | ✅      | ⚠️ py_compile     | ❌                  |
| `profiles/xeon/ai-server.service`     | ✅      | ✅                 | ❌                  |
| `profiles/ryzen/install.sh`           | ✅      | ✅                 | ❌                  |
| `profiles/ryzen/docker-setup.sh`      | ✅      | ✅                 | ❌                  |
| `profiles/ryzen/registry-setup.sh`    | ✅      | ✅                 | ❌                  |
| `profiles/ryzen/gitea-compose.yml`    | ✅      | ⚠️ (YAML)          | ❌                  |
| `profiles/ryzen/build-runner.sh`      | ✅      | ✅                 | ❌                  |
| `tests/smoke-test.sh`                 | ✅      | ✅                 | ❌                  |
| `docs/TUTORIAL.md`                    | ✅      | ⚠️ (revisão manual)| ❌                  |
| `profiles/ryzen/llama-build.sh`       | ✅      | ✅                 | ❌                  |
| `docker/Dockerfile`                   | ✅      | ⚠️ (buildx --check)| ❌                  |
| `.github/workflows/*.yml`             | ✅      | ⚠️ (yamllint)      | ❌ (1º run pendente)|
| `Makefile`                            | ✅      | ⚠️ (make -n/test)  | ❌                  |

Legenda: ✅ sim · ❌ não · ⚠️ parcial

> **Lint:** todos os scripts passam em `shellcheck -x -S warning` sem
> nenhum aviso (verificado localmente em 2026-10-07 com shellcheck 0.11.0).
> O CI (`validate`) passa a garantir isso a cada push/PR.

### 3.1 Status do CI/CD

| Workflow             | Estado | Observação |
|----------------------|--------|------------|
| `validate`           | ✅ **verde no GitHub** (run 37655861546) | Os 4 jobs passaram: Lint, Regras do projeto, Dry-run (xeon), Dry-run (ryzen) |
| `build-llama`        | ✅ escrito, validado por dry-run local | **Nunca executado** — requer `workflow_dispatch` ou tag |
| `container`          | ⚠️ falhou no 1º run; **corrigido**, aguardando re-run | Falta de `pkg-config` no builder (ver § 3.2) |

### 3.2 Primeira execução do CI no GitHub (2026-10-07)

O commit `6da0c35` disparou `validate` e `container`:

- ✅ **`validate` — sucesso.** Prova que o lint (shellcheck sem avisos),
  os dry-runs dos dois perfis e os guarda-corpos das regras funcionam no
  ambiente real do GitHub.
- ❌ **`container` — falhou**, revelando um **bug real do projeto**:

  ```text
  CMake Error: Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)
  Call Stack: ggml/src/ggml-blas/CMakeLists.txt:25 (find_package)
  ```

  O backend BLAS do ggml usa `find_package(PkgConfig)` para achar o OpenBLAS;
  `libopenblas-dev` não traz o `pkg-config`. **O mesmo bug existia no build
  nativo** (`profiles/xeon/llama-build.sh` e `install.sh`) — ou seja, o
  primeiro build real no host teria falhado também.

  Correção aplicada em `docker/Dockerfile`, `profiles/xeon/llama-build.sh`,
  `profiles/xeon/install.sh` e no job `build-llama`. Registrado em
  `docs/CI.md` § 8.1 e `docs/TROUBLESHOOTING.md`.

> **Lição:** lint verde ≠ build comprovado. O CI **executando** o build foi o
> que revelou o problema.

---

## 4. Problemas conhecidos no momento

1. **Nada validado em execução.** O maior risco atual é um erro de runtime
   que a revisão estática não pegou (ex.: nome de pacote, caminho).
2. **Kernel cmdline não persiste até reboot.** `kernel-tuning.sh` escreve a
   orientação de `intel_idle.max_cstate=1`, mas a aplicação completa exige
   edição do GRUB + reboot — deixado como passo manual documentado.
3. **Detecção de canais de memória** depende de `dmidecode` (root) e pode
   falhar em algumas BIOS/placas (ex.: JGINYUE). Há fallback por heurística
   de `dmidecode -t 17`, mas não é infalível.
4. **Modelo GGUF não é baixado automaticamente** no `install.sh` do Xeon por
   padrão (link pode expirar/HTTPS). Deixamos função `--download-model`
   explícita.
5. **`shell-ia.py`** depende de um `llama-server` acessível; sem ele, roda em
   modo degradado (erro claro).
6. **Single channel no Ryzen** não é corrigível por software — é alertado,
   não resolvido.
7. **O CI `build-llama` ainda não foi executado.** O `validate` já rodou
   verde no GitHub, mas a compilação dos dois perfis (com inferência real)
   depende de `workflow_dispatch` ou de uma tag.
8. **A imagem do GHCR ainda não foi publicada.** O 1º run do `container`
   falhou por falta de `pkg-config` no builder; a correção foi aplicada e o
   re-run está pendente.

---

## 5. Métricas de performance medidas

> Nenhuma métrica real ainda. Preencher após rodar `llama-bench` nos dois
> sistemas. Formato sugerido:

| Sistema | Modelo                                | Threads | Antes (tok/s) | Depois (tok/s) | Δ     |
|---------|---------------------------------------|---------|---------------|----------------|-------|
| xeon    | Qwen2.5-Coder-1.5B-Q4_K_M             | 24      | *(pendente)*  | *(pendente)*   | —     |
| ryzen   | Qwen2.5-Coder-1.5B-Q4_K_M             | 6       | *(pendente)*  | *(pendente)*   | —     |

Tempo de build do llama.cpp: *(pendente)*

---

## 6. Próxima ação imediata

> **👉 ESTA É A SEÇÃO REFERENCIADA PELO `AGENTS.md`.**

**Passo 0 — Deixar o CI verde no GitHub (rápido, sem risco).**

```bash
make ci                    # reproduz o workflow 'validate' localmente
git push origin main       # dispara o workflow 'validate' no GitHub
```

Depois, em *Actions*, confirme: (a) `validate` verde; (b) dispare
`build-llama` manualmente (*Run workflow*) para comprovar de verdade que o
llama.cpp compila e roda com as flags dos dois perfis.

**Passo 1 — Subir uma VM Debian 12 e validar `detect-hardware.sh` + `build.sh
--dry-run`.**

Motivo: é o caminho de menor risco para capturar erros de runtime (nomes de
pacotes, caminhos, permissões) sem tocar em hardware físico. Numa VM,
`--dry-run` mostra toda a sequência sem aplicar nada.

Passos concretos:

```bash
# 1. Criar VM Debian 12 (virt-manager ou libvirt), instalar minimal + sudo.
# 2. Clonar o repositório dentro da VM.
git clone <repo> && cd ai-cpu-os
chmod +x build.sh detect-hardware.sh common/*.sh profiles/*/*.sh tests/*.sh

# 3. Sintaxe de todos os scripts.
bash -n build.sh && bash -n detect-hardware.sh
for f in common/*.sh profiles/xeon/*.sh profiles/ryzen/*.sh tests/*.sh; do bash -n "$f" || echo "FALHOU: $f"; done

# 4. Detecção + dry-run.
./detect-hardware.sh || true
sudo ./build.sh --profile auto --dry-run
```

**Passo 2 (após VM):** rodar `tests/smoke-test.sh` num Xeon físico com
`llama-server` de pé e preencher a seção 5 acima.

**Passo 3 (ao fechar o marco de validação):** atualizar `docs/TUTORIAL.md`
com o que passou a ser testado e com os números reais de `llama-bench`
(diretriz obrigatória — Regra 9 do `AGENTS.md`).

---

## 7. Como atualizar este arquivo

Ao terminar qualquer tarefa:

1. Atualize **Data** no topo.
2. Marque na tabela da seção 3 o que mudou.
3. Registre métricas novas na seção 5.
4. Reescreva a seção 6 ("Próxima ação imediata") para o próximo passo real.
5. Se mover algo no roadmap, atualize também `docs/ROADMAP.md`.

---

## Histórico

| Data       | Mudança                                                    |
|------------|------------------------------------------------------------|
| 2026-10-07 | Criação do arquivo junto com o repositório `0.1.0-alpha`.   |
| 2026-10-07 | Commit inicial `85a083e` realizado; 26 arquivos versionados. |
| 2026-10-07 | Projeto publicado no GitHub (`main` + tag `v0.1.0-alpha`); adicionado `docs/TUTORIAL.md` e a diretriz de tutorial por marco. |
| 2026-10-07 | Adicionada a esteira de CI/CD (`validate`, `build-llama`, `container`), `Makefile`, `docker/`, `docs/CI.md` e templates. Corrigidos todos os avisos do shellcheck. |
| 2026-10-07 | 1º run do CI no GitHub: `validate` ✅ verde (4/4 jobs). `container` falhou e revelou a falta de `pkg-config` (bug também presente no build nativo) — corrigido em 3 lugares + docs. |
