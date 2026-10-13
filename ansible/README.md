# Ansible: one control node for the server and the gaming PC

The Linux server is the Ansible control node. It manages itself and the Windows 11 gaming PC,
and the Windows side is reached over the **OpenSSH server** that Windows already ships with,
not WinRM. Nothing had to be installed on the PC; the SSH key that was already in use for
remote administration is the one Ansible uses.

This is a deliberately small starting point: an inventory, a few read-only playbooks and one
patch playbook. The larger goal, rebuilding the whole server from playbooks, is described in
[the roadmap](../roadmap/).

## Layout

```
ansible.cfg                  inventory path, fact cache, pipelining
inventory/hosts.yml          two hosts in two groups: linux, windows
inventory/group_vars/        how each group is reached
playbooks/ping.yml           reach everything
playbooks/facts.yml          OS, uptime, memory, LAN address per host
playbooks/update-linux.yml   apt safe-upgrade, reports whether a reboot is pending (never reboots)
playbooks/windows-info.yml   service state + a Windows Update *search* on the PC (installs nothing)
```

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
- Distro packages (ansible-core 2.16) rather than pip: fine for this scope, and one less thing to maintain.
  If a collection ever needs a newer core, `pipx install ansible-core` is the escape hatch.
- The Linux update playbook never reboots. The server runs a media server and a nightly backup; a reboot
  is a decision for a human.
