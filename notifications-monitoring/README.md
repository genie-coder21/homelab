# Notifications and monitoring

One self-hosted notification hub for the whole homelab. The server, its containers, the backup job, the intrusion-prevention stack and the Windows gaming-pc all publish to it. Desktop toasts on Windows and the phone app subscribe to it.

Before this existed, signals were scattered. Backup results popped up on the server's own desktop where nobody sits, security bans lived in a log file, and a broken service stayed invisible until someone noticed.

## Architecture

```
                         +-----------------------------------------------+
  backup job ----------->|                                               |
  intrusion prevention ->|   ntfy (container on the server)              |
  self-hosted apps ----->|   LAN + VPN only, deny-all by default         |
  hl-watchdog (5 min) -->|                                               |
  hl-notify (anything) ->|   topics: lab-alerts | lab-info | lab-security |
                         +---------+---------------------+---------------+
  gaming-pc monitor ------------->^ |                     |
  (publishes its own events)        | JSON stream         | poll request only
                                    v                     v
                      gaming-pc: native toast      ntfy.sh -> Apple push -> phone app
                      subscriber (WinRT)            (phone then fetches the message
                                                     from the server over the VPN)
```

### Topics

| Topic | Carries | Priority |
|---|---|---|
| `lab-alerts` | something is broken: backup failed, container down, disk full, tunnel or internet down, disk I/O errors | 3 to 5 (5 buzzes) |
| `lab-info` | FYI: backup succeeded, routine events | 2 to 3 (quiet) |
| `lab-security` | intrusion-prevention bans (batched), the VPS firewall bouncer stopped pulling decisions | 2 to 4 |

Splitting topics is the point. Put everything on one topic and you mute all of it within a week.

### Accounts

The server runs with `auth-default-access: deny-all`, so nothing works without a login. There are three kinds of identity:

- **a human login** for the phone and the browser, with read-write access to the lab topics
- **a write-only publisher token** for everything on the server. It can send but not read.
- **a read-write token for the gaming-pc**, which both subscribes and publishes

Tokens live in the server's TPM-bound secret store (see `../secrets-and-hardening`). On Windows the token is wrapped with DPAPI, so only that user on that machine can decrypt it. It is never kept in a script or on a share.

## Components

| Piece | Where | What it does |
|---|---|---|
| `scripts/ntfy-server/` | server | compose file and `server.yml` for the ntfy container |
| `scripts/server/hl-notify` | server | one-line publisher for any script. It **always exits 0**, so a dead hub can never fail the job that called it, and it logs dropped messages to the journal |
| `scripts/server/hl-watchdog` + `.timer` | server | health checks every 5 min (below) |
| `scripts/server/hl-mailquota` + `.service` / `.timer` | server | every 5 min: counts the mail VPS's relayed sends in the last 24 h over SSH and publishes the first crossing of 50 / 75 / 90 / 98 % of the relay's daily allowance each day, plus one line each morning with yesterday's total; since 2026-10-28 it also alerts when the mail filter's Gmail API import starts falling back to the relay |
| `scripts/server/hl-notify-flush` | server | the older local fallback: queued backup results become desktop popups at the next graphical login |
| `scripts/windows/ntfy-subscriber.ps1` | gaming-pc | streams the topics and raises native Windows toasts |
| `scripts/windows/send-ntfy.ps1` | gaming-pc | publishes from Windows (JSON, UTF-8 safe) |
| `scripts/windows/gaming-pc-monitor.ps1` | gaming-pc | the PC's own health checks, published on change |
| `scripts/windows/install-ntfy-subscriber.ps1` | gaming-pc | registers the toast sender and the two at-logon scheduled tasks |

## The watchdog

`hl-watchdog` covers what the apps can't report about themselves. It alerts **once** when a problem starts, reminds every **6 hours** while it lasts, and sends **"Recovered"** when it clears. Flappy checks need 2 or 3 consecutive failures before they fire. A check that throws is recorded and skipped, so one broken check never takes down the others. State is written atomically, and there is a dry-run mode that prints instead of sending.

| Check | Fires when |
|---|---|
| mount | the data disk is not mounted |
| container-mounts | a running container sees an **empty** bind mount of the data disk while the host sees files. This catches the Docker-started-before-the-disk race (see HISTORY) |
| containers | any container is not running or is unhealthy. It stands down while the backup has containers stopped on purpose |
| disk | `/` or the data disk is at least 90 % full |
| tunnel | no WireGuard handshake with the VPS for 3 minutes |
| public | the fronted web services don't answer 200 through the VPS (3 times in a row) |
| internet | none of the probe hosts answers on TCP **443** |
| failed-units | any failed systemd unit |
| services | a must-always-run unit (e.g. the tunnel) is not active |
| backup-fresh | the last good backup is more than 30 h old. This catches "the timer never ran", because the backup reports its own failures |
| bouncer | the VPS firewall bouncer hasn't pulled ban decisions for 15 min |
| data-disk | the kernel logs I/O errors or resets on the data disk |
| certs (daily) | public TLS certificates expire within 14 days |
| ssd-smart (daily) | the system SSD's SMART health is not PASSED |

## Windows toasts

The subscriber holds a long-lived JSON stream on all lab topics. It saves the last message ID and resumes with `?since=` after sleep or a server reboot, so nothing is missed. It backs off from 5 to 60 seconds and retries forever.

Priority mapping:

| Priority | Toast |
|---|---|
| 5 | "reminder" scenario: alarm sound, stays on screen, Dismiss button |
| 4 | normal toast with sound |
| 3 | normal toast |
| 1 and 2 | silent, delivered to Action Center only |

A message's `click` URL opens when the toast is clicked. A topic icon prefixes the title.

The gaming-pc also publishes. Every 5 minutes it checks the Hyper-V service, physical disk health, free space, the health of selected VMs and new `ERROR` lines in a watched log. It alerts on change only and sends a quiet "Resolved" when a problem clears.

## Phone

A self-hosted ntfy server can't wake an iPhone by itself. `upstream-base-url: https://ntfy.sh` fixes that without handing over content: ntfy.sh only receives a poll request (the message ID and a hash of the topic). The app then fetches the real message from the home server, which needs the VPN when away from home. `base-url` must match the server URL entered in the app **exactly**.

## Design decisions

- **ntfy over a SaaS push service.** It needs no account, the container is tiny, many self-hosted apps speak it natively, and anything else can publish with one HTTP POST.
- **Not exposed to the internet.** The hub is reachable from the LAN and the VPN only. Nothing on it needs to be public.
- **A native toast subscriber instead of the web app (PWA).** The original plan was to install the ntfy web app as a PWA, but browsers only allow notifications over HTTPS and this server is deliberately plain HTTP on the LAN.
- **The backup sends its result after it finishes, not during the run.** The backup stops every container, the hub included, so a message sent mid-run would be lost. Results are queued and pushed once containers are back.
- **Alert on change, not on state.** Both the watchdog and the Windows monitor keep state, so a problem that lasts all night produces one alert plus a reminder every few hours, not 100 identical pushes.

## Traps and lessons learned

- **Toasts never appear from SSH.** SSH sessions on Windows run in session 0, so nothing reaches the logged-in desktop. The subscriber has to be a scheduled task with an *interactive* logon in the user's own session.
- **PowerShell 5.1 needs UTF-8 *with BOM*.** Without it, emoji and symbols in the script become mojibake in the toasts. The installer re-saves the scripts with a BOM.
- **HTTP headers are ASCII-only.** An em dash in a `Title:` header broke every alert from one client tool. Publish as JSON (all the helpers here do) and make the notify function unable to raise.
- **PowerShell 5.1 over SSH strips inner quotes**, so a multi-word title passed to a Linux helper gets split. This is harmless but confusing.
- **Probe the internet on 443, not 53.** An outbound filter on the host refused TCP 53, so a DNS-port probe "failed" forever while the internet was fine.
- **USB enclosures often don't pass SMART through**, even with SAT pass-through. For that disk, kernel I/O errors are the only early warning, so the watchdog reads the kernel log.
- **CrowdSec's stock `profiles.yaml`** has the commented-out `notifications:` lines between `decisions:` and `on_success:` in *each* profile. The first edit missed one profile, and the notification plugin showed as unused.
- **Saving a notification target in many self-hosted apps also sends a test**, so expect to see every test twice.
- **A log the monitor watches must be writable by whoever writes it.** A helper running under another account "ran fine" but logged nothing because the log folder wasn't writable for it. Check permissions before trusting silence.
