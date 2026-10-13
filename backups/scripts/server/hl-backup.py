#!/usr/bin/env python3
"""Nightly file-level backup of the server to a restic repository on the gaming-pc.

Flow: wait until services are idle -> make sure the backup share is reachable
(waking the gaming-pc with wake-on-LAN if needed) -> stop containers for a
consistent copy -> restic backup -> restart containers -> apply retention ->
notify.

Secrets arrive via systemd LoadCredentialEncrypted (TPM-bound); nothing
sensitive is stored on disk in plain text or passed on a command line.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ============================================================== CONFIG
# Every site-specific value lives here. Replace the placeholders.
SHARE = "//<BACKUP_HOST_IP>/<SHARE_NAME>"      # SMB share on the gaming-pc
TARGET_MAC = "<GAMING_PC_MAC>"                 # wired NIC with wake-on-magic-packet enabled
BROADCAST = "<LAN_BROADCAST_ADDR>"             # e.g. 192.0.2.255
MOUNT = Path("/mnt/backup-target")
REPO = MOUNT / "<VAULT_DIR>/server"

MOUNT_TRIES = 24                               # 24 x 15 min = 6 h of grace
MOUNT_RETRY = timedelta(minutes=15)

# Idle check: a command that exits 0 when it is OK to back up now, and non-zero
# (printing a short description of the activity) when something is busy.
# If the check itself cannot run, the job treats that as idle.
IDLE_CHECK_CMD: list[str] | None = None        # e.g. ["/usr/local/sbin/hl-idle-check"]
WAIT_LIMIT = timedelta(hours=6)                # after this, back up anyway
POLL = timedelta(minutes=5)

STACK_ROOT = Path("/opt")                      # one <stack>/compose.yaml per service
NEVER_STOP: set[str] = set()                   # stacks deliberately kept stopped

RETENTION = ["--keep-daily", "30", "--keep-weekly", "8", "--keep-monthly", "12"]
EXCLUDES = ["/proc", "/sys", "/dev", "/run", "/tmp", "/mnt", "/media", "/snap",
            "/swap.img", "/lost+found", "/var/lib/docker", "/var/cache", "/var/tmp",
            "/var/log/journal", "/opt/*/cache", "/opt/*/config/logs", "/opt/*/config/log",
            "/home/*/.cache", "/home/*/thinclient_drives", "/home/*/snap/*/common/.cache"]

STATE = Path("/var/lib/hl-backup")
LOGFILE = Path("/var/log/hl-backup.log")
QUEUE = STATE / "notify-queue.jsonl"
STATUS = STATE / "status.json"

BROWSE_UNIT = "hl-backup-browse.service"

# Push notifications (e.g. a self-hosted ntfy). NOTIFY_CMD is called as:
#   NOTIFY_CMD <topic> <priority> <title> <body>
NOTIFY_CMD = "/usr/local/bin/hl-notify"
NOTIFY_HEALTH_URL = "http://127.0.0.1:<NOTIFY_PORT>/v1/health"
TOPIC_OK, TOPIC_ALERT = "<OK_TOPIC>", "<ALERT_TOPIC>"
DESKTOP_FLUSH_CMD: str | None = None           # optional: shows queued popups at desktop login

CREDS = Path(os.environ.get("CREDENTIALS_DIRECTORY", "/dev/null"))
# ============================================================== END CONFIG


def log(msg: str) -> None:
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    try:
        with LOGFILE.open("a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ---------------------------------------------------------------- idle wait
def busy() -> str | None:
    """Return a description of current activity, or None if idle."""
    if not IDLE_CHECK_CMD:
        return None
    try:
        r = run(IDLE_CHECK_CMD, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"idle check failed ({exc}) - treating as idle")
        return None
    return None if r.returncode == 0 else (r.stdout.strip() or "busy")


def wait_for_quiet() -> tuple[bool, timedelta]:
    """Poll until services are idle, or the wait limit is reached."""
    started = datetime.now()
    while True:
        activity = busy()
        waited = datetime.now() - started
        if activity is None:
            return True, waited
        if waited >= WAIT_LIMIT:
            log(f"waited {waited} - limit reached, backing up anyway")
            return False, waited
        log(f"services busy ({activity}) - re-checking in {int(POLL.total_seconds() / 60)} min")
        time.sleep(POLL.total_seconds())


# ---------------------------------------------------------------- containers
def stacks() -> list[Path]:
    return [p.parent for p in sorted(STACK_ROOT.glob("*/compose.yaml"))
            if p.parent.name not in NEVER_STOP]


_STOPPED: list[str] = []   # only these get restarted, so a stack that was down on purpose stays down


def containers(stack: Path, running_only: bool = True) -> list[str]:
    """Container ids for a stack, found by compose's own project label.

    Deliberately not `docker compose stop`: a compose.yaml that uses ${VAR:?...}
    guards cannot be parsed without its secrets, so compose refuses to act and
    those containers silently keep running through the backup. Labels need no
    interpolation.
    """
    cmd = ["docker", "ps", "-q"] if running_only else ["docker", "ps", "-aq"]
    cmd += ["--filter", f"label=com.docker.compose.project={stack.name}"]
    return run(cmd).stdout.split()


def stop_all() -> None:
    _STOPPED.clear()
    for s in stacks():
        ids = containers(s, running_only=True)
        if not ids:
            continue
        r = run(["docker", "stop", *ids])
        if r.returncode != 0:
            log(f"WARNING: could not stop {s.name}: {r.stderr.strip()[:120]}")
            continue
        _STOPPED.extend(ids)
    log(f"stopped {len(_STOPPED)} container(s)")


def start_all() -> None:
    ids = list(_STOPPED)
    if not ids:
        # Crash path: we do not know what we stopped, so bring every stack up.
        for s in stacks():
            ids += containers(s, running_only=False)
    if not ids:
        return
    r = run(["docker", "start", *ids])
    if r.returncode != 0:
        log(f"WARNING: some containers failed to start: {r.stderr.strip()[:200]}")
    _STOPPED.clear()


# ---------------------------------------------------------------- target + mount
def wake_target() -> None:
    """Send a wake-on-LAN magic packet (the gaming-pc sleeps when idle)."""
    mac = bytes.fromhex(TARGET_MAC.replace(":", "").replace("-", ""))
    packet = b"\xff" * 6 + mac * 16
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for port in (7, 9):
            s.sendto(packet, (BROADCAST, port))
    log("sent wake-on-LAN")


MOUNT_OPTS = ("credentials={creds}/smbcred,uid=0,gid=0,"
              "file_mode=0600,dir_mode=0700,vers=3.1.1,nounix,noserverino")


def share_usable() -> bool:
    """Mounted AND answering. A sleeping host leaves a CIFS mount that is still
    listed in /proc/mounts but fails every I/O - and blocks a fresh mount with EBUSY."""
    if not os.path.ismount(MOUNT):
        return False
    return run(["timeout", "10", "ls", str(MOUNT)]).returncode == 0


def clear_stale_mount() -> None:
    if os.path.ismount(MOUNT) and not share_usable():
        log("share is mounted but not responding - clearing the stale mount")
        run(["umount", "-f", str(MOUNT)])
        if os.path.ismount(MOUNT):
            run(["umount", "-l", str(MOUNT)])


def try_mount() -> subprocess.CompletedProcess:
    return run(["mount", "-t", "cifs", SHARE, str(MOUNT),
                "-o", MOUNT_OPTS.format(creds=CREDS)])


def mount_share() -> None:
    """Get a working share, waking the target and retrying as needed.
    Usability is re-checked on EVERY pass, never decided once up front."""
    last = ""
    for attempt in range(1, MOUNT_TRIES + 1):
        if share_usable():
            return
        clear_stale_mount()
        res = try_mount()
        if res.returncode == 0 and share_usable():
            return
        last = (res.stderr or res.stdout or "").strip()
        if attempt == MOUNT_TRIES:
            break
        log(f"mount failed (attempt {attempt}/{MOUNT_TRIES}): {last[:120]}")
        wake_target()
        time.sleep(60)
        if share_usable():
            log("mounted after wake-on-LAN")
            return
        clear_stale_mount()
        if try_mount().returncode == 0 and share_usable():
            log("mounted after wake-on-LAN")
            return
        log(f"still down - retrying in {int(MOUNT_RETRY.total_seconds() / 60)} min")
        time.sleep(MOUNT_RETRY.total_seconds())
    raise RuntimeError(f"cannot mount the backup share after {MOUNT_TRIES} attempts: {last}")


# ---------------------------------------------------------------- restic
def restic(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    env = os.environ | {
        "RESTIC_REPOSITORY": str(REPO),
        "RESTIC_PASSWORD_FILE": str(CREDS / "resticpw"),
        "RESTIC_CACHE_DIR": "/var/cache/restic",
        "HOME": "/root",
    }
    res = subprocess.run(["restic", *args], capture_output=True, text=True, env=env)
    if check and res.returncode:
        raise RuntimeError(f"restic {args[0]} failed: {res.stderr.strip()[:300]}")
    return res


def browse_running() -> bool:
    return run(["systemctl", "is-active", "--quiet", BROWSE_UNIT]).returncode == 0


def browse(action: str) -> None:
    """`restic mount` holds a repository lock; `forget --prune` needs an exclusive
    one. The browse mount is released for the run and handed back afterwards."""
    run(["systemctl", action, BROWSE_UNIT])


def do_backup() -> dict:
    # Two tags: "nightly" (what retention matches on) and the date, because
    # restic snapshot IDs are content hashes and cannot be named.
    args = ["backup", "--verbose=0", "--one-file-system",
            "--tag", "nightly", "--tag", datetime.now().strftime("%Y-%m-%d"),
            "/", "/home", "/opt", "--json"]
    for e in EXCLUDES:
        args += ["--exclude", e]
    res = restic(*args, check=False)
    summary = {}
    for line in res.stdout.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("message_type") == "summary":
            summary = obj
    if res.returncode:
        raise RuntimeError(f"backup failed (rc={res.returncode}): {res.stderr.strip()[:300]}")
    return summary


def forget() -> subprocess.CompletedProcess:
    return restic("forget", "--tag", "nightly", *RETENTION, "--prune", check=False)


# ---------------------------------------------------------------- notifications
_PUSH: list = []   # sent after main() returns - see push_pending()


def queue_notification(title: str, body: str, urgent: bool) -> None:
    _PUSH.append((title, body, urgent))
    STATE.mkdir(parents=True, exist_ok=True)
    with QUEUE.open("a") as fh:
        fh.write(json.dumps({"when": datetime.now(timezone.utc).isoformat(),
                             "title": title, "body": body, "urgent": urgent}) + "\n")
    if DESKTOP_FLUSH_CMD:
        run([DESKTOP_FLUSH_CMD])


def push_pending() -> None:
    """The notification server is itself a container that the backup stops, so a
    message sent from inside main() could be lost. Send at the very end, after
    waiting up to 2 min for the server to be healthy again."""
    if not _PUSH:
        return
    for _ in range(24):
        if run(["curl", "-sf", "-m", "5", NOTIFY_HEALTH_URL]).returncode == 0:
            break
        time.sleep(5)
    for title, body, urgent in _PUSH:
        run([NOTIFY_CMD, TOPIC_ALERT if urgent else TOPIC_OK,
             "5" if urgent else "2", title, body])


def write_status(**kw) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    STATUS.write_text(json.dumps(kw, indent=1, default=str))
    os.chmod(STATUS, 0o644)


# ---------------------------------------------------------------- main
def main() -> int:
    started = datetime.now()
    log("=== backup run starting")

    # The backup owns the CIFS mount for the whole run; the browse service gets it
    # back in `finally`, so even a crashed run leaves backups browsable.
    browsing_at_start = browse_running()
    if browsing_at_start:
        browse("stop")
        log("browse mount released for the duration of the run")
    stopped = False
    try:
        quiet, waited = wait_for_quiet()
        mount_share()
        log("backup share mounted")
        if restic("cat", "config", check=False).returncode:
            log("initialising repository")
            restic("init")

        stop_all()
        stopped = True
        summary = do_backup()
        start_all()
        stopped = False
        log("containers started")

        added = summary.get("data_added", 0) / 1024**2
        files = summary.get("total_files_processed", 0)
        secs = summary.get("total_duration", 0)
        log(f"backup complete: {files} files, {added:.0f} MB added, {secs:.0f}s")

        # check=False so a failed prune never aborts a good backup - but it must be
        # REPORTED. A stale lock (left by a browse mount whose host went to sleep)
        # is cleared with `restic unlock`, which only removes locks of dead processes.
        res = forget()
        if res.returncode and "already locked" in (res.stderr or res.stdout or ""):
            log("repository locked - clearing stale locks and retrying retention")
            restic("unlock", check=False)
            res = forget()
        if res.returncode:
            err = (res.stderr or res.stdout or "").strip().replace("\n", " ")
            log(f"WARNING: retention FAILED (rc={res.returncode}): {err[:200]}")
            queue_notification("Backup retention FAILED", err[:250], urgent=True)
        else:
            log("retention applied")

        snaps = restic("snapshots", "--json", check=False)
        count = len(json.loads(snaps.stdout)) if snaps.stdout.strip().startswith("[") else 0
        write_status(result="ok", finished=datetime.now(timezone.utc).isoformat(),
                     files=files, mb_added=round(added, 1), snapshots=count,
                     waited_minutes=int(waited.total_seconds() // 60),
                     ran_while_busy=not quiet,
                     duration_seconds=int((datetime.now() - started).total_seconds()))
        queue_notification("Backup complete",
                           f"{files:,} files - {added:.0f} MB added - {count} restore points",
                           urgent=False)
        return 0

    except Exception as exc:  # noqa: BLE001 - report everything
        log(f"FAILED: {exc}")
        write_status(result="failed", finished=datetime.now(timezone.utc).isoformat(),
                     error=str(exc)[:500])
        queue_notification("Backup FAILED", str(exc)[:300], urgent=True)
        return 1
    finally:
        if stopped:
            start_all()
            log("containers restarted after failure")
        if os.path.ismount(MOUNT):
            run(["umount", str(MOUNT)])
        if browsing_at_start and not browse_running():
            browse("start")
            log("browse mount handed back")


if __name__ == "__main__":
    rc = main()
    push_pending()
    sys.exit(rc)
