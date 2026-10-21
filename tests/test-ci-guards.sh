#!/usr/bin/env bash
#
# tests/test-ci-guards.sh — prova que os guardas do CI REALMENTE derrubam o job
# -----------------------------------------------------------------------------
# "Guarda que nunca reprovou não é guarda."
#
# Descobri na marra (sessão #19) que SEIS guardas negativos do job
# `project-rules` eram DECORATIVOS: estavam escritos como `! grep -q X arquivo`,
# e o `set -e` do bash **ignora o exit status de um comando invertido com `!`**
# (está na doc do `set`: "...or if the command's return value is being inverted
# with !"). Ou seja, a violação era detectada e... nada acontecia: o job seguia
# verde. Pior: os testes que eu vinha fazendo "reprovavam" por causa do guarda
# POSITIVO que vinha logo depois, dando a impressão de que o negativo funcionava.
#
# Este teste fecha o buraco em dois níveis:
#   1. Roda os passos do job como o CI roda (`bash -e`, um por passo) e exige que
#      o job PASSE numa árvore limpa;
#   2. PLANTA cada violação, uma por vez, e exige que o job FALHE.
#
# Nada é alterado na árvore de trabalho: tudo acontece numa cópia temporária
# (o repositório tem ~1,3 MB, então copiar é barato e elimina o risco de deixar
# o workspace sujo se o teste for interrompido).
#
# Uso: bash tests/test-ci-guards.sh [--verbose]
# Requer: python3 (para extrair os blocos `run:` do workflow). Sem rede, sem root.
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
SRC_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly SRC_ROOT

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly REPO="${WORK}/repo"
readonly PRISTINE="${WORK}/pristine"

# Copia a árvore de trabalho (sem .git) — duas vezes: uma para mexer, outra
# para restaurar arquivo a arquivo sem depender de git.
# Exclui os ARTEFATOS de build (iso/work pode ter GB de cache/downloads):
# sem isto, o teste estoura a cota do /tmp (tmpfs) em máquinas que já geraram
# uma ISO — o guarda em si não tem nada a ver com eles.
copy_tree() {
  local dst="$1"
  mkdir -p "$dst"
  tar -C "$SRC_ROOT" \
      --exclude=.git --exclude=iso/out --exclude=iso/work \
      --exclude='./*.iso' --exclude='./*.gguf' \
      -cf - . | tar -C "$dst" -xf -
}
copy_tree "$REPO"
copy_tree "$PRISTINE"

# ---------------------------------------------------------------------------
# Extrai os blocos `run:` do job project-rules, como o CI os executa.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/blocks"
python3 - "$REPO/.github/workflows/validate.yml" "${WORK}/blocks" <<'PY'
import pathlib, sys
wf, outdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = wf.read_text().split("\n")
jobs = [(i, l) for i, l in enumerate(lines)
        if l.startswith("  ") and not l.startswith("    ") and l.rstrip().endswith(":")]
start = next(i for i, l in jobs if l.strip() == "project-rules:")
end = next((i for i, l in jobs if i > start), len(lines))
n = 0
for i in range(start, end):
    if lines[i].strip() == "run: |" and len(lines[i]) - len(lines[i].lstrip()) == 8:
        body = []
        for m in lines[i + 1:]:
            if m.strip() == "":
                body.append("")
                continue
            if not m.startswith("          "):
                break
            body.append(m[10:])
        n += 1
        (outdir / f"step{n}.sh").write_text("\n".join(body) + "\n")
print(n)
PY

BLOCKS=$(find "${WORK}/blocks" -name 'step*.sh' | wc -l)
[[ "$BLOCKS" -ge 1 ]] || { echo "não consegui extrair os passos do job"; exit 1; }

# Roda o job inteiro como o CI: cada passo em um shell próprio. O job falha se
# QUALQUER passo falhar.
job_fails() {
  local b
  for b in "${WORK}"/blocks/step*.sh; do
    if ! ( cd "$REPO" && bash -e "$b" >/dev/null 2>&1 ); then
      return 0
    fi
  done
  return 1
}

restore() { cp -a "${PRISTINE}/$1" "${REPO}/$1"; }

# planta <descrição> <arquivo> <como>
# Espera que o job FALHE; restaura em seguida.
planta() {
  local desc="$1" arq="$2"; shift 2
  if job_fails; then
    bad "job JÁ falhava na árvore limpa antes de '${desc}'"
    restore "$arq"
    return 0
  fi
  "$@"
  if job_fails; then
    ok "reprova: ${desc}"
  else
    bad "NÃO reprova (guarda decorativo?): ${desc}"
  fi
  restore "$arq"
}

app() { printf '\n# isca do teste de guardas\n%s\n' "$1" >> "${REPO}/$2"; }
sed_() { sed -i "$1" "${REPO}/$2"; }

echo "Guardas do CI (job project-rules) — ${BLOCKS} passos extraídos"

# --- Sanidade: a árvore limpa (com as minhas mudanças) tem de passar ---------
if job_fails; then
  bad "o job falha numa árvore LIMPA (existe guarda errado ou o repo está sujo)"
else
  ok "árvore limpa: o job passa"
fi

# --- Guardas negativos (o que `! grep` fingia fazer) ------------------------
planta "--gpu auto em llama-build.sh" llama-build.sh app 'foo --gpu auto' llama-build.sh
planta "download em lote sem fallback (xargs -r -n 25)" iso/build-iso.sh app 'foo | xargs -r -n 25 sh -c bar' iso/build-iso.sh
planta "--prebuilt em build-iso.sh" iso/build-iso.sh app 'foo --prebuilt bar' iso/build-iso.sh
planta "COPY build/bin no Dockerfile" docker/Dockerfile app 'COPY build/bin /usr/local/bin/x' docker/Dockerfile
planta "upload-artifact em @v6" .github/workflows/build-llama.yml sed_ 's|upload-artifact@v7|upload-artifact@v6|' .github/workflows/build-llama.yml
planta "actions/checkout em @v4 (major antigo)" .github/workflows/build-llama.yml sed_ 's|actions/checkout@v7|actions/checkout@v4|' .github/workflows/build-llama.yml

# --- Meta-guarda: a PRÓPRIA forma proibida --------------------------------
planta "meta-guarda: volta um guarda na forma '! cmd'" .github/workflows/validate.yml \
  sed_ "s|^          grep -q 'iso-repo-test' Makefile\$|          ! grep -q isca Makefile|" .github/workflows/validate.yml

# --- Guardas de existência/positivos (o outro lado: apagar o alvo) ---------
planta "tirar iso-repo-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-dry-run|' Makefile
planta "tirar iso-select-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-repo-test ci-guards-test iso-dry-run|' Makefile
planta "tirar ci-guards-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test iso-dry-run|' Makefile
planta "tirar iso-verify-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test ci-guards-test iso-dry-run|' Makefile
planta "renomear packages_with_candidate()" iso/build-iso.sh \
  sed_ 's|^packages_with_candidate()|packages_with_candidate_velho()|' iso/build-iso.sh
planta "renomear normalize_iso_name()" iso/build-iso.sh \
  sed_ 's|^normalize_iso_name()|normalize_iso_name_velho()|' iso/build-iso.sh
planta "tirar o marcador '*' da fixture do SHA256SUMS" tests/fixtures/SHA256SUMS.ubuntu-24.04 \
  sed_ 's|\*ubuntu-24.04.5|ubuntu-24.04.5|' tests/fixtures/SHA256SUMS.ubuntu-24.04
planta "o pendrive deixar de exigir disco inteiro (TYPE)" iso/write-pendrive.sh \
  sed_ 's|TYPE|TIPO|g' iso/write-pendrive.sh
planta "o pendrive deixar de conferir a assinatura CD001" iso/write-pendrive.sh \
  sed_ 's|CD001|XXXXX|g' iso/write-pendrive.sh
planta "o teste do pendrive esquecer que o alvo e um ARQUIVO" tests/test-write-pendrive.sh \
  sed_ 's|ARQUIVO|ALVO|g' tests/test-write-pendrive.sh
planta "o conferidor de ISO esquecer a assinatura CD001" iso/check-iso.sh \
  sed_ 's|CD001|XXXXX|g' iso/check-iso.sh
planta "tirar iso-check-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test ci-guards-test pendrive-test iso-dry-run|' Makefile
planta "o artifact da ISO voltar a ser gateado pela Release" .github/workflows/iso.yml \
  sed_ 's|steps.size.outputs.release_too_big|steps.size.outputs.too_big|' .github/workflows/iso.yml

# --- Interface web (fácil de degradar sem ninguém notar) --------------------
planta "tirar ui-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test ci-guards-test pendrive-test iso-check-test iso-dry-run|' Makefile
planta "a UI passar a usar dependência externa" webui/server.py \
  app 'import fastapi' webui/server.py
planta "a UI passar a exigir pip install" webui/server.py \
  app 'print("rode: pip install flask")' webui/server.py
planta "a página passar a carregar um recurso externo (CDN)" webui/index.html \
  app '<script src="https://cdn.jsdelivr.net/npm/x.js"></script>' webui/index.html
planta "a UI voltar a pedir senha de sudo (pendrive)" webui/server.py \
  app 'sudo -S true' webui/server.py
planta "senha em TEXTO PURO na linha de comando da UI" webui/server.py \
  app 'args += ["--password", pw]' webui/server.py
planta "a UI perder o hash crypt (senha chegaria em claro)" webui/server.py \
  sed_ 's|crypt\.crypt|X|g; s|crypt\.mksalt|X|g' webui/server.py
planta "a UI perder a lista branca de ações" webui/server.py \
  sed_ 's|^ACTIONS = {|OPACO = {|' webui/server.py
planta "a UI perder o validador de disco" webui/server.py \
  sed_ 's|^RE_DISK = |# RE_DISK = |' webui/server.py
planta "a UI deixar de recusar bind fora do localhost" webui/server.py \
  sed_ 's|args.host not in|args.host in|' webui/server.py
planta "a ISO passar a levar o webui/ (Regra 13-b)" iso/build-iso.sh \
  sed_ 's|--exclude=./webui||' iso/build-iso.sh

# --- ai-talk (chat da frota): invariantes do ADR-003/004/005 ----------------
planta "tirar talk-test do validate" Makefile \
  sed_ 's| talk-test||' Makefile
planta "tirar a chamada de make talk-test do CI" .github/workflows/validate.yml \
  sed_ 's|make talk-test|make ui-test|' .github/workflows/validate.yml
planta "o ai-talk deixar de assinar (compare_digest)" talk/ai_talk.py \
  sed_ 's|hmac.compare_digest|str.__eq__|' talk/ai_talk.py
planta "o ai-talk deixar de ligar TCP_NODELAY" talk/ai_talk.py \
  sed_ 's|socket.TCP_NODELAY|0|' talk/ai_talk.py
planta "o ack sair ANTES do fsync (perde durabilidade)" talk/ai_talk.py \
  sed_ 's|os.fsync(self.handle.fileno())|pass|' talk/ai_talk.py
planta "o teto de 15 nós virar 30" talk/ai_talk.py \
  sed_ 's|^MAX_PEERS = 15|MAX_PEERS = 30|' talk/ai_talk.py
# `--keydir` sozinho (o modo recomendado) tem de gerar serviço que INICIA.
# Sem derivar a chave do próprio nó, a config aponta para fleet.key (inexistente
# nesse modo) e o daemon morre no start — com o serviço habilitado.
planta "o instalador deixar de derivar a chave do próprio nó do --keydir" talk/install.sh \
  sed_ 's|^      OWN_KEY_FROM_KEYDIR=1$|      :|' talk/install.sh
# A checagem de chave órfã tem de vir DEPOIS de montar a frota: antes dela todo
# peer vindo de --peers-file era acusado de órfão (bug real, sessão #46).
planta "a checagem de chave órfã voltar para antes dos peers do arquivo" talk/install.sh \
  sed_ 's|^# Peers do arquivo (uma linha|# A chave do PRÓPRIO nó não é "órfã" (violação plantada)\n# Peers do arquivo (uma linha|' talk/install.sh
planta "o ai-talk aceitar chave legível por outros" talk/ai_talk.py \
  sed_ 's|if st.st_mode & stat.S_IROTH:|if False:|' talk/ai_talk.py
planta "o dedupe_window voltar a 1024 (não cobre o retry de 9 s)" talk/ai_talk.py \
  sed_ 's|"dedupe_window": 8192|"dedupe_window": 1024|' talk/ai_talk.py
planta "o ai-talk passar a usar dependência externa" talk/ai_talk.py \
  app 'import requests' talk/ai_talk.py

# --- AVX-512 + trava de instância única do gerador de ISO -------------------
planta "tirar avx512-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test ci-guards-test iso-lock-test pendrive-test iso-check-test ui-test iso-dry-run|' Makefile
planta "tirar iso-lock-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test ci-guards-test pendrive-test iso-check-test ui-test iso-dry-run|' Makefile

# --- Disco do autoinstall: o modo nº 1 de a automação não acontecer ---------
# `--disk auto` ia LITERAL para o YAML e virava `match: {path: auto}`: nenhum
# disco casa e o Subiquity não instala sozinho, sem erro visível.
planta "--disk auto voltar a ir LITERAL para o YAML (match: {path: auto})" iso/build-iso.sh \
  sed_ 's|if \[\[ "$DISK" == "auto" \|\| "$DISK" == "any" \|\| "$DISK" == "none" \]\]; then|if false; then|' iso/build-iso.sh
planta "o default do CI voltar a /dev/vda (só existe em VM)" .github/workflows/iso.yml \
  sed_ "s#inputs.disk || 'auto'#inputs.disk || '/dev/vda'#" .github/workflows/iso.yml
planta "tirar iso-disk-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test ci-guards-test iso-lock-test pendrive-test iso-check-test ui-test iso-dry-run|' Makefile
planta "renomear acquire_build_lock()" iso/build-iso.sh \
  sed_ 's|^acquire_build_lock()|acquire_build_lock_velho()|' iso/build-iso.sh
planta "renomear download_to()" iso/build-iso.sh \
  sed_ 's|^download_to()|download_to_velho()|' iso/build-iso.sh
# A armadilha do run do v0.2.5: `matrix.exec != 'false'` num `if:` NUNCA dá
# falso (booleano x string) e o passo roda no runner sem a ISA -> SIGILL.
planta "voltar a comparar matrix.exec com STRING num if:" .github/workflows/build-llama.yml \
  app "        if: steps.model.outputs.ok == '1' && matrix.exec != 'false'" .github/workflows/build-llama.yml

# --- Repositório apt: a 2ª tentativa tem de ser diagnosticável --------------
planta "o retry deixar de refrescar o índice (404 de espelho volta)" iso/build-iso.sh \
  sed_ 's|índice fresco para a 2ª tentativa|segunda tentativa|' iso/build-iso.sh
planta "o retry voltar a descartar a saída do apt (log ilegível)" iso/build-iso.sh \
  sed_ 's|apt-get download -o Acquire::Retries=5 "\$p"|apt-get download -o Acquire::Retries=5 ${faltando}|' iso/build-iso.sh

# --- Rede do alvo: default DHCP + os três elos da configuração --------------
planta "o default de --network voltar a 'none'" iso/build-iso.sh \
  sed_ 's|^NETWORK_MODE="auto"|NETWORK_MODE="none"|' iso/build-iso.sh
planta "o autoinstall perder o bloco de rede" iso/autoinstall/autoinstall.yaml \
  sed_ 's|^@@NETWORK_SECTION@@$|# sem rede|' iso/autoinstall/autoinstall.yaml
planta "o late-command deixar de gravar o netplan do alvo" iso/common/late-command.sh \
  sed_ 's|99-ai-cpu-os.yaml|SEM-REDE.yaml|' iso/common/late-command.sh
planta "a ISO deixar de embarcar o netplan do alvo" iso/build-iso.sh \
  sed_ 's|ai-cpu-os-netplan.yaml|sem-netplan.yaml|g' iso/build-iso.sh
planta "cloud-init deixar de ser desligado na rede" iso/common/late-command.sh \
  sed_ 's|99-ai-cpu-os-disable-network.cfg|cloud-init.yaml|' iso/common/late-command.sh

# --- Mod `network`: o reparo da maquina JA instalada ------------------------
planta "a mod network perder o netplan do ai-cpu-os" mods/network/apply.sh \
  sed_ 's|99-ai-cpu-os.yaml|rede.yaml|g' mods/network/apply.sh
planta "a mod network deixar de mover o netplan do cloud-init" mods/network/apply.sh \
  sed_ 's|ai-cpu-os.bak|bak2|g' mods/network/apply.sh
planta "a mod network deixar de desligar a rede do cloud-init" mods/network/apply.sh \
  sed_ 's|99-ai-cpu-os-disable-network.cfg|cloud-init.yaml|g' mods/network/apply.sh
planta "a mod network perder o --root (impede testar sem root)" mods/network/apply.sh \
  sed_ 's|--root|--raiz|g' mods/network/apply.sh
planta "o revert deixar de restaurar o netplan original" mods/network/revert.sh \
  sed_ 's|restaurado|removido|' mods/network/revert.sh
planta "a mod network deixar de avisar que o glob não casa placa" mods/network/apply.sh \
  sed_ 's|não vai pegar NADA|verifique a rede|' mods/network/apply.sh
planta "a mod network entrar no conjunto system (mexeria na rede no build)" mods/network/mod.conf \
  sed_ 's|^MOD_SETS="network"|MOD_SETS="system"|' mods/network/mod.conf
planta "tirar network-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test ci-guards-test iso-lock-test iso-disk-test pendrive-test iso-check-test ui-test iso-dry-run|' Makefile
planta "tirar o alvo network-fix (o reparo na propria maquina)" Makefile \
  sed_ 's|^network-fix:|network_velho:|' Makefile

# --- Gravação do disco: sync no alvo + tempo antes de matar o qemu ----------
planta "o firstboot deixar de sincronizar o disco (arquivos de 0 byte)" iso/common/firstboot.sh \
  sed_ 's|^sync$|true|' iso/common/firstboot.sh
planta "o test-vm voltar a matar o qemu sem esperar o disco" iso/test-vm.sh \
  sed_ 's|descarregarem o disco|encerrando|' iso/test-vm.sh

# --- Flags do llama.cpp que o upstream renomeia -----------------------------
planta "a unit voltar a fixar --no-mmap (removido do llama.cpp)" roles/inference/ai-server.service \
  app '    --no-mmap' roles/inference/ai-server.service
planta "o install.sh deixar de detectar a sintaxe do binário" roles/inference/install.sh \
  sed_ 's|detect_extra_args()|detect_extra_args_velho()|' roles/inference/install.sh
planta "o shell-ia voltar a devolver a linha do protocolo" roles/inference/shell-ia.py \
  sed_ 's|^        return chat(messages)$|        return messages[-1].get("content", "")|' roles/inference/shell-ia.py

# --- ISO: a instalação automática tem de começar sozinha --------------------
# O caminho Debian (preseed) saiu no ADR-001, mas o que ele ensinou continua
# valendo como CLASSE de bug: a máquina fica parada, o disco não é tocado e o
# serial não mostra erro. Os equivalentes no Ubuntu/Subiquity têm guarda
# própria — e cada item abaixo planta a violação correspondente.
planta "o autoinstall sair da cmdline do GRUB (instalador fica interativo)" iso/build-iso.sh \
  sed_ 's|autoinstall quiet|interativo quiet|g' iso/build-iso.sh
planta "o autoinstall deixar de ir para a RAIZ da ISO" iso/build-iso.sh \
  sed_ 's|-map "${UBUNTU_STAGE}/autoinstall.yaml" /autoinstall.yaml|-map "${UBUNTU_STAGE}/autoinstall.yaml" /boot/autoinstall.yaml|' iso/build-iso.sh
planta "o verificador deixar de procurar o autoinstall na raiz" iso/verify-iso.sh \
  sed_ 's|/autoinstall.yaml|/autoinstal.yaml|g' iso/verify-iso.sh
planta "a instalação deixar de reiniciar sozinha (para no 'Reboot Now')" iso/autoinstall/autoinstall.yaml \
  sed_ 's|^shutdown: reboot|shutdown: poweroff|' iso/autoinstall/autoinstall.yaml
planta "o instalador voltar a tentar se atualizar no meio do caminho" iso/autoinstall/autoinstall.yaml \
  sed_ 's|^  update: false|  update: true|' iso/autoinstall/autoinstall.yaml
planta "o late-command deixar a fonte 'cdrom:' no apt do alvo" iso/common/late-command.sh \
  sed_ 's|cdrom:|cdromx:|g' iso/common/late-command.sh
planta "o firstboot deixar de espelhar no console serial" iso/common/firstboot.sh \
  sed_ 's|/dev/ttyS0|/dev/ttyS1|g' iso/common/firstboot.sh
planta "o autoinstall deixar de instalar o servidor SSH" iso/autoinstall/autoinstall.yaml \
  sed_ 's|install-server: true|install-server: false|' iso/autoinstall/autoinstall.yaml
planta "o EXTRA_PACKAGES perder o sudo (fica sem acesso administrativo)" iso/build-iso.sh \
  sed_ 's|^EXTRA_PACKAGES="sudo |EXTRA_PACKAGES="|' iso/build-iso.sh

# --- ISO: uma base só (ADR-001) ---------------------------------------------
# Se o caminho Debian voltar pela porta dos fundos, o projeto volta a ter duas
# ISOs — que é exatamente o que o ADR-001 decidiu encerrar.
planta "o build-iso voltar a mencionar o caminho Debian (preseed)" iso/build-iso.sh \
  app 'log_info "preseed/ antigo"' iso/build-iso.sh
planta "o verificador voltar a conferir a preseed" iso/verify-iso.sh \
  app 'grep -q apt-setup/local0 "$f"' iso/verify-iso.sh
planta "o workflow da ISO voltar a passar DISTRO= ao make (variavel morta)" .github/workflows/iso.yml \
  app 'make iso-dry-run DISTRO="$ISO_DISTRO"' .github/workflows/iso.yml

# --- Identidade derivada do papel (ADR-002) --------------------------------
# O modo de falha e' silencioso: a ISO instala, o alvo sobe, e o usuario e'
# outro. So se descobre ao tentar `ssh` ou ao ler um log de outra maquina.
planta "a derivacao da identidade sumir (tudo vira ai-cpu-os)" iso/build-iso.sh \
  sed_ 's|^    inference) printf .ai-inference.|    inference) printf "ai-cpu-os"|; s|^    builder)   printf .ai-builder.|    builder)   printf "ai-cpu-os"|' iso/build-iso.sh
planta "o --username deixar de vencer o papel (a flag passaria a mentir)" iso/build-iso.sh \
  sed_ 's|^  if \[\[ $USERNAME_EXPLICIT -eq 1 \]\]; then|  if \[\[ $USERNAME_EXPLICIT -eq 99 \]\]; then|' iso/build-iso.sh
planta "a identidade deixar de chegar ao alvo (.iso-config)" iso/common/late-command.sh \
  sed_ 's|ISO_USERNAME=%s||' iso/common/late-command.sh
planta "a linha estavel do --dry-run mudar de formato" iso/build-iso.sh \
  sed_ 's|usuario=%s hostname=%s papel=%s origem=%s|user=%s host=%s role=%s|' iso/build-iso.sh
planta "o verificador deixar de conferir a derivacao do papel" iso/verify-iso.sh \
  sed_ 's|derivação do ADR-002|identidade|' iso/verify-iso.sh
planta "tirar identity-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test ci-guards-test iso-lock-test iso-disk-test iso-release-test iso-space-test network-test apt-test pendrive-test iso-check-test ui-test talk-test iso-dry-run|' Makefile

# --- F2 do chat: o `ai-talk` tem de CHEGAR na máquina (ADR-003) ------------
# Os dois modos de falha são silenciosos: o serviço sobe sem chave (promete
# autenticação e não entrega) e a chave por nó não entra na config (o nó cai na
# chave global e qualquer um assina como outro).
planta "o instalador do chat deixar de recusar chave legível por outros" talk/install.sh \
  sed_ 's|(8#$perms & 8#004) != 0|(8#$perms \& 8#004) == 99|g' talk/install.sh
planta "o instalador do chat deixar o serviço ativo SEM chave" talk/install.sh \
  sed_ 's|^  ENABLE_SERVICE=0$|  ENABLE_SERVICE=1|' talk/install.sh
planta "o instalador do chat perder a chave POR NÓ" talk/install.sh \
  sed_ 's|--peer-key|--ignorado|g' talk/install.sh
planta "a ISO deixar de embarcar o payload do chat" iso/build-iso.sh \
  sed_ 's|^  stage_chat_payload "${dest}/chat"$|  true|' iso/build-iso.sh
planta "o firstboot deixar de repassar a intenção do chat ao build.sh" iso/common/firstboot.sh \
  sed_ 's|^  export AI_CHAT_INSTALL=1$|  true|' iso/common/firstboot.sh
planta "o late-command deixar de registrar os caminhos do chat" iso/common/late-command.sh \
  sed_ 's|^printf .CHAT_KEY=%s|printf "CHAT_X=%s|' iso/common/late-command.sh
planta "o build.sh deixar de instalar o chat (etapa 2.5)" build.sh \
  sed_ 's|^  run_chat_install$|  : run_chat_install|' build.sh
planta "a unit do chat perder o endurecimento (NoNewPrivileges)" talk/ai-talk.service \
  sed_ 's|^NoNewPrivileges=yes|NoNewPrivileges=no|' talk/ai-talk.service
planta "tirar talk-install-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test identity-test iso-chat-test ci-guards-test iso-lock-test iso-disk-test iso-release-test iso-space-test network-test apt-test pendrive-test iso-check-test ui-test talk-test iso-dry-run|' Makefile
# --- A página web é JavaScript: tem de ser EXECUTADA, não só lida --------
# O bug real da sessão #43: `syncIdentityHint()` no topo do <script>, antes de
# `loadOptions()` preencher OPTIONS → TypeError que mata a página inteira. O
# `ui-test` (API) continuou verde. Aqui plantamos o bug de volta.
# O `sed_` precisa do ALVO no fim (é `sed_ <expr> <arquivo>`); esquecer o
# arquivo dá "variável não associada" sob `set -u` — foi assim que descobri.
planta "a página voltar a ler OPTIONS no topo do script (mata a página)" webui/index.html \
  app 'syncIdentityHint();' webui/index.html
planta "a página perder a guarda de OPTIONS nulo na dica de identidade" webui/index.html \
  sed_ 's|const map = (OPTIONS \&\& OPTIONS.identity) \|\| {};|const map = OPTIONS.identity \|\| {};|' webui/index.html
planta "tirar ui-page-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test identity-test iso-chat-test ci-guards-test iso-lock-test iso-disk-test iso-release-test iso-space-test network-test apt-test pendrive-test iso-check-test ui-test talk-test talk-install-test iso-dry-run|' Makefile

# --- Base instalada explícita (a default da ISO pode mudar) ---------------
planta "o autoinstall voltar a depender do default da ISO (sem source:)" iso/autoinstall/autoinstall.yaml \
  sed_ 's|^source:$|# sem source|' iso/autoinstall/autoinstall.yaml
planta "o build deixar de conferir o id da base na ISO" iso/build-iso.sh \
  sed_ 's|Bases disponíveis|Bases|' iso/build-iso.sh
planta "o verificador deixar de conferir a base instalada" iso/verify-iso.sh \
  sed_ 's|install-sources.yaml|sources.yaml|g' iso/verify-iso.sh
planta "tirar iso-chat-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test identity-test ci-guards-test iso-lock-test iso-disk-test iso-release-test iso-space-test network-test apt-test pendrive-test iso-check-test ui-test talk-test talk-install-test iso-dry-run|' Makefile

# --- Acesso remoto: sem sshd a máquina instalada é um tijolo ---------------
# Medido numa instalação real (sessão #36): o alvo subiu, pegou IP e não tinha
# NENHUM listener (65535 portas em RST). Sem teclado/tela, não há conserto.
planta "o late-command deixar de garantir o SSH do alvo" iso/common/late-command.sh \
  sed_ 's|openssh-server|openssh-cliente|g' iso/common/late-command.sh
planta "o build.sh deixar de garantir o SSH no 1º boot" build.sh \
  sed_ 's|^[[:space:]]*ensure_ssh$|: ensure_ssh|' build.sh

# --- Mod de reparo do apt: é o conserto de quem JÁ instalou ----------------
planta "o mod apt-sources apagar fontes e não testar o resultado" mods/apt-sources/apply.sh \
  sed_ "s|apt-get update|apt-get dist-upgrade|g" mods/apt-sources/apply.sh
planta "o mod apt-sources deixar de limpar o 'cdrom:' do instalador" mods/apt-sources/apply.sh \
  sed_ 's|cdrom:|midia:|g' mods/apt-sources/apply.sh
planta "o mod apt-sources esquecer o backup antes de alterar" mods/apt-sources/apply.sh \
  sed_ 's|ai-cpu-os.bak|bak|g' mods/apt-sources/apply.sh

# --- --iso-repo auto: a conferência de release -----------------------------
planta "a versão da base voltar a ignorar o arquivo (--iso)" iso/build-iso.sh \
  sed_ 's|s#^ubuntu-|s#^no-ubuntu-|' iso/build-iso.sh
planta "o codename voltar a sair só da tabela fixa" iso/build-iso.sh \
  sed_ 's|    want="\$(iso_base_codename)"|    want="\$(ubuntu_codename_for_version "$ver")"|' iso/build-iso.sh

# --- O verificador não pode quebrar por falta de espaço -------------------
planta "o verificador voltar a extrair o modelo INTEIRO" iso/verify-iso.sh \
  sed_ 's|^  if \[\[ -n "\$lba" \]\]; then|  if false; then|' iso/verify-iso.sh
planta "o verificador voltar a usar /tmp às cegas" iso/verify-iso.sh \
  sed_ 's|df -Pk|true|g' iso/verify-iso.sh

# --- Log honesto da família (visto numa execução real, sessão #37) ---------
planta "o llama-build voltar a dizer 'forçada' para família detectada" llama-build.sh \
  sed_ 's|detectada na CPU e repassada pela cadeia|forçada por --family|' llama-build.sh

# --- A instalação não pode exigir internet --------------------------------
# Regra 13-b: a ISO é air-gapped. No Subiquity a tentação equivalente é o
# `refresh-installer` (baixa o instalador novo) e o `geoip` (consulta remota).
planta "o autoinstall voltar a consultar geoip pela rede" iso/autoinstall/autoinstall.yaml \
  sed_ 's|^  geoip: false|  geoip: true|' iso/autoinstall/autoinstall.yaml
planta "o Release do repo local voltar a dizer Codename: ./" iso/build-iso.sh \
  sed_ "s|printf 'Codename: %s\\\\n' \"\${REPO_SUITE:-stable}\"|printf 'Codename: ./\\\\n'|" iso/build-iso.sh

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ci-guards: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "ci-guards: PASS=${PASS} FAIL=${FAIL}"
exit 1
