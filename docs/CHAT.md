# CHAT — `ai-talk`, o canal rápido da frota

> **Status:** 🟡 **F1 implementada e testada em loopback** (`talk/ai_talk.py` +
> `make talk-test`, 30 asserções). F2 (ISO/duas VMs), F3 (ponte com o modelo) e
> P4 (bancada de 15 nós) **não** existem.
>
> **Última atualização:** 2026-10-20 (sessão #41) — **F1 no código**, com o
> contrato de §6.7/§6.8 provado por teste. Três pontos ficaram mais precisos na
> implementação: `ping` **conta** no throttle (só `ack`/`hello` são isentos),
> `queue_max` conta só quem **aguarda** (a mensagem em trânsito não ocupa vaga)
> e `--no-wait` retorna após **enfileirar**.
>
> Este documento é o contrato a implementar. Ele existe para que a próxima
> sessão não precise inventar protocolo, porta, formato de mensagem ou modelo
> de segurança no meio do código.

---

## 1. Problema

As máquinas da frota já têm SSH (humano → máquina) e o `llama-server`
(HTTP local). Falta um canal **simétrico e rápido** entre os agentes/processos
das máquinas:

- `builder` termina um build e avisa `inference`;
- `inference` termina um benchmark e publica o resultado;
- uma máquina pede status/ajuda a outra sem abrir uma sessão SSH;
- um agente quer enviar uma mensagem curta a outro (ou a toda a frota).

Requisitos:

1. **Rápido e simples:** mensagens de texto curtas, **p99 ≤ 10 ms** na LAN
   cabeada (orçamento em §6.7), com espaçamento explícito entre envios.
2. **Simétrico:** qualquer nó envia e recebe; não há “servidor central”.
3. **Seguro o suficiente para a LAN:** autenticação por chave compartilhada,
   sem aceitar comandos remotos.
4. **Air-gapped:** nada de download na instalação/primeiro boot; tudo vem na
   ISO.
5. **Sem dependências novas:** Python 3 da biblioteca padrão (ou Bash puro),
   nada de `pip`, Matrix, MQTT, IRC ou `talkd`.
6. **Observável:** log append-only, `tail`, `status`, `peers`.
7. **Escalável até 15 nós** em malha completa, sem servidor central (§5.2,
   ADR-005). Acima disso, relay/hub.

## 2. Não-objetivos

- Substituir SSH, Gitea, registry ou o `llama-server`.
- Chat gráfico/navegador (a `webui/` é para gerar ISO, não para a frota).
- Mensagens binárias, chamadas de vídeo, transferência de arquivos grandes.
- Descoberta automática de peers (mDNS/DHT) na v1.
- Executar comandos recebidos da rede. **Mensagem é dado, nunca comando.**
- Funcionar fora da LAN confiável (não expor na internet).

## 3. Por que **não** o `talk` do netkit

O pedido citou “talk ou algo do tipo”. O `talk` clássico (netkit) é:

| Problema | Detalhe |
|----------|---------|
| Obsoleto | `talk`/`talkd` vêm sendo removidos das distros; não é uma base para code novo. |
| UDP 517/518 | Sem conexão, sem retransmissão moderna, difícil de atravessar firewall. |
| Sem autenticação | Qualquer um na rede pode tentar falar; não há assinatura. |
| Sem criptografia | Texto claro. |
| Interativo | Feito para duas pessoas digitando, não para mensagens máquina-a-máquina. |
| Sem log durável | Não serve para auditoria/observabilidade. |

**Decisão:** inspirar a UX (“falar com o outro nó”), mas implementar o
`ai-talk` com TCP + JSON lines + HMAC. O nome `talk/` no repositório é o
diretório do componente; o comando é `ai-talk` para não colidir com o
`talk` do sistema.

## 4. Topologia e identidade

```text
        LAN confiável (ex.: 192.168.0.0/24)
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ ai-inference (role inference)│        │ ai-builder (role builder)    │
│  ai-talk.service :7331/tcp   │◀──────▶│  ai-talk.service :7331/tcp   │
│  CLI: ai-talk send ...       │  HMAC  │  CLI: ai-talk send ...       │
│  log: messages.jsonl         │        │  log: messages.jsonl         │
└──────────────────────────────┘        └──────────────────────────────┘
              ▲                                        ▲
              └───────────── mesma chave de frota ─────┘
```

- O **nó** é identificado por `node` no config (padrão: hostname/identidade do
  ADR-002: `ai-inference`/`ai-builder`).
- O **papel** (`inference`/`builder`) é informativo; não altera o protocolo.
- Peers são **estáticos** (`nome → IP`). Sem descoberta automática.
- A porta padrão é **7331/tcp**; pode ser mudada no config e nas flags da ISO.

## 5. Arquitetura

```text
┌─────────────────────────────── máquina ───────────────────────────────┐
│                                                                        │
│  ai-talk (CLI)  ── Unix socket ──▶  ai-talk.service (daemon)           │
│  ai-talk send/listen/tail/status     │                                 │
│                                      ├── TCP :7331 ◀── peers (HMAC)    │
│                                      ├── /var/lib/ai-talk/messages.jsonl│
│                                      └── /etc/ai-talk/config.json      │
│                                                                        │
│  (fase 3, opcional) ai-talk agent ── HTTP ──▶ llama-server :8080       │
│                                      │                                 │
└────────────────────────────────────────────────────────────────────────┘
```

- **Daemon** (`ai-talk serve`): escuta TCP nos peers, valida HMAC, grava o
  log, responde `ack`; escuta também o **Unix socket** de controle
  (`/run/ai-talk/control.sock`) para o CLI local.
- **CLI** (`ai-talk send|listen|tail|status|peers|ping`): fala com o daemon
  pelo Unix socket; não abre TCP diretamente (exceto `--no-daemon` para
  diagnóstico).
- **Systemd** mantém o daemon vivo e com o diretório de estado.
- **Sem banco:** log append-only em JSONL; `tail` lê o arquivo. Rotação por
  tamanho (5 × 10 MB por padrão).

### 5.1 Por que um daemon?

- Um único ponto de escuta e de log por máquina (não um processo por CLI).
- O CLI pode ser rápido e stateless.
- O `systemd` garante reinício e limites de recurso.
- A ponte com o modelo (fase 3) roda no daemon/agent, não no CLI.

### 5.2 Escala: teto de **15 nós** (malha completa)

> **Perguntas respondidas em 2026-10-20 (sessão #40):** *“se será possível
> outras máquinas entrarem na mesma conversa (imagino umas 30)”* → **sim**, e
> *“mantenha um teto de 15 máquinas, assim fica confortável”* → **o teto
> oficial é 15**. Ver ADR-005 em [`docs/DECISIONS.md`](DECISIONS.md).

**Topologia v1: malha completa** (`full mesh`). Cada nó mantém **uma conexão
persistente** com cada peer configurado. Não há servidor central, então não há
ponto único de falha nem um nó que precise "estar de pé" para os outros
conversarem.

**Teto suportado: 15 nós.** Não é um número redondo escolhido por estética:
é o ponto em que fan-out, `fsync` por mensagem e janela de dedupe ainda
deixam folga confortável numa única máquina modesta. Acima disso, **relay/hub**
deixa de ser opcional (§15).

Para **15 nós**:

| Métrica | Valor | Observação |
|---------|-------|------------|
| Conexões por nó | **14** | 105 no cluster; trivial para `ulimit -n` (~1024) |
| Config por nó | 14 peers | gerada por `--chat-peers-file` (§7.1), não à mão |
| Broadcast típico (1 msg/s por nó) | 14 msg/s de entrada por nó | ~210 msg/s no cluster |
| Broadcast no limite (20 msg/s por par) | **280 msg/s por nó** | 4.200 msg/s no cluster; o teto teórico |
| Banda no limite | ~106 KB/s por nó (**~0,85 Mbit/s**) | cabe em GbE com muita folga |
| HMAC no limite | ~1,5 ms de CPU por segundo | irrelevante |
| `fsync` no limite | ~84 ms de CPU por segundo (**~8% de 1 core**) | é o custo dominante do limite |
| Log no limite | ~106 KB/s | 32 MB em ~5 min → rotação por tamanho (§7) |
| Log no uso típico | ~5,7 KB/s | 32 MB em ~1,6 h; ~8 h com `keep=5` |
| Threads/processos | 1 daemon + N conexões | sem thread por peer obrigatória (`selectors`/`asyncio`) |

Três ajustes que o teto de 15 **exige** (todos no ADR-005):

1. **Janela de deduplicação.** Os **1024 IDs** originais cobrem apenas
   **~3,7 s** a 280 msg/s, mas o retry do emissor dura **9 s** (§6.4) — um
   retry legítimo seria entregue duas vezes. → **`dedupe_window = 8.192`**
   (≈29 s no teto; ≈14 min no uso típico).
2. **Chave única da frota permite impersonação.** Com uma chave só, qualquer
   nó que a tenha pode assinar uma mensagem com `from` de outro nó — inofensivo
   em 2 máquinas, inaceitável em 15. → **chave por nó**
   (`peers[nome].key_file`), o que também permite revogar **um** nó sem trocar
   a chave de todos.
3. **Log de controle infla o arquivo.** `ack`/`hello`/`ping` são a maior parte
   do volume e não são conversa. → **`log.control = false`** (só `msg` e
   erros vão para o `messages.jsonl`).

Decisões operacionais para o teto de 15:

| Item | Decisão |
|------|---------|
| Configuração | `--chat-peers-file` na ISO (uma linha `nome=ip` por nó) — 14 flags `--chat-peer` é erro de digitação esperando acontecer |
| Teto global de saída | `max_out_per_sec = 120` por nó, **além** dos 20/s por par: um broadcast sustentado acima de ~8,5 msg/s para os 14 peers bate no teto global (exit 5) em vez de saturar a frota |
| Broadcast | fan-out paralelo com concorrência 8; tempo ≈ `ceil(14/8) × RTT` = **2 RTTs**, não 14 |
| Reconexão | backoff com **jitter** (evita tempestade de reconexão quando o switch reinicia) |
| IP ↔ nome | com chave por nó, a checagem `from` × IP é **opcional**; com DHCP, prefiram reservas |
| Retenção | `max_bytes` 32 MB × `keep` 5 (~160 MB), rotação só de `msg` |
| Acima de 15 | **relay/hub obrigatório** (não é “otimização”): reduz para N conexões, ao custo de um ponto único de falha |

**“Mesma conversa” tem dois significados — e só um existe na v1:**

| Quero… | v1 | Observação |
|--------|----|------------|
| Avisar **todos** os nós | ✅ `ai-talk send '*' "..."` | broadcast para os 14 peers |
| Uma **sala/tópico** (`#build`) | ❌ **F4** | campo `room` no envelope, sem quebrar o v1 (quem não conhece ignora) |

**Sobre “sala” e tráfego:** em malha completa, uma sala **não** reduz tráfego —
o emissor ainda envia uma cópia por peer; ela reduz **interesse** (log e
`listen` filtram). Para reduzir tráfego de verdade seria preciso um **relay**
(hub): cada nó conecta no hub (15 conexões em vez de 105) e o hub faz o
fan-out. Custo: ponto único de falha e um nó com 14× o tráfego de entrada.
**Decisão:** não implementar agora; é o caminho **obrigatório** acima de 15 nós
ou em múltiplas sub-redes (§15).

**Limite honesto:** o teto de 15 é **cálculo**, não medição. O Bloco R do
`VALIDATION.md` mede 2 nós; a bancada de 15 (§13.5) ainda não foi executada.
Se a medição mostrar que 15 não cabe, o próximo passo é o **relay**, não
aumentar o teto.

## 6. Protocolo v1

### 6.1 Transporte e framing

- **TCP**, IPv4 ou IPv6, porta padrão `7331`.
- Uma mensagem = **um objeto JSON em uma linha**, terminado por `\n`.
- Codificação **UTF-8**.
- Tamanho máximo do frame: **16 KiB** (incluindo o `\n`); corpo máximo:
  **8 KiB**. Frame maior é rejeitado e a conexão é fechada.
- Sem TLS na v1 (LAN confiável + HMAC). TLS é evolução possível (v2).
- **`TCP_NODELAY` sempre ligado.** Sem ele, Nagle + delayed ACK injetam até
  ~40 ms numa mensagem pequena — o que sozinho estouraria a meta de §6.7.
- **Uma conexão persistente por peer** (não uma por mensagem): evita um RTT
  de handshake por envio e o acúmulo de sockets em `TIME_WAIT`.
- Timeout de leitura ociosa: 120 s; `ping` a cada 60 s (opcional).

### 6.2 Envelope

```json
{
  "v": 1,
  "id": "6f1c2a9e-6f1c-4a9e-9f1c-2a9e6f1c4a9e",
  "ts": "2026-10-20T18:00:00Z",
  "from": "ai-inference",
  "to": "ai-builder",
  "kind": "msg",
  "body": "build #42 terminou",
  "reply_to": null,
  "sig": "9f2c... (64 hex)"
}
```

| Campo | Obrigatório | Regra |
|-------|-------------|-------|
| `v` | sim | versão do protocolo; hoje `1` |
| `id` | sim | UUIDv4; único por mensagem |
| `ts` | sim | UTC ISO-8601 (`Z`), gerado pelo emissor |
| `from` | sim | nó emissor (deve casar com o config) |
| `to` | sim | nó destino ou `"*"` (broadcast) |
| `kind` | sim | `msg`, `ack`, `hello`, `ping` |
| `body` | sim | texto UTF-8; vazio em `ack`/`hello`/`ping` |
| `reply_to` | não | `id` da mensagem respondida (ack/resposta) |
| `sig` | sim | HMAC-SHA256 em hex minúsculo |

### 6.3 Assinatura (HMAC)

Para evitar ambiguidade de serialização JSON, a assinatura cobre uma
concatenação **canônica** com `\n`:

```text
canonical = v + "\n"
          + id + "\n"
          + ts + "\n"
          + from + "\n"
          + to + "\n"
          + kind + "\n"
          + (reply_to or "") + "\n"
          + body

sig = hex(HMAC-SHA256(key, UTF-8(canonical)))
```

- `key`: 32 bytes aleatórios, arquivo `0600`/`0640` (dono `ai-talk` ou
  root:ai-talk). Nunca vai para o repositório nem para o log.
- Comparação em tempo constante (`hmac.compare_digest`).
- Chave ausente/ilegível: o daemon **não inicia** (fail closed), com erro
  claro no journal.
- Rotação de chave: fase futura (v1 aceita uma chave ativa; documentar o
  procedimento de troca coordenada).

### 6.4 Handshake, ack e retry

1. Ao conectar, o emissor envia `hello` com `from` e `v`.
2. O receptor confere que `from` é um peer conhecido; se não, fecha.
3. Para `msg`, o receptor **grava no log com `fsync`** e só então responde
   `ack` (`kind:"ack"`, `to` = emissor, `reply_to` = `id` da mensagem). Um
   `ack` significa “está no disco”, não “está no buffer” — ver §6.8.
4. O emissor tem `connect_timeout_ms` (**1 s**) para estabelecer o TCP — sem
   ele, um IP obsoleto pode bloquear por ~2 min e o timeout de ack nunca vale.
5. O emissor espera o `ack` por até **2 s** (`ack_timeout_ms`). Sem ack, tenta
   de novo até **3 tentativas no total**, com backoff de **1 s e 2 s** entre
   elas. Sem ack após a última: erro visível (**exit 3**) — **não** há fila
   persistente na v1.
   - **Pior caso calculado:** 2 s + 1 s + 2 s + 2 s + 2 s = **9 s**.
   - Este orçamento é limitado por `send_timeout_ms` (15 s), que também
     inclui a espera na fila de espaçamento (§6.7).
6. O receptor mantém uma janela LRU de **`dedupe_window` IDs** (padrão
   **8.192**) para ignorar duplicatas (retry do emissor); ao ver um `id`
   repetido, **reenvia o ack** sem gravar de novo.
   - **Por que 8.192 e não 1024:** a janela precisa cobrir a duração do retry
     (9 s) na **taxa de entrada** do nó. Com 15 nós no limite (280 msg/s),
     1024 IDs cobrem ~3,7 s — um retry legítimo seria entregue duas vezes.
     8.192 cobre ~29 s no teto e ~14 min no uso típico (ADR-005).
7. Broadcast (`to:"*"`): envia para todos os peers configurados; o resultado
   é `ok` se pelo menos um ack veio, com a lista de falhas no stderr. Para
   “todos precisam receber”, usar `--require-all` (exit 3 se algum falhar).

### 6.5 `hello` e `ping`

- `hello`: `{kind:"hello", body:""}`; serve para o receptor validar o peer e
  registrar “online”.
- `ping`: `{kind:"ping", body:""}`; o receptor responde `ack` com
  `reply_to` = id do ping.
- `status` local não usa rede; `peers` mostra o último `hello`/erro por peer
  (em memória; não é health check contínuo na v1).

### 6.6 Códigos de saída do CLI

| Código | Significado |
|--------|-------------|
| 0 | sucesso |
| 1 | erro genérico |
| 2 | uso/config inválido |
| 3 | peer offline / sem ack / falha de gravação (`fsync`) |
| 4 | assinatura inválida / peer desconhecido |
| 5 | frame/corpo grande demais ou **rate limit (fila cheia)** |

### 6.7 Latência e espaçamento entre mensagens

> **Decisão de 2026-10-20.** “Delay entre mensagens” aqui significa **intervalo
> mínimo entre dois `msg` do mesmo nó para o mesmo peer**. Não é um atraso
> artificial em cada envio, e não inclui `ack`/`hello`.

#### 6.7.1 Orçamento de latência

Cenário de referência: LAN cabeada 1 GbE, mesmo switch, Python 3, mensagem
≤ 8 KiB, `fsync` por mensagem em NVMe (ver §6.8).

| Etapa | Típico | p99 | Nota |
|-------|--------|-----|------|
| CLI → daemon (Unix socket) | 0,05–0,3 ms | ~1 ms | wakeup de processo |
| JSON + HMAC-SHA256 | 0,01–0,05 ms | ~0,2 ms | stdlib, payload pequeno |
| TCP na LAN (1 RTT) | 0,1–0,5 ms | ~2 ms | switch store-and-forward |
| Receptor: decode + verify + append + `fsync` | 0,15–1,2 ms | ~4 ms | NVMe; disco lento domina |
| `ack` de volta (1 RTT) | 0,1–0,5 ms | ~2 ms | mesma conexão |
| **Total `send` com ack** | **0,5–2,5 ms** | **≤ 10 ms** | meta de projeto, **não SLA** |

Fatores que mudam o número:

| Fator | Efeito | Regra |
|-------|--------|-------|
| `TCP_NODELAY` desligado | +0–40 ms (Nagle + delayed ACK) | **Sempre ligado** (§6.1) |
| Conexão nova por mensagem | +1 RTT + handshake + `TIME_WAIT` | Conexão persistente por peer |
| `fsync` por mensagem | +0,1–1 ms (NVMe), +0,5–2 ms (SATA SSD), +5–15 ms (HDD) | Decisão: **sempre** (§6.8) |
| Python GIL sob carga | picos de 10–20 ms | medir em F2; não prometer |
| Wi-Fi / rede virtualizada | p99 pode ir a dezenas de ms | fora da meta |
| Broadcast para N peers | ~`max(RTT)`, não a soma | envio paralelo, concorrência limitada (8) |

> **Não existe SLA.** O teste de F1 verifica a **semântica** (desiste no tempo
> certo, respeita a fila, isenta o ack), não wall-clock rígido no CI. O número
> de p50/p99 vem do Bloco R (`VALIDATION.md`), medido em duas VMs.

#### 6.7.2 Espaçamento (throttle)

- **`min_interval_ms` = 50** (equivalente a 20 msg/s), por par
  `(nó de origem, peer de destino)`. `0` desliga (não recomendado).
- **Escopo por par:** falar com `ai-builder` não atrasa uma mensagem para
  outro nó.
- **O que conta:** `kind` = `msg` e `ping`.
- **O que NÃO conta:** `ack` e `hello` (controle de protocolo). Se contassem,
  cada envio pagaria +50 ms e a meta de 10 ms seria impossível.
- **Fila:** FIFO por peer, `queue_max = 256`. O `send` **enfileira** e espera
  a vez; a ordem é garantida dentro do par.
  - `queue_max` conta as mensagens **aguardando na fila**. A mensagem que já
    está **em trânsito** (sendo entregue neste instante) não ocupa vaga — por
    isso um peer aceita `queue_max + 1` mensagens simultâneas.
- **Overflow:** fila cheia → **exit 5 imediato**, com mensagem explícita
  (`rate limit: fila cheia (256)`). **Nunca** descarta em silêncio.
- **Prazo total:** `send_timeout_ms` (**15 s**) cobre
  `espera na fila + tentativas + backoff`. Se estourar:
  - estourou **na fila** → **exit 5** (limite de taxa);
  - estourou **sem ack** → **exit 3** (peer offline/mudo).
- **`--no-wait`:** enfileira e retorna 0 **imediatamente** (não espera a vez
  do espaçamento, o write nem o ack); fila
  cheia continua sendo exit 5 (o limite de taxa não é “melhor esforço”).
- **Broadcast `*`:** uma entrada por peer, cada uma na fila do seu peer; o
  tempo total é ~`max(RTT)` + a espera da fila do peer mais lento.
- **Observabilidade:** `ai-talk status` mostra `queue_depth` e a idade da
  mensagem mais antiga por peer; `peers` mostra o próximo slot livre.

**Custo visível do espaçamento:**

| Rajada (mesmo peer) | Tempo até a última | Comportamento |
|---------------------|--------------------|---------------|
| 2 mensagens | ~50 ms | normal |
| 40 mensagens | ~2 s | normal (fila) |
| 256 mensagens | ~12,8 s | fila cheia; a partir daí **exit 5** |

Se o uso real exigir mais que 20 msg/s, `min_interval_ms` é o **único** lugar
a mudar — o resto do protocolo não depende desse valor.

#### 6.7.3 Semântica de falha (o que o usuário sente)

| Situação | Comportamento | Tempo até desistir |
|----------|---------------|--------------------|
| Peer recusa conexão (`ECONNREFUSED`) | **fail fast**: sem retry, exit 3 | ~1–5 ms |
| Peer não responde ao `connect` | `connect_timeout_ms` (1 s) por tentativa | 1 s × tentativas |
| Conectou, mas sem `ack` | `ack_timeout_ms` 2 s × 3 tentativas + backoff 1 s/2 s | **9 s** |
| Peer lento mas vivo | ack chega dentro do timeout; sem retry | 0,5–2,5 ms típico |
| Fila cheia | exit 5 imediato | ~0 ms |
| `--no-wait` | retorna após enfileirar | ~0 ms |

### 6.8 Durabilidade do log (`fsync`)

- **`fsync` por mensagem** (decisão de 2026-10-20): append no
  `messages.jsonl` → `fsync` → só então `ack`.
  - O `ack` significa **“gravado no disco”**, não “aceito no buffer”.
  - Custo: +0,1–1 ms em NVMe (o alvo do projeto). Em SATA SSD/HDD o `fsync`
    domina; aí a meta de p99 ≤ 10 ms pode não ser atingida.
- **Escape explícito** (não default): `"fsync": "interval"` com
  `fsync_interval_ms = 100`. Troca durabilidade por latência — documentar no
  `status` qual modo está ativo.
- **Falha de gravação** (disco cheio/erro de I/O): **não** responde `ack`;
  registra o erro no journal e o CLI recebe **exit 3**. Nunca confirmar o que
  não foi gravado.
- A ordem no disco é a ordem de chegada; a ordenação por `ts` é só para
  leitura (`tail`), não para entrega.

## 7. Configuração

Arquivo: `/etc/ai-talk/config.json` (root:ai-talk, `0640`).

```json
{
  "node": "ai-inference",
  "role": "inference",
  "listen": { "address": "0.0.0.0", "port": 7331 },
  "key_file": "/etc/ai-talk/fleet.key",
  "peers": {
    "ai-builder": { "addr": "192.168.0.20", "key_file": "/etc/ai-talk/keys/ai-builder.key" },
    "ai-worker-07": { "addr": "192.168.0.27" }
  },
  "log": {
    "path": "/var/lib/ai-talk/messages.jsonl",
    "max_bytes": 33554432,
    "keep": 5,
    "control": false,
    "fsync": "always",
    "fsync_interval_ms": 100
  },
  "limits": {
    "max_frame_bytes": 16384,
    "max_body_bytes": 8192,
    "dedupe_window": 8192,
    "max_out_per_sec": 120
  },
  "timing": {
    "min_interval_ms": 50,
    "queue_max": 256,
    "send_timeout_ms": 15000,
    "connect_timeout_ms": 1000,
    "ack_timeout_ms": 2000,
    "max_attempts": 3,
    "backoff_ms": [1000, 2000],
    "tail_poll_ms": 250
  },
  "agent": {
    "enabled": false,
    "endpoint": "http://127.0.0.1:8080",
    "model": "",
    "max_tokens": 256
  }
}
```

- `listen.address`: `0.0.0.0` (todas as interfaces) ou um IP específico. Em
  máquina com interface pública, **prefira** o IP da LAN.
- `peers`: mapa nome → `{addr, key_file?}`. O nó não fala com quem não está
  aqui.
  - **`key_file` por peer** (ADR-005): cada nó tem a **sua** chave. O receptor
    escolhe a chave pelo campo `from` e verifica; assim um nó não consegue
    assinar como outro. Sem `key_file` no peer, cai na chave global do
    `key_file` do topo (modo frota pequena, compatível com o v1).
  - O formato string (`"ai-builder": "192.168.0.20"`) continua aceito como
    atalho para `{addr}` (sem chave própria).
- `key_file`: chave **global** de fallback; permissão verificada na inicialização
  (recusa se for legível por “outros”).
- `limits.dedupe_window`: janela de IDs para deduplicar retries (§6.4);
  dimensione como `taxa_de_entrada × 20 s` (mínimo 1024).
- `limits.max_out_per_sec`: teto **global** de saída por nó, **além** do
  `min_interval_ms` por par. Impede que um agente em loop fale com 14 peers ao
  mesmo tempo (§5.2).
- `log.control`: `false` por padrão — `ack`/`hello`/`ping` **não** vão para o
  `messages.jsonl` (só `msg` e erros). Em 15 nós, eles seriam a maior parte do
  arquivo.
- `log.fsync`: `"always"` (padrão, durável — §6.8) ou `"interval"` (escape
  para disco lento; usa `fsync_interval_ms`).
- `timing`: todos os tempos do §6.7 em **um só lugar** — nada de número
  escondido no código.
  - `min_interval_ms`: espaçamento entre `msg`/`ping` do mesmo par (§6.7.2);
  - `queue_max`: fila FIFO por peer; cheia → exit 5;
  - `send_timeout_ms`: prazo total (fila + tentativas), separa exit 5 de 3;
  - `max_attempts`: **tentativas totais** (3 = 1 envio + 2 retries);
  - `backoff_ms`: espera entre as tentativas (lista de tamanho
    `max_attempts - 1`);
  - `tail_poll_ms`: intervalo do `tail -f` (não afeta a entrega).
- `agent`: bloco da fase 3; `false` por padrão.
- **`TCP_NODELAY` não é knob**: ligado sempre (§6.1). Desligá-lo só
  reintroduziria o pior caso de latência.

### 7.1 O que vai na ISO (planejado)

Flags futuras do `iso/build-iso.sh` (não implementadas ainda):

```text
--chat-key-file PATH     chave GLOBAL de fallback (32 bytes) a embutir na ISO
--chat-keydir DIR        diretório com uma chave por nó (nome.key) — frota de até 15
--chat-peers-file PATH   arquivo da frota: uma linha "nome=ip" por nó
--chat-peer NAME=IP      peer individual (repetível; para frotas pequenas)
--chat-port N            porta (padrão 7331)
--chat-bind ADDR         endereço de escuta (padrão 0.0.0.0)
--chat-node NAME         nome do nó (padrão: hostname/identidade do ADR-002)
--chat-disable           instala o serviço, mas desabilitado (padrão sem chave)
```

- **Frota de até ~8 nós:** `--chat-peer NAME=IP` repetido + `--chat-key-file`.
- **Frota no teto (até 15 nós):** `--chat-peers-file frota.txt` + `--chat-keydir keys/`.
  O arquivo é a fonte única; gerar 14 flags por ISO seria erro de digitação
  esperando acontecer (§5.2).
- **Sem chave** (nem global nem por nó), o `talk/install.sh` instala o serviço
  **desabilitado** e avisa: não existe chave default, e um canal sem HMAC não é
  aceitável.
- As chaves são copiadas para `/etc/ai-talk/` no alvo pelo `late-command.sh`
  (mesmo padrão do repositório apt/modelo), com modo `0640`. Elas **não** são
  escritas no `.iso-config`, no log ou no repositório.
- O config é gerado no alvo a partir de `.iso-config` + flags; o `ai-talk`
  valida o config antes de iniciar (`ai-talk check-config`).
- O `verify-iso.sh` ganha uma seção “Chat da frota”: presença de `talk/`,
  unit, config, chaves (quantidade e modo) e ausência de downloads.

## 8. CLI

```bash
ai-talk status                     # nó, papel, peers, uptime, fila/erros
ai-talk peers                      # peers configurados + último hello/erro
ai-talk send ai-builder "build #42 terminou"
ai-talk send '*' "vou reiniciar em 60 s"
ai-talk send --file resultado.txt ai-builder
ai-talk listen                     # imprime mensagens recebidas (stream)
ai-talk listen --from ai-builder   # filtra por emissor
ai-talk tail -n 50                 # últimas 50 do log local
ai-talk tail -f                    # segue o log
ai-talk ping ai-builder            # hello/ping + ack
ai-talk check-config               # valida o config e a permissão da chave
ai-talk serve --config /etc/ai-talk/config.json   # usado pelo systemd
```

- `send` espera o ack (pior caso **9 s**, §6.4/§6.7.3) e devolve:
  - **0** entregue;
  - **3** peer offline/mudo ou falha de gravação;
  - **5** fila cheia (rate limit).
  `--no-wait` só enfileira e retorna imediatamente (menos confiável, mas a
  fila cheia continua sendo exit 5).
- `listen` é um cliente do Unix socket; não abre porta. O daemon faz **push**,
  então a mensagem aparece em ~1 ms (não depende de `tail_poll_ms`).
- `tail` lê o JSONL local; `-f` segue com `tail_poll_ms` (padrão 250 ms).
  É leitura de arquivo, **não** é o caminho de entrega.
- `--json` em `status`/`peers` para consumo por agentes.
- `--help` e `--version` em todos os subcomandos.

## 9. Segurança

**Modelo de ameaça:** LAN confiável (casa/escritório/laboratório), adversário
capaz de escutar a rede e tentar enviar pacotes, mas **sem** acesso à chave.
Não é um modelo de internet.

| Controle | Implementação |
|----------|----------------|
| Autenticação | HMAC-SHA256; **chave por nó** quando configurada (ADR-005), com a chave global como fallback; sem chave, não inicia |
| Confidencialidade | **não** na v1 (texto claro na LAN); TLS é v2 |
| Anti-spoof | `from` tem de ser peer conhecido **e** a assinatura tem de casar com a chave **daquele** nó; a checagem `from` × IP é opcional quando há chave por nó |
| Anti-replay | `id` único + janela LRU dimensionada pela taxa (`dedupe_window`); `ts` fora de ±5 min é avisado/rejeitado |
| Tamanho | frame ≤ 16 KiB, body ≤ 8 KiB |
| Rate limit | 20 msg/s por peer (`min_interval_ms=50`) + teto global `max_out_per_sec=120`; fila de 256 e **exit 5** no overflow — nunca descarte silencioso (§6.7.2) |
| Escala | **teto suportado: 15 nós** em malha completa (ADR-005); acima disso, relay/hub **obrigatório** (§5.2). Janela de dedupe e log dimensionados pela taxa |
| Integridade do log | `fsync` por mensagem **antes** do `ack`; falha de gravação = sem ack (§6.8) |
| Latência | meta **p99 ≤ 10 ms** na LAN cabeada; `TCP_NODELAY` obrigatório (§6.7.1) |
| Execução | **nenhuma**; mensagem nunca vira shell/comando |
| Superfície | bind na LAN; firewall recomendado; sem porta na internet |
| Permissões | config/chave `0640` root:ai-talk; log `0600` ai-talk |
| Serviço | `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`,
  `ProtectHome=yes`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` |
| Auditoria | JSONL append-only; mensagens e erros com timestamp |

**Prompt injection (fase 3):** mensagens recebidas são **não confiáveis**. A
ponte com o modelo deve:

- colocar a mensagem em um bloco delimitado e instruir o modelo a tratá-la
  como dados;
- **nunca** executar tool calls/ comandos sugeridos por uma mensagem remota;
- limitar tokens/tempo e registrar prompt/resposta;
- opcionalmente aceitar só peers de uma allowlist.

## 10. Instalação e systemd (planejado)

### 10.1 Layout no alvo

```text
/opt/ai-cpu-os/talk/                 # fonte copiada pela ISO (fase 2)
/usr/local/bin/ai-talk               # CLI + daemon (Python 3 stdlib)
/usr/local/lib/ai-talk/ai_talk.py    # implementação (ou um único script)
/etc/ai-talk/config.json             # 0640 root:ai-talk
/etc/ai-talk/fleet.key               # 0640 root:ai-talk
/var/lib/ai-talk/messages.jsonl      # 0600 ai-talk
/run/ai-talk/control.sock            # 0660 ai-talk
/etc/systemd/system/ai-talk.service
```

### 10.2 Unit (esboço)

```ini
[Unit]
Description=ai-talk — chat da frota ai-cpu-os
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ai-talk
Group=ai-talk
StateDirectory=ai-talk
RuntimeDirectory=ai-talk
ExecStart=/usr/local/bin/ai-talk serve --config /etc/ai-talk/config.json
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ai-talk
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
```

- Usuário de sistema `ai-talk` criado idempotentemente (`useradd --system`).
- O serviço é instalado por um `talk/install.sh` idempotente, com
  `--dry-run`, `--yes`, logs `INFO/WARN/ERROR` (Regra 7 do `AGENTS.md`).
- **Ordem no primeiro boot:** instalar o `ai-talk` **antes** do papel
  (`build.sh` etapa 2.5), para que a máquina possa relatar uma falha do papel
  pelo próprio chat. Se o `ai-talk` falhar, o `build.sh` **degrada com aviso**
  e continua (Regra 13-a) — o chat não pode impedir a inferência de subir.
- `talk/install.sh` **não** baixa nada: o código veio na ISO.

### 10.3 `build.sh` e papéis

- `build.sh` chama `talk/install.sh` depois das mods e antes do papel.
- `roles/inference/install.sh` e `roles/builder/install.sh` **não** precisam
  duplicar a instalação; apenas o `build.sh` orquestra.
- Em uma instalação manual (sem ISO), `talk/install.sh --key-file ...` cria o
  config a partir de flags; sem chave, instala desabilitado.

## 11. Log e observabilidade

- JSONL append-only no `messages.jsonl`; cada linha é o envelope recebido
  (`direction:"in"`) ou enviado (`direction:"out"`), com `received_at`.
- Rotação simples: quando passa de `max_bytes`, renomeia para `.1`…`.keep`.
- `ai-talk status` mostra: nó, papel, versão, uptime, peers, último erro,
  contadores (enviadas/recebidas/rejeitadas) — em memória, sem banco.
- `journalctl -u ai-talk` para o serviço; o log de mensagens é separado
  (privacidade/rotação).
- **Nunca** logar a chave; corpo da mensagem é logado (é o conteúdo do chat),
  então não envie segredos por ele.

## 12. Falhas e degradação

| Cenário | Comportamento |
|---------|----------------|
| Chave ausente/inválida | daemon não inicia; `systemctl status` e journal explicam; instalação avisa |
| Peer offline | `ECONNREFUSED` → exit 3 em ~ms; sem resposta → exit 3 em **9 s** (§6.7.3); `status` mostra o último erro |
| HMAC inválido | fecha a conexão, incrementa `rejected`, loga aviso (sem corpo) |
| Frame grande | fecha a conexão, exit 5 no CLI quando local |
| Config inválido | `ai-talk check-config` falha com exit 2; daemon não inicia |
| Porta ocupada | daemon falha; systemd reinicia com backoff; `status` mostra |
| **Fila cheia (rate limit)** | `send` recebe **exit 5** imediato (`rate limit: fila cheia (256)`); nada é descartado em silêncio |
| **`fsync` falha (disco cheio/I/O)** | receptor **não** responde `ack`; erro no journal; cliente recebe exit 3 (§6.8) |
| Disco cheio | o log para de crescer com aviso; o daemon continua e **nunca** derruba o `llama-server` |
| Relógio muito fora | `ts` fora de ±5 min é rejeitado/avisado; documentar NTP |
| Duplicata (retry) | ignorada pela janela de IDs; `ack` reenviado sem gravar de novo |
| **Peer lento (rede saturada)** | ack pode passar de 10 ms; o protocolo continua correto — a meta é de projeto, não SLA |

## 13. Testes (o que cada um prova)

### 13.1 Offline / loopback (entra no `make validate`)

`tests/test-ai-talk.sh` prova, sem root e sem rede externa (**30 asserções**
na F1):

- daemons reais em `127.0.0.1` com portas efêmeras e diretórios temporários;
- `send` → `ack`, mensagem no log do receptor com `direction=in`;
- assinatura alterada (chave errada) → rejeitada, **sem ack** e **sem gravar**;
- corpo > 8 KiB → exit 5;
- `id` repetido → **não** duplica no log; ack reenviado nas duas vezes;
- peer desconhecido → exit 4; peer offline → exit 3;
- `check-config` recusa chave `0644` (exit 2) e **16 peers** (exit 2, ADR-005);
- `--version`, `--help` e `send --help` funcionam;
- **somente biblioteca padrão** (AST: nenhum import fora da stdlib).

**Tempos (§6.7) — semântica, não wall-clock rígido (valores usados na F1):**

| Regra | Como é provado |
|---|---|
| **spacing** | com `min_interval_ms=400`, 2 `msg` do mesmo par levam **≥ 350 ms** |
| **`hello` isento** | logo após as 2 mensagens, `hello` responde em **< 300 ms** (medido: < 1 ms) |
| **`ping` conta** | logo depois, `ping` paga o intervalo (**≥ 300 ms**) — como o §6.7.2 manda |
| **fila** | `queue_max=2`, 4 envios `--no-wait`: 3 aceitos (1 em trânsito + 2 aguardando) e o 4º com **exit 5** |
| **dedupe** | `id` igual enviado 2×: 2 acks, **1** linha no log |
| **fail fast** | `ECONNREFUSED` → exit 3 em **< 2 s** (medido: ~100 ms) |
| **`--no-wait`** | retorna imediatamente; a fila cheia continua sendo exit 5 |
| **`listen` / `tail`** | a mensagem aparece no `listen` e no JSONL (< 2 s de margem) |

> O loopback **não** mede latência de rede: p50/p99 e o teto de 15 nós só saem
> do Bloco R (duas VMs) e da bancada de §13.5.

### 13.2 ISO (entra no `verify-iso.sh` / `make iso-yaml`)

- a árvore da ISO contém `talk/` (código, unit, config de exemplo);
- a unit e o config são sintaticamente válidos;
- a chave existe com modo `0640` quando `--chat-key-file` foi usado;
- sem chave, o serviço está desabilitado e há aviso;
- não há download/`pip`/`curl` no `talk/install.sh`.

### 13.3 Duas VMs (manual/Bloco R do `VALIDATION.md`)

- duas VMs na mesma bridge isolada, cada uma com um papel;
- `ai-talk send` de A para B e de B para A;
- broadcast `*`;
- derrubar B e conferir exit 3 em A;
- reiniciar B e conferir que volta a receber;
- capturar `messages.jsonl` e `status` das duas;
- **medir a latência** de `send` (p50 e p99, com `fsync` ligado) e comparar
  com a meta de §6.7.1 — registrar o número real, mesmo que acima;
- **medir o espaçamento**: 10 mensagens seguidas devem levar ~450 ms
  (9 × 50 ms), não 0 ms.

### 13.4 Ponte com o modelo (fase 3)

- `agent.enabled=false` por padrão;
- com um `llama-server` fake local, uma mensagem gera uma resposta e um
  `reply_to` correto;
- mensagem remota **não** executa comando;
- limite de tokens/tempo respeitado;
- prompt injection de teste não vaza a chave nem executa shell.

### 13.5 Frota no teto: 15 nós (bancada separada — NÃO é o Bloco R)

> ❌ **Não executado.** É uma bancada de **carga**, não de correção: exige 15
> processos/containers, e não 15 máquinas físicas. É o teste que valida o
> **teto do ADR-005** — se falhar aqui, o teto cai ou o relay entra.

- 15 daemons em containers na mesma bridge (nomes `n01`…`n15`), cada um com a
  **sua** chave; config gerada por `--chat-peers-file`.
- **Conexões:** cada nó deve ter 14 sockets `ESTABLISHED` (`ss -tn`).
- **Broadcast:** um nó envia `*`; os 14 devem receber **e** o tempo total deve
  ser próximo de `ceil(14/8) × RTT` = **2 RTTs** (não 14).
- **Dedupe:** com retry forçado (derrubar o ack), o receptor **não** pode
  gravar a mesma mensagem duas vezes com 280 msg/s de fundo.
- **Teto global:** um agente em loop deve parar em `max_out_per_sec=120`, com
  **exit 5**, sem derrubar o daemon.
- **Impersonação:** um nó com a chave de outro (simulada) deve ser rejeitado
  quando há chave por nó (exit 4 / `rejected`).
- **Volume:** medir `messages.jsonl` em bytes/s e confirmar a rotação em 32 MB
  com `log.control=false`.
- **Recursos:** `%CPU`, RSS, `fd` por nó — registrar o número real.
- **Critério de aprovação do teto:** p99 de `send` ≤ 10 ms **e** daemon sem
  crescimento de memória/fd ao longo de 10 min de carga. Se não passar, a
  resposta é **relay/hub** (§5.2) — não “aumentar o teto”.
- Registrar tudo no Bloco R do `VALIDATION.md`.

## 14. Fases de implementação

| Fase | Entrega | Prova |
|------|---------|-------|
| **F0** (sessão #39) | ADR-003 + este desenho | revisão humana; links no `AGENTS.md`/`STATE.md` |
| **F1** ✅ (sessão #41) | `talk/ai_talk.py` + CLI + `tests/test-ai-talk.sh`; **chave por nó**, `dedupe_window`, `max_out_per_sec`, `log.control`, espaçamento | **`make talk-test`: 30 asserções em loopback**; nenhuma mudança na ISO |
| **F2** | `talk/install.sh` (com `--dry-run`) + unit + integração no `build.sh` (etapa 2.5) + flags `--chat-*` (inclui `--chat-peers-file`/`--chat-keydir`) + `verify-iso.sh` | ISO dry-run/yaml; duas VMs (Bloco R) |
| **F3** | `ai-talk agent` (ponte com `llama-server`) + métricas/observabilidade | teste com fake + teste de injeção; opcional |
| **F4** (só se precisar) | **salas/tópicos** (`room` no envelope) e/ou **relay/hub** | bancada de 15 nós (§13.5); decidido por medição, não por vontade |

**Como rodar a F1:**

```bash
make talk-test                        # 30 asserções, sem rede externa, sem root
bash tests/test-ai-talk.sh -v         # com o nome de cada asserção
```

> ⚠️ A F1 prova a **semântica** (desiste no tempo certo, respeita a fila, isenta
> o `hello`), **não** a latência de rede: o loopback é mais rápido que qualquer
> LAN. p50/p99 reais exigem duas VMs (Bloco R) — e o teto de 15 exige a bancada
> de §13.5.

**Ordem recomendada:** F0 → (P0/P1 do `DECISIONS.md`) → F1 → F2 → F3. O chat
não deve competir com a remoção do Debian nem com a identidade por papel; ele
é a última das três mudanças.

> **Por que salas e relay ficam em F4:** a malha completa com `to:"*"` já
> responde “avisar todo mundo” — que é o pedido real de uma frota de até 15
> máquinas. Sala e hub adicionam componentes (e, no caso do hub, um ponto único
> de falha) sem resolver um problema **medido**. Fazer F4 sem a bancada de
> §13.5 seria otimização por intuição.

## 15. Alternativas consideradas

| Alternativa | Por que não (v1) |
|-------------|------------------|
| `talk`/`talkd` (netkit) | Obsoleto, UDP, sem auth/cripto, interativo, sem log. |
| `nc`/`socat` + script | Sem framing/ack/HMAC robustos; `socat` não é dependência garantida. |
| SSH + `wall`/`write` | Exige sessão/keys; `wall` é local; não é simétrico. |
| Matrix | Servidor, contas, banco, Federação — peso absurdo para 2 nós. |
| MQTT (mosquitto) | Broker central + pacote extra; QoS resolve problemas que não temos. |
| IRC | Servidor central, protocolo antigo, sem HMAC nativo. |
| Redis pub/sub | Serviço extra, sem persistência por padrão, auth simples. |
| HTTP webhook | Mais overhead e precisa de servidor HTTP; JSON lines é mais direto. |
| mDNS + TCP | Descoberta é conveniente, mas aumenta a superfície; peers estáticos bastam. |
| **Relay/hub central** | Reduz conexões (15 em vez de 105), mas cria **ponto único de falha** e um nó com N× o tráfego. Na malha completa, os **15 nós do teto** cabem com folga (§5.2); o hub é **obrigatório acima de 15** ou em múltiplas sub-redes. |
| **Gossip (estilo Serf/memberlist)** | Descoberta e disseminação elegantes, mas exigem protocolo próprio (SWIM), estado e uma biblioteca — fora do “stdlib, sem dependência”. |
| **Kafka/NATS** | Broker, persistência e operação desproporcionais para mensagens efêmeras de frota. |
| **Uma chave única para todos** | Em 15 nós, qualquer nó assina como outro. Chave por nó resolve com HMAC (sem PKI) — ADR-005. |

## 16. Perguntas em aberto (decidir na F1/F2)

> ✅ **Decididas em 2026-10-20 (sessão #40):** o **delay entre mensagens** é o
> intervalo mínimo entre `msg` do mesmo par (**50 ms / 20 msg/s**), com fila
> FIFO de **256** e **exit 5** no overflow; a meta de latência é **p99 ≤ 10 ms**
> (LAN cabeada); o log usa **`fsync` por mensagem**; e a frota suporta **~30
> nós em malha completa — **teto de 15** — com **chave por nó**,
> `dedupe_window=8192` e `max_out_per_sec=120`. Ver §5.2, §6.7, §6.8 e
> ADR-004/ADR-005.

1. **Habilitar por padrão?** Recomendação: instalar **desabilitado** quando não
   houver chave; habilitar só com `--chat-key-file` (fail closed).
2. **Rotação de chave:** procedimento coordenado (parar, trocar, subir) ou
   duas chaves ativas por janela? Com **chave por nó** (ADR-005), revogar um nó
   é trocar **uma** chave — o procedimento fica local.
3. **Canais/salas:** ✅ decidido — **só `to:"*"` na v1** (responde “avisar todo
   mundo”); `room` fica para F4, sem quebrar o envelope.
4. **TLS:** v2, se o modelo de ameaça mudar (LAN compartilhada com terceiros).
5. **Broadcast:** `--require-all` deve ser o padrão? Recomendação: não; o
   padrão é “melhor esforço com relatório”.
6. **Retenção:** 5 × 10 MB é suficiente? Ajustar após medir uso real.
7. **Ponte com o modelo:** `ai-talk agent` deve ser um processo separado ou
   um modo do daemon? Recomendação: processo separado (`ai-talk-agent`), para
   que o chat continue funcionando se o modelo cair.
8. **`min_interval_ms` = 50 ms é o número certo?** É o default; se o uso real
   (ex.: streaming de progresso de build) precisar de mais, é o único knob a
   mudar. Medir no Bloco R antes de mexer.
9. **`fsync` em disco não-NVMe:** o `fsync: "always"` pode estourar a meta em
   HDD. Se isso acontecer, usar `"interval"` **explicitamente** e registrar no
   `status` qual modo está ativo — não trocar o default em silêncio.

## 17. Referências internas

- [`docs/DECISIONS.md`](DECISIONS.md) — ADR-003 (desenho), ADR-004
  (latência/durabilidade) e ADR-005 (teto de 15 nós).
- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — onde o `talk/` se encaixa.
- [`docs/ISO.md`](ISO.md) — como a mídia leva o `talk/` e a chave.
- [`roles/README.md`](../roles/README.md) — fronteira papel × frota.
- [`AGENTS.md`](../AGENTS.md) — Regra 18 (invariantes do `ai-talk`).
