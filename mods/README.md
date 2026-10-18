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
`--set portable` (seguras em qualquer máquina). A mod `network` tem conjunto
próprio (`--set network`): mudar a rede de um servidor é decisão do dono da
máquina, nunca efeito colateral de um tuning.

> 📦 **O `apt-get update` falha sempre depois de instalar?**
> `sudo bash mods/apt-sources/apply.sh` (ou `make apt-fix`) diagnostica as
> fontes, remove as que apontam para o nada (`file:///opt/apt-repo` de uma ISO
> antiga, `cdrom:` do instalador) e valida com `apt-get update`. Teste:
> `make apt-test` (17 asserções, árvore falsa, sem root).
>
> 🔧 **Está sem rede depois de instalar?** `sudo bash mods/network/apply.sh`
> (ou `make network-fix`) aplica no sistema em execução o netplan que a ISO nova
> traz. Ver [`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md).

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
