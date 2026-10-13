#!/usr/bin/python3
"""Kids' VM launcher - the piece that makes "on demand" actually work.

Neither Guacamole nor Moonlight can START a stopped VM; they can only connect to a
running one. Without this page a kid clicking their name just gets a connection error.

The flow, all of it asynchronous so the page can show progress:
    wake the gaming-pc (WoL) if it is asleep    ~8 s measured
    -> Start-VM (resumes a saved VM in seconds)
    -> hold the gaming-pc awake
    -> poll until the guest's VNC port answers
    -> hand off to Guacamole

Standard library only - no pip dependencies to rot. Runs as a systemd service on the
host rather than in a container, because it needs the SSH key to the gaming-pc and a
broadcast socket for wake-on-LAN.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# ------------------------------------------------------------------ site config
# Set these in the systemd unit. GUAC_URL is the Guacamole base URL as the kids'
# browsers will reach it on the home LAN (the launcher also POSTs to it server-side).
PORT        = int(os.environ.get("LAUNCHER_PORT", "8000"))
GUAC_URL    = os.environ.get("GUAC_URL", "http://<SERVER_IP>:<GUAC_PORT>")
VMCTL       = os.environ.get("VMCTL", "/usr/local/sbin/vmctl")
WAKE_WAIT   = int(os.environ.get("WAKE_WAIT", "150"))
VNC_WAIT    = int(os.environ.get("VNC_WAIT", "180"))

# kids.json: Get-VM name -> {label, ip, vnc_port}. A config file rather than a systemd
# Environment= line, because systemd strips the double quotes out of inline JSON and the
# service dies on startup. Edit kids.json and restart to rename or re-address a VM.
KIDS_FILE = os.environ.get("KIDS_FILE", "/opt/kids-launcher/kids.json")


def load_kids() -> dict:
    """Read kids.json on every request, so renaming a kid needs no restart."""
    try:
        raw = json.loads(open(KIDS_FILE).read())
    except (OSError, ValueError) as e:
        print(f"could not read {KIDS_FILE}: {e}", flush=True)
        return {}
    vms = raw.get("vms", raw)
    out = {}
    for name, v in vms.items():
        if name.startswith("_"):                       # skip _comment and friends
            continue
        if isinstance(v, str):                          # tolerate the old flat format
            v = {"label": v}
        out[name] = {"label": v.get("label", name),
                     "ip": v.get("ip", ""),
                     "vnc_port": int(v.get("vnc_port", 5900))}
    return out


# vm -> {"step": str, "pct": int, "error": str|None, "done": bool}
JOBS: dict[str, dict] = {}
LOCK = threading.Lock()


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')}  {msg}", flush=True)


def vnc_open(ip: str, port: int) -> bool:
    """Is the guest's VNC server actually accepting connections? Checked before the
    hand-off, so a kid never lands on a Guacamole error page."""
    try:
        with socket.create_connection((ip, port), timeout=3):
            return True
    except OSError:
        return False


def vmctl(*args: str, timeout: int = 60) -> tuple[int, str]:
    try:
        r = subprocess.run([VMCTL, *args], capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 1, "timed out"


def set_job(vm: str, step: str, pct: int, error: str | None = None, done: bool = False) -> None:
    with LOCK:
        prev = JOBS.get(vm, {})
        JOBS[vm] = {"step": step, "pct": pct, "error": error, "done": done,
                    "url": prev.get("url"),              # never lose a hand-off URL
                    "vm_ready": prev.get("vm_ready", False),
                    "web_error": prev.get("web_error")}


# ---------------------------------------------------------------- Guacamole hand-off

# Secrets come from systemd's credential directory, decrypted from the TPM store by
# LoadCredentialEncrypted= in the unit. No sudo, no helper binary, and the plaintext
# only ever exists in a tmpfs this one service can read.
CREDS_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")


def _cred(name: str) -> str | None:
    if not CREDS_DIR:
        return None
    try:
        return open(os.path.join(CREDS_DIR, name)).read().strip()
    except OSError:
        return None


def vnc_password() -> str | None:
    """The VNC password. Never sent to the browser - it is embedded in the encrypted
    blob that travels server-to-server to Guacamole."""
    return _cred("kids-vncpass")


def build_token(payload: dict) -> str | None:
    """Sign + encrypt a guacamole-auth-json descriptor.

        HMAC-SHA256(json, key) || json  ->  AES-128-CBC, null IV, no salt  ->  base64

    openssl does the AES because the standard library has no cipher, and the whole
    point of this service is zero pip dependencies. The key never touches disk.
    """
    key = _cred("guac-jsonkey")
    if not key:
        return None
    raw = json.dumps(payload).encode()
    sig = hmac.new(bytes.fromhex(key), raw, hashlib.sha256).digest()
    try:
        r = subprocess.run(
            ["openssl", "enc", "-aes-128-cbc", "-K", key,
             "-iv", "0" * 32, "-nosalt", "-a", "-A"],
            input=sig + raw, capture_output=True, timeout=20)
        return r.stdout.decode().strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def guac_handoff(vm: str, ip: str, port: int) -> tuple[str | None, str | None]:
    """Build a pre-authenticated Guacamole URL for this VM.

    THE POINT: the kids must never see a login page - not Guacamole's, not VNC's.
    guacamole-auth-json lets us describe a connection, sign and encrypt it with a shared
    key, and POST it to /api/tokens. Guacamole returns a session that already contains
    exactly that one connection. The kid lands on the desktop.

    Returns (url, error).
    """
    pw = vnc_password()
    if pw is None or pw.startswith("REPLACE-ME"):
        return None, ("The VNC password credential has not been set yet "
                      "(see the systemd unit's LoadCredentialEncrypted= lines).")

    conn = f"{vm}-vnc"
    payload = {
        # Short-lived and per-VM: this blob is only good for one desktop, for 60s.
        "username": f"kid-{vm}",
        "expires": int((time.time() + 60) * 1000),
        "connections": {
            conn: {
                "protocol": "vnc",
                "parameters": {
                    "hostname": ip,
                    "port": str(port),
                    "password": pw,
                    "color-depth": "24",
                    # Let the kids move files in/out and use the clipboard normally.
                    "enable-audio": "true",
                },
            }
        },
    }
    blob = build_token(payload)
    if not blob:
        return None, "could not build the Guacamole token"

    # Exchange the blob for a session token.
    try:
        import urllib.parse, urllib.request
        data = urllib.parse.urlencode({"data": blob}).encode()
        with urllib.request.urlopen(f"{GUAC_URL}/api/tokens", data=data, timeout=20) as resp:
            tok = json.loads(resp.read()).get("authToken")
    except Exception as e:
        return None, f"Guacamole rejected the connection ({type(e).__name__})"
    if not tok:
        return None, "Guacamole returned no token"

    # Guacamole identifies a client by base64 of "<id>\0<type>\0<datasource>";
    # 'c' = connection, 'json' = the auth provider that supplied it.
    ident = base64.b64encode(f"{conn}\0c\0json".encode()).decode()
    return f"{GUAC_URL}/#/client/{ident}?token={tok}", None


# Poll intervals. Deliberately tight: these are kids, and every second between the tap
# and the desktop is a second of "is it broken?". Measured phase timings live in the
# journal so these can be tuned from evidence rather than guesswork.
POLL_HOST = float(os.environ.get("POLL_HOST", "2"))    # waiting for the gaming-pc
POLL_VNC  = float(os.environ.get("POLL_VNC", "2"))     # waiting for the guest


def launch(vm: str) -> None:
    """Run the whole start sequence, timing every phase.

    Each step logs how long it took, so the slow one is obvious rather than inferred.
    Errors are reported to the page, never raised.
    """
    t0 = time.time()
    marks: list[tuple[str, float]] = []

    def mark(label: str) -> None:
        marks.append((label, time.time() - t0))

    def timings() -> str:
        out, prev = [], 0.0
        for label, at in marks:
            out.append(f"{label}={at - prev:.1f}s")
            prev = at
        return "  ".join(out) + f"  TOTAL={marks[-1][1]:.1f}s" if marks else "no phases"

    try:
        cfg = load_kids().get(vm, {})
        port = cfg.get("vnc_port", 5900)

        # ---- phase 1: is the gaming-pc awake? --------------------------------------
        set_job(vm, "Waking the big computer…", 5)
        rc, _ = vmctl("host-up", timeout=20)
        mark("host-check")
        if rc != 0:
            # Asleep. Send the magic packet, then poll hard rather than sleeping blind.
            vmctl("wake", timeout=15)
            mark("wol-sent")
            deadline = time.time() + WAKE_WAIT
            while time.time() < deadline:
                if vmctl("host-up", timeout=8)[0] == 0:
                    break
                time.sleep(POLL_HOST)
            else:
                mark("host-timeout")
                log(f"[{vm}] gaming-pc did not wake  |  {timings()}")
                set_job(vm, "", 0, error="The big computer did not wake up. Ask a grown-up.",
                        done=True)
                return
            mark("host-awake")
        set_job(vm, "Starting your computer…", 35)

        # ---- phase 2: resume the VM -------------------------------------------------
        rc, out = vmctl("start", vm, timeout=120)
        mark("vm-start")
        if rc != 0:
            log(f"[{vm}] start failed: {out[:100]}  |  {timings()}")
            set_job(vm, "", 0, error=f"Could not start it ({out[:60]}). Ask a grown-up.",
                    done=True)
            return

        # Hold the gaming-pc awake. Deliberately NOT blocking the kid on this - it takes
        # ~15 s to register and the VM is usable long before then.
        threading.Thread(target=lambda: vmctl("keepawake", "on", timeout=45),
                         daemon=True).start()
        set_job(vm, "Almost ready…", 60)

        # ---- phase 3: wait for the guest to answer ----------------------------------
        deadline = time.time() + VNC_WAIT
        while time.time() < deadline:
            ip = cfg.get("ip") or ""
            if not ip:
                rc, out = vmctl("ip", vm, timeout=20)
                ip = out if rc == 0 else ""
            if ip and vnc_open(ip, port):
                mark("guest-up")
                set_job(vm, "Connecting…", 90)
                url, err = guac_handoff(vm, ip, port)
                mark("guac-handoff")
                with LOCK:
                    JOBS[vm]["url"] = url
                    JOBS[vm]["vm_ready"] = True
                    JOBS[vm]["web_error"] = err
                    JOBS[vm]["timings"] = timings()
                log(f"[{vm}] READY  |  {timings()}")
                set_job(vm, "Ready" if not err else "Ready (browser access unavailable)",
                        100, done=True)
                return
            time.sleep(POLL_VNC)

        mark("guest-timeout")
        log(f"[{vm}] guest never answered  |  {timings()}")
        set_job(vm, "", 0, error="It started but never came online. Ask a grown-up.", done=True)

    except Exception as e:
        log(f"[{vm}] unexpected {type(e).__name__}: {e}  |  {timings()}")
        set_job(vm, "", 0, error=f"Something went wrong: {type(e).__name__}", done=True)


PAGE = """<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pick Your Computer</title>
<style>
  :root{--bg:#0f1220;--card:#1b2036;--ink:#f2f4ff;--muted:#9aa3c7;--accent:#5a7bff;--ok:#2fbf71;--bad:#e5484d}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;background:linear-gradient(160deg,#0f1220,#161a30);
       color:var(--ink);font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
       display:flex;flex-direction:column;align-items:center;padding:32px 16px}
  h1{font-size:clamp(28px,6vw,44px);margin:8px 0 4px;text-align:center}
  p.sub{color:var(--muted);margin:0 0 28px;text-align:center}
  .grid{display:grid;gap:18px;width:100%;max-width:960px;
        grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
  .card{background:var(--card);border:1px solid #2a3154;border-radius:18px;padding:26px 22px;
        text-align:center;transition:transform .15s,border-color .15s}
  .card:hover{transform:translateY(-3px);border-color:var(--accent)}
  .name{font-size:24px;font-weight:650;margin-bottom:6px}
  .state{color:var(--muted);font-size:14px;min-height:22px;margin-bottom:16px}
  .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;vertical-align:1px}
  .on{background:var(--ok)} .off{background:#5b6488} .err{background:var(--bad)}
  button{width:100%;padding:15px;font-size:17px;font-weight:600;color:#fff;cursor:pointer;
         background:var(--accent);border:0;border-radius:12px}
  button:disabled{background:#39406a;cursor:not-allowed}
  .bar{height:7px;background:#2a3154;border-radius:99px;overflow:hidden;margin-top:14px;display:none}
  .bar>i{display:block;height:100%;width:0;background:var(--accent);transition:width .4s}
  .msg{font-size:13px;color:var(--muted);margin-top:9px;min-height:18px}
  .msg.bad{color:var(--bad)}
  footer{margin-top:34px;color:#5b6488;font-size:12px;text-align:center}
</style></head><body>
<h1>Pick Your Computer</h1>
<p class="sub">Click your name. It takes about a minute to wake up.</p>
<div class="grid" id="grid"></div>
<footer id="foot"></footer>
<script>
const guac = "__GUAC__";
let vms = [];

function card(v){
  const cls = v.state === "Running" ? "on" : (v.state === "NotFound" ? "err" : "off");
  const label = v.state === "Running" ? "Ready to use" :
                v.state === "NotFound" ? "Not set up yet" : "Sleeping";
  return `<div class="card" id="c-${v.name}">
    <div class="name">${v.label}</div>
    <div class="state"><span class="dot ${cls}"></span>${label}</div>
    <button id="b-${v.name}" onclick="go('${v.name}')">
      ${v.state === "Running" ? "Connect" : "Start"}</button>
    <div class="bar" id="p-${v.name}"><i></i></div>
    <div class="msg" id="m-${v.name}"></div>
  </div>`;
}

async function refresh(){
  const r = await fetch("api/vms"); const d = await r.json();
  vms = d.vms;
  document.getElementById("grid").innerHTML = vms.map(card).join("");
  document.getElementById("foot").textContent =
    d.mode === "stub" ? "Test mode — the real computers are not built yet."
                      : "";
}

async function go(vm){
  const btn = document.getElementById("b-"+vm);
  const bar = document.getElementById("p-"+vm);
  const msg = document.getElementById("m-"+vm);
  btn.disabled = true; bar.style.display = "block"; msg.className = "msg";
  await fetch("api/start/"+vm, {method:"POST"});
  const poll = setInterval(async () => {
    const r = await fetch("api/job/"+vm); const j = await r.json();
    bar.firstElementChild.style.width = (j.pct||0)+"%";
    msg.textContent = j.error || j.step || "";
    if (j.error){ msg.className = "msg bad"; btn.disabled = false; clearInterval(poll); return; }
    if (j.done){
      clearInterval(poll);
      if (j.url){ msg.textContent = "Opening…"; setTimeout(()=>{ window.location = j.url; }, 600); }
      else { msg.textContent = j.step || "Ready"; btn.disabled = false; }
    }
  }, 1500);
}
refresh(); setInterval(()=>{ if(!Object.keys(document.querySelectorAll('.bar[style*="block"]')).length) refresh(); }, 15000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json")

    def log_message(self, fmt, *a):                           # quieter journal
        if "api/job" not in (a[0] if a else ""):
            super().log_message(fmt, *a)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self._send(200, PAGE.replace("__GUAC__", GUAC_URL).encode(), "text/html; charset=utf-8")
        elif path == "/api/vms":
            live = {v["name"]: v for v in _list()}
            kids = load_kids()
            out = [{"name": n, "label": k["label"],
                    "state": live.get(n, {}).get("state", "NotFound")}
                   for n, k in kids.items()]
            self._json(200, {"vms": out, "mode": vmctl("mode")[1]})
        elif path.startswith("/api/job/"):
            vm = path.rsplit("/", 1)[-1]
            with LOCK:
                self._json(200, JOBS.get(vm, {"step": "", "pct": 0, "done": False, "error": None}))
        elif path.startswith("/wake/"):
            # Log ARRIVAL, not just completion. The access log line is written when the
            # response is sent, so a slow client-side connection is otherwise invisible -
            # and "it felt longer than your numbers say" is usually time spent before the
            # request ever reached us.
            log(f"REQUEST IN  {self.client_address[0]}  {path}")
            # Designed for an iOS Shortcut: one GET, waits for the VM, replies in plain
            # text so Siri can read it out. Accepts the friendly label ("kid1") or the
            # full Get-VM name, case-insensitive, so the URL is something a person can
            # actually type.
            want = path.rsplit("/", 1)[-1].strip().lower()
            kids = load_kids()
            vm = next((n for n, k in kids.items()
                       if want in (n.lower(), k["label"].lower())), None)
            if not vm:
                self._send(404, f"I do not know a PC called '{want}'.\n".encode(),
                           "text/plain; charset=utf-8")
                return

            rc, state = vmctl("state", vm, timeout=45)
            if rc == 0 and state == "Running":
                self._send(200, f"{kids[vm]['label']}'s PC is already on.\n".encode(),
                           "text/plain; charset=utf-8")
                return

            with LOCK:
                busy = vm in JOBS and not JOBS[vm]["done"]
            if not busy:
                set_job(vm, "Starting…", 1)
                threading.Thread(target=launch, args=(vm,), daemon=True).start()

            # Wait, so the Shortcut reports the real outcome rather than "probably".
            deadline = time.time() + 45
            while time.time() < deadline:
                with LOCK:
                    j = dict(JOBS.get(vm, {}))
                if j.get("done") and j.get("vm_ready"):
                    self._send(200, f"{kids[vm]['label']}'s PC is ready.\n".encode(),
                               "text/plain; charset=utf-8")
                    return
                if j.get("error"):
                    self._send(200, f"Could not start it. {j['error']}\n".encode(),
                               "text/plain; charset=utf-8")
                    return
                if j.get("done"):
                    self._send(200, f"{kids[vm]['label']}'s PC is ready.\n".encode(),
                               "text/plain; charset=utf-8")
                    return
                time.sleep(1)
            self._send(200, f"{kids[vm]['label']}'s PC is still starting.\n".encode(),
                       "text/plain; charset=utf-8")

        elif path.startswith("/go/"):
            # Fire-and-forget twin of /wake/. Replies INSTANTLY instead of holding the
            # connection for the whole start, because a Shortcut that returns at once and
            # a PC that is ready by the time you switch apps *feels* far quicker than an
            # identical wait with a spinner on it. Same work, better perceived latency.
            log(f"REQUEST IN  {self.client_address[0]}  {path}")
            want = path.rsplit("/", 1)[-1].strip().lower()
            kids = load_kids()
            vm = next((n for n, k in kids.items()
                       if want in (n.lower(), k["label"].lower())), None)
            if not vm:
                self._send(404, f"I do not know a PC called '{want}'.\n".encode(),
                           "text/plain; charset=utf-8")
                return
            with LOCK:
                busy = vm in JOBS and not JOBS[vm]["done"]
            if not busy:
                set_job(vm, "Starting…", 1)
                threading.Thread(target=launch, args=(vm,), daemon=True).start()
            self._send(200, f"Waking {kids[vm]['label']}'s PC…\n".encode(),
                       "text/plain; charset=utf-8")

        elif path == "/healthz":
            # Logged with arrival time so a Shortcut hitting this can be compared against
            # when the user actually tapped. This endpoint does NO work, so any delay the
            # user feels here is entirely client-side or network.
            log(f"HEALTHZ from {self.client_address[0]}")
            # Plain text, not JSON: iOS Shortcuts auto-parses a JSON body into a
            # Dictionary and then errors trying to display it. Every other endpoint here
            # returns text for the same reason.
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path.startswith("/api/start/"):
            vm = path.rsplit("/", 1)[-1]
            if vm not in load_kids():
                self._json(404, {"error": "unknown vm"}); return
            with LOCK:
                running = vm in JOBS and not JOBS[vm]["done"]
            if not running:
                set_job(vm, "Starting…", 1)
                threading.Thread(target=launch, args=(vm,), daemon=True).start()
            self._json(202, {"accepted": True})
        else:
            self._json(404, {"error": "not found"})


def _list() -> list[dict]:
    rc, out = vmctl("list", timeout=40)
    vms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            vms.append({"name": parts[0], "state": parts[1]})
    return vms


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"kids-launcher listening on :{PORT}  guac={GUAC_URL}  mode={vmctl('mode')[1]}",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
