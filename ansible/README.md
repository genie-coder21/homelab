# Ansible: one control node for the server, the VPS and the gaming PC

The Linux server is the Ansible control node. It manages itself and the Windows 11 gaming PC,
plus the cloud VPS over SSH. The Windows side is reached over the **OpenSSH server** that Windows already ships with,
not WinRM. Nothing had to be installed on the PC; the SSH key that was already in use for
remote administration is the one Ansible uses.

It started small: an inventory, a few read-only playbooks and one patch playbook. Since then the
host hardening of both Linux machines lives here as roles (see below). The larger goal, rebuilding the
whole server from playbooks, is described in [the roadmap](../roadmap/).

## Layout

```
ansible.cfg                  inventory and roles paths, fact cache, pipelining
inventory/hosts.yml          three hosts in three groups: linux (server), cloud (vps), windows (gaming-pc)
inventory/group_vars/        how each group is reached
playbooks/ping.yml           reach everything
playbooks/facts.yml          OS, uptime, memory, LAN address per host
playbooks/update-linux.yml   apt safe-upgrade, reports whether a reboot is pending (never reboots)
playbooks/windows-info.yml   service state + a Windows Update *search* on the PC (installs nothing)
playbooks/hardening.yml      the hardening baseline for server + vps, one role per area (tags)
playbooks/audit-compose.yml  read-only: every compose service meets the container standard
playbooks/logging-gaming-pc.yml  the Windows end of the remote-log chain
roles/                       the hardening roles; see roles/README.md
```

## The hardening playbook

`playbooks/hardening.yml` applies the public roles to the two Linux hosts, each behind a tag of its own
(`ssh`, `os`, `docker`, `base`, `systemd`, `logging`), so one area can be run on one host at a time. The
roles and what each owns are listed in [roles/README.md](roles/README.md). Further host- and VPS-specific
roles are kept private.

The rules that keep it safe:

- **Check mode first, every time.** A dry run with diff output comes before every real run. On a
  healthy day the full dry run reports `changed=0` on both hosts, and so does the Windows log playbook.
  Anything else is drift: find out why before applying.
- **`changed=0` after.** Every role is idempotent; the run after an apply must change nothing.
- **Roles never restart sshd or docker** (nor the tunnel or the mesh VPN). sshd gets a config test and
  a reload, which keeps existing sessions. A changed docker daemon config only prints a reminder to
  restart in a maintenance window.
- **Check mode can't prove everything.** It does not run `validate:`, handlers or shell tasks, so for sshd
  the config test is also run by hand before applying.
- **New roles start as a copy of what is live**, proven at `changed=0`, and only then changed.

`playbooks/audit-compose.yml` reads every `compose.yaml` under `/opt` and fails if any service lacks
`no-new-privileges`, a memory limit, a process limit or log rotation. It changes nothing.

## Windows over SSH: what matters

- **`ansible_shell_type` must match the sshd default shell on the PC.** Windows OpenSSH defaults to
  `cmd.exe`, so the inventory says `cmd`. If the default shell is ever switched to PowerShell, the
  inventory has to change in the same step, or every task fails with confusing quoting errors.
- **No Python is needed on Windows.** Setting `ansible_python_interpreter: none` skips the interpreter
  discovery that would otherwise warn on every run. Windows tasks use the `ansible.windows` modules;
  the `ansible.builtin` ones for Linux (apt, stat, …) don't exist there.
- A Windows Update search is a real scan and takes half a minute or more even though it installs nothing.

## Decisions

- Project lives on the data drive rather than the OS disk, so it survives an OS reinstall, and inside
  the file share so it can be edited from the PC.
- Distro packages rather than pip: fine for this scope, and one less thing to maintain.
  If a collection ever needs a newer core, `pipx install ansible-core` is the escape hatch.
- Host-specific files are not copied verbatim into roles here; settings are rendered from variables, so
  this public copy carries no site details.
- The Linux update playbook never reboots. The server runs long-lived services and a nightly backup; a reboot
  is a decision for a human.
