# mods/ — Modificações portáveis

Cada pasta aqui é uma **mod**: uma modificação pequena, isolada, reversível e
documentada que **qualquer pessoa pode aplicar e testar no seu sistema
operacional** — sem instalar o ai-cpu-os inteiro.

```bash
bash mods/apply.sh list                    # catálogo
bash mods/apply.sh info <id>               # o que faz, risco, requisitos, ganho
sudo bash mods/apply.sh apply <id>         # aplica
sudo bash mods/apply.sh revert <id>        # desfaz
sudo bash mods/apply.sh apply <id> --dry-run   # mostra sem fazer
bash mods/apply.sh test                    # testa em container Ubuntu (sem root real)
```

Conjuntos prontos: `--set system` (tuning de base, usado pelo `build.sh`) e
`--set portable` (seguras em qualquer máquina).

Estrutura de uma mod:

```text
mods/<id>/
├── mod.conf    metadados: MOD_NAME, MOD_DESC, MOD_RISK, MOD_REQUIRES, ...
├── apply.sh    aplica (idempotente, aceita --dry-run/--yes)
└── revert.sh   desfaz (volta ao padrão da distro)
```

**Documentação completa:** [`docs/MODS.md`](../docs/MODS.md) — anatomia,
catálogo, requisitos, fronteiras de segurança e como escrever uma mod nova.

**Fronteira importante:** o `test` em container valida sintaxe, execução e
idempotência em `--dry-run`; ele **não** prova o efeito real de sysctl, governor
ou C-states na sua máquina. Essas são explicitamente "não validadas" em
`docs/VALIDATION.md`.
