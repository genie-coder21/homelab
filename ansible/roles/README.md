# roles

One role per hardening area. All are wired into `playbooks/hardening.yml` with a tag of the same short name.
Inventory groups: `linux` = the server (local connection), `cloud` = the vps (SSH).

| Role | Tag | Hosts | What |
|---|---|---|---|
| `hardening_ssh` | `ssh` | both | sshd drop-in rendered from defaults (key-only, pinned algorithm set), sshd_config mode, no ECDSA host key |
| `hardening_os` | `os` | both | kernel sysctl, no core dumps, unused protocol modules blocked, login banners, hash rounds, and host-specific items |
| `hardening_docker_daemon` | `docker` | server | `/etc/docker/daemon.json`, **no handler, never restarts docker** |
| `hardening_base` | `base` | both | process accounting, `compilers` group, umask 027, SysRq off, boot-loader password for editing only |
| `hardening_systemd` | `systemd` | both | per-unit sandbox drop-ins generated from one dict |
| `hardening_logging` | `logging` | both | remote log shipping vps → server → gaming-pc (the Windows end is `playbooks/logging-gaming-pc.yml`) |

Further host- and VPS-specific roles are kept private.

Every value that identifies a site (addresses, ports, user and secret names) is a `<PLACEHOLDER>` or an
RFC 5737 address in `defaults/main.yml`.
Fill them in before the first run.

## Rules for every role

- **Reproduce live first.** A new role starts as an exact copy of what is running, proven with
  `--check --diff` → `changed=0` on every host before it is ever applied.
- **Never restart sshd, docker, the WireGuard tunnel or the mesh VPN.** sshd: the handler runs `sshd -t`,
  then *reloads*. docker: no handler, only a "restart needed at the next maintenance window" message.
  sysctl: `sysctl -p <one file>`, never `--system`.
- **No secrets in the repo.** They are read from the TPM-bound store at run time, in a `no_log` task.
- **Two roles never manage the same file or key.** `login.defs` is split by key: UMASK → base,
  SHA_CRYPT_* → os, the rest → a private role. A new sysctl gets a new file.
- FQCN modules, a comment saying *why* on every task, knobs in `defaults/main.yml`.
- Change the live box only through the role: edit → `--check --diff` → apply → test → re-run = `changed=0`.
