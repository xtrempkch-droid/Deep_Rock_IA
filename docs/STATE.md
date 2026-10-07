# STATE — Estado atual do projeto ai-cpu-os

> **⚠️ Documento vivo. Atualize SEMPRE ao terminar uma tarefa (regra do AGENTS.md).**
> **Última atualização:** 2026-10-07 (criação inicial)

---

## 1. Versão

- **Versão do projeto:** `0.2.0` (marco de **CI/CD** — nenhuma validação nova de
  hardware nesta versão; ver seção 2)
- **Commit de referência:** tag `v0.2.0` (commit `4cde4bb`)
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

| Workflow      | Estado | Evidência |
|---------------|--------|-----------|
| `validate`    | ✅ **verde** | Run #1 (main, `6da0c35`) e #2: 4/4 jobs (Lint, Regras, Dry-run xeon, Dry-run ryzen). Também verde na tag `v0.2.0` e no PR do Dependabot. |
| `build-llama` | ✅ **verde (build real!)** | Run #1 na tag `v0.2.0` (`4cde4bb`): **6m04s**, os dois perfis compilaram, os binários executaram e a **inferência real** rodou. |
| `container`   | ✅ **verde** | Run #3 (main, `4cde4bb`): 9m14s · Run #4 (tag `v0.2.0`): 8m48s — imagens publicadas no GHCR. |

> ⚠️ **Dependabot PR #1** (`ci(deps): bump the actions group`): o run de
> `container` nesse PR ficou ❌ porque a branch foi criada **antes** da correção
> do `pkg-config` (base desatualizada). O `validate` no PR passou. É preciso
> rebasear a branch — **não** é um problema de código.

### 3.2 Histórico das execuções do CI (2026-10-07)

| Momento | O que aconteceu |
|---------|-----------------|
| Commit `6da0c35` | `validate` ✅ verde. `container` ❌ **revelou um bug real**: o builder não tinha `pkg-config`, exigido pelo backend BLAS do ggml (`find_package(PkgConfig)`). **O mesmo bug existia no build nativo** (`profiles/xeon/llama-build.sh` e `install.sh`) — o primeiro build real no host também teria falhado. Corrigido em 4 lugares (commit `4cde4bb`). |
| Tag `v0.2.0` (`4cde4bb`) | `build-llama` ✅ **6m04s** (compilou `xeon` e `ryzen`, executou os binários e rodou inferência real com o modelo minúsculo) · `container` ✅ **8m48s** · **Release `ai-cpu-os v0.2.0` publicada com os `.tar.gz` dos dois perfis**. |
| `main` (`4cde4bb`) | `validate` ✅ · `container` ✅ 9m14s (imagem `:latest` publicada no GHCR). |

> **Resultado importante:** o CI **compila o sistema de verdade** e publica
> binários utilizáveis, sem intervenção humana. O `pkg-config` foi um bug que
> só a **execução** poderia revelar — reforçando a regra: lint verde ≠ build
> comprovado.

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
7. **Métricas de performance ainda não medidas.** O CI prova que o llama.cpp
   compila e roda; **não** prova quantos tokens/s o hardware entrega. As
   seções 5, 6 e 7.6 do `docs/TUTORIAL.md` seguem `pendente`.
8. **PR #1 do Dependabot está com o `container` ❌** porque a branch é
   anterior à correção do `pkg-config` (base desatualizada). Rebasear a
   branch resolve — não há problema de código.
9. **A imagem do GHCR não foi validada no hardware alvo.** Ela foi construída
   e publicada com sucesso no CI, mas ninguém ainda a executou no Xeon nem no
   Ryzen.

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

**Passo 0 — ✅ CONCLUÍDO.** O CI está verde no GitHub: `validate` (4/4 jobs),
`build-llama` (compilou os dois perfis + inferência real em 6m04s) e
`container` (imagem publicada no GHCR). A Release `ai-cpu-os v0.2.0` foi
publicada com os binários `.tar.gz` dos dois perfis. Ver § 3.1.

**Passo 1 (AGORA) — Subir uma VM Debian 12 e validar `detect-hardware.sh` +
`build.sh --dry-run`.**

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
| 2026-10-07 | Publicada a versão **`0.2.0`** (tag `v0.2.0`, commit `4cde4bb`): marco de CI/CD. **Nenhuma validação de hardware foi feita nesta versão** — ver § 2 e § 3.2. O `build-llama` e o `container` foram disparados pela tag. |
