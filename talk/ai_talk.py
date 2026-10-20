#!/usr/bin/env python3
"""
talk/ai_talk.py — `ai-talk`: o chat da frota do ai-cpu-os (fase F1).

Contrato: docs/CHAT.md (§5.2 teto de 15 nós, §6.7 latência/espaçamento,
§6.8 durabilidade). Este arquivo implementa transporte, CLI e regras de tempo;
a integração com a ISO é a fase F2.

Regras que NÃO podem ser quebradas:
  * somente biblioteca padrão (sem pip, sem broker, sem talkd);
  * mensagem é DADO, nunca comando — nada aqui executa shell;
  * sem chave, o daemon não inicia (fail closed);
  * `ack` só depois do `fsync` (o ack significa "está no disco");
  * acima de 15 peers o config é recusado (ADR-005): relay/hub é outro passo.

Uso:
  ai-talk serve --config /etc/ai-talk/config.json
  ai-talk status | peers | check-config
  ai-talk send <peer|'*'> "mensagem"
  ai-talk listen [--from <peer>]
  ai-talk tail [-n N] [-f]
  ai-talk ping <peer>
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import queue
import socket
import stat
import sys
import threading
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timezone

VERSION = "0.1.0"
PROTO_V = 1

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_PEER = 3
EXIT_AUTH = 4
EXIT_LIMIT = 5

MAX_PEERS = 15           # ADR-005: teto de malha completa
MAX_FRAME = 16384        # §6.1
MAX_BODY = 8192          # §6.1
TS_WINDOW_S = 300        # ±5 min (§9)

DEFAULTS = {
    "node": socket.gethostname(),
    "role": "auto",
    "listen": {"address": "127.0.0.1", "port": 7331},
    "control_socket": "/run/ai-talk/control.sock",
    "key_file": "/etc/ai-talk/fleet.key",
    "peers": {},
    "log": {
        "path": "/var/lib/ai-talk/messages.jsonl",
        "max_bytes": 33554432,
        "keep": 5,
        "control": False,
        "fsync": "always",
        "fsync_interval_ms": 100,
    },
    "limits": {
        "max_frame_bytes": MAX_FRAME,
        "max_body_bytes": MAX_BODY,
        "dedupe_window": 8192,
        "max_out_per_sec": 120,
    },
    "timing": {
        "min_interval_ms": 50,
        "queue_max": 256,
        "send_timeout_ms": 15000,
        "connect_timeout_ms": 1000,
        "ack_timeout_ms": 2000,
        "max_attempts": 3,
        "backoff_ms": [1000, 2000],
        "tail_poll_ms": 250,
    },
    "agent": {"enabled": False},
}


class ConfigError(Exception):
    """Config inválida — exit 2, sempre com mensagem clara."""


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def _merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def load_config(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except FileNotFoundError:
        raise ConfigError(f"config não encontrado: {path}")
    except json.JSONDecodeError as exc:
        raise ConfigError(f"config não é JSON válido: {exc}")
    if not isinstance(raw, dict):
        raise ConfigError("config deve ser um objeto JSON")

    cfg = _merge(DEFAULTS, raw)
    peers = cfg.get("peers") or {}
    if not isinstance(peers, dict):
        raise ConfigError("'peers' deve ser um objeto {nome: endereço}")
    if len(peers) > MAX_PEERS:
        raise ConfigError(
            f"{len(peers)} peers excedem o teto de {MAX_PEERS} (ADR-005); "
            "acima disso é preciso relay/hub"
        )
    if not cfg.get("node"):
        raise ConfigError("'node' vazio")
    port = cfg["listen"].get("port", 7331)
    if not isinstance(port, int) or not 0 <= port <= 65535:
        raise ConfigError(f"porta inválida: {port!r}")
    for name, peer in peers.items():
        if not isinstance(peer, (str, dict)):
            raise ConfigError(f"peer '{name}' deve ser string ou objeto")
        if isinstance(peer, dict) and not peer.get("addr"):
            raise ConfigError(f"peer '{name}' sem 'addr'")
    if not isinstance(cfg["timing"].get("backoff_ms"), list):
        raise ConfigError("'timing.backoff_ms' deve ser uma lista")
    return cfg


def peer_addr(peer) -> str:
    return peer if isinstance(peer, str) else peer["addr"]


def peer_key_file(cfg: dict, name: str):
    peer = cfg["peers"].get(name) or {}
    return peer.get("key_file") if isinstance(peer, dict) else None


def parse_addr(addr: str):
    if addr.startswith("["):
        host, _, rest = addr[1:].partition("]")
        return host, int(rest.lstrip(":")) if rest else 7331
    if addr.count(":") == 1:
        host, port = addr.split(":")
        return host, int(port)
    return addr, 7331


# ---------------------------------------------------------------------------
# Chaves e assinatura (§6.3)
# ---------------------------------------------------------------------------
def read_key(path: str) -> bytes:
    if not path:
        raise ConfigError("chave ausente: configure 'key_file'")
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise ConfigError(f"chave não encontrada: {path}")
    except PermissionError:
        raise ConfigError(f"sem permissão para ler a chave: {path}")
    if not stat.S_ISREG(st.st_mode):
        raise ConfigError(f"chave não é um arquivo regular: {path}")
    if st.st_mode & stat.S_IROTH:
        raise ConfigError(f"chave legível por 'outros': {path} (use 0640)")
    with open(path, "rb") as handle:
        data = handle.read()
    text = data.strip()
    if len(text) == 64:
        try:
            data = bytes.fromhex(text.decode("ascii"))
        except (ValueError, UnicodeDecodeError):
            pass
    if len(data) < 16:
        raise ConfigError(f"chave curta demais ({len(data)} bytes): {path}")
    return data


def canonical(env: dict) -> bytes:
    parts = [
        str(env.get("v", PROTO_V)),
        str(env.get("id", "")),
        str(env.get("ts", "")),
        str(env.get("from", "")),
        str(env.get("to", "")),
        str(env.get("kind", "")),
        str(env.get("reply_to") or ""),
        str(env.get("body", "")),
    ]
    return "\n".join(parts).encode("utf-8")


def sign(env: dict, key: bytes) -> str:
    return hmac.new(key, canonical(env), hashlib.sha256).hexdigest()


def verify(env: dict, key: bytes) -> bool:
    return hmac.compare_digest(str(env.get("sig", "")), sign(env, key))


def now_ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ts_ok(value: str) -> bool:
    try:
        when = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except (TypeError, ValueError):
        return False
    return abs(time.time() - when.timestamp()) <= TS_WINDOW_S


# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------
def encode_line(obj: dict) -> bytes:
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"


def recv_line(sock: socket.socket, max_bytes: int) -> bytes:
    """Lê UMA linha, com teto. Levanta ValueError se passar do teto."""
    chunks = []
    total = 0
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            return b"".join(chunks) if chunks else b""
        newline = chunk.find(b"\n")
        if newline >= 0:
            total += newline
            if total > max_bytes:
                raise ValueError("frame grande demais")
            chunks.append(chunk[:newline])
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            raise ValueError("frame grande demais")


# ---------------------------------------------------------------------------
# Log (§6.8)
# ---------------------------------------------------------------------------
class MessageLog:
    def __init__(self, cfg: dict):
        self.path = cfg["log"]["path"]
        self.max_bytes = int(cfg["log"]["max_bytes"])
        self.keep = int(cfg["log"]["keep"])
        self.control = bool(cfg["log"]["control"])
        self.mode = str(cfg["log"].get("fsync", "always"))
        self.lock = threading.Lock()
        self.handle = None

    def _open(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        self.handle = open(self.path, "ab", buffering=0)

    def _rotate(self):
        if self.handle:
            self.handle.close()
            self.handle = None
        for index in range(self.keep - 1, 0, -1):
            src = f"{self.path}.{index}"
            if os.path.exists(src):
                os.replace(src, f"{self.path}.{index + 1}")
        if os.path.exists(self.path):
            os.replace(self.path, f"{self.path}.1")
        self._open()

    def append(self, entry: dict) -> None:
        if entry.get("kind") != "msg" and not self.control:
            return
        line = encode_line(entry)
        with self.lock:
            if self.handle is None:
                self._open()
            if os.fstat(self.handle.fileno()).st_size + len(line) > self.max_bytes:
                self._rotate()
            self.handle.write(line)
            if self.mode == "always":
                os.fsync(self.handle.fileno())

    def close(self):
        with self.lock:
            if self.handle:
                self.handle.close()
                self.handle = None


# ---------------------------------------------------------------------------
# Peer de saída: fila, espaçamento, ack e retry
# ---------------------------------------------------------------------------
class Result:
    __slots__ = ("code", "msg", "done")

    def __init__(self, code=None, msg=""):
        self.code = code
        self.msg = msg
        self.done = threading.Event()
        if code is not None:
            self.done.set()

    def finish(self, code, msg=""):
        self.code = code
        self.msg = msg
        self.done.set()

    def wait(self, seconds):
        self.done.wait(seconds)
        return self.code, self.msg


class PeerLink:
    def __init__(self, daemon: "Daemon", name: str):
        self.daemon = daemon
        self.name = name
        self.addr = peer_addr(daemon.cfg["peers"][name])
        self.lock = threading.Lock()
        self.sock = None
        self.pending = 0
        self.next_allowed = 0.0
        self.last_error = ""
        self.connected = False
        self.queue: "queue.Queue" = queue.Queue()
        threading.Thread(target=self._run, name=f"out-{name}", daemon=True).start()

    def _connect(self) -> socket.socket:
        host, port = parse_addr(self.addr)
        timeout = self.daemon.cfg["timing"]["connect_timeout_ms"] / 1000.0
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        self.connected = True
        return sock

    def _drop(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.connected = False

    def enqueue(self, env: dict) -> Result:
        timing = self.daemon.cfg["timing"]
        with self.lock:
            if self.pending >= int(timing["queue_max"]):
                return Result(EXIT_LIMIT, f"rate limit: fila cheia ({timing['queue_max']})")
            if not self.daemon.take_global_token():
                return Result(EXIT_LIMIT, "rate limit: teto global de saída")
            self.pending += 1
            result = Result()
            self.queue.put((env, result))
        return result

    def _run(self):
        while True:
            env, result = self.queue.get()
            try:
                code, msg = self._deliver(env)
            except Exception as exc:  # a thread não pode morrer
                code, msg = EXIT_ERROR, f"erro interno: {exc}"
            result.finish(code, msg)
            with self.lock:
                self.pending -= 1
            self.queue.task_done()

    def _wait_turn(self):
        interval = int(self.daemon.cfg["timing"]["min_interval_ms"]) / 1000.0
        with self.lock:
            due = max(time.time(), self.next_allowed)
            self.next_allowed = due + interval
        delay = due - time.time()
        if delay > 0:
            time.sleep(delay)

    def _deliver(self, env: dict):
        timing = self.daemon.cfg["timing"]
        attempts = max(1, int(timing["max_attempts"]))
        ack_timeout = int(timing["ack_timeout_ms"]) / 1000.0
        backoff = [float(x) / 1000.0 for x in timing["backoff_ms"]]
        if env.get("kind") in ("msg", "ping"):
            self._wait_turn()
        refused = False

        for attempt in range(attempts):
            if attempt and attempt - 1 < len(backoff):
                time.sleep(backoff[attempt - 1])
            try:
                sock = self.sock if self.sock else self._connect()
                sock.settimeout(ack_timeout)
                sock.sendall(encode_line(env))
                line = recv_line(sock, MAX_FRAME)
                if not line:
                    raise ConnectionResetError("conexão fechada")
                ack = json.loads(line.decode("utf-8"))
                if ack.get("kind") != "ack" or ack.get("reply_to") != env.get("id"):
                    continue
                self.last_error = ""
                return EXIT_OK, "ok"
            except ConnectionRefusedError:
                refused = True
                self.last_error = "conexão recusada"
                break
            except (socket.timeout, TimeoutError):
                self.last_error = "sem ack (timeout)"
                self._drop()
            except (ConnectionResetError, BrokenPipeError, OSError) as exc:
                self.last_error = f"falha de conexão: {exc}"
                self._drop()
            except (ValueError, json.JSONDecodeError):
                self.last_error = "resposta inválida do peer"
                self._drop()

        if refused:
            return EXIT_PEER, f"peer {self.name} offline (conexão recusada)"
        return EXIT_PEER, f"peer {self.name} sem ack ({self.last_error or 'timeout'})"

    def stop(self):
        self._drop()


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------
class Daemon:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.node = cfg["node"]
        self.key = read_key(cfg["key_file"])
        self.log = MessageLog(cfg)
        self.dedupe: "OrderedDict[str, None]" = OrderedDict()
        self.dedupe_max = int(cfg["limits"]["dedupe_window"])
        self.started = time.time()
        self.links = {name: PeerLink(self, name) for name in cfg["peers"]}
        self.subscribers = []
        self.sub_lock = threading.Lock()
        self.token_lock = threading.Lock()
        self.tokens = float(cfg["limits"]["max_out_per_sec"])
        self.token_ts = time.time()
        self.counters = {"sent": 0, "received": 0, "rejected": 0, "duplicated": 0}
        self.counters_lock = threading.Lock()
        self.stop_event = threading.Event()

    def take_global_token(self) -> bool:
        rate = float(self.cfg["limits"]["max_out_per_sec"])
        if rate <= 0:
            return True
        with self.token_lock:
            now = time.time()
            self.tokens = min(rate, self.tokens + (now - self.token_ts) * rate)
            self.token_ts = now
            if self.tokens < 1:
                return False
            self.tokens -= 1
            return True

    def bump(self, key: str):
        with self.counters_lock:
            self.counters[key] = self.counters.get(key, 0) + 1

    def seen(self, msg_id: str) -> bool:
        if msg_id in self.dedupe:
            self.dedupe.move_to_end(msg_id)
            return True
        self.dedupe[msg_id] = None
        while len(self.dedupe) > self.dedupe_max:
            self.dedupe.popitem(last=False)
        return False

    def _peer_key(self, name: str) -> bytes:
        path = peer_key_file(self.cfg, name)
        return read_key(path) if path else self.key

    def _ack(self, sock, to, reply_to):
        env = {
            "v": PROTO_V, "id": str(uuid.uuid4()), "ts": now_ts(),
            "from": self.node, "to": to, "kind": "ack",
            "body": "", "reply_to": reply_to, "sig": "",
        }
        env["sig"] = sign(env, self.key)
        sock.sendall(encode_line(env))

    def handle_conn(self, sock: socket.socket):
        max_frame = int(self.cfg["limits"]["max_frame_bytes"])
        max_body = int(self.cfg["limits"]["max_body_bytes"])
        try:
            sock.settimeout(120)
            while not self.stop_event.is_set():
                try:
                    line = recv_line(sock, max_frame)
                except ValueError:
                    self.bump("rejected")
                    return
                if not line:
                    return
                try:
                    env = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    self.bump("rejected")
                    return
                if not isinstance(env, dict):
                    self.bump("rejected")
                    return
                if self.process(env, sock, max_body) != EXIT_OK:
                    return
        except (socket.timeout, ConnectionResetError, OSError):
            return
        finally:
            try:
                sock.close()
            except OSError:
                pass

    def process(self, env: dict, sock, max_body: int) -> int:
        sender = env.get("from")
        if sender not in self.cfg["peers"]:
            self.bump("rejected")
            return EXIT_AUTH
        if env.get("v") != PROTO_V or not ts_ok(str(env.get("ts", ""))):
            self.bump("rejected")
            return EXIT_AUTH
        try:
            key = self._peer_key(sender)
        except ConfigError:
            self.bump("rejected")
            return EXIT_AUTH
        if not verify(env, key):
            self.bump("rejected")
            return EXIT_AUTH
        body = str(env.get("body", ""))
        if len(body.encode("utf-8")) > max_body:
            self.bump("rejected")
            return EXIT_LIMIT

        kind = env.get("kind")
        if kind in ("hello", "ping"):
            self._ack(sock, sender, env.get("id"))
            return EXIT_OK
        if kind != "msg":
            self.bump("rejected")
            return EXIT_AUTH
        if env.get("to") not in (self.node, "*"):
            self.bump("rejected")
            return EXIT_AUTH

        if self.seen(str(env.get("id"))):
            self.bump("duplicated")
            self._ack(sock, sender, env.get("id"))
            return EXIT_OK

        entry = dict(env)
        entry["direction"] = "in"
        entry["received_at"] = now_ts()
        try:
            self.log.append(entry)
        except OSError:
            # Sem ack: nunca confirmar o que não foi gravado (§6.8).
            return EXIT_ERROR
        self.bump("received")
        self.publish(entry)
        self._ack(sock, sender, env.get("id"))
        return EXIT_OK

    def publish(self, entry: dict):
        with self.sub_lock:
            for target in list(self.subscribers):
                try:
                    target.put_nowait({"event": "message", "message": entry})
                except queue.Full:
                    pass

    def _envelope(self, to: str, kind: str, body: str = "", reply_to=None) -> dict:
        env = {
            "v": PROTO_V, "id": str(uuid.uuid4()), "ts": now_ts(),
            "from": self.node, "to": to, "kind": kind, "body": body,
            "reply_to": reply_to, "sig": "",
        }
        env["sig"] = sign(env, self.key)
        return env

    def send(self, to: str, body: str, wait: bool = True):
        if len(body.encode("utf-8")) > int(self.cfg["limits"]["max_body_bytes"]):
            return EXIT_LIMIT, "corpo grande demais"
        if to != "*" and to not in self.links:
            return EXIT_AUTH, f"peer desconhecido: {to}"
        targets = list(self.links) if to == "*" else [to]
        if not targets:
            return EXIT_USAGE, "nenhum peer configurado"

        for name in targets:
            path = peer_key_file(self.cfg, name)
            if path:
                try:
                    read_key(path)
                except ConfigError as exc:
                    return EXIT_USAGE, str(exc)

        pending = [(name, self.links[name].enqueue(self._envelope(name, "msg", body)))
                   for name in targets]
        failed_now = [(n, r.code, r.msg) for n, r in pending if r.done.is_set()
                      and r.code != EXIT_OK]
        if failed_now:
            return failed_now[0][1], failed_now[0][2]
        pending = [(n, r) for n, r in pending if not r.done.is_set()]

        if not wait:
            return EXIT_OK, "enfileirado"
        if not pending:
            return EXIT_OK, "ok"

        deadline = int(self.cfg["timing"]["send_timeout_ms"]) / 1000.0
        failures = []
        for name, result in pending:
            code, msg = result.wait(deadline)
            if code == EXIT_OK:
                self.bump("sent")
            else:
                failures.append((name, code, msg))
        if not failures:
            return EXIT_OK, "ok"
        if len(pending) == 1:
            return failures[0][1], failures[0][2]
        detail = "; ".join(f"{n}: {m}" for n, _, m in failures)
        return failures[0][1], detail

    def ping(self, name: str, kind: str = "ping"):
        if name not in self.links:
            return EXIT_AUTH, f"peer desconhecido: {name}"
        result = self.links[name].enqueue(self._envelope(name, kind))
        if result.done.is_set():
            return result.code, result.msg
        return result.wait(int(self.cfg["timing"]["send_timeout_ms"]) / 1000.0)

    def status(self) -> dict:
        peers = [
            {
                "name": name,
                "addr": link.addr,
                "connected": link.connected,
                "queue_depth": link.queue.qsize() + link.pending,
                "last_error": link.last_error,
            }
            for name, link in self.links.items()
        ]
        return {
            "node": self.node,
            "role": self.cfg.get("role", "auto"),
            "version": VERSION,
            "uptime_s": round(time.time() - self.started, 1),
            "protocol": PROTO_V,
            "fsync": self.log.mode,
            "counters": dict(self.counters),
            "peers": peers,
            "limits": {
                "min_interval_ms": self.cfg["timing"]["min_interval_ms"],
                "queue_max": self.cfg["timing"]["queue_max"],
                "max_out_per_sec": self.cfg["limits"]["max_out_per_sec"],
                "dedupe_window": self.dedupe_max,
                "max_peers": MAX_PEERS,
            },
        }

    def close(self):
        self.stop_event.set()
        for link in self.links.values():
            link.stop()
        self.log.close()


# ---------------------------------------------------------------------------
# Servidor de controle (Unix socket)
# ---------------------------------------------------------------------------
def reply(sock, ok: bool, **fields):
    payload = {"ok": ok}
    payload.update(fields)
    sock.sendall(encode_line(payload))


def control_loop(daemon: Daemon, sock: socket.socket):
    try:
        sock.settimeout(None)
        line = recv_line(sock, MAX_FRAME)
        if not line:
            return
        req = json.loads(line.decode("utf-8"))
        cmd = req.get("cmd")
        if cmd == "status":
            reply(sock, True, **daemon.status())
        elif cmd == "peers":
            reply(sock, True, peers=daemon.status()["peers"])
        elif cmd == "send":
            code, msg = daemon.send(
                str(req.get("to", "")), str(req.get("body", "")),
                bool(req.get("wait", True)),
            )
            reply(sock, code == EXIT_OK, code=code, msg=msg)
        elif cmd == "ping":
            code, msg = daemon.ping(str(req.get("to", "")))
            reply(sock, code == EXIT_OK, code=code, msg=msg)
        elif cmd == "hello":
            code, msg = daemon.ping(str(req.get("to", "")), kind="hello")
            reply(sock, code == EXIT_OK, code=code, msg=msg)
        elif cmd == "listen":
            channel: "queue.Queue" = queue.Queue(maxsize=1024)
            with daemon.sub_lock:
                daemon.subscribers.append(channel)
            try:
                reply(sock, True, listening=True)
                while True:
                    sock.sendall(encode_line(channel.get()))
            finally:
                with daemon.sub_lock:
                    if channel in daemon.subscribers:
                        daemon.subscribers.remove(channel)
        elif cmd == "shutdown":
            reply(sock, True, msg="encerrando")
            daemon.stop_event.set()
        else:
            reply(sock, False, code=EXIT_USAGE, msg=f"comando desconhecido: {cmd}")
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        try:
            sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def socket_path(args) -> str:
    path = getattr(args, "socket", None)
    if path:
        return path
    try:
        return load_config(args.config).get("control_socket")
    except ConfigError:
        return DEFAULTS["control_socket"]


def call_daemon(path: str, request: dict, stream: bool = False):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except (FileNotFoundError, ConnectionRefusedError):
        sys.stderr.write(
            f"ai-talk: daemon não encontrado em {path} "
            "(o serviço está rodando? `systemctl status ai-talk`)\n"
        )
        raise SystemExit(EXIT_ERROR)
    sock.sendall(encode_line(request))
    if not stream:
        line = recv_line(sock, MAX_FRAME)
        sock.close()
        return json.loads(line.decode("utf-8")) if line else {"ok": False}
    return sock


def cmd_serve(args) -> int:
    try:
        cfg = load_config(args.config)
        if args.node:
            cfg["node"] = args.node
        daemon = Daemon(cfg)
        host = cfg["listen"].get("address", "127.0.0.1")
        port = int(cfg["listen"].get("port", 7331))
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        server = socket.socket(family, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(64)
        server.settimeout(0.5)
        bound = server.getsockname()[1]

        ctl_path = socket_path(args)
        os.makedirs(os.path.dirname(ctl_path) or ".", exist_ok=True)
        if os.path.exists(ctl_path):
            os.unlink(ctl_path)
        ctl = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        ctl.bind(ctl_path)
        os.chmod(ctl_path, 0o660)
        ctl.listen(16)
        ctl.settimeout(0.5)
    except ConfigError as exc:
        sys.stderr.write(f"ai-talk: {exc}\n")
        return EXIT_USAGE
    except OSError as exc:
        sys.stderr.write(f"ai-talk: falha ao abrir a porta/socket: {exc}\n")
        return EXIT_ERROR

    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as handle:
            handle.write(str(bound))
    print(f"ai-talk {VERSION}: {cfg['node']} em {host}:{bound} "
          f"({len(cfg['peers'])} peers, fsync={daemon.log.mode})", flush=True)

    def accept(srv, handler):
        while not daemon.stop_event.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=handler, args=(conn,), daemon=True).start()

    threading.Thread(target=accept,
                     args=(server, lambda conn: daemon.handle_conn(conn)),
                     daemon=True).start()
    threading.Thread(target=accept,
                     args=(ctl, lambda conn: control_loop(daemon, conn)),
                     daemon=True).start()

    try:
        while not daemon.stop_event.is_set():
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        daemon.close()
        server.close()
        ctl.close()
        try:
            os.unlink(ctl_path)
        except OSError:
            pass
    return EXIT_OK


def cmd_check_config(args) -> int:
    try:
        cfg = load_config(args.config)
        read_key(cfg["key_file"])
        for name in cfg["peers"]:
            path = peer_key_file(cfg, name)
            if path:
                read_key(path)
    except ConfigError as exc:
        sys.stderr.write(f"ai-talk: {exc}\n")
        return EXIT_USAGE
    print(f"config OK: node={cfg['node']} peers={len(cfg['peers'])} "
          f"fsync={cfg['log'].get('fsync', 'always')}")
    return EXIT_OK


def cmd_status(args) -> int:
    data = call_daemon(socket_path(args), {"cmd": "status"})
    if args.json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return EXIT_OK
    print(f"nó: {data.get('node')} · papel: {data.get('role')} · v{data.get('version')}")
    print(f"uptime: {data.get('uptime_s')}s · fsync: {data.get('fsync')}")
    counters = data.get("counters", {})
    print("contadores: " + " · ".join(f"{k}={v}" for k, v in sorted(counters.items())))
    for peer in data.get("peers", []):
        state = "conectado" if peer["connected"] else "ocioso"
        err = f" (último erro: {peer['last_error']})" if peer.get("last_error") else ""
        print(f"  {peer['name']:<20} {peer['addr']:<22} {state} "
              f"fila={peer['queue_depth']}{err}")
    return EXIT_OK


def cmd_peers(args) -> int:
    data = call_daemon(socket_path(args), {"cmd": "peers"})
    if args.json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return EXIT_OK
    for peer in data.get("peers", []):
        state = "conectado" if peer["connected"] else "ocioso"
        print(f"{peer['name']:<20} {peer['addr']:<22} {state}")
    return EXIT_OK


def cmd_send(args) -> int:
    body = args.message
    if args.file:
        with open(args.file, "r", encoding="utf-8") as handle:
            body = handle.read()
    data = call_daemon(
        socket_path(args),
        {"cmd": "send", "to": args.to, "body": body, "wait": not args.no_wait},
    )
    if data.get("ok"):
        if args.no_wait:
            print("enfileirado")
        return EXIT_OK
    sys.stderr.write(f"ai-talk: {data.get('msg')}\n")
    return int(data.get("code", EXIT_ERROR))


def cmd_ping(args) -> int:
    data = call_daemon(socket_path(args), {"cmd": "ping", "to": args.to})
    if data.get("ok"):
        print("ok")
        return EXIT_OK
    sys.stderr.write(f"ai-talk: {data.get('msg')}\n")
    return int(data.get("code", EXIT_ERROR))


def cmd_hello(args) -> int:
    data = call_daemon(socket_path(args), {"cmd": "hello", "to": args.to})
    if data.get("ok"):
        print("ok")
        return EXIT_OK
    sys.stderr.write(f"ai-talk: {data.get('msg')}\n")
    return int(data.get("code", EXIT_ERROR))


def cmd_listen(args) -> int:
    sock = call_daemon(socket_path(args), {"cmd": "listen"}, stream=True)
    try:
        while True:
            line = recv_line(sock, MAX_FRAME)
            if not line:
                return EXIT_OK
            message = (json.loads(line.decode("utf-8")) or {}).get("message") or {}
            if args.from_peer and message.get("from") != args.from_peer:
                continue
            if args.json:
                print(json.dumps(message, ensure_ascii=False), flush=True)
            else:
                print(f"[{message.get('ts')}] {message.get('from')} → "
                      f"{message.get('to')}: {message.get('body')}", flush=True)
    except KeyboardInterrupt:
        return EXIT_OK
    finally:
        sock.close()


def cmd_tail(args) -> int:
    try:
        path = args.path or load_config(args.config)["log"]["path"]
    except ConfigError:
        path = args.path or DEFAULTS["log"]["path"]
    if not os.path.exists(path):
        sys.stderr.write(f"ai-talk: log não encontrado: {path}\n")
        return EXIT_ERROR
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
        for line in lines[-args.lines:]:
            print(line.rstrip("\n"))
        if not args.follow:
            return EXIT_OK
        poll = DEFAULTS["timing"]["tail_poll_ms"] / 1000.0
        try:
            while True:
                chunk = handle.readline()
                if chunk:
                    print(chunk.rstrip("\n"), flush=True)
                else:
                    time.sleep(poll)
        except KeyboardInterrupt:
            return EXIT_OK


def cmd_shutdown(args) -> int:
    data = call_daemon(socket_path(args), {"cmd": "shutdown"})
    return EXIT_OK if data.get("ok") else EXIT_ERROR


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ai-talk",
        description="chat da frota ai-cpu-os (TCP 7331, JSON lines, HMAC)",
    )
    parser.add_argument("--version", action="version", version=f"ai-talk {VERSION}")
    parser.add_argument("--config", default="/etc/ai-talk/config.json",
                        help="config (padrão: /etc/ai-talk/config.json)")
    parser.add_argument("--socket", default=None,
                        help="Unix socket do daemon (sobrepõe o config)")

    # Aceitar `ai-talk serve --config ...` (como está no systemd e no contrato)
    # além de `ai-talk --config ... serve`. SUPPRESS evita que o default do
    # subparser sobrescreva o valor global.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", default=argparse.SUPPRESS,
                        help="config (alternativa à opção global)")
    common.add_argument("--socket", default=argparse.SUPPRESS,
                        help="Unix socket (alternativa à opção global)")

    sub = parser.add_subparsers(dest="cmd", required=True)

    serve = sub.add_parser("serve", parents=[common],
                           help="roda o daemon (usado pelo systemd)")
    serve.add_argument("--node", default=None)
    serve.add_argument("--port-file", default=None,
                       help="grava a porta efetiva (útil com port=0 em teste)")
    serve.set_defaults(func=cmd_serve)

    check = sub.add_parser("check-config", parents=[common],
                           help="valida config e permissões da chave")
    check.set_defaults(func=cmd_check_config)

    status = sub.add_parser("status", parents=[common], help="estado do nó e dos peers")
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_status)

    peers = sub.add_parser("peers", parents=[common], help="lista os peers")
    peers.add_argument("--json", action="store_true")
    peers.set_defaults(func=cmd_peers)

    send = sub.add_parser("send", parents=[common], help="envia uma mensagem")
    send.add_argument("to")
    send.add_argument("message", nargs="?", default="")
    send.add_argument("--file", default=None)
    send.add_argument("--no-wait", action="store_true")
    send.set_defaults(func=cmd_send)

    ping = sub.add_parser("ping", parents=[common], help="marca presença (throttled)")
    ping.add_argument("to")
    ping.set_defaults(func=cmd_ping)

    hello = sub.add_parser("hello", parents=[common],
                           help="handshake (isento do throttle, como o ack)")
    hello.add_argument("to")
    hello.set_defaults(func=cmd_hello)

    listen = sub.add_parser("listen", parents=[common],
                            help="imprime mensagens recebidas")
    listen.add_argument("--from", dest="from_peer", default=None)
    listen.add_argument("--json", action="store_true")
    listen.set_defaults(func=cmd_listen)

    tail = sub.add_parser("tail", parents=[common], help="lê o log local")
    tail.add_argument("-n", "--lines", type=int, default=50)
    tail.add_argument("-f", "--follow", action="store_true")
    tail.add_argument("--path", default=None)
    tail.set_defaults(func=cmd_tail)

    shutdown = sub.add_parser("shutdown", parents=[common],
                              help="encerra o daemon (teste/manutenção)")
    shutdown.set_defaults(func=cmd_shutdown)

    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args) or EXIT_OK)


if __name__ == "__main__":
    sys.exit(main())
