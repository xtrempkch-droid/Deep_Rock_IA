#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
webui/server.py — interface web LOCAL para gerar, conferir e gravar a ISO do
ai-cpu-os.

POR QUE EXISTE
--------------
Gerar a ISO exige lembrar de 6+ flags (`--disk`, `--role`,
`--family`, `--iso-source/model/repo`), e o passo seguinte (gravar num pendrive)
é o mais perigoso do projeto. O terminal já faz tudo isso — este servidor só
tira a memorização e mostra o que vai acontecer ANTES de acontecer.

TRÊS REGRAS DE PROJETO (valem mais que a interface)
---------------------------------------------------
1. **NUNCA reimplementar.** Toda ação executa o script/alvo que já existe
   (`iso/build-iso.sh`, `iso/check-iso.sh`, `iso/write-pendrive.sh`,
   `detect-hardware.sh`). Este projeto já foi mordido duas vezes por comando
   duplicado que divergiu e deixou o CI vermelho — uma UI que reimplementasse o
   build recriaria esse bug em escala maior.
2. **SEM dependências.** Só a biblioteca padrão do Python 3 (`http.server`,
   `subprocess`, `json`). Nada de FastAPI/Flask/Redis/Celery: a máquina do
   usuário é modesta e o projeto é explícito contra infra que não paga por si.
3. **SÓ LOCALHOST + LISTA BRANCA.** O servidor escuta em 127.0.0.1 e as ações
   são um conjunto FECHADO de operações com parâmetros validados. Não existe
   endpoint de "executar comando arbitrário" — quem tem o navegador aberto não
   deve conseguir rodar `dd` em qualquer coisa.

LIMITAÇÕES HONESTAS (a UI diz isso na tela, não esconde)
--------------------------------------------------------
* Gerar a ISO precisa de `xorriso` na máquina. Sem ele, o botão fica
  desabilitado COM O MOTIVO, e a tela mostra o caminho alternativo (gerar no
  GitHub Actions e baixar o artifact). Fingir que funciona seria pior.
* Gravar no pendrive precisa de root. O servidor NÃO executa `sudo` (pediria
  senha por um navegador, o que é inaceitável): ele lista os dispositivos e
  monta o comando exato para você colar no terminal.

Uso:
    python3 webui/server.py                 # http://127.0.0.1:8787
    python3 webui/server.py --port 9000
    python3 webui/server.py --port 0        # porta livre; imprime "PORT=<n>"
    python3 webui/server.py --no-browser    # não tenta abrir o navegador

Sem dependências externas. Sem rede. Sem root.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

# ---------------------------------------------------------------------------
# Caminhos e constantes
# ---------------------------------------------------------------------------
WEBUI_DIR = Path(__file__).resolve().parent
REPO_ROOT = WEBUI_DIR.parent
ISO_DIR = REPO_ROOT / "iso"
ISO_OUT = ISO_DIR / "out"
ISO_WORK = ISO_DIR / "work"

# Só estas ações existem. É a "lista branca" da interface.
ACTIONS = {
    "preview",     # dry-run do build (sempre seguro, não baixa nada)
    "build",       # gera a ISO de verdade (exige xorriso)
    "iso-check",   # confere um arquivo .iso baixado
    "iso-verify",  # confere o CONTEÚDO de uma ISO gerada (exige xorriso)
    "pendrives",   # lista dispositivos candidatos (só leitura)
}

# ADR-001 (docs/DECISIONS.md): Ubuntu é a base ÚNICA da ISO. A lista fica como
# tupla de um item (e não é removida) para o validador continuar recusando
# QUALQUER outro valor vindo do navegador.
DISTROS = ("ubuntu",)
ROLES = ("auto", "inference", "builder")
# ADR-002 (docs/DECISIONS.md): a identidade do sistema segue a FUNÇÃO da
# máquina. Este mapa é a MESMA tabela do `resolve_identity()` no
# build-iso.sh — ele existe aqui só para a página SUGERIR o valor; quem
# decide de verdade continua sendo o build. A UI nunca obriga: campo vazio
# significa "deixe o build derivar do papel".
ROLE_IDENTITY = {
    "inference": "ai-inference",
    "builder": "ai-builder",
    "auto": "ai-cpu-os",
}
PAYLOADS = ("auto", "none")
# Rede do sistema INSTALADO. O default é `auto` (DHCP) de propósito: sem uma
# configuração persistente o alvo sobe com a placa DOWN (bug real, sessão #28).
NETWORK_MODES = ("auto", "dhcp", "static", "none")

# Um dispositivo de bloco: /dev/sdb, /dev/nvme0n1, /dev/vda. Nada além disso.
RE_DISK = re.compile(r"^/dev/[a-zA-Z0-9]+$")
# Nome de usuário POSIX e hostname: minúsculas, dígitos, `_` e `-`. Restringir
# aqui não é preciosismo — o valor vai para o `autoinstall.yaml`, para o
# `.iso-config` e para o prompt do alvo.
RE_USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
RE_HOSTNAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
# Nome de ISO gerada pelo projeto (usado para achar arquivos dentro de iso/out).
RE_ISO_NAME = re.compile(r"^[A-Za-z0-9._-]+\.iso$")
# Valores que vão para o netplan/preseed — validados aqui também (a UI nunca
# repassa texto do navegador sem conferir o formato).
RE_IPV4 = re.compile(
    r"^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}"
    r"(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$"
)
RE_IFACE = re.compile(r"^[A-Za-z0-9_.:-]{1,32}$")
RE_NET_IP = re.compile(
    r"^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}"
    r"(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(/[0-9]{1,2})?$"
)

# Tempo máximo para comandos "curtos" (status, listagens).
FAST_TIMEOUT = 60


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def have(cmd: str) -> bool:
    """O comando existe no PATH?"""
    return shutil.which(cmd) is not None


def run_capture(argv: list[str], cwd: Path | None = None,
                timeout: int = FAST_TIMEOUT) -> tuple[int, str]:
    """Roda um comando CURTO e devolve (rc, saída). Nunca levanta exceção:
    transforma falha em rc != 0 com a mensagem, para a UI poder mostrar."""
    try:
        p = subprocess.run(
            argv, cwd=str(cwd or REPO_ROOT), capture_output=True,
            text=True, timeout=timeout,
        )
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, f"[timeout após {timeout}s] {' '.join(argv)}"
    except FileNotFoundError:
        return 127, f"[não encontrado] {argv[0]}"
    except OSError as exc:  # pragma: no cover - erro de ambiente
        return 1, f"[erro] {exc}"


def read_line_var(text: str, key: str) -> str:
    """Lê 'KEY=valor' de uma saída de texto (formato do detect-hardware.sh)."""
    for line in text.splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    return ""


# ---------------------------------------------------------------------------
# Trabalhos (jobs) com log ao vivo
# ---------------------------------------------------------------------------
class Job:
    """Um comando em execução, com saída acumulada para streaming.

    O log é guardado linha a linha porque o front consome por SSE e precisa
    poder RECONECTAR (recarregar a página no meio de um build não pode perder o
    que já saiu).
    """

    def __init__(self, job_id: str, argv: list[str], label: str,
                 cwd: Path | None = None):
        self.id = job_id
        self.argv = argv
        self.label = label
        self.lines: list[str] = []
        self.done = False
        self.rc: int | None = None
        self.started = time.time()
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, args=(cwd,), daemon=True)
        self.thread.start()

    def _emit(self, line: str) -> None:
        with self.lock:
            self.lines.append(line)

    def _run(self, cwd: Path | None) -> None:
        self._emit(f"$ {' '.join(self.argv)}")
        try:
            proc = subprocess.Popen(
                self.argv, cwd=str(cwd or REPO_ROOT),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                self._emit(line.rstrip("\n"))
            rc = proc.wait()
        except FileNotFoundError:
            self._emit(f"[não encontrado] {self.argv[0]}")
            rc = 127
        except OSError as exc:  # pragma: no cover
            self._emit(f"[erro] {exc}")
            rc = 1
        with self.lock:
            self.rc = rc
            self.done = True

    def snapshot(self) -> tuple[list[str], bool, int | None]:
        with self.lock:
            return list(self.lines), self.done, self.rc

    def status(self) -> dict[str, Any]:
        with self.lock:
            return {
                "id": self.id,
                "label": self.label,
                "argv": self.argv,
                "done": self.done,
                "rc": self.rc,
                "lines": len(self.lines),
                "elapsed": round(time.time() - self.started, 1),
            }


JOBS: dict[str, Job] = {}
JOBS_LOCK = threading.Lock()
JOB_SEQ = 0


def new_job(argv: list[str], label: str, cwd: Path | None = None) -> Job:
    global JOB_SEQ
    with JOBS_LOCK:
        JOB_SEQ += 1
        job_id = f"j{JOB_SEQ}"
        job = Job(job_id, argv, label, cwd)
        JOBS[job_id] = job
    # Mantém só os 20 mais recentes (o log vive em memória).
    with JOBS_LOCK:
        if len(JOBS) > 20:
            for old in sorted(JOBS, key=lambda k: int(k[1:]))[:-20]:
                JOBS.pop(old, None)
    return job


def get_job(job_id: str) -> Job | None:
    with JOBS_LOCK:
        return JOBS.get(job_id)


# ---------------------------------------------------------------------------
# Validação de parâmetros (é aqui que a "lista branca" fica sólida)
# ---------------------------------------------------------------------------
class Invalid(Exception):
    """Parâmetro inválido vindo do cliente."""


def v_distro(value: str) -> str:
    if value not in DISTROS:
        raise Invalid(f"distro inválida: {value!r} (use {' ou '.join(DISTROS)})")
    return value


def v_role(value: str) -> str:
    if value not in ROLES:
        raise Invalid(f"papel inválido: {value!r}")
    return value


def v_payload(value: str) -> str:
    if value not in PAYLOADS:
        raise Invalid(f"payload inválido: {value!r}")
    return value


def v_family(value: str) -> str:
    """Aceita 'auto' ou o nome de uma família que EXISTE em families/.

    Lemos o diretório em vez de manter uma lista: assim uma família nova entra
    na UI sozinha, sem ninguém editar o servidor (e sem duas listas divergindo).
    """
    if value == "auto":
        return value
    if not re.fullmatch(r"[a-z0-9-]+", value):
        raise Invalid(f"família com caracteres inválidos: {value!r}")
    if not (REPO_ROOT / "families" / value / "family.conf").is_file():
        raise Invalid(f"família desconhecida: {value!r}")
    return value


def v_disk(value: str) -> str:
    """O disco é apenas GRAVADO na ISO (a instalação acontece no alvo). Ainda
    assim validamos: evita lixo na configuração e qualquer tentativa de injeção."""
    if not RE_DISK.match(value):
        raise Invalid(f"disco inválido: {value!r} (esperado algo como /dev/vda)")
    return value


def v_network_mode(value: str) -> str:
    if value not in NETWORK_MODES:
        raise Invalid(f"modo de rede inválido: {value!r} (use {' ou '.join(NETWORK_MODES)})")
    return value


def v_net_ip(value: str) -> str:
    if not RE_NET_IP.match(value):
        raise Invalid(f"IP inválido: {value!r} (esperado algo como 192.168.1.50/24)")
    if "/" in value:
        prefix = int(value.rsplit("/", 1)[1])
        if not 1 <= prefix <= 32:
            raise Invalid(f"prefixo inválido em {value!r} (use 1..32)")
    return value


def v_gateway(value: str) -> str:
    if not RE_IPV4.match(value):
        raise Invalid(f"gateway inválido: {value!r}")
    return value


def v_username(value: str) -> str:
    """Usuário administrativo (vazio = o build deriva do papel, ADR-002)."""
    if value == "":
        return value
    if not RE_USERNAME.match(value):
        raise Invalid(
            f"usuário inválido: {value!r} (minúsculas, dígitos, '_' e '-'; "
            "começa com letra ou '_'; até 32 caracteres)"
        )
    return value


def v_hostname(value: str) -> str:
    """Hostname (vazio = o build usa o mesmo nome do usuário)."""
    if value == "":
        return value
    if not RE_HOSTNAME.match(value):
        raise Invalid(
            f"hostname inválido: {value!r} (minúsculas, dígitos e '-' entre "
            "eles; até 63 caracteres)"
        )
    return value


def v_iface(value: str) -> str:
    if value == "":
        return value
    if not RE_IFACE.match(value):
        raise Invalid(f"interface inválida: {value!r} (esperado algo como enp5s0)")
    return value


def v_dns(value: str) -> str:
    """Aceita '1.1.1.1,8.8.8.8' (também com espaço) e devolve normalizado."""
    parts = [p for p in re.split(r"[,\s]+", value.strip()) if p]
    if not parts:
        raise Invalid("DNS vazio (informe ao menos um IP)")
    if len(parts) > 4:
        raise Invalid("DNS: no máximo 4 servidores")
    for p in parts:
        if not RE_IPV4.match(p):
            raise Invalid(f"DNS inválido: {p!r}")
    return ",".join(parts)


def v_iso_path(value: str) -> Path:
    """Resolve um caminho de ISO para LEITURA (conferir/verificar).

    Aceita um nome dentro de iso/out ou um caminho absoluto já existente (o
    caso de uma ISO baixada em ~/Downloads). Só leitura, extensão .iso.
    """
    if not value:
        raise Invalid("informe a ISO")
    if value.startswith("/"):
        path = Path(value)
    else:
        if "/" in value or not RE_ISO_NAME.match(value):
            raise Invalid(f"nome de ISO inválido: {value!r}")
        path = ISO_OUT / value
    try:
        path = path.resolve()
    except OSError as exc:
        raise Invalid(f"caminho inválido: {exc}") from exc
    if path.suffix.lower() != ".iso":
        raise Invalid("o arquivo precisa ter extensão .iso")
    if not path.is_file():
        raise Invalid(f"arquivo não encontrado: {path}")
    return path


def v_job_id(value: str) -> str:
    if not re.fullmatch(r"j\d+", value or ""):
        raise Invalid(f"id de job inválido: {value!r}")
    return value


# ---------------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------------
def action_status() -> dict[str, Any]:
    """Estado da máquina — SEM reimplementar detecção: usa o detect-hardware.sh."""
    rc, out = run_capture(["bash", "detect-hardware.sh", "--quiet"])
    family = read_line_var(out, "FAMILY") if rc == 0 else ""
    role = read_line_var(out, "ROLE") if rc == 0 else ""
    gpu = read_line_var(out, "GPU") if rc == 0 else ""

    disk = shutil.disk_usage(REPO_ROOT)
    tools = {t: have(t) for t in ("xorriso", "qemu-system-x86_64", "dd", "lsblk",
                                  "mtools", "mkisofs")}

    isos = []
    if ISO_OUT.is_dir():
        for f in sorted(ISO_OUT.glob("*.iso")):
            try:
                st = f.stat()
            except OSError:
                continue
            isos.append({
                "name": f.name,
                "size_mb": round(st.st_size / 1024 / 1024),
                "mtime": int(st.st_mtime),
                "sha256_file": (f.with_suffix(".iso.sha256")).is_file(),
            })

    return {
        "repo": str(REPO_ROOT),
        "hardware": {"family": family, "role": role, "gpu": gpu,
                     "detect_ok": rc == 0},
        "tools": tools,
        "disk": {"total_mb": round(disk.total / 1024 / 1024),
                 "free_mb": round(disk.free / 1024 / 1024),
                 "free_gb": round(disk.free / 1024 / 1024 / 1024, 1)},
        "isos": isos,
        # O front usa isto para habilitar/desabilitar com MOTIVO visível.
        "can_build": tools["xorriso"],
        "can_verify": tools["xorriso"],
        "can_vm": tools["qemu-system-x86_64"],
    }


def action_options() -> dict[str, Any]:
    """Valores aceitos — lidos do REPOSITÓRIO, não de listas duplicadas."""
    families = ["auto"]
    fam_dir = REPO_ROOT / "families"
    if fam_dir.is_dir():
        families += sorted(
            d.name for d in fam_dir.iterdir()
            if d.is_dir() and (d / "family.conf").is_file()
        )
    mods: list[str] = []
    mod_dir = REPO_ROOT / "mods"
    if mod_dir.is_dir():
        mods = sorted(
            d.name for d in mod_dir.iterdir()
            if d.is_dir() and (d / "mod.conf").is_file()
        )
    return {
        "distros": list(DISTROS),
        "roles": list(ROLES),
        "families": families,
        "payloads": list(PAYLOADS),
        "network_modes": list(NETWORK_MODES),
        "mods": mods,
        # A tabela do ADR-002 vai junto para a página poder SUGERIR o usuário
        # ao escolher o papel (sem impedir outro valor).
        "identity": dict(ROLE_IDENTITY),
        "defaults": {"distro": "ubuntu", "disk": "/dev/vda", "role": "auto",
                     "family": "auto", "payload": "none", "network": "auto",
                     "username": "", "hostname": ""},
    }


def _crypt_hash(pw: str) -> str:
    """Hash crypt SHA-512 da senha.

    A senha do usuário/root da ISO chega do formulário, mas **nunca vai em
    texto puro para a linha de comando nem para o log**: vira hash crypt AQUI,
    em memória, e só o hash entra no `argv` do build-iso.sh.

    Caminho 1: módulo `crypt` da stdlib (Python <= 3.12; o PEP 594 o removeu
    no 3.13). Caminho 2: `openssl passwd -6 -stdin` — a MESMA ferramenta que o
    build-iso.sh exige para gerar a senha dele, com o texto vindo pelo STDIN
    (nunca nos argumentos, onde apareceria em `ps`). Sem nenhum dos dois,
    degrada com motivo explícito (Regra 13-a).
    """
    try:
        import crypt  # stdlib até o Python 3.12

        return crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512))
    except (ImportError, AttributeError):
        pass

    try:
        proc = subprocess.run(
            ["openssl", "passwd", "-6", "-stdin"],
            input=pw, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise Invalid(
            "não consegui gerar o hash crypt da senha (sem o módulo 'crypt' "
            "e sem openssl funcionando) — use o terminal: "
            "`mkpasswd -m sha-512` e passe --password-hash."
        ) from exc
    out = (proc.stdout or "").strip()
    if proc.returncode != 0 or not out.startswith("$6$"):
        raise Invalid(
            "não consegui gerar o hash crypt da senha (openssl recusou) — "
            "use o terminal: `mkpasswd -m sha-512` e passe --password-hash."
        )
    return out


def _password_or_none(raw: Any, label: str) -> str | None:
    """Valida a senha do formulário. Vazio/vazio-ausente = não fornecida."""
    if raw is None:
        return None
    s = str(raw)
    if s == "":
        return None
    if len(s) > 128:
        raise Invalid(f"{label}: máximo de 128 caracteres")
    if any(c in s for c in "\r\n\x00"):
        raise Invalid(f"{label}: contém caracteres inválidos")
    return s


def _iso_args_from(params: dict[str, Any]) -> list[str]:
    """Monta as flags do build-iso.sh a partir do formulário, validando tudo.

    Centralizado de propósito: a mesma montagem serve para o preview (dry-run) e
    para o build real — é o que garante que "o que você simulou é o que vai
    rodar".
    """
    # Base única (ADR-001). O valor continua validado — a UI não pode injetar
    # uma distro arbitrária na linha de comando.
    distro = v_distro(str(params.get("distro", "ubuntu")))
    disk = v_disk(str(params.get("disk", "/dev/vda")))
    role = v_role(str(params.get("role", "auto")))
    family = v_family(str(params.get("family", "auto")))
    payload = v_payload(str(params.get("payload", "none")))
    netmode = v_network_mode(str(params.get("network", "auto")))
    netiface = v_iface(str(params.get("net_iface", "")))
    # Identidade (ADR-002). Campo VAZIO = não passa a flag e o build-iso.sh
    # deriva do papel — o caminho recomendado. Preenchido = o valor explícito
    # vence (é o caso de frota: `ai-inference` com hostname `ai-inference-2`).
    username = v_username(str(params.get("username", "")))
    hostname = v_hostname(str(params.get("hostname", "")))
    args = ["--distro", distro, "--disk", disk, "--role", role,
            "--family", family, "--network", netmode]
    if username:
        args += ["--username", username]
    if hostname:
        args += ["--hostname", hostname]
    if netiface:
        args += ["--network-interface", netiface]
    if netmode == "static":
        # Só no modo static: os campos de IP/gateway são obrigatórios aqui (e
        # o build-iso.sh também recusa static sem eles — defesa em dois níveis).
        args += ["--network-ip", v_net_ip(str(params.get("net_ip", "")))]
        args += ["--network-gateway", v_gateway(str(params.get("net_gateway", "")))]
        args += ["--network-dns", v_dns(str(params.get("net_dns", "1.1.1.1,8.8.8.8")))]
    if payload != "none":
        # air-gapped: fonte + modelo + repositório na mídia
        args += ["--iso-source", "auto", "--iso-model", "auto",
                 "--iso-repo", "auto"]
    # Senhas: vão para o build como HASH crypt, nunca em texto puro (o
    # texto fica só nesta função, em memória). Sem senha de usuário, o
    # build-iso.sh gera uma aleatória e mostra (comportamento de sempre);
    # sem senha de root, o root fica bloqueado.
    user_pw = _password_or_none(params.get("user_password"), "Senha do usuário")
    root_pw = _password_or_none(params.get("root_password"), "Senha do root")
    if user_pw is not None:
        args += ["--password-hash", _crypt_hash(user_pw)]
    if root_pw is not None:
        args += ["--root-password-hash", _crypt_hash(root_pw)]
    return (args, distro, disk, role, family, payload, netmode,
            bool(user_pw), bool(root_pw))


def action_preview(params: dict[str, Any]) -> dict[str, Any]:
    args, distro, disk, role, family, payload, netmode, has_user_pw, has_root = \
        _iso_args_from(params)
    argv = ["bash", "iso/build-iso.sh", *args, "--dry-run", "--yes"]
    job = new_job(argv, f"Simulação ({distro} · {role} · {family} · rede {netmode})")
    return {"job": job.id, "argv": argv,
            "summary": {"distro": distro, "disk": disk, "role": role,
                        "family": family, "payload": payload, "network": netmode,
                        "user_password": has_user_pw, "root": has_root}}


def action_build(params: dict[str, Any]) -> dict[str, Any]:
    if not have("xorriso"):
        # Degrada com MOTIVO em vez de falhar de um jeito confuso.
        raise Invalid(
            "xorriso não está instalado nesta máquina — gerar a ISO aqui é "
            "impossível. Use a seção 'Gerar no GitHub Actions' desta página: "
            "o CI faz o build e você baixa o artifact."
        )
    args, distro, disk, role, family, payload, netmode, has_user_pw, has_root = \
        _iso_args_from(params)
    out = ISO_OUT / f"ai-cpu-os-{distro}.iso"
    argv = ["bash", "iso/build-iso.sh", *args, "--yes", "--out", str(out)]
    job = new_job(argv, f"Gerando a ISO ({distro} · {role} · {family})")
    return {"job": job.id, "argv": argv, "out": str(out)}


def action_iso_check(params: dict[str, Any]) -> dict[str, Any]:
    path = v_iso_path(str(params.get("iso", "")))
    job = new_job(["bash", "iso/check-iso.sh", "--iso", str(path)],
                  f"Conferindo {path.name}")
    return {"job": job.id}


def action_iso_verify(params: dict[str, Any]) -> dict[str, Any]:
    if not have("xorriso"):
        raise Invalid(
            "conferir o CONTEÚDO da ISO exige xorriso (ele abre a imagem). "
            "Nesta máquina use a conferência básica, que usa dd/od/sha256sum."
        )
    path = v_iso_path(str(params.get("iso", "")))
    job = new_job(["bash", "iso/verify-iso.sh", "--iso", str(path)],
                  f"Verificando {path.name}")
    return {"job": job.id}


def action_pendrives() -> dict[str, Any]:
    """Lista dispositivos usando o SCRIPT do projeto (mesmas travas)."""
    rc, out = run_capture(["bash", "iso/write-pendrive.sh", "--list"])
    return {"rc": rc, "output": out}


# ---------------------------------------------------------------------------
# Servidor HTTP
# ---------------------------------------------------------------------------
INDEX = WEBUI_DIR / "index.html"


class Handler(BaseHTTPRequestHandler):
    server_version = "ai-cpu-os-webui/1.0"

    # Silencia o log de cada requisição (o padrão polui o terminal).
    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        pass

    # -- respostas utilitárias -------------------------------------------------
    def _json(self, obj: Any, code: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _html(self, path: Path) -> None:
        try:
            body = path.read_bytes()
        except OSError:
            self.send_error(404, "index.html não encontrado")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        if length > 64 * 1024:
            raise Invalid("corpo grande demais")
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise Invalid(f"JSON inválido: {exc}") from exc
        if not isinstance(data, dict):
            raise Invalid("o corpo precisa ser um objeto JSON")
        return data

    # -- verbos -----------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        route = url.path

        if route in ("/", "/index.html"):
            self._html(INDEX)
            return

        if route == "/api/status":
            self._json(action_status())
            return

        if route == "/api/options":
            self._json(action_options())
            return

        if route == "/api/pendrives":
            self._json(action_pendrives())
            return

        m = re.fullmatch(r"/api/jobs/([^/]+)", route)
        if m:
            try:
                job = get_job(v_job_id(m.group(1)))
            except Invalid as exc:
                self._json({"error": str(exc)}, 400)
                return
            if not job:
                self._json({"error": "job não encontrado"}, 404)
                return
            self._json(job.status())
            return

        m = re.fullmatch(r"/api/jobs/([^/]+)/events", route)
        if m:
            try:
                job = get_job(v_job_id(m.group(1)))
            except Invalid as exc:
                self._json({"error": str(exc)}, 400)
                return
            if not job:
                self._json({"error": "job não encontrado"}, 404)
                return
            self._stream(job)
            return

        self._json({"error": "rota não encontrada"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        route = url.path
        if not route.startswith("/api/"):
            self._json({"error": "rota não encontrada"}, 404)
            return
        try:
            params = self._read_json()
        except Invalid as exc:
            self._json({"error": str(exc)}, 400)
            return

        try:
            if route == "/api/preview":
                self._json(action_preview(params))
            elif route == "/api/build":
                self._json(action_build(params))
            elif route == "/api/iso-check":
                self._json(action_iso_check(params))
            elif route == "/api/iso-verify":
                self._json(action_iso_verify(params))
            else:
                self._json({"error": "rota não encontrada"}, 404)
        except Invalid as exc:
            # 400: o pedido é do usuário e é corrigível.
            self._json({"error": str(exc)}, 400)
        except Exception as exc:  # pragma: no cover - salvaguarda
            self._json({"error": f"erro interno: {exc}"}, 500)

    # -- streaming (SSE) --------------------------------------------------------
    def _stream(self, job: Job) -> None:
        """Manda o log acumulado e depois cada linha nova, até o job terminar.

        SSE em vez de WebSocket de propósito: é uma conexão HTTP comum (não
        precisa de biblioteca no cliente nem handshake) e reconecta sozinho.
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        sent = 0
        try:
            while True:
                lines, done, rc = job.snapshot()
                while sent < len(lines):
                    payload = json.dumps(lines[sent], ensure_ascii=False)
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    sent += 1
                    self.wfile.flush()
                if done:
                    self.wfile.write(
                        f"event: done\ndata: {json.dumps({'rc': rc})}\n\n"
                        .encode("utf-8"))
                    self.wfile.flush()
                    return
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            # O usuário fechou a aba: não é erro. O job continua rodando; o
            # log permanece disponível em /api/jobs/<id>.
            return


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Interface web local do ai-cpu-os (gera, confere e grava a ISO).")
    ap.add_argument("--host", default="127.0.0.1",
                    help="endereço de escuta (padrão: 127.0.0.1, só local)")
    ap.add_argument("--port", type=int, default=8787,
                    help="porta (0 = escolhe uma livre; padrão: 8787)")
    ap.add_argument("--no-browser", action="store_true",
                    help="não tenta abrir o navegador")
    args = ap.parse_args(argv)

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        # Amarrar em 0.0.0.0 exporia uma interface que gera ISO e mexe em
        # dispositivo na rede local. Não fazemos isso por padrão — e avisamos.
        print("[aviso] escutando em um endereço NÃO local: "
              f"{args.host}. A interface executa builds e lê dispositivos; "
              "exponha só se souber o que isso significa.", file=sys.stderr)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    port = httpd.server_address[1]
    url = f"http://{args.host}:{port}/"

    # A linha PORT= facilita o teste automatizado (porta 0 = aleatória).
    # `flush=True` é obrigatório: com a saída redirecionada (pipe/arquivo) o
    # stdout fica em buffer de BLOCO, e quem espera ler "PORT=" só receberia no
    # fim — o teste subia o servidor e achava que ele não tinha subido.
    print(f"PORT={port}", flush=True)
    print(f"ai-cpu-os · interface web local: {url}", flush=True)
    print(f"repositório: {REPO_ROOT}", flush=True)
    if not have("xorriso"):
        print("[aviso] xorriso ausente: gerar a ISO nesta máquina não é possível. "
              "A página mostra o caminho pelo GitHub Actions.", flush=True)
    print("Ctrl+C para encerrar.", flush=True)

    if not args.no_browser and args.host in ("127.0.0.1", "localhost"):
        threading.Thread(
            target=lambda: (time.sleep(0.6), webbrowser.open(url)),
            daemon=True,
        ).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nencerrando…")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
