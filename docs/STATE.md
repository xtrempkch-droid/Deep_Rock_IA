# STATE — Estado atual do projeto ai-cpu-os

> **⚠️ Documento vivo. Atualize SEMPRE ao terminar uma tarefa (regra do AGENTS.md).**
> **Última atualização:** 2026-10-07 (criação inicial)

---

## 1. Versão

- **Versão do projeto:** `0.1.0-alpha`
- **Commit de referência:** `85a083e` (commit inicial — todos os arquivos gerados)
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

Legenda: ✅ sim · ❌ não · ⚠️ parcial

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
