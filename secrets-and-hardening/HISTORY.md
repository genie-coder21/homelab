# History

## 2026-09-20: the base build

The server was rebuilt from a wiped SSD, and remote access was hardened first, in a deliberate order:
1. Install the SSH server.
2. Add the admin workstation's public key and **prove a key login works**.
3. Only then turn off password authentication and root login.

Doing it the other way round is how people lock themselves out. The settings went into a drop-in file rather than the distribution's main config, so package upgrades merge cleanly. The host key fingerprints were written down so any new client could verify the server on first connect.

Docker was installed from the vendor's repository with the compose plugin. The layout convention was set on day one: one folder per stack under `/opt`, compose file plus a `config/` folder, a single external network so containers find each other by name, restart-unless-stopped, an explicit timezone, and the unprivileged service UID for every container.

## 2026-09-22: the firewall, and Docker's way around it

The host firewall went on with a default-deny inbound policy and narrow allowances: the LAN, plus the VPN tunnel from the VPS reaching only the fronted services.

The catch with Docker is that published container ports are wired in through Docker's own iptables rules, which **bypass the host firewall**. A published port would be reachable no matter what the firewall said. The fix was explicit rules in the `DOCKER-USER` chain, the hook Docker provides for exactly this.

Locking yourself out of a remote box with a firewall change is easy, so the new rule set was enabled behind a **timed auto-disable guard** that would revert it after five minutes unless cancelled. Every path was tested (LAN, tunnel, container-to-host) before the guard was cancelled.

## 2026-09-23: the secret store

The problem was that backup credentials (the network share password and the backup repository key) sat in a plaintext file. Three options were weighed: tighter file permissions, an external password manager, or the TPM. The server has a TPM 2.0 chip, and `systemd-creds` can encrypt to it, so the result is ciphertext that only this machine can decrypt. A stolen disk or a copied file is worthless. That was the chosen option.

Two tools came out of it:
- **`hl-secret`**, a small CLI over `systemd-creds` with set (from stdin, never argv), new (generate and print once), get, list and rm.
- **`hl-compose`**, a wrapper that renders a stack's `.env` from `@secret:` placeholders, runs compose and shreds the file afterwards.

The backup's credentials were moved into the store and loaded by the backup unit with `LoadCredentialEncrypted=`. The old plaintext file was shredded. A restore test confirmed the backup still worked end to end.

The same day the question came up whether the TPM store could hold credentials that some apps keep for talking to *other* services. It can't. Those apps persist credentials in their own databases and accept no external secret source, and handing them a decrypted value just makes them write it out again. The conclusion, recorded so it isn't re-litigated: **the TPM protects what we hand to a program at start time; for anything an app persists itself, the real fix is to stop needing the credential.** Where that was done, the old stored values were deleted and the app databases vacuumed, so the deleted values didn't linger in free pages.

## 2026-09-24: two bugs in the wrapper

While putting a new container behind the wrapper, it turned out the wrapper had **never done anything**. The script had no `__main__` entry point, so it imported, exited 0 and printed nothing. As a result, one app had kept its default admin password since day one. The fix was the missing line and a real password for that app. The lesson was to verify security tooling by its *effect*, not its exit status.

The second bug was in the compose guard. The `${VAR:?message}` guard had a message containing a colon followed by a space, so YAML parsed the whole environment entry as a mapping. The fix was to quote the entry and keep colon-space out of guard messages.

## 2026-09-25: the guard bites the backup

A failed overnight backup was investigated, and one finding was that the backup's quiesce step had been **silently skipping exactly the stacks that held secrets**. It used the plain compose stop action, and compose can't even parse a file with `:?` guards when the secrets aren't rendered. Those containers ran through every backup, so their config was captured live instead of quiesced, and the run still reported success. The fix was to stop and start containers by their **compose project label**, which needs no file parsing, and to restart only what was actually stopped. The boot-time container starter got the same fix. Verification was a full cycle: every container stopped and came back.

## 2026-09-29: credentials in units, not wrappers

A new service needed a TPM-held secret. The first approach was a small wrapper calling `systemd-run` to decrypt it, which failed for a non-root service with "Interactive authentication required". The fix was simpler and tighter: the unit carries `LoadCredentialEncrypted=` itself, and the value appears in the unit's private credentials directory.

The same day, a newly deployed web app's default admin password was replaced right away with a store-generated secret. That went through the app's own REST API instead of hand-computing its salted hash format, and a follow-up test confirmed the old default was rejected.

## 2026-09-30: Docker beat the disk

After a reboot, Docker started before the data disk's mount and every container bound the empty mountpoint. They ran "healthy" and blind for hours. The permanent fix was a Docker drop-in with `RequiresMountsFor=` on the data mount. That adds both an ordering and a hard requirement, which is a conscious trade-off: if the disk is dead, Docker now refuses to start rather than running blind, the safer and more noticeable failure. The watchdog also got a check for the symptom (see `../notifications-monitoring`).

## 2026-10-04: more consumers of the store

- **A cloud provider's CLI API key** was moved into the store and the plaintext key file shredded. A wrapper decrypts it to a per-user tmpfs for one invocation and removes it afterwards.
- **The notification hub's tokens** went in too. The intrusion-prevention container gets its notification token through `hl-compose`, and the Windows gaming-pc fetched its token over SSH once and re-wrapped it with DPAPI on its side.

## 2026-10-07: guarding what leaves the box

Configuration was set to be mirrored to a private git remote on a schedule. Each repository got its own deploy key, held in the store, and a **secret scan runs before every push and blocks it on any hit**.

## 2026-10-08: the build cache

Repeated image rebuilds had left about 255 GB of stale build-cache layers and pushed the system disk to 71 %. A one-off trim to 30 GB freed 225 GB. To stop it recurring, `hl-compose` now trims the build cache after any build. It never fails the build and prints what it freed. A daily timer, scheduled after the nightly backup, is the backstop. Recent layers are kept, so builds stay fast.

## 2026-10-13: the public version

For this repository:
- Scripts were renamed and stripped of site details.
- The wrappers gained a root check, stack-name validation and a restrictive umask when writing `.env`.
- The examples folder shows each pattern (template, guard, unit credential, mount dependency, SSH drop-in) as a standalone file.

## 2026-10-28: A code-audit skill for the coding agent

Cloudflare published an open-source security-audit skill for coding agents: a folder of
Markdown guidance plus two small validators, no scanner binary. It was installed as a
user-level skill by copying the folder from the official repository rather than through a
third-party installer, and its validator self-tests were run first. In full audit mode it
drives parallel hunter and verifier sub-agents over a codebase, writes structured findings
checked against a schema, and refuses to execute target code outside an OS-enforced
sandbox, reporting those checks as needing validation instead. It is meant for reviewing
the lab's own scripts before they are published here.

## 2026-10-28: A baseline host audit

The Linux hosts got a baseline audit pass with vendor-maintained tools: Lynis for the OS,
Trivy for container images, ssh-audit for the SSH daemons, Docker Bench for Security for
the container runtime, and nmap from each side of the tunnel to confirm what is actually
reachable. It was a read-only pass to establish a baseline; follow-up hardening is recorded
here as it lands. The external view came back as expected: the home connection answers on
nothing, and the VPS side answers only on the services it fronts.

## 2026-10-28: Acting on the audit, without breaking anything

The baseline audit's follow-ups were done the same night. They were split into four scoped
work streams (VPS, host settings, container images, runtime permissions), and each was
checked independently.

The rule that made it safe: a health baseline before anything else, then a re-check after
every single change, with an immediate rollback on any difference. Every change kept a
dated backup and a one-line rollback. Restarts were scheduled for quiet periods.

What landed:

- package updates;
- SSH algorithm hardening on the server and the VPS;
- the audit daemon, file integrity, rootkit and package-integrity checks;
- kernel and login defaults;
- updated container images, with locally built images rebuilt on current bases;
- the runtime daemon config, plus `no-new-privileges` and resource limits on every service.

The README sections above describe the end state.

Lessons:

- **`compose run` recreates dependencies whose image or config changed, even with
  `--no-deps`.** Don't pull or edit shared dependencies of a live stack outside a deploy
  window.
- **A memory limit sized from recent peaks can be hit by a rarer, larger workload.** Leave
  headroom, and announce live changes.
