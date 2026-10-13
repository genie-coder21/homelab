# Homelab

A small self-hosted infrastructure built and run at home: one always-on Ubuntu server, one Windows 11 gaming PC, and a free-tier cloud VPS as the public front door. Each folder is a self-contained project with its design notes, the lessons learned along the way, a dated history of changes, and sanitized copies of the scripts that run it.

```
                 internet
                    |
             +-------------+        WireGuard tunnel        +-------------------+
             |     vps     | <----------------------------> |      server       |
             | reverse     |   (home exposes no ports)      | Ubuntu 24.04      |
             | proxy +     |                                | Docker, restic,   |
             | CrowdSec    |                                | orchestration,    |
             | bouncer     |                                | ntfy, watchdogs   |
             +-------------+                                +-------------------+
                                                                |   wake-on-LAN,
                                                                |   SSH + PowerShell
                                                                v
                                                       +-------------------+
                                                       |    gaming-pc      |
                                                       | Windows 11 Pro    |
                                                       | Hyper-V kids VMs, |
                                                       | backup target,    |
                                                       | local LLM (GPU)   |
                                                       +-------------------+
```

## Projects

| Folder | What it is |
|---|---|
| [backups](backups/) | Nightly restic backups to the gaming PC (woken on demand), an off-site Git mirror with pre-push secret scanning, and a boot-order guard for Docker |
| [kids-gaming-vms](kids-gaming-vms/) | Windows game VMs for the kids in Hyper-V, launched from a web page, streamed with Sunshine/Moonlight, managed and put to sleep by the server |
| [vps-front-door](vps-front-door/) | A free cloud VPS as the only public entry point, WireGuard back home, CrowdSec, layered firewalling, and the migration to a faster instance |
| [notifications-monitoring](notifications-monitoring/) | Self-hosted ntfy push notifications, a server watchdog, and Windows toast notifications |
| [secrets-and-hardening](secrets-and-hardening/) | TPM-bound secrets with systemd-creds, a compose wrapper that injects them, and host hardening conventions |
| [local-llm](local-llm/) | An Ollama model on the gaming PC's GPU, woken on demand by the server |
| [windows-power](windows-power/) | Power-plan switching scripts and shortcuts for the gaming PC |
| [ansible](ansible/) | The server as an Ansible control node for itself and the gaming PC, the Windows side over OpenSSH |
| [roadmap](roadmap/) | Design notes for planned work: a ZFS rebuild, an Ansible rebuild, a two-node k3s cluster |

## Conventions

- **Roles, not names.** "server", "gaming-pc" and "vps" stand in for the real machines. Addresses use the RFC 5737 documentation ranges or `<PLACEHOLDER>` values.
- **Every script is a template.** Site-specific values sit in a config block at the top and must be filled in before use.
- **Secrets never live in this repo.** Scripts read them at runtime from the host's encrypted credential store.
- **Each HISTORY.md is the engineering log.** It records what was built, what broke, why, and how it was fixed.
