# `talk/` — o chat da frota (`ai-talk`)

> **Fase F1 implementada** (transporte + CLI + testes offline). A integração com
> a ISO é a **F2**. Contrato completo: [`docs/CHAT.md`](../docs/CHAT.md).
> Decisões: ADR-003/004/005 em [`docs/DECISIONS.md`](../docs/DECISIONS.md).

## O que é

Um canal **simétrico** entre as máquinas da frota: TCP + um objeto JSON por
linha + HMAC-SHA256, sem servidor central, sem broker e **sem dependências**
fora da biblioteca padrão do Python 3.

```text
 A ── TCP 7331 (JSON lines, HMAC) ──▶ B
   ◀────────────── ack ──────────────
```

**Mensagem é dado, nunca comando.** O `ai-talk` não executa shell.

## Testar (o que a F1 prova)

```bash
make talk-test          # 30 asserções, loopback, sem rede externa e sem root
bash tests/test-ai-talk.sh -v
```

Cobre: entrega + `ack` + `fsync`, espaçamento de 50 ms por par, `hello` isento,
`ping` throttled, fila com **exit 5** no overflow, dedupe de `id`, assinatura
por nó, `ECONNREFUSED` em *fail fast*, `check-config`, teto de 15 peers e
"somente stdlib".

## Uso manual (dois nós na mesma máquina)

```bash
# 1) chaves (uma por nó, 0640)
mkdir -p /tmp/talk && head -c32 /dev/urandom | xxd -p -c64 > /tmp/talk/keyA
head -c32 /dev/urandom | xxd -p -c64 > /tmp/talk/keyB
chmod 640 /tmp/talk/keyA /tmp/talk/keyB

# 2) configs (veja o formato no docs/CHAT.md §7)
# 3) daemons
python3 talk/ai_talk.py serve --config /tmp/talk/A.json &
python3 talk/ai_talk.py serve --config /tmp/talk/B.json &

# 4) conversar
python3 talk/ai_talk.py --config /tmp/talk/A.json status
python3 talk/ai_talk.py --config /tmp/talk/A.json send B "build #42 terminou"
python3 talk/ai_talk.py --config /tmp/talk/B.json tail -n 5
python3 talk/ai_talk.py --config /tmp/talk/B.json listen
```

## Limites (por contrato)

| Item | Valor |
|------|-------|
| Teto de nós (malha completa) | **15** (ADR-005); acima disso, relay/hub |
| Espaçamento entre `msg` do mesmo par | **50 ms** (20 msg/s) |
| Fila por peer | **256** aguardando (a em trânsito não conta) → **exit 5** |
| Corpo / frame | 8 KiB / 16 KiB |
| Pior caso sem ack | **9 s** (3 tentativas, backoff 1 s/2 s) |

## O que ainda NÃO existe

- `talk/install.sh`, unit `ai-talk.service` e `--chat-*` na ISO (**F2**).
- Teste com duas VMs (**Bloco R**) e bancada de 15 nós (**P4**).
- Ponte opcional com o `llama-server` (**F3**).
