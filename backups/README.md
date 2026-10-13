# Backups

Nightly, encrypted, incremental file-level backups of the always-on Ubuntu **server** to a Windows share on the **gaming-pc**, plus an every-15-minutes off-site copy of the documentation and a private code project to private GitHub repos. Also here: the boot-order guard that stops Docker from starting before the data disk is mounted, and the helper that makes sure containers are always brought back up.

## Architecture

```
                         server (Ubuntu, always on)
  +---------------------------------------------------------------------+
  |  hl-backup.timer  04:00 (+/-15 min, Persistent=true)                |
  |        |                                                            |
  |        v                                                            |
  |  hl-backup.py                                                       |
  |   1. release the browse mount (hl-backup-browse.service)            |
  |   2. wait until services are idle (re-check 5 min, max 6 h)         |
  |   3. mount SMB share ---- fails? --> wake-on-LAN, retry  ------+    |
  |   4. stop containers (by compose project label)                |    |
  |   5. restic backup  /, /home, /opt   (encrypted client-side)   |    |
  |   6. start only the containers it stopped                      |    |
  |   7. forget --prune (unlock stale locks, retry once)           |    |
  |   8. unmount, hand browse mount back, push notification        |    |
  |                                                                |    |
  |  safety nets: ExecStopPost + hl-containers-start at boot       |    |
  |  docker.service  RequiresMountsFor=<data disk>                 |    |
  +----------------------------------------------------------------|----+
                                                                   | magic packet
                         SMB 3.1.1 (restic repo)                   v
  +---------------------------------------------------------------------+
  |  gaming-pc (Windows 11, sleeps when idle)                           |
  |    <BACKUP_DRIVE>:\<VAULT_DIR>\server     <- server repository      |
  |    <BACKUP_DRIVE>:\<VAULT_DIR>\gaming-pc  <- its own repo (draft)   |
  +---------------------------------------------------------------------+

  hl-git-backup.timer (every 15 min)
     docs wiki --secret scan--> private GitHub repo
     project main --personal-data scan of new lines--> private GitHub repo
```

## What gets backed up

- **Included:** the system root, `/home`, and `/opt` (every container's config and data). Roughly 27 GB of logical data, about 400k files.
- **Excluded:** the large data disk, Docker's image store (images re-download), caches, logs, pseudo-filesystems, swap, and the per-user FUSE folder that xrdp creates during an RDP session.
- **Retention:** 30 daily, 8 weekly, 12 monthly. Every snapshot carries two tags: `nightly` (what retention matches on) and the date, because restic snapshot IDs are content hashes and cannot be renamed.
- **Size:** the first snapshot stored 26.8 GB as 17.5 GiB (1.44x compression). A typical night adds a few hundred MB. A month of daily history plus the weekly and monthly tiers sits at about 20 GiB, because restic deduplicates chunks across snapshots.

## Design decisions

- **File-level restic, not disk images.** The server's root is ext4, which cannot snapshot, so an image would mean either downtime or an inconsistent copy, and each image is a full copy. restic stores each unique chunk once. Every snapshot browses as a complete system but only costs what changed.
- **Encrypted before it leaves the server.** The Windows side only ever sees opaque blobs, so anyone who can read that share still can't read the backup.
- **TPM-bound secrets.** The SMB credentials and the repository password are `systemd-creds` blobs sealed to the server's TPM and delivered to the job through `LoadCredentialEncrypted=`. They are useless if copied to another machine and never appear on a command line or in a plain file.
- **Quiesce the containers.** A graceful stop makes each app close its SQLite databases properly. On an incremental run the containers are down for about 40 seconds. A restore test confirmed it: restored databases passed `integrity_check` with full table counts, and restored config files matched by checksum.
- **Wait until services are idle.** Before stopping anything, the job asks whether anyone is actively using a service. If so, it checks again every 5 minutes. After 6 hours it backs up anyway, because a missed backup is worse than a 40-second blip. That case is recorded in the status file. If the idle check itself can't run, the job treats the services as idle.
- **Wake the target instead of keeping it awake.** The gaming-pc sleeps after 15 idle minutes. Rather than change its power plan, the job sends a wake-on-LAN magic packet, waits a minute and retries the mount. It keeps retrying every 15 minutes for up to 6 hours. In practice the PC wakes in under 10 seconds.
- **Notify after the run, not during it.** The push-notification server is itself one of the containers the backup stops, so messages are queued and sent once everything is back up and the server reports healthy. Failures and retention problems go to a high-priority topic. A separate watchdog alerts if the last good backup is more than 30 hours old. Status is also written to a machine-readable JSON file.
- **Browsable restores.** A small service keeps the repository FUSE-mounted, so every snapshot appears as a dated folder that can be browsed like any other directory. A wrapper (`hl-restic`) runs any restic command with the TPM credentials, so restores never need the password typed.
- **Off-site copy of what matters most.** The docs wiki and a private code project are pushed to private GitHub repos every 15 minutes. Each repo has its own deploy key, with write access to that one repo only, held in the TPM credstore. Before every push, the docs are scanned for anything secret-looking, and the project's new lines are scanned against a root-only personal-data pattern list. A hit blocks the push and fails the unit.
- **Boot order guard.** A Docker drop-in with `RequiresMountsFor=` on the data disk means Docker can't start until the disk is mounted.

## Traps and lessons learned

These are the useful part. Each one cost real debugging time.

1. **Wake-on-LAN was blocked by the BIOS.** For two nights the magic packets went out and nothing woke. The usual suspects were ruled out one at a time. Fast Startup was ruled out because the event log showed S3 sleep, not shutdown. The network was ruled out because a packet capture on the target received 48 of 48 magic packets while it was awake. The NIC driver's power settings were already correct and were not enough on their own. The cause was the motherboard's **ErP/EuP standby-power mode**, which cuts power to PCIe devices (including the onboard NIC) in sleep, together with **"resume by PCI-E device"** being disabled. Fixing both firmware settings made it wake within about 2 seconds.
2. **Windows' "last wake source" can be wrong.** On this board a genuine WoL wake is reported as "Power Button", because the firmware signals the PCIe wake through the power-button event. Judge by timing instead: a wake seconds after a magic packet is WoL, and a wake minutes later is a human.
3. **A sleeping NIC that doesn't answer ARP can still wake on a magic packet.** An `INCOMPLETE` ARP entry looked like proof that the NIC was deaf, yet the very next magic packet woke the machine. The two behaviours are independent, so an ARP pre-check gives false negatives. Only a real wake test proves anything.
4. **Turn off "wake on pattern match".** With it on, ordinary LAN traffic can wake the PC, which makes every WoL test ambiguous. The isolation test that settled it sent magic packets only, with no pings.
5. **A persistent network mount to a machine that sleeps is a liability.** When the target slept, the browse service's CIFS mount went stale. It still appeared in the mount table but every I/O failed, and the next fresh mount failed with EBUSY. The mount logic had checked "is it mounted?" once, outside its retry loop, so it hammered `mount` for two hours. Four fixes followed:
   - test real I/O behind a timeout, not just whether the mount exists
   - re-check on every pass of the retry loop
   - force-clear stale mounts before retrying
   - give the backup sole ownership of the mount for the whole run, handing it back in a `finally`
6. **A held repository lock silently killed pruning for 43 hours.** `restic mount` holds a lock for as long as it is mounted, and `forget --prune` needs an exclusive one. The prune call ignored its exit code, so the log said "retention applied" every night. Now the backup releases the browse mount for the run, retention failures are reported and pushed as alerts, and a stale lock (normal after the target sleeps mid-mount) is cleared with `restic unlock`. That command only removes locks whose owning process is dead.
7. **Compose secret guards silently broke the container quiesce.** Stacks whose `compose.yaml` uses `${VAR:?...}` guards can't be parsed without their secrets, so `docker compose stop` refused to run and those containers kept running through every backup, while the run still reported success. Containers are now stopped and started by compose's own project label, which needs no interpolation. Only the containers the job actually stopped are restarted, so a stack that was down on purpose stays down.
8. **An open RDP session failed the backup.** xrdp mounts a FUSE folder in the user's home while a session is connected, and root can't stat it. restic exits with code 3 ("some files unreadable"), which the job counts as a failure, even though the snapshot was saved without that one folder. The folder is now excluded.
9. **Docker beat the data disk at boot.** After a reboot, `docker.service` started in parallel with the data disk's mount unit and won the race. Every container that bind-mounts the disk got the empty mountpoint directory instead. The files were on the host the whole time but invisible inside the containers, and services that serve files from that disk were broken for eight hours. The first log error looked like a device-permission regression after the reboot. The real error was about 20 lines further down, so read logs to the end. The fix is `RequiresMountsFor=`, which adds both `Requires=` and `After=` on the mount. The trade-off was accepted deliberately: a dead disk now means Docker refuses to start, rather than apps that catalogue the disk seeing it empty and acting on that. The restic job reads the disk natively, so it was unaffected. Still, an implausibly small snapshot should send you looking for this class of fault first, because restic records an empty source directory as a perfectly valid snapshot.
10. **Containers must survive a crash mid-backup.** `restart: unless-stopped` respects a deliberate stop, so a job killed between "stop" and "start" would leave everything down. Two safety nets cover this: `ExecStopPost=` in the unit and a boot-time `hl-containers-start` service. Both use the label method from lesson 7.
11. **The nightly stop wipes in-memory state.** One app kept its "paused" flags only in an in-memory store. After the nightly stop/start the flags were gone and it resumed work it had been told to hold. Anything that must survive the quiesce has to be persisted.
12. **A push error must fail the job.** The first off-site script swallowed push errors and logged success while nothing reached GitHub.
13. **The TPM credstore drops a key's trailing newline**, and OpenSSH then refuses the key with "error in libcrypto". The script writes private temporary copies with the newline restored and deletes them on exit.

## Windows side (gaming-pc)

`scripts/windows/` holds a draft restic job for the gaming-pc itself. It backs up user profiles and selected data folders to a separate physical drive. It reads open files consistently through VSS (`--use-fs-snapshot`), keeps the repository password DPAPI-encrypted, writes a status JSON and runs a weekly `restic check`. The exclude list drops temp files, browser and Electron caches, package caches, cloud-sync folders and registry transaction logs. A dry run shrank 6.3 GB of selected data to 3.9 GB stored. The alternative being weighed is weekly Windows restore points plus a C: image every few days. Restore points are an undo button, not a backup: they live on the same SSD and don't cover personal files.

## Files

| Path | Role |
|---|---|
| `scripts/server/hl-backup.py` | the nightly job |
| `scripts/server/hl-restic` | runs any restic command with TPM-sealed credentials |
| `scripts/server/hl-backup-browse` | hand-run browse mount (stop it when done) |
| `scripts/server/hl-containers-start` | safety net that starts any stopped stack |
| `scripts/server/hl-git-backup` | off-site GitHub copy with pre-push scans |
| `scripts/systemd/` | units, timers, and the Docker drop-in |
| `scripts/windows/` | gaming-pc restic job and exclude list (draft) |

All site-specific values are placeholders in a CONFIG block at the top of each script. The personal-data pattern file used by the off-site job is deliberately not published.
