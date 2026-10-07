#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
shell-ia.py — Shell de IA em linguagem natural para o perfil xeon do ai-cpu-os.

Este script recebe comandos em linguagem natural, envia ao llama-server
(backend llama.cpp exposto via HTTP) e executa ferramentas SEGURAS quando o
modelo solicita, com sandbox básico:

  * Rodam como usuário não-root (o serviço é systemd com User=llama).
  * Não usam shell=True — comandos são executados com lista de argumentos.
  * Comandos do sistema passam por uma WHITELIST explícita.
  * Leitura de arquivos restrita a diretórios permitidos (ALLOWED_ROOTS).
  * Timeout em toda execução.

Protocolo de ferramentas (simples e robusto, sem dependências externas):

    O modelo responde normalmente, e quando quer usar uma ferramenta emite,
    em uma linha própria:

        TOOL: <nome> <json>

    Exemplo:
        TOOL: list_dir {"path": "."}
        TOOL: read_file {"path": "nota.txt"}
        TOOL: run_command {"argv": ["uptime"]}

    O resultado é realimentado ao modelo como:

        RESULT: <nome>
        <saída>

Requisitos: apenas biblioteca padrão do Python 3.
Configuração por variáveis de ambiente:
    AI_SERVER_URL   (padrão http://127.0.0.1:8080)
    AI_MODEL        (padrão "local")
    AI_ALLOWED_ROOTS (separadas por ':', padrão "/opt/models:${HOME}")
    AI_CMD_TIMEOUT  (padrão 15 segundos)
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
AI_SERVER_URL = os.environ.get("AI_SERVER_URL", "http://127.0.0.1:8080").rstrip("/")
AI_MODEL = os.environ.get("AI_MODEL", "local")
CMD_TIMEOUT = int(os.environ.get("AI_CMD_TIMEOUT", "15"))

_DEFAULT_ROOTS = ":".join(
    p for p in ("/opt/models", os.path.expanduser("~"), "/tmp/ai-shell") if p
)
ALLOWED_ROOTS = [
    Path(p).resolve()
    for p in os.environ.get("AI_ALLOWED_ROOTS", _DEFAULT_ROOTS).split(":")
    if p.strip()
]

# WHITELIST: apenas o primeiro argumento (programa) é verificado.
# NUNCA adicione comandos destrutivos (rm, dd, mkfs, shutdown, ...) sem
# consciência plena — consulte docs/TROUBLESHOOTING.md antes.
COMMAND_WHITELIST = {
    "ls", "cat", "head", "tail", "wc", "grep", "find", "tree",
    "uptime", "free", "df", "du", "lscpu", "nproc", "uname", "whoami",
    "date", "echo", "pwd", "stat", "file", "which",
    "systemctl", "journalctl",
    "llama-bench", "llama-cli",
    "git", "python3", "pip3",
    "ps", "top",
}
# Argumentos bloqueados mesmo em comandos permitidos (fuga de sandbox).
BLOCKED_ARG_TOKENS = {"sudo", "su", "rm", "mkfs", "dd", "shutdown", "reboot", "chmod", "chown"}

# ---------------------------------------------------------------------------
# Cores / logs
# ---------------------------------------------------------------------------
def _c(code: str) -> str:
    return code if sys.stdout.isatty() else ""

C_RESET, C_INFO, C_WARN, C_ERR, C_OK, C_DIM = _c("\033[0m"), _c("\033[36m"), _c("\033[33m"), _c("\033[31m"), _c("\033[32m"), _c("\033[2m")

def log_info(msg: str) -> None:
    print(f"{C_INFO}[i]{C_RESET} {msg}")

def log_warn(msg: str) -> None:
    print(f"{C_WARN}[warn]{C_RESET} {msg}", file=sys.stderr)

def log_error(msg: str) -> None:
    print(f"{C_ERR}[err]{C_RESET} {msg}", file=sys.stderr)

# ---------------------------------------------------------------------------
# Sandbox: validação de caminhos
# ---------------------------------------------------------------------------
class SandboxError(Exception):
    """Levantada quando uma operação viola o sandbox."""

def _is_within_allowed(path: Path) -> bool:
    rp = path.resolve()
    for root in ALLOWED_ROOTS:
        try:
            rp.relative_to(root)
            return True
        except ValueError:
            continue
    return False

def resolve_path(raw: str) -> Path:
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = (Path.cwd() / p).resolve()
    if not _is_within_allowed(p):
        raise SandboxError(
            f"Caminho fora das raízes permitidas: {p} "
            f"(permitidas: {', '.join(str(r) for r in ALLOWED_ROOTS)})"
        )
    return p

# ---------------------------------------------------------------------------
# Ferramentas
# ---------------------------------------------------------------------------
def tool_list_dir(args: dict[str, Any]) -> str:
    p = resolve_path(str(args.get("path", ".")))
    if not p.exists():
        return f"ERRO: caminho não existe: {p}"
    if not p.is_dir():
        return f"ERRO: não é um diretório: {p}"
    entries = sorted(p.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower()))
    lines = []
    for e in entries:
        tag = "dir " if e.is_dir() else "file"
        size = "" if e.is_dir() else f"{e.stat().st_size:>10} B"
        lines.append(f"{tag}  {size}  {e.name}")
    return "\n".join(lines) if lines else "(diretório vazio)"

def tool_read_file(args: dict[str, Any]) -> str:
    p = resolve_path(str(args.get("path", "")))
    if not p.exists():
        return f"ERRO: arquivo não existe: {p}"
    if not p.is_file():
        return f"ERRO: não é um arquivo: {p}"
    max_bytes = int(args.get("max_bytes", 65536))
    data = p.read_bytes()[:max_bytes]
    try:
        text = data.decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        text = repr(data)
    if p.stat().st_size > max_bytes:
        text += f"\n... [truncado em {max_bytes} bytes]"
    return text

def tool_search_files(args: dict[str, Any]) -> str:
    root = resolve_path(str(args.get("path", ".")))
    pattern = str(args.get("pattern", ""))
    if not pattern:
        return "ERRO: 'pattern' é obrigatório."
    cmd = ["grep", "-rn", "--", pattern, str(root)]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=CMD_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        return "ERRO: busca excedeu o tempo limite."
    result = (out.stdout or "").strip()
    if not result and out.stderr:
        return f"ERRO: {out.stderr.strip()}"
    return result[:8192] if result else "(nenhuma correspondência)"

def tool_run_command(args: dict[str, Any]) -> str:
    argv = args.get("argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv) or not argv:
        return "ERRO: 'argv' deve ser uma lista não vazia de strings."
    program = os.path.basename(argv[0])
    if program not in COMMAND_WHITELIST:
        return (
            f"ERRO: comando '{program}' não está na whitelist.\n"
            f"Permitidos: {', '.join(sorted(COMMAND_WHITELIST))}"
        )
    for tok in argv[1:]:
        if tok in BLOCKED_ARG_TOKENS:
            return f"ERRO: argumento bloqueado pelo sandbox: '{tok}'"
    try:
        out = subprocess.run(
            argv, capture_output=True, text=True, timeout=CMD_TIMEOUT,
            check=False, shell=False,
        )
    except FileNotFoundError:
        return f"ERRO: comando não encontrado: {program}"
    except subprocess.TimeoutExpired:
        return f"ERRO: comando excedeu {CMD_TIMEOUT}s."
    body = (out.stdout or "") + (("\n[stderr]\n" + out.stderr) if out.stderr else "")
    return body.strip()[:8192] or f"(sem saída; exit={out.returncode})"

TOOLS: dict[str, Callable[[dict[str, Any]], str]] = {
    "list_dir": tool_list_dir,
    "read_file": tool_read_file,
    "search_files": tool_search_files,
    "run_command": tool_run_command,
}

# ---------------------------------------------------------------------------
# Backend llama.cpp (endpoint compatível com OpenAI)
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """Você é o shell-IA do ai-cpu-os, rodando em um Intel Xeon E5-2678 v3 (12c/24t, AVX2).

Você ajuda o usuário a operar o sistema. Quando precisar de informação do
sistema, use ferramentas emitindo UMA linha no formato:

TOOL: <nome> <json>

Ferramentas disponíveis:
- list_dir {"path": "."}                     lista um diretório
- read_file {"path": "arquivo.txt"}          lê um arquivo (sandbox)
- search_files {"path": ".", "pattern": "x"} busca texto
- run_command {"argv": ["uptime"]}           executa comando da whitelist

Regras:
- Emita no máximo uma TOOL por resposta.
- Após receber "RESULT:", use o resultado para responder ao usuário.
- Nunca invente resultados de ferramentas.
- Responda de forma concisa e em português.
"""

def _post_json(url: str, payload: dict[str, Any], timeout: int = 120) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        return json.loads(resp.read().decode("utf-8"))

def chat(messages: list[dict[str, str]]) -> str:
    """Envia o histórico ao llama-server e retorna o texto do assistente."""
    url = f"{AI_SERVER_URL}/v1/chat/completions"
    payload = {
        "model": AI_MODEL,
        "messages": messages,
        "temperature": 0.2,
        "stream": False,
    }
    try:
        resp = _post_json(url, payload)
    except urllib.error.URLError as exc:
        raise RuntimeError(
            f"Não foi possível contatar o llama-server em {url}: {exc}\n"
            "Verifique: sudo systemctl status ai-server && curl -s "
            f"{AI_SERVER_URL}/health"
        ) from exc
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"llama-server retornou HTTP {exc.code}: {exc.reason}") from exc

    choices = resp.get("choices") or []
    if not choices:
        return ""
    return (choices[0].get("message") or {}).get("content", "") or ""

def parse_tool_call(text: str) -> tuple[str, dict[str, Any]] | None:
    """Procura por uma linha 'TOOL: <nome> <json>' e a interpreta."""
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("TOOL:"):
            continue
        rest = stripped[len("TOOL:"):].strip()
        # Nome + resto JSON
        parts = rest.split(None, 1)
        if not parts:
            return None
        name = parts[0]
        raw_json = parts[1] if len(parts) > 1 else "{}"
        try:
            args = json.loads(raw_json)
        except json.JSONDecodeError:
            # Tenta corrigir aspas simples comuns de LLM (fallback pragmático).
            try:
                args = json.loads(raw_json.replace("'", '"'))
            except json.JSONDecodeError:
                return None
        if not isinstance(args, dict):
            return None
        return name, args
    return None

# ---------------------------------------------------------------------------
# Loop principal
# ---------------------------------------------------------------------------
def run_once(prompt: str, messages: list[dict[str, str]], verbose: bool = False) -> str:
    messages.append({"role": "user", "content": prompt})
    max_tool_rounds = 3
    for _ in range(max_tool_rounds):
        reply = chat(messages)
        if verbose:
            print(f"{C_DIM}[debug] resposta bruta do modelo:{C_RESET}\n{reply}")
        messages.append({"role": "assistant", "content": reply})

        call = parse_tool_call(reply)
        if not call:
            return reply

        name, args = call
        tool = TOOLS.get(name)
        if tool is None:
            result = f"ERRO: ferramenta desconhecida: {name}"
        else:
            try:
                result = tool(args)
            except SandboxError as exc:
                result = f"ERRO (sandbox): {exc}"
            except Exception as exc:  # noqa: BLE001
                result = f"ERRO ao executar {name}: {exc}"

        log_info(f"ferramenta '{name}' executada ({len(result)} bytes de saída).")
        messages.append({"role": "user", "content": f"RESULT: {name}\n{result}"})

    # Esgotou as rodadas de ferramentas.
    return messages[-1].get("content", "") or "(limite de ferramentas atingido)"

def interactive(messages: list[dict[str, str]], verbose: bool = False) -> int:
    log_info(f"shell-IA pronto. Backend: {AI_SERVER_URL}")
    log_info(f"Raízes permitidas: {', '.join(str(r) for r in ALLOWED_ROOTS)}")
    log_info("Digite 'sair' ou Ctrl-D para terminar.")
    try:
        while True:
            try:
                line = input(f"{C_OK}você>{C_RESET} ")
            except EOFError:
                print()
                break
            if line.strip().lower() in {"sair", "exit", "quit"}:
                break
            if not line.strip():
                continue
            try:
                answer = run_once(line, messages, verbose=verbose)
            except RuntimeError as exc:
                log_error(str(exc))
                continue
            print(f"{C_INFO}ia>{C_RESET} {answer}\n")
    except KeyboardInterrupt:
        print()
    log_info("Até logo.")
    return 0

def main() -> int:
    parser = argparse.ArgumentParser(description="Shell-IA do ai-cpu-os (perfil xeon).")
    parser.add_argument("-p", "--prompt", help="Executa um único prompt e sai.")
    parser.add_argument("-v", "--verbose", action="store_true", help="Mostra a resposta bruta do modelo.")
    parser.add_argument("--url", help="Sobrescreve AI_SERVER_URL.")
    args = parser.parse_args()

    global AI_SERVER_URL  # noqa: PLW0603
    if args.url:
        AI_SERVER_URL = args.url.rstrip("/")

    messages: list[dict[str, str]] = [{"role": "system", "content": SYSTEM_PROMPT}]

    if args.prompt:
        try:
            print(run_once(args.prompt, messages, verbose=args.verbose))
        except RuntimeError as exc:
            log_error(str(exc))
            return 1
        return 0

    return interactive(messages, verbose=args.verbose)

if __name__ == "__main__":
    sys.exit(main())
