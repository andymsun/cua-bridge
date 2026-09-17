#!/usr/bin/env python3
"""
cua-bridge: expose Codex's CUA Node REPL runtime (browser + native macOS app control)
to any MCP client.

Transparent stdio JSON-RPC proxy that adds two things the Codex runtime expects
from its host but that a generic MCP client does not provide:

  1. Turn metadata. Every tools/call gets
     _meta["x-codex-turn-metadata"] = {"session_id", "turn_id"}.
     The bundled browser service hard-requires this.

  2. Elicitation. Native app access asks the host for consent via MCP
     elicitation/create. If the downstream client supports elicitation the
     request is forwarded untouched, preserving the real consent prompt.
     If it does not, behaviour depends on CUA_BRIDGE_ELICIT:
       "forward" (default) - decline, with a message explaining how to enable
       "accept"            - auto-accept locally (skips the consent prompt)
       "decline"           - always decline

Env overrides: CUA_NODE_HOME, CODEX_HOME, CUA_REPL_ENABLED_SURFACES,
CUA_BRIDGE_TURN_MODE (call|session), CUA_BRIDGE_ELICIT.
"""
import json, os, subprocess, sys, threading, uuid

CUA_NODE = os.environ.get(
    "CUA_NODE_HOME", "/Applications/ChatGPT.app/Contents/Resources/cua_node"
)
CODEX_HOME = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
SURFACES = os.environ.get("CUA_REPL_ENABLED_SURFACES", "browser,computer")
TURN_MODE = os.environ.get("CUA_BRIDGE_TURN_MODE", "call")
ELICIT_MODE = os.environ.get("CUA_BRIDGE_ELICIT", "forward")

NODE = f"{CUA_NODE}/bin/node"
LAUNCHER = f"{CUA_NODE}/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs"
MODULES = f"{CUA_NODE}/lib/node_modules"

for path in (NODE, LAUNCHER):
    if not os.path.exists(path):
        sys.stderr.write(
            f"cua-bridge: missing {path}\n"
            "The ChatGPT/Codex desktop app supplies this runtime. Install it, or set "
            "CUA_NODE_HOME to a cua_node directory.\n")
        sys.exit(1)

env = dict(os.environ)
env.update({
    "CUA_REPL_NODE_REPL_PATH": f"{CUA_NODE}/bin/node_repl",
    "CUA_REPL_ENABLED_SURFACES": SURFACES,
    "NODE_REPL_NODE_MODULE_DIRS": MODULES,
    "NODE_REPL_NODE_PATH": NODE,
    "NODE_REPL_TRUSTED_CODE_PATHS": f"{CODEX_HOME}:{MODULES}",
    "NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS": "1000",
    "CODEX_HOME": CODEX_HOME,
    "BROWSER_USE_AVAILABLE_BACKENDS": os.environ.get(
        "BROWSER_USE_AVAILABLE_BACKENDS", "chrome,iab"),
    "BROWSER_USE_TINYSKY_ENABLED": "1",
    "SKY_CUA_SERVICE_PATH": os.environ.get(
        "SKY_CUA_SERVICE_PATH", f"{CODEX_HOME}/computer-use/Codex Computer Use.app"),
})

child = subprocess.Popen(
    [NODE, LAUNCHER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=sys.stderr, env=env, text=True, bufsize=1,
)

SESSION_ID = str(uuid.uuid4())
_fixed_turn = str(uuid.uuid4())
_client_elicits = False
_wlock = threading.Lock()


def to_child(msg):
    with _wlock:
        try:
            child.stdin.write(json.dumps(msg) + "\n")
            child.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass


def to_client(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def turn_metadata():
    tid = str(uuid.uuid4()) if TURN_MODE == "call" else _fixed_turn
    return json.dumps({"session_id": SESSION_ID, "turn_id": tid})


def pump_up():
    """client -> child"""
    global _client_elicits
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method")
        if method == "initialize":
            caps = msg.setdefault("params", {}).setdefault("capabilities", {})
            _client_elicits = "elicitation" in caps
            # Always advertise elicitation downstream; we answer it ourselves
            # when the client cannot.
            caps.setdefault("elicitation", {})
        elif method == "tools/call":
            params = msg.setdefault("params", {})
            params.setdefault("_meta", {}).setdefault(
                "x-codex-turn-metadata", turn_metadata())
        to_child(msg)
    to_child({"jsonrpc": "2.0", "method": "notifications/cancelled"})


def handle_elicitation(msg):
    if _client_elicits and ELICIT_MODE == "forward":
        to_client(msg)  # real consent prompt in the client
        return
    if ELICIT_MODE == "accept":
        result = {"action": "accept", "content": {}}
    else:
        result = {"action": "decline"}
        sys.stderr.write(
            "cua-bridge: declined an elicitation (consent form) because this MCP "
            "client does not support elicitation. Native app access needs it. "
            "Set CUA_BRIDGE_ELICIT=accept to auto-approve locally.\n")
    to_client_none = {"jsonrpc": "2.0", "id": msg.get("id"), "result": result}
    to_child(to_client_none)


def pump_down():
    """child -> client, intercepting server-initiated requests we must answer"""
    for line in child.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            sys.stdout.write(line + "\n"); sys.stdout.flush(); continue
        if msg.get("method") == "elicitation/create" and "id" in msg:
            handle_elicitation(msg)
            continue
        to_client(msg)


threading.Thread(target=pump_up, daemon=True).start()
try:
    pump_down()
except KeyboardInterrupt:
    pass
finally:
    child.terminate()
