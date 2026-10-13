# Secrets and hardening

How the homelab server keeps credentials out of config files, injects them into services and containers at start time, restricts remote login, and lays out its Docker stacks so they behave the same way every time.

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
