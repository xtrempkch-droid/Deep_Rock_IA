# DECISIONS — Registros de decisão (ADRs) do ai-cpu-os

> **Última atualização:** 2026-10-20 (sessão #40)
>
> **Documento vivo.** Uma decisão que muda contrato, arquitetura ou a
> experiência de instalação entra aqui **antes** de virar código. O objetivo é
> que uma sessão futura não precise redescobrir o porquê — e não reabra uma
> decisão já firmada por engano.
>
> **Nesta sessão:** ADR-004 (latência/espaçamento/durabilidade do `ai-talk`) e
> ADR-005 (**teto de 15 nós** em malha completa).
>
> **Fonte de verdade do estado:** [`docs/STATE.md`](STATE.md).
> **Continuidade:** [`docs/JOURNAL.md`](JOURNAL.md).
> **Regras:** [`AGENTS.md`](../AGENTS.md).

---

## Índice

| ADR | Título | Status | Código |
|-----|--------|--------|--------|
| [ADR-001](#adr-001--uma-única-base-de-iso-ubuntu-server) | Uma única base de ISO: Ubuntu Server | ✅ **Implementada** | `iso/preseed/` apagado; scripts em `iso/common/`; `--distro debian` → exit 2; guardas no CI |
| [ADR-002](#adr-002--identidade-do-sistema-derivada-do-papel) | Identidade do sistema derivada do papel | ✅ Aceita | **Não implementada** |
| [ADR-003](#adr-003--chat-de-frota-ai-talk) | Chat de frota `ai-talk` | ✅ **F1 implementada** | `talk/ai_talk.py` + `make talk-test`; F2/F3 pendentes — ver [`docs/CHAT.md`](CHAT.md) |
| [ADR-004](#adr-004--latência-espaçamento-e-durabilidade-do-ai-talk) | Latência, espaçamento e durabilidade do `ai-talk` | ✅ **F1 implementada** | `CHAT.md` §6.7/§6.8 + 30 asserções em loopback |
| [ADR-005](#adr-005--teto-de-15-nós-em-malha-completa) | Teto de **15 nós** em malha completa | ✅ **F1 implementada** (teto validado por teste; falta a bancada) | `CHAT.md` §5.2 |

Status possíveis: **Proposta** · **Aceita** · **Implementada** · **Substituída**
· **Rejeitada**.

---

## ADR-001 — Uma única base de ISO: Ubuntu Server

- **Data:** 2026-10-20
- **Status:** ✅ **IMPLEMENTADA** (sessão #42, 2026-10-20). O código Debian foi
  removido e o CI tem guardas provados contra a volta dele. A descrição abaixo
  fica como registro da decisão; ver `docs/STATE.md` § 3.9 para o que foi
  executado.
- **Decisor:** dono do projeto (pedido de 2026-10-20: *“esse projeto está
  ficando complicado demais com 2 imagens de ISO; vamos ficar só com o
  Ubuntu”*).

### Contexto

O `iso/build-iso.sh` mantém **dois caminhos de instalação completos**:

- **Ubuntu Server** (`--distro ubuntu`, padrão): Subiquity/autoinstall,
  `autoinstall.yaml` na raiz, remontagem por `xorriso -indev/-outdev -map`.
- **Debian** (`--distro debian`, legado): debian-installer/preseed, initrd
  com `/preseed.cfg`, `isolinux`, `mtools`/`efi.img`, `apt-setup/local0/*` e
  uma cadeia de boot diferente.

Os dois caminhos têm templates, ramos de código, testes, dependências e
documentação próprios. O caminho Debian exigiu **10 travas mudas** na sessão
#35 (nenhuma dava mensagem de erro; o sintoma era “a VM fica parada”) e
continua sendo o único a usar `mtools`, `isolinux` e `md5sum.txt` regenerado.
Manter os dois **não** paga o custo: o sistema de referência do projeto é
Ubuntu Server e o Debian já é exercitado como **hospedeiro das mods**, não
como base de ISO.

### Decisão

1. A **única base suportada da ISO** passa a ser **Ubuntu Server**
   (autoinstall/Subiquity).
2. O caminho **Debian/preseed está DEPRECADO** a partir de 2026-10-20. Ele
   continua funcionando temporariamente (para não quebrar uma ISO já em uso),
   mas **não recebe feature, correção de conveniência nem teste novo**.
3. A remoção do código Debian é uma tarefa **P0** da próxima fase. Até lá,
   `--distro debian` emite um aviso explícito e aponta para este ADR.
4. **O que NÃO muda:** `build.sh`, `mods/`, `families/` e `roles/` continuam
   aceitando Debian 12+ como **sistema hospedeiro**. A decisão é sobre a
   **base da ISO**, não sobre o runtime das mods.

### Consequências

**Positivas**

- Uma única cadeia de boot, um único conjunto de templates e um único
  instalador para manter.
- Menos dependências de build (`mtools`, `isolinux`, `isohybrid` deixam de ser
  necessários).
- `verify-iso.sh`, `test-vm.sh`, `Makefile`, `webui/` e CI ficam menores e com
  menos ramos.
- Menos tempo de CI e menos documentação duplicada.
- O modo air-gapped fica com um caminho único para provar (fonte + modelo +
  repositório local na mídia).

**Negativas / custo**

- Quem precisa de uma ISO com base Debian perde o caminho automatizado; a
  alternativa é instalar Debian manualmente e rodar `build.sh` (o runtime
  continua suportado).
- A remoção toca muitos arquivos de uma vez; exige `make validate` e, se
  possível, uma nova geração + boot de ISO Ubuntu antes do merge.

### Plano de remoção (P0) — ✅ EXECUTADO na sessão #42

Ordem que foi seguida em uma sessão dedicada (o "não fazer pela metade" valeu:
as 10 etapas abaixo foram feitas juntas):

1. **Sinalizar** (feito nesta sessão): aviso em `iso/build-iso.sh`, help e
   documentação; este ADR.
2. **Mover o que é compartilhado** de `iso/preseed/` para um diretório comum
   (`iso/common/` ou `iso/autoinstall/`):
   - `late-command.sh` (usado pelos dois instaladores);
   - `firstboot.sh`;
   - `ai-cpu-os-firstboot.service`;
   - o template de netplan, se ainda estiver em `preseed/`.
3. **Remover do `iso/build-iso.sh`:** o ramo `debian`, o download/validação da
   netinst, a injeção no initrd, `mkisofs`/`isolinux`/`mtools`, o tratamento de
   `--mirror-host` exclusivo do Debian e a preseed.
4. **Aceitar somente `ubuntu`** em `--distro` (ou remover a flag, mantendo um
   alias que explique a mudança). `debian` deve falhar com **exit 2** e uma
   mensagem que aponte este ADR — não pode cair num ramo morto.
5. **Limpar `iso/verify-iso.sh`** dos ramos `debian`/preseed, mantendo o
   verificador distro-aware apenas enquanto a remoção não termina.
6. **Atualizar `Makefile`:** `iso-dry-run-both` deixa de fazer sentido; o
   `validate` passa a rodar só o dry-run Ubuntu. Remover `mtools` das listas
   de dependências.
7. **Atualizar o CI:** `.github/workflows/iso.yml` (input `distro` deixa de
   oferecer Debian), `.github/workflows/validate.yml` (dry-run e guardas) e
   `docs/CI.md`.
8. **Atualizar a `webui/`:** `DISTROS = ("ubuntu",)` e remover o seletor
   Debian da página.
9. **Atualizar os testes:** remover/renomear a metade Debian de
   `tests/test-verify-iso-repo.sh`, ajustar `tests/test-ci-guards.sh`,
   `tests/test-iso-disk.sh` e `tests/test-iso-selection.sh` se houver casos
   Debian.
10. **Atualizar a documentação:** `docs/ISO.md`, `README.md`,
    `README.technical.md`, `docs/TUTORIAL.md`, `docs/VALIDATION.md`,
    `docs/TROUBLESHOOTING.md`, `docs/IMPLANTAR-EM-OUTRO-PC.md`,
    `docs/ARCHITECTURE.md`, `docs/STATE.md`, `docs/ROADMAP.md`,
    `docs/JOURNAL.md` e `AGENTS.md`.
11. **Provar:** `make validate`, `make iso-dry-run`, `make iso-yaml`,
    `make iso-verify-test`; se houver ambiente, gerar uma ISO Ubuntu e rodar
    `iso/test-vm.sh` (uma ISO Ubuntu já foi bootada em VM e o fluxo já foi
    provado; a remoção não pode regredir isso).

### Critérios de aceite

- [ ] `grep` por `--distro debian` não encontra **caminho funcional** (só
      histórico em docs/JOURNAL).
- [ ] `bash iso/build-iso.sh --distro debian --dry-run` falha com mensagem
      clara (exit 2), em vez de seguir por um ramo morto.
- [ ] `make validate` verde (lint, docs, famílias, AVX-512, ISO, rede, UI,
      guardas, dry-run).
- [ ] `make iso-yaml` e `make iso-dry-run` verdes.
- [ ] `docs/ISO.md` lista **uma** base suportada.
- [ ] `iso.yml` não oferece mais `debian` e `docs/CI.md` reflete isso.
- [ ] `webui/` não oferece mais `debian`.
- [ ] Nenhum documento trata Debian/preseed como caminho recomendado.
- [ ] Se possível: ISO Ubuntu gerada + `verify-iso.sh` + `test-vm.sh`.

### O que NÃO foi decidido aqui

- Remover o suporte a Debian **como hospedeiro** de `build.sh`/`mods/` — isso
  **não** está em discussão.
- Trocar a base da ISO para outra distro (ex.: Fedora) — fora de escopo.
- Uma ISO única que instale “qualquer” distro — explicitamente rejeitado por
  complexidade.

### Mapa de impacto (arquivos que a remoção toca)

| Área | Arquivos | O que muda |
|------|----------|------------|
| Gerador | `iso/build-iso.sh` | remove ramo Debian, preseed, netinst, `mkisofs`, `mtools`; mantém só Ubuntu |
| Verificador | `iso/verify-iso.sh` | remove checagens preseed/Debian; mantém `ubuntu|auto` |
| Templates | `iso/preseed/*` → `iso/common/*` | move `late-command.sh`, `firstboot.sh` e o unit; apaga preseed |
| Teste de VM | `iso/test-vm.sh` | remove ou isola ramos Debian (conferir) |
| Build local | `Makefile` | `iso-dry-run-both` → `iso-dry-run`; remove `mtools` |
| CI | `.github/workflows/iso.yml`, `.github/workflows/validate.yml`, `docs/CI.md` | remove input/guardas Debian |
| UI | `webui/server.py`, `webui/index.html` | `DISTROS = ("ubuntu",)` |
| Testes | `tests/test-verify-iso-repo.sh`, `tests/test-ci-guards.sh`, outros | remove casos Debian |
| Docs | `docs/ISO.md` e demais docs listados acima | Ubuntu como única base |

---

## ADR-002 — Identidade do sistema derivada do papel

- **Data:** 2026-10-20
- **Status:** ✅ **Aceita**; **não implementada**.
- **Decisor:** dono do projeto (*“o usuário será definido pela função
  (builder ou inference)”*).

### Contexto

Hoje o `iso/build-iso.sh` grava `--role auto|inference|builder` na ISO, mas o
usuário administrativo tem um padrão fixo: `ai-cpu-os` (e o hostname deriva
dele). As duas máquinas de referência têm funções diferentes, e a identidade
não diz nada sobre isso — quem entra por SSH ou lê um log não sabe se está no
servidor de inferência ou na máquina de build.

O papel já é **decidido na geração da ISO** (não no primeiro boot) quando
`--role` é concreto; portanto, é possível derivar a identidade sem renomear
usuário depois da instalação.

### Decisão

1. **Mapeamento padrão:**

   | `--role` | Usuário padrão | Hostname padrão |
   |----------|----------------|-----------------|
   | `inference` | `ai-inference` | `ai-inference` |
   | `builder` | `ai-builder` | `ai-builder` |
   | `auto` | `ai-cpu-os` (compatibilidade) | `ai-cpu-os` |

2. **Precedência:**
   1. `--username` explícito vence o mapeamento.
   2. Se `--username` não foi passado, o papel concreto define o usuário.
   3. `--hostname` explícito vence o padrão.
   4. Sem `--hostname`, o hostname é o usuário (comportamento atual).
   5. `--role auto` mantém `ai-cpu-os` e **avisa** que a identidade não será
      derivada — porque o papel só é conhecido no primeiro boot.
3. **Nada de criar dois usuários** (`inference` e `builder`) e desabilitar um
   depois. Isso aumenta a superfície de ataque, confunde o `sudoers`/`known_hosts`
   e não resolve nada.
4. **O papel é uma escolha de função, não uma promessa de hardware.** Uma ISO
   `--role inference` aplica o papel `inference` no primeiro boot mesmo que a
   CPU sugira outra coisa; o usuário ainda pode rodar `build.sh --role ...`
   manualmente. A identidade segue a **função**, não o modelo de CPU.
5. **Múltiplos nós do mesmo papel:** usar `--hostname` (ex.:
   `ai-inference-1`, `ai-inference-2`). O usuário pode continuar
   `ai-inference`; o hostname diferencia. Um `--node` dedicado fica como
   possível evolução, não como requisito.

### Consequências

- Novas ISOs passam a ter identidade legível e coerente com a função; ISOs
  antigas continuam com `ai-cpu-os`.
- Exemplos de SSH, `known_hosts`, documentação, logs e o nó do `ai-talk`
  (ADR-003) passam a usar `ai-inference`/`ai-builder`.
- `--role auto` continua existindo (não quebra automação), mas fica explícito
  que ele **não** dá identidade por papel.
- O `autoinstall.yaml` já é templatizado (`@@USERNAME@@`/`@@HOSTNAME@@`), então
  a mudança é concentrada no `build-iso.sh` + validação + testes + docs.

### Plano de implementação (P1)

1. Em `iso/build-iso.sh`, marcar se `--username` foi passado
   (`USERNAME_EXPLICIT=1`). Hoje o valor já nasce preenchido, então a
   distinção precisa ser explícita.
2. Criar uma função única de identidade (ex.: `resolve_identity()`), chamada
   **depois** da validação de `--role` e **antes** do cálculo do hostname:
   - `inference` → `ai-inference`
   - `builder` → `ai-builder`
   - `auto` → `ai-cpu-os` + `log_warn`
   - se `USERNAME_EXPLICIT=1`, não sobrescrever.
3. Definir `USER_FULLNAME` de forma coerente (ex.: `ai-inference` ou
   `ai-cpu-os (inference)`); manter simples e documentado.
4. Emitir no `--dry-run` uma linha legível/máquina-testável, por exemplo:
   `identidade: usuario=ai-inference hostname=ai-inference papel=inference`.
5. Atualizar `iso/verify-iso.sh` para conferir a coerência
   `identity.username` × papel (quando o papel for concreto) e o `.iso-config`.
6. Atualizar a `webui/`: ao escolher o papel, sugerir o usuário/hostname
   correspondentes **sem** impedir que o usuário digite outro.
7. Novo teste offline `tests/test-role-identity.sh` + alvo `make identity-test`
   + entrada no `validate`.
8. Atualizar docs (`ISO.md`, `README.md`, `README.technical.md`,
   `TUTORIAL.md`, `IMPLANTAR-EM-OUTRO-PC.md`, `VALIDATION.md`, `STATE.md`,
   `ROADMAP.md`, `JOURNAL.md`, `AGENTS.md`).

### Critérios de aceite

- [ ] `--role inference` + sem `--username` → `identity.username:
      ai-inference`, hostname `ai-inference`.
- [ ] `--role builder` + sem `--username` → `ai-builder` / `ai-builder`.
- [ ] `--role auto` + sem `--username` → `ai-cpu-os` + aviso explícito.
- [ ] `--username custom` vence qualquer papel.
- [ ] `--hostname custom` vence o padrão.
- [ ] `--role inference --username custom` → `custom` / `custom`.
- [ ] O `autoinstall.yaml` gerado e o `.iso-config` refletem a identidade.
- [ ] `--dry-run` imprime a identidade escolhida (testável sem gerar ISO).
- [ ] `make validate` verde e `verify-iso.sh` aprova a ISO de teste.

### O que NÃO foi decidido aqui

- Renomear usuário **depois** da instalação (rejeitado: mexe em home,
  `sudoers`, chaves e serviços).
- Criar usuários por **modelo de CPU** (ex.: `xeon`, `ryzen`) — o papel é a
  função, não o hardware.
- Um usuário por nó (`ai-inference-1`) — o hostname já resolve; usuario
  genérico por papel é mais simples.

---

## ADR-003 — Chat de frota `ai-talk`

- **Data:** 2026-10-20
- **Status:** ✅ **Aceita** (decisão de arquitetura); **não implementada**.
- **Decisor:** dono do projeto (*“precisamos de um chat pela rede para que as
  IAs possam se comunicar entre si de forma rápida (pensei no talk ou algo do
  tipo)”*).
- **Desenho completo:** [`docs/CHAT.md`](CHAT.md).

### Contexto

As máquinas `inference` e `builder` já se falam por SSH e (futuramente) por
HTTP no `llama-server`. Falta um canal **simétrico, rápido e simples** para
que os processos/agentes de uma máquina enviem mensagens curtas à outra —
status de build, resultado de um benchmark, “terminei”, “preciso de X” — sem
depender de uma sessão SSH interativa.

O `talk` do netkit (o comando Unix clássico) é a inspiração de UX, mas **não**
é a solução: é obsoleto, usa UDP 517/518 e `talkd`, não tem autenticação nem
criptografia, e não é adequado para mensagens máquina-a-máquina.

### Decisão

1. Criar o componente **`ai-talk`** (diretório `talk/` no projeto, binário
   `ai-talk`, unit `ai-talk.service`).
2. **Transporte:** TCP na LAN, um objeto JSON por linha, porta padrão
   **7331** (configurável), com **HMAC-SHA256** sobre uma chave de frota.
3. **Sem dependências novas:** implementação em **Python 3 da biblioteca
   padrão** (o alvo Ubuntu já tem Python; o precedente é o `shell-ia.py`).
   Nada de `pip`, Matrix, MQTT, IRC ou `talkd`.
4. **Sem execução remota:** mensagem recebida é **dado**, nunca comando. O
   `ai-talk` não executa shell; a ponte opcional com o modelo (fase 3) também
   não executa tool calls vindas da rede.
5. **Frota pequena e estática:** peers configurados explicitamente
   (`nome → IP`), sem descoberta mDNS/DHT. O **teto é de 15 nós** em malha
   completa (ADR-005); acima disso, relay/hub.
6. **Air-gapped:** o código vai na ISO junto com o projeto; nenhum passo de
   instalação/primeiro boot baixa nada. A chave e os peers são decididos na
   geração da ISO (ou configurados localmente depois).
7. **Faseado:** primeiro o transporte + CLI + testes (loopback, sem ISO);
   depois a integração com a ISO e o teste de duas VMs; por último a ponte com
   o `llama-server`. Ver `docs/CHAT.md` § 14.

### Consequências

- Um canal novo na frota, com um serviço a manter e um contrato de protocolo
  versionado.
- Uma chave compartilhada precisa ser gerada e distribuída com cuidado; se ela
  vazar, o canal permite spoofing **na LAN** (o modelo de ameaça é LAN
  confiável, não internet).
- O `ai-talk` vira o lugar natural para observabilidade da frota (status,
  mensagens, resultados), mas **não** substitui SSH, `systemd`/journal nem o
  `llama-server`.
- A identidade do nó segue o ADR-002 (`ai-inference`/`ai-builder`), o que
  torna as mensagens legíveis.

### Critérios de aceite (fase 1) — ✅ **cumpridos na sessão #41**

- [x] Dois processos em loopback trocam mensagens, recebem `ack` e ignoram
      duplicatas.
- [x] Assinatura inválida, frame grande demais e peer desconhecido são
      rejeitados com erro claro.
- [x] Peer offline retorna erro (exit code documentado), sem travar.
- [x] **Espaçamento e fila do ADR-004** obedecidos (50 ms por par, fila 256,
      exit 5 no overflow) — provado em loopback na sessão #41.
- [x] `ai-talk --help`, `status`, `peers`, `send`, `listen`, `tail` funcionam.
- [x] Teste offline `tests/test-ai-talk.sh` cobre o contrato e roda no CI.
- [x] Nenhum download, nenhuma dependência Python externa.
- [x] `make validate` verde.

### O que NÃO foi decidido aqui

- TLS no transporte (v1 é LAN confiável + HMAC; TLS pode ser v2).
- Salas/canais (v1 tem direto + broadcast `*`).
- Descoberta automática de peers (mDNS) — rejeitada para v1.
- Ponte automática com o modelo (fase 3, opcional e explícita).
- Substituir SSH, Gitea ou o registry.

---

## ADR-004 — Latência, espaçamento e durabilidade do `ai-talk`

- **Data:** 2026-10-20 (sessão #40)
- **Status:** ✅ **Aceita** (contrato); **não implementada**.
- **Refina:** ADR-003. Contrato em [`docs/CHAT.md`](CHAT.md) §6.7 e §6.8.
- **Decisor:** dono do projeto (pergunta *“como fica o delay entre as
  mensagens?”*).

### Contexto

O ADR-003 deixou três tempos implícitos e um deles contraditório:

1. **Não havia definição de “delay”.** Conviviam quatro tempos diferentes:
   entrega (mensagem → ack), espaçamento entre envios, tempo até desistir de um
   peer morto e atraso de exibição (`listen`/`tail`). Cada um tem dono e
   orçamento próprios.
2. **O pior caso estava errado.** O §6.4 dizia “3 tentativas” e o §8 resumia
   “até ~6 s”; a conta correta é `2 s + 1 s + 2 s + 2 s + 2 s = 9 s`.
3. **Faltava `connect_timeout`** — com IP obsoleto/ARP pendurado, o `connect`
   pode levar ~2 min e o timeout de ack nunca chega a valer.
4. **Nagle/delayed ACK** pode injetar até ~40 ms numa mensagem pequena, o que
   sozinho estoura qualquer meta razoável.
5. **Durabilidade não estava decidida:** `fsync` por mensagem custa latência,
   mas sem ele um `ack` pode significar apenas “está no buffer”.

### Decisão

1. **“Delay entre mensagens” = intervalo mínimo entre dois `msg` do mesmo nó
   para o mesmo peer.** Default **50 ms** (= 20 msg/s), por par; `ack` e
   `hello` **isentos** do throttle; escopo por par (não global).
2. **Fila FIFO de 256 por peer.** Overflow → **exit 5 imediato**, nunca
   descarte silencioso. `send_timeout_ms = 15 s` cobre fila + tentativas.
3. **Meta de latência: p99 ≤ 10 ms** em LAN cabeada (típico 0,5–2,5 ms), com
   `TCP_NODELAY` **sempre** ligado e conexão persistente por peer.
4. **Falha:** `ECONNREFUSED` → fail fast (exit 3 em ~ms); sem ack → **3
   tentativas totais**, `ack_timeout_ms = 2 s`, backoff 1 s/2 s →
   **9 s** até desistir (exit 3).
5. **Durabilidade:** **`fsync` por mensagem**, depois do append e **antes** do
   `ack`. Falha de gravação ⇒ **sem ack** (exit 3 no cliente). Escape explícito
   `fsync: "interval"` (100 ms) para disco lento, nunca default.
6. **Exibição:** `listen` é push (~1 ms); `tail -f` usa `tail_poll_ms = 250`
   e não é o caminho de entrega.
7. **Todos os tempos num só bloco `timing` do `config.json`** — nada de número
   escondido no código.

### Consequências

**Positivas**

- Um único lugar para responder “quanto tempo leva” e “por que demorou”.
- O usuário vê **exit 5** (limite de taxa) e **exit 3** (peer/mudo ou gravação)
  como causas distintas — não é mais “deu erro”.
- `ack` passa a significar “gravado no disco”, o que torna o log auditável.
- `TCP_NODELAY` e conexão persistente removem fontes de latência acidental.

**Negativas / custo**

- `fsync` por mensagem adiciona 0,1–1 ms em NVMe e mais em disco lento; a meta
  de 10 ms pode não valer em HDD (escape documentado).
- Uma rajada de 256 mensagens leva ~12,8 s; quem precisa de mais pode mudar
  `min_interval_ms` (o resto do protocolo não depende do valor).
- Sem fila persistente, um peer offline continua exigindo retry do chamador.

### Critérios de aceite (F1, offline)

- [ ] 3 `msg` para o mesmo peer levam ≥ 100 ms (2 × 50 ms).
- [ ] `ack`/`hello` **não** são atrasados pelo throttle.
- [ ] `msg` para o peer A não atrasa `msg` para o peer B.
- [ ] `queue_max=2` com 4 mensagens: 2 saem, as outras recebem **exit 5**.
- [ ] Ordem FIFO dentro do par, inclusive após retry.
- [ ] `ECONNREFUSED` → exit 3 em **< 1 s**.
- [ ] Peer mudo → desiste em `max_attempts × ack_timeout + Σ backoff`.
- [ ] `--no-wait` retorna antes do ack, mas fila cheia continua exit 5.
- [ ] `listen` mostra a mensagem em **< 100 ms** em loopback.
- [ ] `status` expõe `queue_depth` e o modo de `fsync` ativo.

### Critérios de aceite (F2, duas VMs)

- [ ] p50/p99 de `send` medidos **com `fsync` ligado** e registrados no Bloco R.
- [ ] 10 mensagens seguidas levam ~450 ms (9 × 50 ms), não 0 ms.
- [ ] Broadcast não soma a espera de todos os peers.

### O que NÃO foi decidido aqui

- SLA: não existe. Os números são orçamento de projeto; o teste de CI valida
  **semântica**, não wall-clock.
- TLS (muda o orçamento do handshake; fica para v2).
- Fila persistente entre reinícios (fora da v1 por decisão do ADR-003).
- Tuning de `SO_SNDBUF`/`SO_RCVBUF` e de scheduler — medir antes de mexer.

---

## ADR-005 — Teto de 15 nós em malha completa

- **Data:** 2026-10-20 (sessão #40)
- **Status:** ✅ **Aceita** (contrato); **não implementada**.
- **Refina:** ADR-003 (que falava em “2–8 nós”).
- **Contrato em:** [`docs/CHAT.md`](CHAT.md) §5.2, §6.4, §7, §13.5.
- **Decisor:** dono do projeto (*“imagino umas 30 máquinas conversando entre
  si”* → depois *“mantenha um teto de 15 máquinas, assim fica confortável”*).

### Contexto

O ADR-003 foi escrito para **2–8 nós** e assumia implicitamente:

- uma **chave única** de frota (aceitável em 2 máquinas);
- janela de deduplicação de **1024 IDs** (suficiente em 2 nós);
- log com `ack`/`hello`/`ping` misturados às mensagens;
- configuração por flags repetidas (`--chat-peer`).

O dono perguntou se **~30 máquinas** poderiam entrar na mesma conversa e, em
seguida, fixou o **teto em 15**. Com 15 nós em malha completa, três dessas
premissas deixam de valer — e o modo de falha é **silencioso** (duplicata no
log, impersonação aceita, arquivo de log girando a cada poucos minutos).

### Decisão

1. **Teto oficial: 15 nós** em malha completa (`full mesh`, 14 conexões
   persistentes por nó, 105 no cluster). Acima de 15, **relay/hub é
   obrigatório** — não é otimização.
2. **Chave por nó** (`peers[nome].key_file`), com a chave global como fallback
   para frotas pequenas. O receptor verifica com a chave **do `from`**, então um
   nó não assina como outro. Revogar um nó = trocar **uma** chave.
3. **`dedupe_window = 8.192`** (era 1024): precisa cobrir o retry de 9 s
   (§6.4) na taxa de entrada do teto (280 msg/s → ~29 s de cobertura).
4. **`max_out_per_sec = 120`** por nó, além dos 20/s por par: um broadcast
   sustentado acima de ~8,5 msg/s para os 14 peers bate no teto global com
   **exit 5**, em vez de saturar a frota.
5. **`log.control = false`**: `ack`/`hello`/`ping` não vão para o
   `messages.jsonl`; só `msg` e erros. Rotação em **32 MB × keep 5** (~160 MB).
6. **Configuração por arquivo**, não por flags: `--chat-peers-file`
   (`nome=ip` por linha) + `--chat-keydir` (uma chave por nó).
7. **Broadcast** com fan-out paralelo, concorrência 8 → `ceil(14/8) = 2 RTTs`,
   não 14. Reconexão com **jitter**.
8. **Salas/tópicos (`room`) ficam para F4:** `to:"*"` já responde “avisar todo
   mundo”, que é o pedido real. Sala não reduz tráfego em malha completa —
   reduz interesse (log/`listen`).

### Por que 15 e não 30

| Recurso | **15 nós** (280 msg/s/nó) | 30 nós (580 msg/s/nó) |
|---|---|---|
| Conexões por nó | 14 | 29 |
| `fsync` por mensagem (0,3 ms) | ~84 ms/s (**~8%** de 1 core) | ~174 ms/s (~17%) |
| Banda | ~106 KB/s (~0,85 Mbit/s) | ~220 KB/s (~1,8 Mbit/s) |
| Janela de dedupe necessária (9 s de retry) | **8.192** (≈29 s) | 16.384 (≈28 s) |
| Broadcast (concorrência 8) | **2 RTTs** | 4 RTTs |
| Log a 32 MB no limite | ~5 min por arquivo | ~2,5 min |

15 mantém o custo de `fsync` abaixo de 10% de um core e o log girando a cada
~5 min **no pior caso**, com uso típico de horas. 30 exigiria dobrar a janela,
o teto de saída e a retenção — e ainda deixaria menos margem. O dono escolheu
o conforto: **15**.

### Consequências

**Positivas**

- Um número **oficial** e testável; nada de “acho que aguenta”.
- Chave por nó remove impersonação sem introduzir PKI.
- Dedupe dimensionado pela taxa evita duplicata silenciosa em retry.
- Configuração por arquivo elimina 14 flags digitadas à mão.

**Negativas / custo**

- Uma chave por nó é mais trabalho de distribuição (o `--chat-keydir` e o
  `late-command.sh` resolvem; a chave **nunca** vai para o `.iso-config`).
- 15 é **cálculo**, não medição: se a bancada de §13.5 falhar, o teto cai (ou o
  relay entra) — não se “aumenta o teto” para salvar a tabela.
- Acima de 15, o projeto **precisa** de um componente novo (relay/hub), com
  ponto único de falha a ser tratado.

### Critérios de aceite (F1, offline)

- [x] `dedupe_window=8192` configurável e efetivo (retry não duplica).
- [x] Chave por nó: mensagem assinada com a chave de outro nó é rejeitada.
- [x] Sem `key_file` no peer, a chave global funciona (compatibilidade).
- [ ] `max_out_per_sec=120` gera **exit 5** ao ser atingido, sem derrubar o
      daemon. *(o limitador existe; o teste dedicado fica para a bancada)*
- [x] `log.control=false` não grava `ack`/`hello`/`ping`.
- [x] Parser aceita `peers` em forma string **e** objeto (`{addr,key_file}`).

### Critérios de aceite (F2/F4, bancada de 15)

- [ ] 15 daemons, 14 conexões cada (105 `ESTABLISHED`).
- [ ] Broadcast em ~2 RTTs.
- [ ] p99 de `send` ≤ 10 ms com 280 msg/s de fundo.
- [ ] RSS e `fd` estáveis ao longo de 10 min.
- [ ] Rotação de 32 MB confirmada com `log.control=false`.
- [ ] Documentado no Bloco R o número real medido.

### O que NÃO foi decidido aqui

- Implementar o relay/hub agora (F4, só se a bancada exigir ou se passar de 15).
- Salas/tópicos (F4).
- Autenticação por PKI/certificados (HMAC por nó basta na LAN).
- Descoberta automática de peers (rejeitada desde o ADR-003).

---

## Como adicionar uma decisão

1. Copie o formato de um ADR acima.
2. Numere em sequência (`ADR-004`, ...) e adicione ao índice.
3. Registre **contexto → decisão → consequências → plano → critérios de
   aceite**. Se não houver critério de aceite, a decisão ainda é uma ideia.
4. Atualize `docs/STATE.md` § 6 e `docs/ROADMAP.md`; registre a sessão no
   `docs/JOURNAL.md` (Regra 14 do `AGENTS.md`).
5. Se a decisão mudar uma regra, atualize o `AGENTS.md` na mesma sessão.
