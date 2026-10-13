# ai-cpu-os

**Um jeito de fazer seu computador rodar modelos de IA (LLMs) o mais rápido
possível — usando só o processador, sem placa de vídeo.**

> Se você tem uma máquina sem GPU (ou não quer depender dela) e quer rodar
> modelos como Qwen, Llama ou Mistral, este projeto ajusta o seu Linux para
> tirar o máximo do hardware que você já tem.

![status](https://img.shields.io/badge/status-alpha-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![shell](https://img.shields.io/badge/shell-bash%205.x-green)

[![validate](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/validate.yml/badge.svg)](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/validate.yml)
[![build-llama](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/build-llama.yml/badge.svg)](https://github.com/xtrempkch-droid/Deep_Rock_IA/actions/workflows/build-llama.yml)

---

## 🧭 Índice

1. [O que é isto, em uma frase](#1-o-que-é-isto-em-uma-frase)
2. [Isto serve para mim?](#2-isto-serve-para-mim)
3. [O que exatamente acontece com a minha máquina](#3-o-que-exatamente-acontece-com-a-minha-máquina)
4. [O que você precisa ter antes](#4-o-que-você-precisa-ter-antes)
5. [Instalação passo a passo](#5-instalação-passo-a-passo)
6. [Usando no dia a dia](#6-usando-no-dia-a-dia)
7. [Medindo o resultado (e entendendo o número)](#7-medindo-o-resultado-e-entendendo-o-número)
8. [Só quero uma melhoria, não o sistema todo](#8-só-quero-uma-melhoria-não-o-sistema-todo)
9. [Como desfazer](#9-como-desfazer)
10. [A ISO: instalar já pronto](#10-a-iso-instalar-já-pronto)
11. [Usar uma GPU (opcional)](#11-usar-uma-gpu-opcional)
12. [Problemas comuns](#12-problemas-comuns)
13. [Perguntas frequentes](#13-perguntas-frequentes)
14. [Onde está cada coisa](#14-onde-está-cada-coisa)
15. [Licença](#15-licença)

---

## 1. O que é isto, em uma frase

É um **conjunto de ajustes** que você aplica no seu Linux (Ubuntu Server ou
Debian) para que, ao rodar um modelo de IA no processador, ele responda mais
rápido **sem comprar hardware novo**.

E onde ele melhora? Em quatro coisas, explicadas sem jargão:

| O que é ajustado | Em linguagem simples |
|---|---|
| **Banda de memória** | Ao rodar IA em CPU, o que mais atrasa não é "fazer contas" — é **buscar os dados na memória**. O ajuste prioriza esse caminho. |
| **Latência** | Reservar páginas grandes de memória e evitar que o conteúdo saia para o disco faz o modelo carregar e responder sem "engasgos". |
| **Relógio do processador** | Por padrão, o Linux deixa o CPU "dormir" para economizar energia — e ele demora para acordar. Aqui ele fica sempre pronto. |
| **Sem surpresas** | Você pode simular tudo antes (`--dry-run`) e desfazer o que quiser. Nada é caixa-preta. |

### 🧠 A filosofia, em uma linha

> **"1% importa."** Nenhum ajuste aqui é um truque mágico de 2x. São dezenas de
> pequenos ganhos que, somados, mudam a experiência de uso.

---

## 2. Isto serve para mim?

Nem todo mundo precisa disso. Para não perder seu tempo:

| ✅ Faz sentido se você… | ❌ Não vai ajudar se você… |
|---|---|
| tem um **servidor/desktop sem GPU** e quer rodar LLMs nele | já roda os modelos numa **GPU** (aí o gargalo é outro) |
| quer tirar mais de uma máquina que **já tem** (não vai comprar nada) | espera que "10x mais rápido" aconteça — não acontece |
| se incomoda com **latência instável** (às vezes rápido, às vezes lento) | usa o modelo poucas vezes por dia e está satisfeito |
| tem **16 GB+ de RAM** e quer rodar modelos pequenos/médios | tem 8 GB e quer rodar modelos de 7B+ (não cabem) |
| quer um sistema **reprodutível** (mesmo setup em outra máquina) | precisa de algo "clicar e pronto, com interface gráfica" |

**Resumo honesto:** o ganho real aparece em máquinas **sem GPU** que rodam o
modelo **na própria CPU**, onde a memória é apertada e a latência incomoda.

---

## 3. O que exatamente acontece com a minha máquina

Antes de decidir, veja o que será mexido. **Nada aqui instala programas
desconhecidos ou manda seus dados para fora.**

| Mudança | Detalhe | Reversível? |
|---|---|---|
| **Ajustes de memória** (`sysctl`) | Um arquivo em `/etc/sysctl.d/` diz ao kernel para não usar swap com facilidade e manter cache | ✅ sim — apagar o arquivo |
| **Governador da CPU** | Um serviço systemd mantém o processador no máximo | ✅ sim — `mods/apply.sh revert governor` |
| **Páginas grandes de memória** | Ativa um recurso que reduz "idas e vindas" na memória | ✅ sim — `revert hugepages` |
| **Linha de boot (só se você aceitar)** | Adiciona um parâmetro para o CPU acordar rápido. **Exige reiniciar** | ✅ sim — o script faz backup do GRUB |
| **Compilar o llama.cpp** | Baixa e compila o programa que roda o modelo, ajustado ao **seu** processador | ✅ sim — é só apagar a pasta |
| **Serviço de IA** (opcional) | Um serviço systemd que sobe o modelo e responde em `localhost:8080` | ✅ sim — `systemctl disable ai-server` |

> 💡 **Antes de aplicar em uma máquina importante:** rode com `--dry-run` (não
> altera nada) e, se possível, teste numa máquina virtual primeiro. O projeto
> foi feito para você poder olhar antes de aceitar.

### Sobre energia e temperatura

O ajuste de CPU deixa o processador sempre no máximo. Isso significa
**mais consumo e mais calor**. Em servidor, normal. Em **notebook**, pense
duas vezes — e veja a seção 8 (você pode aplicar só parte dos ajustes).

---

## 4. O que você precisa ter antes

| Item | Requisito |
|---|---|
| **Sistema** | Ubuntu Server 22.04+ / 24.04+ (recomendado) ou Debian 12+ |
| **Acesso** | `root` ou `sudo` |
| **Internet** | Sim, na primeira vez (baixa pacotes e o llama.cpp) |
| **Disco** | ~10 GB livres (código + modelos pequenos) |
| **Memória** | 16 GB confortável para modelos até 7B; menos que isso, só modelos bem pequenos |
| **Kernel** | 5.1+ (Ubuntu 22.04 já vem com 5.15 — ok) |
| **Processador** | x86-64. Intel ou AMD, de qualquer geração (ver abaixo) |

### Meu processador é suportado?

Provavelmente sim. O projeto reconhece automaticamente o seu CPU e escolhe o
ajuste certo, por **família de geração**:

| Seu processador | O que o projeto usa |
|---|---|
| Intel Xeon E5 **v3** (Haswell-EP) | `haswell` |
| Intel Xeon E5 **v4** (Broadwell-EP) | `broadwell` |
| Intel Xeon Scalable **v5/v6** (tem AVX-512) | `skylake-avx512` *(só se você pedir)* |
| AMD Ryzen **1000 / 2000** | `znver1` |
| AMD Ryzen **3000 / 4000** | `znver2` |
| AMD Ryzen **5000 / 6000** | `znver3` |
| AMD Ryzen **7000 / 8000 / 9000** | `znver4` |
| **Qualquer outro** x86-64 | detecção automática no seu próprio CPU |

> Não precisa saber qual é a sua. O comando da seção 5 descobre sozinho e te
> mostra antes de aplicar qualquer coisa.

---

## 5. Instalação passo a passo

São 5 passos. Os comandos estão prontos para copiar e colar.

### Passo 1 — Baixar o projeto

```bash
git clone https://github.com/xtrempkch-droid/Deep_Rock_IA.git
cd Deep_Rock_IA
chmod +x build.sh detect-hardware.sh llama-build.sh
chmod +x mods/apply.sh mods/*/*.sh families/resolve.sh roles/*/*.sh tests/*.sh
```

### Passo 2 — Ver o que ele descobriu sobre a sua máquina

Este comando **não altera nada** — ele só olha e relata:

```bash
./detect-hardware.sh
```

Você vai ver algo assim (resumido — no Xeon de referência):

```text
== CPU ==
[i] Modelo:      Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
[i] Fabricante:  GenuineIntel
[i] Núcleos:     14 (por socket)
[i] Threads:     28 (total)

== Flags ISA ==
[i] AVX2:    SIM
[i] AVX-512: NÃO

== Memória ==
[i] Total:       16 GiB
[i] Canais:      quad

== GPU ==
[i] Nenhuma GPU de vídeo/computação encontrada.

== Resultado ==
[ok] Família de CPU: intel-broadwell
[ok] Papel sugerido: inference

== Recomendações de build (llama.cpp) ==
[i] March:     -march=broadwell -mtune=broadwell
[i] Caminho recomendado (portátil, usa a família):
[i]   sudo bash llama-build.sh --family intel-broadwell
```

**Pare e leia:** confirme que a CPU e a memória estão certos. Se aparecer um
aviso sobre **canais de memória** (ex.: "single channel"), leia — isso muda
muito o desempenho e geralmente é um pente no slot errado.

> 💡 Quer só a resposta curta?
> `./detect-hardware.sh --quiet` mostra `FAMILY=`, `ROLE=` e `GPU=`.

### Passo 3 — Simular (recomendado na primeira vez)

```bash
sudo ./build.sh --dry-run
```

Isso mostra **tudo** o que seria feito, sem fazer nada. Leia a lista com
calma. Se algo não fizer sentido para você, é aqui que você percebe.

### Passo 4 — Aplicar

```bash
sudo ./build.sh
```

Ele mostra o que vai fazer e **pergunta antes de continuar**. Ao final:

- aplica os ajustes de sistema;
- compila o llama.cpp ajustado ao seu CPU (**pode levar de 5 a 20 minutos**);
- instala o serviço de IA (se o papel for `inference`);
- roda uma verificação final.

**Alguma coisa pediu reinício?** Se ele avisou isso, reinicie — é o ajuste da
linha de boot, e só vale depois do reboot.

### Passo 5 — Testar

```bash
systemctl status ai-server --no-pager     # o serviço está rodando?
curl -s http://127.0.0.1:8080/health      # responde "ok"?
```

Ainda não tem um modelo baixado? Baixe um pequeno de exemplo:

```bash
sudo bash roles/inference/install.sh --auto-model --yes
sudo systemctl restart ai-server
```

Isso baixa o **Qwen2.5-Coder-1.5B** (~1,1 GB), pequeno de propósito: serve para
testar o caminho inteiro rápido.

> **Não quer o serviço de IA?** Use `--role builder` (máquina de compilar e
> hospedar registry/Gitea) ou leia a seção 8 para aplicar só melhorias pontuais.

---

## 6. Usando no dia a dia

Depois que está rodando, você usa o modelo de três formas.

### a) Pelo navegador ou por um cliente de API

O serviço responde em `http://127.0.0.1:8080` e é **compatível com a API da
OpenAI** — então funciona com qualquer ferramenta que aceite essa API:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Explique swap em uma frase."}]}'
```

> Por padrão ele só escuta em `127.0.0.1` (só a própria máquina). Para acessar
> de outra, veja `/etc/default/ai-server` e **pense na segurança** antes de
> abrir para a rede.

### b) Pela linha de comando (tirar dúvidas do sistema)

O projeto inclui um "shell de IA" que responde perguntas sobre a própria
máquina:

```bash
python3 roles/inference/shell-ia.py -p "quantas CPUs e quanta memória livre tem aqui?"
```

### c) Trocar o modelo

Coloque o arquivo `.gguf` em `/opt/models/` e aponte o serviço para ele:

```bash
sudo cp seu-modelo.gguf /opt/models/
sudo nano /etc/default/ai-server      # ajuste MODEL_PATH=...
sudo systemctl restart ai-server
```

### Ajustes finos que você provavelmente vai querer

Tudo no arquivo `/etc/default/ai-server`:

| Ajuste | Para que serve | Como escolher |
|---|---|---|
| `LLAMA_THREADS` | Quantos núcleos usar | Comece em **1 por núcleo físico** (não por thread). Meça e teste valores menores — às vezes menos é mais. |
| `LLAMA_CTX` | Tamanho do "contexto" (memória da conversa) | Contexto maior = mais RAM. Se faltar memória, reduza. |
| `MODEL_PATH` | Qual modelo carregar | Veja a seção 13 sobre tamanho do modelo |

---

## 7. Medindo o resultado (e entendendo o número)

Não confie em impressão. Meça.

```bash
# 1. ANTES de aplicar: rode o benchmark
cd /opt/llama.cpp
./build/bin/llama-bench -m /opt/models/seu-modelo.gguf -p 512 -n 128 -t 24

# 2. Aplique o ai-cpu-os (se ainda não aplicou)
# 3. Meça DE NOVO, com o mesmo comando, mesmo modelo, mesmo -t
```

### Como ler o resultado

O `llama-bench` mostra dois números, e eles significam coisas diferentes:

| Número | O que é | Importância |
|---|---|---|
| **pp512** (prompt processing) | Velocidade de **ler** o que você escreveu | Importa se você cola textos longos |
| **tg128** (token generation) | Velocidade de **escrever** a resposta | É o que você sente no uso normal |

**O ajuste daqui melhora os dois, mas o ganho é diferente em cada um.** Não se
surpreenda se o `tg128` subir menos que o `pp512` — é esperado: a geração de
token é o caminho mais limitado por memória, e é justamente onde o hardware
sem GPU é o teto.

### Regras para a medição valer

1. Mesmo modelo, mesma quantização, mesmo `-t`.
2. Nada mais rodando na máquina durante o teste.
3. Reinicie antes de medir, se mexeu em linha de boot.
4. Rode 2–3 vezes e use a média; descarte o primeiro (carrega o modelo).

> 📝 **Registre o resultado.** Se você preencher a seção "Métricas de
> performance" de [`docs/STATE.md`](docs/STATE.md), o número passa a valer para
> todo mundo — inclusive com "esse modelo, nessa máquina, deu isso".

---

## 8. Só quero uma melhoria, não o sistema todo

Faz total sentido. Cada melhoria é uma **"mod"**: aplicável sozinha e
reversível.

```bash
bash mods/apply.sh list          # o catálogo: o que faz, risco, se precisa reboot
bash mods/apply.sh info governor # detalhes de uma
sudo bash mods/apply.sh apply governor       # aplica só ela
sudo bash mods/apply.sh revert governor      # desfaz
```

As quatro disponíveis hoje:

| Mod | O que faz | Risco | Reiniciar? |
|---|---|---|---|
| `governor` | Mantém a CPU no máximo | médio | não |
| `hugepages` | Páginas grandes de memória | médio | **sim** |
| `kernel-tuning` | Ajustes de memória + acorda CPU rápido | médio | **sim** |
| `openblas-threads` | Evita que dois sistemas disputem seus núcleos | **baixo** | não |

Sugestão para começar: **`openblas-threads`** (baixo risco, sem reboot) e
depois **`governor`**. Meça entre uma e outra para saber o que cada coisa
contribuiu.

```bash
bash mods/apply.sh check         # os requisitos estão atendidos na sua máquina?
sudo bash mods/apply.sh apply --set system --dry-run   # ver o conjunto inteiro
```

---

## 9. Como desfazer

**Mod a mod:** cada uma tem o seu `revert` (seção 8) — ele volta o sistema ao
estado anterior (o script faz backup antes de editar arquivos de sistema).

**Desfazer tudo:**

```bash
# 1. Ajustes de sistema (volta ao padrão da sua distro)
for m in kernel-tuning hugepages governor openblas-threads; do
  sudo bash mods/apply.sh revert "$m"
done

# 2. Serviço de IA (se instalou)
sudo systemctl disable --now ai-server

# 3. O llama.cpp compilado e os modelos (⚠️ apaga modelos que você baixou)
sudo rm -rf /opt/llama.cpp
# sudo rm -rf /opt/models          # só se você não quer mais os modelos

# 4. O projeto
cd .. && rm -rf Deep_Rock_IA
```

> ⚠️ **A linha de boot** (C-states) exige reiniciar para o revert valer. O
> `revert` já cuida do arquivo do GRUB — mas o efeito só aparece depois de
> reiniciar.

---

## 10. A ISO: instalar já pronto

> 🎯 **Este é o objetivo final do projeto:** uma **ISO de instalação** que já
> traz tudo isso embutido — você dá boot, a instalação é automática e o sistema
> **nasce afinado**. Sem clonar, sem rodar script.

```bash
# Gerar a ISO (precisa de xorriso: sudo apt install -y xorriso curl)
bash iso/build-iso.sh --distro ubuntu --disk /dev/vda --dry-run   # simular
sudo bash iso/build-iso.sh --distro ubuntu --disk /dev/vda         # gerar

# Testar numa máquina virtual (SEMPRE antes de máquina real)
bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-*.iso --yes
```

**O modelo vai dentro da ISO.** Por padrão, gerar a ISO baixa o modelo sugerido
(~1,1 GB) na **sua máquina** e o embute na mídia — assim ela funciona sozinha,
sem depender de internet. O mesmo vale para os **pacotes** que o sistema precisa
para compilar o llama.cpp: eles também vão na mídia (um repositório apt local),
para o primeiro boot não precisar baixar nada. Para trocar ou dispensar:

```bash
bash iso/build-iso.sh --iso-model ~/modelos/meu.gguf   # usa um modelo seu
bash iso/build-iso.sh --iso-model none                 # ISO sem modelo
bash iso/build-iso.sh --iso-repo none                  # ISO sem repositório apt
bash iso/build-iso.sh --iso-source none                # ISO sem a fonte do llama.cpp
```

> 💡 A ISO fica em torno de **4,3–5 GB** com tudo embutido (base ~2,6 GB +
> modelo ~1,1 GB + pacotes ~0,5 GB + fonte). Com tudo em `none`, uns 2,7 GB.
>
> ⚠️ **Não precisa de internet na máquina de destino** — mas **precisa** na
> máquina que **gera** a ISO (ou passe os arquivos já baixados com
> `--iso`, `--iso-model`, `--iso-source` e `--iso-repo`).

Como funciona, em três linhas:

1. A ISO traz o **software e a intenção** (qual papel/família você quer).
2. A instalação é **automática** — não faz perguntas.
3. No **primeiro boot**, o sistema detecta o **hardware de verdade** e aplica
   os ajustes certos para ele.

> 🎯 **A ISO funciona SEM internet.** Se a sua máquina está numa rede isolada,
> a ISO basta-se: o **modelo**, os **pacotes** e a **fonte do llama.cpp** vêm
> todos na mídia, e o primeiro boot compila localmente. Nada é baixado no destino.
>
> 💡 **A ISO já foi gerada e bootada numa VM** (Ubuntu Server 24.04, sessão #21):
> instalou sozinha e o 1º boot aplicou o ai-cpu-os, sem rede. O que ainda **não**
> foi validado (`docs/ISO.md` § 6): o caminho **Debian**, o boot **UEFI** e tudo
> em **hardware físico**. O checklist do § 9 tem o caminho completo.
>
> 💡 **A ISO APAGA o disco** indicado em `--disk`. Teste em máquina virtual
> **primeiro**, sempre.
>
> ⚠️ **Estado atual:** a ISO está escrita e verificada por ferramentas do
> projeto, mas **ninguém ainda a bootou e instalou de verdade** — é o maior
> item em aberto. Detalhes em [`docs/ISO.md`](docs/ISO.md).

---

## 11. Usar uma GPU (opcional)

O projeto é de CPU. Mas se você **quiser** usar uma GPU, existe caminho — sempre
**explícito**, nunca automático:

```bash
bash llama-build.sh --gpu-check        # o que existe na sua máquina (só lê)
bash llama-build.sh --gpu vulkan       # cuda | rocm | vulkan | sycl | metal
```

⚠️ **Leia antes:** com GPU, os ajustes de CPU daqui passam a ser **secundários**
e qualquer número medido antes **não vale** para esse build — o limite deixa de
ser a memória RAM e passa a ser a **memória da placa de vídeo**. O guia completo
(o que muda, como escolher o backend, o caso da RX 580) está em
**[`docs/GPU.md`](docs/GPU.md)**.

---

## 12. Problemas comuns

| Sintoma | O que provavelmente é | O que fazer |
|---|---|---|
| **"Illegal instruction" / o programa morre na hora** | Binário compilado com instruções que seu CPU não tem | Recompile com a sua família: `bash llama-build.sh --family auto` |
| **Muito lento, e o disco "trabalhando"** | O modelo não cabe na RAM e está usando swap | Reduza o modelo (quantização menor) ou o `LLAMA_CTX` |
| **Rápido às vezes, lento outras** | CPU baixando o clock ou algo mais rodando | Aplique a mod `governor` e verifique se não há outro processo pesado |
| **`curl :8080` não responde** | O serviço não subiu ou o modelo não está no caminho | `systemctl status ai-server` e `journalctl -u ai-server -n 50` |
| **Pouca memória / sistema travando** | Modelo grande demais para a RAM | Veja a tabela de tamanhos na FAQ (seção 13) |
| **Perdi acesso após aplicar** | Alguma mod de baixo nível | Reinicie; se persistir, entre pelo modo de recuperação e rode os `revert` |

Mais casos, com o diagnóstico completo, em
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

> Se algo der errado e você quiser relatar, use o modelo de *issue* do
> repositório — ele já pergunta o que o mantenedor precisa saber.

---

## 13. Perguntas frequentes

**Preciso de GPU?**
Não. O projeto inteiro existe justamente para quem **não** tem. Se você tem uma,
veja a seção 11 — mas aí o ganho vem de outro lugar.

**Isso vai rodar o ChatGPT localmente?**
Não é isso. Ele roda **modelos abertos** (Qwen, Llama, Mistral, Phi…) que você
baixa em arquivo. A qualidade depende do modelo e do tamanho que couber na sua
memória.

**Quanto mais rápido fica?**
Depende do hardware e do que já estava ajustado. É uma soma de ganhos pequenos
(memória, latência, clock) — quem mede antes e depois costuma notar mais
estabilidade do que "velocidade bruta". **Não prometemos multiplicador.**

**Que modelo cabe na minha máquina?**
Regra de bolso (a quantização `Q4` é o padrão prático):

| Modelo | RAM necessária (aprox.) | Cabe em 16 GB? |
|---|---|---|
| 1B–3B | 1–2 GB | ✅ folgado |
| 7B–8B | 5–6 GB | ✅ sim, com contexto moderado |
| 13B | 8–10 GB | ⚠️ apertado |
| 30B+ | 18 GB+ | ❌ não |

**Preciso reinstalar o sistema?**
Não. Funciona sobre um Ubuntu/Debian já instalado. (Instalar já pronto é o
objetivo da ISO — seção 10.)

**Meus dados vão para algum lugar?**
Não. Nada sai da sua máquina: o modelo roda local, sem API externa. Na primeira
vez o script só baixa pacotes e o código do llama.cpp.

**Por que compilar em vez de baixar pronto?**
Porque o binário tem que ser feito para o **seu** processador. Compilar certo é
o que evita o erro "illegal instruction" e garante que você use todas as
instruções que seu CPU tem. O GitHub também compila (veja a seção 14) para quem
preferir baixar.

**Vai me atrapalhar em outras tarefas (jogos, Docker, edição)?**
O foco é um servidor de inferência. Em desktop, o `governor` no máximo esquenta
e consome mais (dá para reverter com um comando).

**Funciona em ARM / Raspberry Pi?**
Hoje não. O projeto é x86-64.

---

## 14. Onde está cada coisa

### Quero entender melhor (documentação do usuário)

| Assunto | Documento |
|---|---|
| **Aprender o projeto do zero, passo a passo explicado** | [`docs/TUTORIAL.md`](docs/TUTORIAL.md) |
| Cada ajuste explicado com o porquê técnico | [`docs/TUNING.md`](docs/TUNING.md) |
| Detalhes do hardware alvo | [`docs/HARDWARE.md`](docs/HARDWARE.md) |
| Problemas e soluções | [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) |
| Melhorias isoladas (mods) | [`docs/MODS.md`](docs/MODS.md) |
| Processadores suportados (famílias) | [`docs/FAMILIES.md`](docs/FAMILIES.md) |
| Usar GPU | [`docs/GPU.md`](docs/GPU.md) |
| A ISO de instalação | [`docs/ISO.md`](docs/ISO.md) |
| O que já foi testado e o que **não** foi | [`docs/STATE.md`](docs/STATE.md) |

### Quero mexer no projeto

| Assunto | Documento |
|---|---|
| **Manual do mantenedor** (como o projeto funciona por dentro) | **[`README.technical.md`](README.technical.md)** |
| Regras e fluxo de trabalho (para humanos e IAs) | [`AGENTS.md`](AGENTS.md) |
| Arquitetura, fluxos e diagramas | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| O que está feito / planejado | [`docs/ROADMAP.md`](docs/ROADMAP.md) |
| Como o CI compila e valida tudo | [`docs/CI.md`](docs/CI.md) |
| Como testar em hardware e registrar resultados | [`docs/VALIDATION.md`](docs/VALIDATION.md) |
| Diário de sessões e continuidade | [`docs/JOURNAL.md`](docs/JOURNAL.md) |

### O que dá para rodar aqui, agora

```bash
make help          # lista todos os comandos
make validate      # checagens que o CI faz (não altera nada)
sudo make dry-run  # simula a instalação completa
make mods          # catálogo de melhorias
make gpu-check     # relata GPUs disponíveis (só leitura)
```

### Quero os binários já compilados

O GitHub compila automaticamente. Vá em **Actions → `build-llama` → run mais
recente → Artifacts** e baixe o pacote da família do seu CPU
(`ai-cpu-os-llama-intel-broadwell`, `...-amd-zen2`, etc.). Há também uma imagem
de container pronta para rodar sem instalar nada.

> ⚠️ **O que o CI não testa:** os ajustes de kernel (eles precisam de uma máquina
> de verdade e, para a linha de boot, de reinício). Isso continua sendo
> validação manual — [`docs/VALIDATION.md`](docs/VALIDATION.md).

---

## 15. Licença

MIT — veja [`LICENSE`](LICENSE). Use, modifique e distribua à vontade.

---

> **Status:** `0.2.0` (alpha). O projeto está escrito e verificado por
> ferramentas automatizadas, mas **ainda não foi validado em hardware real** —
> veja [`docs/STATE.md`](docs/STATE.md) para saber exatamente o que já foi
> provado e o que não foi. Trate como um esqueleto funcional, não como release.
