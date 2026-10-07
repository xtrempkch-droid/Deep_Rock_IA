<!--
Template de Pull Request do ai-cpu-os.
Leia AGENTS.md e docs/STATE.md antes de abrir o PR.
-->

## O que muda

<!-- Descreva a mudança em 1-3 frases. -->

## Por que

<!-- Qual problema resolve? Qual é a justificativa técnica?
     Se for uma otimização de performance, cite o número (antes/depois). -->

## Tipo de mudança

- [ ] 🐛 Correção de bug
- [ ] ✨ Nova funcionalidade / otimização
- [ ] 📝 Documentação
- [ ] 🔧 CI/CD ou ferramental
- [ ] ⚠️ Mudança que afeta kernel/hardware (exige teste em VM)

## Checklist (regras do `AGENTS.md`)

- [ ] Li `docs/STATE.md` antes de começar.
- [ ] Rodei `make ci` localmente e passou.
- [ ] Scripts novos/alterados usam `set -euo pipefail` e suportam `--dry-run`.
- [ ] Se alterei tuning de kernel, **testei em VM**.
- [ ] Atualizei `docs/STATE.md` (incluindo "Próxima ação imediata").
- [ ] Atualizei `docs/ROADMAP.md` se movi algo de seção.
- [ ] Se fechei um **marco/versão**, atualizei `docs/TUTORIAL.md` (Regra 9).
- [ ] Deixei explícito o que **não** foi testado.

## O que NÃO foi testado

<!-- Ex.: "dry-run ok, mas não executei em hardware físico." -->

## Como testar

```bash
# comandos que o revisor pode rodar
```
