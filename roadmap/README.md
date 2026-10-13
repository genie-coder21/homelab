# Roadmap

These are design notes for agreed future work that hasn't been built yet. Each one records the idea, the reasoning, the intended approach and the known traps, so the work can start from a decision instead of a blank page.

---

## 1. Rebuild the server on ZFS, using a VM as the workbench

**Status:** proposed, not started.

**Problem.** The server's root filesystem is ext4, which has no snapshots. A bad config change or a failed upgrade means restoring from the nightly file-level backup. That works, but it is slow and coarse.

**Idea.** Build the replacement system **inside a VM**, on a ZFS root, while the live server keeps running. Configure it identically, test it properly, then **transplant** it onto the bare metal and delete the VM. The VM is scaffolding: the end state is still bare metal, just on ZFS and able to snapshot itself.

```
  build in VM (ZFS root) --test--> transplant onto the SSD --> bare metal on ZFS
       throwaway                   (VM deleted afterwards)     + scheduled snapshots
```

**Approach.**
1. **Match the hardware's assumptions.** That means UEFI firmware in the VM (a BIOS-built VM won't boot on UEFI hardware), the same partition layout (an EFI system partition plus a pool on the rest), network config written for the *physical* NIC name and not the VM's, and an initramfs that includes broad storage drivers so the real NVMe is found.
2. **Make it identical.** Rebuild it from the documented configuration: users, SSH, Docker and every stack with its data, file sharing, remote desktop, the VPN tunnel (with the *same* keys, so the far end needs no change), firewall rules including the Docker chain, and scheduled jobs. Keep it in sync with a nightly copy until cutover.
3. **Test in the VM.** Containers survive a reboot, services answer, and snapshot plus rollback works. Some things can only be verified after the transplant: GPU transcoding, the external data disk, and the VPN tunnel. The tunnel must not be started in the VM, or two peers with one key make it flap.
4. **Transplant with ZFS send and receive, not a raw disk image.** That avoids size and partition mismatches. Take a full backup first, boot a live USB, recreate the partitions, receive the pool, install the bootloader, fix the EFI partition's UUID, confirm the NIC name, and reboot.
5. **Snapshots afterwards.** Hourly, daily and weekly local snapshots for near-instant rollback. For the off-machine copy, keep the existing file-level backup. Windows can't receive ZFS streams natively, and a proper Linux receiver is a separate project.

**Decisions still open.** Same SSD (cheap, no free rollback) or a second SSD (the old system stays bootable; recommended)? One pool with datasets, or a separate pool for container data? Whether regenerable artwork and caches belong in snapshots.

**Known traps.**
- Docker on ZFS needs the right dataset properties (`xattr=sa`, `acltype=posixacl`) under the overlay2 driver.
- Cap the ARC so ZFS doesn't crowd out other memory users.
- The external data disk stays as it is and must never be reformatted as part of this.
- SSH clients will warn about a changed host key unless the old host keys are carried over.

---

## 2. Ansible: make the documentation executable

**Status:** proposed. First rung built 2026-10-13: control node, inventory and smoke playbooks for both machines, see [ansible](../ansible/). The rebuild roles are not started.

**Problem.** The server was once rebuilt by hand over several days from written notes. The notes record *what* was done and *why* very well, but a human still has to read them and retype every step, in order, without missing one.

**Idea.** Ansible holds the settings and enforces them. The written docs keep the reasoning and the traps. They complement each other: humans read the docs, and machines run the playbook.

**What it is not for.** Keeping things like mounts continuously correct. Ansible converges state when it runs and then stops caring. Continuous enforcement is systemd's job (mount units, dependencies), not a playbook on a timer.

**Roles, in dependency order:**

| Role | Covers |
|---|---|
| base | packages, timezone, hostname, users, SSH keys, sshd drop-in |
| storage | data-disk mount, directory tree, ownership |
| access | file sharing, remote desktop and its known fixes |
| docker | engine, compose plugin, the shared network |
| stacks | every `/opt/<name>` stack from templates, `.env.template`, bring-up through the secret-injecting wrapper |
| secrets | the secret tooling and store layout, **never the values** |
| backup | backup scripts, timers, browse helper |
| security | host firewall, Docker chain, intrusion prevention, VPN tunnel |

**The hard parts.**
- **Secrets can't be in the repository.** They are sealed to the machine's TPM by design. So a rebuild is deliberately *not* fully unattended: the playbook recreates the structure, then stops and lists which secret slots to fill by hand.
- **Container data belongs to the backup, not to Ansible.** Ansible rebuilds the stacks, and the restore brings back their data. Keep that boundary clean or the two will fight.
- **Idempotency must be real.** Run every role twice; the second run must report zero changes.

**Approach.** Start with `base` and `storage` and run them against the *live* machine. Zero changes means the role matches reality. Any change means either the role is wrong or the docs have drifted, and both are worth knowing. Add roles one at a time with the same test. Only trust it for a rebuild once the whole thing reports zero changes, and optionally prove a from-scratch run in a VM (see note 1).

---

## 3. Two-node k3s cluster across the server and the gaming-pc

**Status:** agreed direction, not started. Planned for after the workload it hosts is stable.

**Problem.** A containerized worker application currently runs under Docker Compose on the server only. The gaming-pc has spare CPU, RAM and the GPU, and the goal is to run workers on **both** machines against **one** shared database, queue and web UI, and to be able to bring the whole thing up somewhere else with little hand-work.

**Proposed shape:**

| Piece | Where | Notes |
|---|---|---|
| Control plane | k3s server on the **server** | always on, and it already holds the data |
| Database, queue, web UI, scheduled jobs | the server, through node affinity | data on local disk; the nightly backup is unchanged |
| Workers | both nodes | start with one or two per node |
| Gaming-pc node | k3s agent in **WSL2**, or a small Hyper-V Linux VM if WSL networking gets in the way | the workers need a Linux image |
| Networking | flannel over the LAN; WireGuard backend if traffic ever crosses networks | |
| Secrets | Kubernetes Secrets created from the server's TPM-bound store at deploy time | never in the repository; the gaming-pc has no store of its own, so secrets come from the server |
| Portability | a Helm chart or kustomize in the repository, plus a bootstrap script; images built once and pushed to a private registry | |

**Design decisions so far.**
- **No master worker.** The shared database and queue are the coordination point (row-level claim locking, leases, shared rate counters, heartbeats). Each worker reads its own assignment by ID.
- **Worker IDs are unique across machines**, prefixed by node.
- **Pinned work.** Each category of work is assigned to exactly one worker, permanently, and that worker keeps its state (e.g. browser profiles) on its own machine. Nothing is shared across nodes, so there's no network file system to get wrong. Only a generic pool may have several workers, still never two on the same target at once.
- **Shadow first.** Run one k3s worker in dry-run mode alongside the Compose deployment until its results match. Keep Compose as the fallback, and use the same image for both.

**Known traps.**
- **The gaming-pc is a desktop.** It sleeps and reboots, so its workers must tolerate the node disappearing; existing restart recovery already re-queues interrupted work.
- **Two machines may have different egress paths.** Decide deliberately how outbound traffic from each node should look.
- **The GPU stays native on Windows.** The local model server is not containerized, and workers on that node reach it locally.

**Order.**
1. Single-node manifests on the server, migrating services one at a time with Compose as the fallback.
2. Add the gaming-pc as an agent and run one worker there.
3. Package it for portability, then test a cold install on a throwaway VM.
