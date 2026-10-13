# Backups: how it was built, and what broke along the way

This is the engineering story of the backup system, told roughly in order. It covers what we were trying to achieve, the reasoning behind each choice, what we tried, what failed and how each failure was fixed. Each fix is written up as a lesson in the README; this file explains how we got there.

## 2026-09-23: choosing the approach

The server started with no backups at all. Its SSD held the operating system, every container's configuration and every app database. The first question was what kind of backup to take.

Disk images were the obvious candidate and we rejected them for two reasons. The root filesystem is ext4, which can't take a snapshot. An image of a live ext4 disk is therefore either inconsistent or needs real downtime. And every image is a full copy, so a month of nightly images would cost a month of full copies. We also discussed rebuilding the server on a snapshot-capable filesystem (ZFS) someday, but that was a separate, larger project. Backups were needed now.

We chose **restic**, which takes file-level, incremental, deduplicated and encrypted backups. It splits files into chunks and stores each unique chunk once, and a snapshot is a list of pointers to chunks. That property shaped most later decisions: every snapshot browses as a complete system but only costs what changed, so a long retention history is cheap.

For the destination we picked the gaming-pc. It has a very large secondary drive with plenty of free space and sits on the same LAN. restic encrypts on the server before anything leaves it, so the Windows machine only ever stores opaque blobs.

### Handling the secrets

Three secrets were needed: the SMB credentials, the repository password and, later, an API key for the idle check. We didn't want any of them in a plain file. Each one was sealed with `systemd-creds` to the server's TPM, and the plaintext password file used during setup was shredded. systemd decrypts the credentials into a private, per-run directory only for the backup service (`LoadCredentialEncrypted=`). A sealed blob copied to another machine is useless. We wrote a small wrapper so restic commands typed by hand go through the same mechanism and the password never has to be typed or exported.

### Getting a consistent copy

Backing up live SQLite databases risks capturing a half-written file. The job therefore stops every container stack before restic runs and starts them again afterwards. A graceful stop lets each app close its databases properly. On an incremental run the containers are down for about 40 seconds, which we judged acceptable at 4 a.m.

Stopping things creates a new risk: if the job dies between stop and start, everything stays down, because `restart: unless-stopped` honours a deliberate stop. We added two safety nets the same day:
- an `ExecStopPost=` hook that starts the stacks even if systemd kills the job
- a boot-time service that starts any stack left stopped

### Proving it

We didn't call it done until a restore had been tested. Config files restored with matching checksums, and four separate app databases restored and passed SQLite's `integrity_check` with full table counts. That proved the stop-then-backup approach produces usable databases, not just files that look right.

The first full snapshot stored 26.8 GB of data as 17.5 GiB. A second snapshot 35 minutes later added only 20 MB, which confirmed the deduplication behaved as expected.

### Waiting until services are idle

The first version was a bash script, and it stopped containers regardless of whether anyone was using them. Interrupting someone mid-use for a backup was not acceptable, so the job was rewritten in Python to make room for that logic.

Before stopping anything, the job now asks whether a service is actively in use. Active use blocks the backup, but an idle or paused session does not. If something is busy, the job logs what it saw and checks again five minutes later. We had to choose what happens when activity never ends. The answer was to back up anyway after six hours, because a missed backup is worse than a 40-second interruption, and to record that in the status file. If the idle check itself fails, the job treats the services as idle rather than skipping the backup.

The rewrite also added desktop notifications. They are shown immediately if someone is logged in, or queued and shown at the next login, with several queued runs collapsed into one summary. A critical alert fires at login if the last success is too old.

The first real run proved the waiting logic. It waited 165 minutes for activity to finish, then backed up in 11 seconds.

## 2026-09-24: the target falls asleep

The first 04:00 run failed. The gaming-pc sleeps after 15 idle minutes, so at 4 a.m. there was nothing to mount.

There were two ways to solve this: change the PC's power plan so it never sleeps, or have the backup wake it. We preferred waking it, since keeping a gaming PC awake all night just for a two-minute job is wasteful. The job gained a wake-on-LAN sender, a broadcast magic packet on the two conventional ports. It sends the packet, waits a minute and retries the mount. We gave it a retry window of 8 attempts, 10 minutes apart. We also confirmed that WoL needs the PC's wired NIC; the Wi-Fi adapter can't do it.

The same day we started thinking about backing up the gaming-pc itself. We drafted a restic job for it. It reads open files consistently through Windows' VSS snapshot support, keeps its repository password DPAPI-encrypted to the machine, and excludes temp files, caches, cloud-synced folders and registry transaction logs. A dry run turned 6.3 GB of selected data into 3.9 GB stored.

We also wrote up the alternative: weekly Windows restore points plus a disk image every few days. The reasoning recorded then was that restore points are an undo button, not a backup. They live on the same SSD, they don't cover personal files and Windows deletes them on its own. Images are the real protection against a drive failure. That decision was left open.

## 2026-09-25: a long day of wake-on-LAN, and two silent failures

### WoL had never actually worked

The second night failed too, after eight magic packets over 78 minutes. Looking back over the log, we found that **every unattended run so far had failed at the mount**. Every success had been started by hand while the PC was awake, so WoL had never once worked. As a stopgap the retry window was widened to 24 attempts, 15 minutes apart. That is six hours, so even a PC switched on mid-morning still gets that night's backup.

We then worked through the causes methodically. The AI assistant on the server and the one on the gaming-pc coordinated through a shared message board, each testing its own side:

1. **Fast Startup.** This was the first suspect, since it is a well-known WoL killer. The Windows event log showed the PC had been in S3 sleep on both failed nights, not shut down. Fast Startup only affects shutdown, so it was ruled out.
2. **The network.** The mesh Wi-Fi system could plausibly have been dropping broadcast frames. We ran an awake capture test: the server sent broadcast and unicast magic packets while the gaming-pc captured on its NIC. All 48 of 48 arrived, so the network was ruled out.
3. **NIC driver power settings.** Several driver options looked guilty: link speed reduction on shutdown, "green Ethernet" and power-saving mode. We corrected them and ran a real sleep test, and the PC still didn't wake. While asleep, the NIC also stopped answering ARP, which we took to mean the NIC had no power or no link at all.
4. **Firmware.** This was the remaining layer. The motherboard's **ErP/EuP mode**, a setting that meets EU standby-power limits by cutting power to PCIe devices in sleep, was enabled, and **resume by PCI-E device** was disabled. With both changed, the next sleep test woke about two seconds after the first packet. That was the fix.

Two of the clues we had trusted along the way turned out to be misleading, and both are written up as traps. First, Windows reported the WoL wake as "Power Button", because the firmware signals a PCIe wake through the power-button event. We learned to judge wakes by timing instead. Second, the ARP silence that seemed to prove the NIC was deaf was wrong: in the successful test the ARP check returned nothing three times, and then the very next magic packet woke the PC. Answering ARP and waking on a magic packet are independent, so the "quick ARP pre-check" idea was dropped as worthless.

Our early tests also had a flaw. They pinged the PC after each burst, and the NIC had "wake on pattern match" enabled, which wakes on ordinary traffic. So the tests proved that *something* woke the PC, but not that the magic packet did. We disabled pattern matching, partly so that stray LAN traffic can't wake the PC at all, and ran an isolation test: twelve magic-packet bursts, no pings, then silence. The PC woke, so the magic packet alone works. We also confirmed a wake from hibernate (S4), which took about 39 seconds.

Finally we needed to prove the whole path the nightly job uses, unattended. One test was voided because someone had unlocked the PC partway through, so we re-ran it with the machine deliberately left alone. The PC woke after the second burst. Within 24 seconds of the wake, every check passed: the SMB port, TPM credential decryption, the CIFS mount, opening the encrypted repository, free space and a write/delete probe. That test was kept as a reusable health check, because it reports each step separately and a partial failure can't hide behind a single summary.

### Silent failure #1: the quiesce wasn't quiescing

While reviewing the job we noticed that three stacks had never been stopped during a backup, although every run reported success. Those stacks keep secrets out of their compose files using `${VAR:?...}` guards. Without the secrets loaded, compose can't parse the file at all, so `docker compose stop` failed, the job ignored the failure, and those containers were copied live.

The fix was to stop relying on compose to interpret the file. The job now finds containers by the project label compose already attaches to them, which needs no interpolation, and stops them directly. It also records exactly which containers it stopped and restarts only those, so a stack that was down on purpose isn't started behind the owner's back. The boot-time safety net was changed the same way.

### Silent failure #2: retention hadn't run for 43 hours

When asked to confirm the backup path was healthy, we found `restic check` couldn't run because the repository was locked. A browse mount that had been started by hand was still running almost two days later. `restic mount` holds a repository lock for as long as it is mounted, and pruning needs an exclusive one, so every nightly prune since then had failed. The job had logged "retention applied" each time, because it called prune without checking the exit code.

We released the mount, cleared the stale locks, ran the backlog prune and verified the repository. The job now reports a failed or skipped retention plainly and names the likely cause.

### Making backups browsable without a command

The owner wanted to look through backups without running anything. We turned the browse helper into a permanent service that keeps the repository mounted from boot, with each snapshot as a dated folder. This walked straight back into the lock problem we had just found. A permanent browser would block pruning every night, so the backup now stops the browse service around its run and restarts it afterwards. It also skips its final unmount while the browser is running, because unmounting the network share would pull it out from under the browse mount.

### Retention and naming

restic snapshot IDs are content hashes and can't be renamed, so every snapshot now carries its date as a tag, which makes "restore from the 25th" a simple selector. At the owner's request, daily retention went from 14 to 30 days, and monthly from 6 to 12. Because restic deduplicates, the extra tiers cost almost nothing on a slowly changing system, and they are what saves you when a problem is only noticed months later. The entire history was about 19 GiB.

## 2026-09-26: the persistent mount bites back

The new always-on browse service caused the next failure. WoL worked and the PC woke. But the browse service had kept the network share mounted while the PC slept, and that mount had gone **stale**: still listed as mounted, yet every I/O failed with "host is down". A stale mount occupies the mountpoint, so every fresh mount attempt failed with EBUSY. The job looped from 04:07 to 05:44.

The underlying bug was in the mount logic. It checked "is it mounted?" once, before its retry loop. Having decided to mount, it kept trying long after the share had become usable again, and it could not recover from a state it was already in.

We made four changes and verified them over three consecutive clean nights:
- **Test usability, not presence:** a mount only counts if a real directory listing succeeds within a timeout.
- **Re-check on every pass** of the retry loop, and return the moment the share works.
- **Clear stale mounts** by force, and lazily if that fails, before retrying, instead of retrying into EBUSY forever.
- **The backup owns the mount for its whole run.** It stops the browse service at the start and hands it back in a `finally` block, so even a crashed run leaves backups browsable.

Retention also became self-healing. A browse mount can't delete its own lock file once its host disappears, so a stale lock is now an expected morning condition. When pruning reports a lock, the job runs `restic unlock`, which removes only locks whose owning process is dead and never a live one, then retries once.

The lesson we recorded: a permanently mounted network share to a machine that sleeps is a liability, not a convenience. It is acceptable here only because the backup explicitly takes it away for every run.

## 2026-09-27: first fully unattended success

The 04:00 run did everything it was designed to do with nobody awake. The first mount attempt failed because the PC was asleep. WoL went out, and the share mounted 60 seconds later. About 400k files and 784 MB were backed up in 16 seconds. A stale lock was found and cleared, retention was applied and the browse mount was handed back. The whole run took 2 minutes 34 seconds. Every fix from the previous two days fired in sequence.

## 2026-09-30: Docker started before the data disk

After an unrelated reboot, services that serve files from the large data disk stopped working: requests started, then hung. The files were present on the host, but containers couldn't see them.

The cause was boot ordering. `docker.service` and the data disk's mount unit started in parallel, and Docker won. Every container that bind-mounts the disk got the empty mountpoint directory underneath instead of the filesystem. Ten containers ran blind for eight hours.

The investigation started down the wrong path. The first error in the app log came right after a hardware-acceleration step and looked exactly like a device-permission regression after the reboot. The device was fine. The real "file not found" error was about twenty lines further down. The lesson: read a log to the end before blaming hardware.

We restarted the affected containers and added a Docker drop-in with `RequiresMountsFor=` for the disk's path. That adds both a hard dependency and an ordering dependency on the mount. We weighed the consequence explicitly: if the disk ever truly dies, Docker now refuses to start at all. We accepted that, because an app that catalogues a disk and suddenly sees it empty may conclude everything was deleted and act on it, while a hard stop gets noticed immediately.

The restic job reads the disk natively, not through a container, so it was unaffected. We noted the general risk anyway. A blind source directory backs up as an empty but perfectly valid snapshot, so an implausibly small snapshot should point to this class of fault first.

The same day, timing work on another project measured the gaming-pc waking from sleep in about 8 seconds. The "about 60 seconds" we had been assuming was really the backup's own fixed wait, not the hardware.

## 2026-10-04: push notifications

The desktop popups only helped if someone was at the server's desktop, so the job gained phone and desktop push notifications through the self-hosted notification server. Success goes to a normal-priority topic. Failures, and any retention problem, go to a high-priority one.

One detail mattered here. The notification server is itself a container, and the backup stops it, so a failure message sent from the middle of the run would be lost. The job collects its messages and sends them only after the run has finished, once it has waited for the notification server to report healthy. A separate watchdog alerts if the last good backup is more than 30 hours old.

## 2026-10-07: an RDP trap, and the off-site copy

A night run reported failure with restic exit code 3, "some files could not be read". The unreadable path was a FUSE folder that the RDP server mounts in the user's home while a remote-desktop session is open, which root is not allowed to read. restic had actually saved the snapshot, minus that one folder. The job treats any non-zero exit as a failure, which is the right default, so the fix was to exclude that folder rather than relax the check.

Separately, the owner asked for a stable off-site copy of the most important text: the documentation wiki that describes these machines, and a private code project. We considered how to do that without creating a new way to leak secrets:
- **Private repos only**, with the docs in a separate repo from the code project, because other tools and sessions read the code repo and the docs map the whole network.
- **One deploy key per repo**, each with write access to that repo alone, stored in the TPM credstore like every other secret.
- **Scan before every push.** The docs are mirrored into a local git working copy and scanned for anything secret-looking: token prefixes, private-key headers, VPN private keys. Any hit blocks the push. The project only pushes committed `main`, and only when it is ahead of the remote. Before it does, every added line is checked against a root-only list of personal-data patterns, and a hit blocks that push too. The pattern list itself is never written into the docs.
- **Every 15 minutes**, five minutes after boot, catching up after downtime.

The first full scan of the docs was clean. Its only hits were credential *names* and placeholders, which is what the docs are supposed to contain.

Two problems surfaced on the first day. The TPM credstore strips a key's trailing newline, and OpenSSH then rejects the key with an unhelpful "error in libcrypto". The script now writes private temporary copies with the newline restored and deletes them on exit. And the first version had swallowed push errors, logging success while nothing reached GitHub. A failed push now fails the unit.

## 2026-10-11 to 2026-10-12: state lost across the nightly stop

The nightly quiesce turned out to have a side effect on one app. A job-application automation tool kept its per-worker "paused" flags only in an in-memory store. The backup stopped and restarted that store, the flags vanished, and the workers resumed work they had been told to hold. The fix in the app was to persist the pause state and restore it on start.

The next night exposed a second-order problem. The saved copy was stale, because some pauses had been changed directly in the in-memory store and so bypassed the code path that updates the saved copy. The general lesson for anything the backup quiesces every night: state that must survive a restart has to be persisted, and it must only be changed through the path that keeps the persisted copy in step.

## Where it stands

The server backs itself up every night, unattended, to an encrypted repository on a machine that is asleep when the run starts. The run waits until services are idle, stops containers only briefly, prunes reliably, cleans up after itself, and reports every outcome to a phone. The docs and the code project have an off-site copy that refuses to push anything secret or personal. Docker can no longer start against a missing data disk. The gaming-pc's own backup is drafted and tested but its final form, file-level restic versus images, is still being decided.
