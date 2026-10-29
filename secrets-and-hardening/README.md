# Secrets and hardening

How the homelab server keeps credentials out of config files, injects them into services and containers at start time, restricts remote login, hardens and sandboxes its hosts, ships their logs off-box, and lays out its Docker stacks so they behave the same way every time. The host hardening itself is code: Ansible roles in [`../ansible/roles`](../ansible/roles/).

## Goals

- **No plaintext secret in any config file**, compose file, git repository or backup of those.
- **A stolen disk or a copied credential file yields nothing.**
- **Secrets are handed to programs at start time** and never written somewhere a program might keep them.
- **One obvious, repeatable way to do it**, so the next service gets it right without thinking.

Application passwords can't be *hashed* here: the apps have to send the real value. So the target is "encrypted at rest, bound to this machine, root-only, never in a config file".

## Architecture

```
                 TPM 2.0 (on the server's motherboard)
                        |
                        | seals / unseals
                        v
   /etc/credstore.encrypted/<name>     ciphertext, root-only, useless on any other machine
          |                     |
          | hl-secret get       | LoadCredentialEncrypted=
          v                     v
   hl-compose <stack> ...    systemd unit
   renders .env (0600)       value appears in $CREDENTIALS_DIRECTORY
   runs docker compose       (private tmpfs, gone when the unit stops)
   shreds .env
          |
          v
   container environment
```

## The secret store: `hl-secret`

`hl-secret` is a thin wrapper around `systemd-creds`. Values are encrypted to the machine's TPM, so the files in the store are ciphertext that only this machine can decrypt. It is root-only.

| Operation | What it does |
|---|---|
| `set` | reads a value from **stdin**, never from an argument, because arguments leak into the process list and shell history |
| `new` | generates a strong random value, stores it, and prints it **once** for the cases where a human also needs it |
| `get` | prints the value |
| `list` | shows names only |
| `rm` | deletes an entry |

Secrets never leave the box. Rebuilding the machine means re-entering them; a rebuild script can recreate the *slots* and list what to fill in, which is the intended behaviour.

## Giving a secret to a container: `hl-compose`

Each stack can have a `.env.template` with `@secret:NAME` placeholders. The template is safe to commit. Starting a stack through `hl-compose` (stack name plus the usual compose arguments) then:

1. decrypts each referenced secret
2. writes `.env` with mode 0600 (created under a restrictive umask, so it is never briefly readable by others)
3. runs `docker compose`
4. **shreds `.env`** in a `finally` block, even when compose fails

The compose file references the variable with a `${VAR:?message}` guard (see `scripts/examples/`). If anyone starts the stack with plain `docker compose`, it fails loudly instead of starting with an empty password.

After any build, `hl-compose` also trims Docker's build cache back to a fixed size. A daily timer is the backstop.

## Giving a secret to a systemd service

The unit declares `LoadCredentialEncrypted=` itself. systemd decrypts the value into a private, root-only tmpfs for the life of the unit. No wrapper script is needed (see `scripts/examples/service-with-credential.service`).

## Windows side

Secrets the gaming-pc needs (e.g. a notification token) are fetched once over SSH from the server's store and wrapped with **DPAPI**. Only that user on that machine can decrypt them. They never sit in a script or on a network share, and they are never printed.

## Remote login

- **SSH accepts public keys only.** Password and keyboard-interactive authentication are off, root login is off, there are few auth tries and a short grace time. All of this lives in a **drop-in** under `sshd_config.d/`, so the distribution's main config stays untouched and upgrades merge cleanly. The config is validated before every reload.
- SSH is **socket-activated**. systemd holds the port and starts the daemon per connection, so "service inactive" is normal; check the socket instead.
- **A modern algorithm set is pinned in the same drop-in** (post-quantum hybrid and curve25519 key exchange, AEAD ciphers, encrypt-then-MAC, Ed25519 and RSA host keys only, per the ssh-audit hardening guide). The ECDSA host key was retired; clients that had pinned it drop it on their own through OpenSSH's host-key update. Agent forwarding is off and each login logs the key fingerprint used.
- **Host key fingerprints are recorded** so a new client can verify the server on first connect.
- **The client's private key is the only way in over SSH**, so keep a backup of it and a separate local-console recovery path.

## Firewall

- **Host firewall, default deny inbound.** The LAN and the VPN tunnel only get what they need, and the tunnel from the VPS can reach only the specific fronted services.
- **Docker-published ports are filtered too**, in the `DOCKER-USER` chain. Docker's own rules otherwise bypass the host firewall, so a published port would be open no matter what the host firewall says. Every new service exposed this way gets a matching rule, and it is tested from each network (LAN, tunnel, VPN) before it counts as done.
- **New firewall rule sets are enabled behind a timed auto-disable guard.** If a change locks out remote access, it reverts itself after a few minutes. Every path is tested before the guard is cancelled.
- **Intrusion prevention** (CrowdSec) runs its decision engine at home and its firewall bouncer on the internet-facing VPS. The watchdog alerts if the bouncer stops pulling decisions (see `../notifications-monitoring`).

## Docker layout conventions

- **One folder per stack:** `/opt/<name>/compose.yaml`, persistent data in `/opt/<name>/config/`, and an optional `.env.template`. Nothing lives in anonymous volumes, so backups and rebuilds are just "copy the folder".
- **A shared external network.** Containers on it reach each other by name, and nothing needs a hard-coded IP.
- **`restart: unless-stopped`** everywhere. Containers come back after a reboot unless someone stopped them deliberately.
- **Containers run as the unprivileged service UID/GID** (via `PUID`/`PGID` for images that support it, `user:` for the rest), so files they create have the right owner.
- **The timezone is set explicitly** in every container.
- **Docker waits for the data disk.** A drop-in with `RequiresMountsFor=` makes Docker require the data disk's mount (see the trap below).
- **Secrets only via `hl-compose`.** Stacks that need secrets carry a `${VAR:?}` guard.
- **The build cache is capped**, after every build and daily.

## Traps and lessons learned

- **A wrapper that silently does nothing is worse than no wrapper.** The first version of the compose wrapper had no `__main__` entry point. It "ran", exited 0 and did nothing, so one app quietly kept its default admin password until the bug was found. Test a security tool by checking its *effect* (the app's password actually changed), not its exit code.
- **Colon-space inside a `${VAR:?message}` guard breaks YAML.** The entry parses as a map. Quote the whole entry and keep `": "` out of the message.
- **Guarded compose files can't be parsed without their secrets.** The backup's quiesce step used the plain compose stop action, which failed on exactly the stacks that held secrets, so those stacks were silently never stopped while the backup still reported success. The fix was to stop and start containers by their compose project *label*, which needs no file parsing, and to restart only what was actually stopped.
- **Don't wrap secret decryption in `systemd-run` scripts for non-root services.** They fail with "Interactive authentication required". Put `LoadCredentialEncrypted=` in the unit.
- **The store only helps with secrets handed over at start time.** Apps that persist credentials in their own database can't take a TPM-held secret; giving them a decrypted value just makes them write it back out. For those, the better move is to remove the need for the credential.
- **Replace default admin passwords immediately**, through the app's own API where possible, instead of hand-computing its password hash format. Then verify that the old default is rejected.
- **Cloud CLI keys can be TPM-held too.** A small wrapper decrypts the key to a per-user tmpfs for a single call and deletes it afterwards, so the plaintext key file is never kept.
- **Build caches grow without limit.** Repeated image rebuilds left about 255 GB of stale layers and took the system disk to 71 %. Trimming to a fixed size after each build and daily keeps recent layers (fast rebuilds) without the growth.
- **Docker can beat the disk at boot.** Without the mount dependency, containers start against the empty mountpoint and run "healthy" while blind. Make the dependency explicit and monitor for the symptom too.

## Auditing and integrity

- **The Linux audit daemon** watches the container runtime: its binaries, socket, config directory and daemon config file, and its systemd units. Any change there leaves a keyed record. Logs rotate at a fixed total size. Watches are kept to config and binaries, so the log volume stays useful.
- **File integrity (AIDE)** covers the system directories with a single strong hash, nightly at idle priority. Trap: the distribution's default includes the whole filesystem, which on a large data disk hashes everything and needs gigabytes of memory; scope it.
- **A rootkit checker** runs daily and **a package-integrity check** weekly. Both run offline and re-baseline automatically after package upgrades.
- **Kernel and login defaults:** no core dumps for setuid programs (the crash reporter is disabled, because it would quietly turn that back on at boot); stricter kernel-pointer and BPF JIT settings; martian-packet logging; protected FIFOs; unused network protocol modules blocked. One trap: a distribution sysctl file sorts after a `90-` name and overrides it, so that setting needed a later-sorting file name to win.

## Container runtime defaults

- **Daemon config:** live-restore, so a runtime upgrade or restart no longer restarts every container. `no-new-privileges` is the default for new containers, and logs are rotated by default. The config is validated before any restart.
- **Every compose service states `no-new-privileges`, a memory limit, a process-count limit and log rotation explicitly.** Limits were sized at three times or more the measured peaks. Each container was function-tested after the change, not only checked for "running". None needed an exception. Daemon defaults apply only when a container is created, so the explicit per-service settings are what make the change hold.
- **Trap:** binding a published port to a single interface address can stop the container starting if that interface isn't up yet at boot.

## Host hardening, second pass

All of the following is applied by the Ansible roles in `../ansible`, on the server and the VPS unless noted. Further host- and VPS-specific roles are kept private.

- **Process accounting.** The kernel records every process that exits (which command, which user, when). The log rotates daily and is kept for a month.
- **Compilers are not for everyone.** The assembler and any C compiler belong to a `compilers` group with mode 0750, set through `dpkg-statoverride` so a package upgrade re-applies it instead of resetting it. A compromised service account can't build a local exploit on the box. Package scripts and Docker builds (which compile inside the image) are unaffected.
- **A stricter default umask (027),** so new files aren't world-readable. It reaches every PAM session, including privilege escalation and Ansible's `become`, so administrative work now creates 640/750 files. Anything a non-root reader needs gets an explicit mode.
- **Magic SysRq is off,** so nobody at a console can send reboot or kill key combinations. It is its own sysctl file that sorts after the distribution's.
- **A boot-loader password for editing only.** Editing a boot entry, the boot-loader command line and recovery entries need a password; normal boot stays unattended. A wrapper runs the distribution's own menu generator and marks every normal entry `--unrestricted`, and the stock generator is kept non-executable by a stat override so it doesn't run twice. A boot password must never block an unattended boot, so there is an **automated gate**: the role builds a candidate config, a verify script proves the default and every normal entry are unrestricted, recovery entries are not, and the syntax is valid, and only then is the real config regenerated. The wrapper itself refuses to emit a config if any entry was missed. The password is read from the TPM-bound store at run time; the hash is computed at run time so the role stays idempotent, and is never stored in the repository.
- **Password quality and hashing** for passwords set from now on: long passphrases with several character classes and a dictionary check, yescrypt matching PAM, ageing defaults for new accounts. SSH stays key-only, so none of this affects logins.
- **One TLS policy for every site.** The VPS's reverse proxy gets its TLS settings (TLS 1.2 and 1.3, Mozilla intermediate ciphers, no session tickets, no version banner) once, at the http level, in a single shared file. Every site, including future ones, inherits it. HSTS is opt-in per host. Cipher scans before and after were identical, so older clients were unaffected.
- **System mail stays local.** Mail the system sends to root is delivered to a local mailbox and never relayed out; the server collects it and turns each message into a push notification.

### Sandboxed services

Every systemd service written for this lab gets a sandbox **drop-in** (the unit file itself is never edited), and all of them are generated by one role from **one dictionary**: unit name → options, a one-line reason, and whether it is a long-running daemon. The options start from five profiles:

| Profile | For |
|---|---|
| strict user | a plain user script: no new privileges, no capabilities, private `/dev`, no writable-and-executable memory, a read-only system |
| root, docker socket only | the socket is a file, so even a private network namespace works |
| root tools | root scripts that need system tools and the TPM: everyday capabilities kept, the dangerous ones dropped |
| user with helpers | like root tools for a non-root script, without no-new-privileges for the units that genuinely need privileged helpers |
| no mount namespace | a unit that mounts something the rest of the host must see |

**Every option set is tested before it is installed:** the unit's real command, or a harmless equivalent, runs through `systemd-run` with exactly the same options and is compared with an unsandboxed run. Daemons are then restarted once, on purpose, and their function checked, not just their state. The role itself only reloads systemd and never restarts anything: a timer job picks up its drop-in on its next run, a daemon at its next deliberate restart. Setting `enabled: false` on an entry removes the drop-in again; that is the rollback. The exposure score from `systemd-analyze security` dropped for every unit.

### Remote logging

Logs leave each machine so an intruder can't quietly erase them:

```
   vps --(TCP over the WireGuard tunnel)--> server --(TCP over the LAN)--> gaming-pc
         size-capped disk queue                     size-capped disk queue  PowerShell receiver
```

- Both hops are rsyslog forwarding with a **size-capped disk queue**, so a brief outage of either leg loses nothing.
- The server's listener binds only to its tunnel address and accepts only the VPS end of the tunnel (host firewall plus a check in the ruleset). The VPS's lines go to their own files and never into the server's own logs, so the server's intrusion detection doesn't mistake attacks on the VPS for local ones.
- Services that write their own log files (the reverse proxy) are read with `imfile`. A service whose log was root-only was switched to log via journald, so rsyslog can read it.
- The gaming PC runs a **tiny PowerShell receiver** under Windows PowerShell 5.1, so nothing is installed. A scheduled task starts it at boot as SYSTEM and restarts it if it exits. It accepts only the server's address (a single-address firewall rule allows nothing else either), writes one file per host per day, and prunes old files.
- Both queues were tested by stopping one leg, logging, and checking that every line arrived after it came back.

### File integrity, alerted by pull

AIDE runs on the VPS on a schedule and leaves a short verdict. The alert is a **pull**: the server reads the verdict and sends the notification. **The internet-facing VPS holds no notification token**, and a scan that silently stopped running is caught as well, because a stale verdict is itself an alert.

## The hardening standard for every new service

A checklist every new service follows, so hardening doesn't decay as things are added:

- **Containers:** every compose service states `no-new-privileges`, a memory limit and a process limit sized at about three times the measured peak, and log rotation, even where the daemon default already covers it. A read-only playbook fails if any service lacks one. Secrets only through `hl-compose`. Publish no port you don't need; anything reachable through the VPS gets matching firewall rules on both sides.
- **systemd units:** a sandbox entry in the dictionary, tested under `systemd-run` first, the score checked before and after, and a re-run of the role that changes nothing.
- **Sites on the VPS:** inherit the shared TLS file; never redeclare its settings at the http level. Logs go where the intrusion detection and the log shipper already look. Reload the proxy after a config test, never restart it.
- **Accounts:** system accounts without a shell or password; explicit file modes for anything a non-root reader needs.
- **Logs:** a service that logs to journald needs nothing more; one that writes its own files gets one line in the log shipper's list.
- **After a deliberate system change:** accept the new file-integrity baseline in the same session.
- **Every change through Ansible:** dry run, apply, test the service, re-run until `changed=0`, and a health check before and after with a rollback on any difference.

## Traps from the second pass

- **No-new-privileges breaks setuid/setgid helpers** that some system tools hand work to. Check what a unit calls before choosing a profile.
- **Mount-namespace options hide mounts.** `PrivateTmp`, `ProtectSystem`, `ProtectHome` and friends give the unit its own mount namespace, so a share it mounts is invisible to the host. Units that mount things get only the options that don't need one. `ProtectHome` also covers `/run/user`, and `PrivateTmp` hides `/tmp` from test scripts.
- **AppArmor vs config validation.** rsyslog's validator can't read a temporary file outside its AppArmor profile, so a template's `validate:` fails. Write the file, validate the live tree, and stop before the restart if it fails.
- **Socket activation undoes a stop.** Stopping rsyslog alone is reversed at once by its socket unit; stop both for a test.
- **New-style rsyslog file actions ignore the legacy file-mode directive;** set the mode and group on each action.
- **A listener bound to a tunnel address must start after the tunnel,** because rsyslog never retries a failed bind. An ordering-only dependency keeps it from blocking boot if the tunnel fails.
- **The umask change reaches administrative sessions,** so files created there lost world-read. Long-running sessions see the umask and the new group only after a fresh login.
- **No backup copies in `sources.list.d` or `rsyslog.d`;** apt warns about them and rsyslog may load them.
- **A boot-loader update can change the menu format.** The wrapper and the verify gate refuse to write a config rather than produce one that stops at a password prompt.
