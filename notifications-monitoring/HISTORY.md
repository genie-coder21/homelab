# History

This is the engineering log for the notification hub and the watchdog: what was built, how, and what went wrong on the way.

## 2026-09-23: the first notification path, desktop popups

Notifications started with the nightly backup. Backups ran at night with nobody logged in, so a desktop popup sent at that moment would go nowhere. The approach was a queue. The backup appended one JSON line per result to a state file, and a small flush script ran at every graphical login and after each backup. It found an active graphical session through `loginctl`, dropped privileges to that user and raised the popup on that user's DBus session bus. If several results had piled up, it collapsed them into one summary ("N backups since Tuesday, M failed"). It also warned when no backup had succeeded for 48 hours.

It worked, but it put the information on the server's own desktop, which nobody sits at. That limitation drove everything after.

## 2026-09-24: the plan, one hub with three topics

The goal was cross-machine notifications: anything happening on the server should show up on the Windows gaming-pc, and ideally on the phone.

**Why ntfy.** Several of the self-hosted apps already speak ntfy natively, the intrusion-prevention stack can post through its generic HTTP plugin, and anything else needs only one HTTP POST. It is self-hosted, needs no account and is a tiny container.

**Topics.** The plan split messages by urgency into alerts, info and security. Everything on one topic gets muted within a week, and then the one important message is missed too.

**Three ways onto Windows** were considered:
- the ntfy web app installed as a PWA, the simplest option
- a native toast agent
- a third-party desktop client

The plan already flagged one problem with the native route: commands sent to Windows over SSH run in session 0, which cannot show anything on the logged-in desktop. A native agent would have to run inside the user's session.

**The phone.** A self-hosted server cannot wake an iPhone directly. The choice was between relaying through the public ntfy.sh service, using a different push service just for the phone, or skipping the phone.

**Build order.** Wire the backup job first, because it already had a notification path and would prove the plumbing end to end. Then Windows, then the security and application sources, and decide on the phone last.

## 2026-09-25: a silent failure that shaped the watchdog

A failed overnight backup was investigated and turned up a second, worse problem. The backup's container stop/start step had been silently skipping some stacks, while the run still reported success. The lesson was that a job's own success report is not enough. Something independent should check outcomes, such as "when did the last good backup finish?", instead of trusting the job. The watchdog's backup-freshness check follows the same principle.

## 2026-09-30: containers went blind for hours

After a routine reboot, Docker started in parallel with the data disk's mount unit and won the race. Every container that bind-mounts the disk got the empty directory underneath instead of the real filesystem. Services kept running, and their databases still listed everything, but they couldn't read a byte. On the host the files were all there; inside the containers they weren't. Nothing alerted, and it was noticed by a user hours later.

The diagnosis had a red herring. The first error in the application log looked exactly like a GPU device permission problem. The actual "no such file" error was 20 lines further down, and reading the log to the end found it. The fix made Docker's unit require the mount (see `../secrets-and-hardening`), deliberately accepting that a dead disk now stops Docker outright instead of letting containers run blind.

The monitoring lesson was that "container running" and "disk mounted" were both true during the outage. The useful signal was the contradiction between them. The watchdog later got a check for exactly that: for each running container's data-disk bind mount, if the host directory has content and the container's view of it is empty, alert at top priority.

## 2026-10-04: building the hub, the watchdog and Windows toasts in one day

### The server side

ntfy was deployed as a container on the shared Docker network, reachable from the LAN and the VPN only. Access control was the first decision. The default policy is **deny-all**, and there are three identities:
- a human login for the phone and browser
- a write-only publisher token for everything on the server
- a read-write token for the gaming-pc

Instead of assuming the access rules worked, they were tested from the outside. The publisher token got 403 when it tried to read, and an anonymous request got 403 for both reading and writing. All credentials went into the TPM-bound secret store.

For the phone, the server was given the upstream base URL. Only a poll request (message ID plus a hashed topic) goes to ntfy.sh, which wakes the app through Apple, and the app then fetches the message itself from home over the VPN.

**`hl-notify`** was written as the one helper every script uses. Its key property is that it **always exits 0**. A notification is never worth failing a backup over. Failures go to the journal instead.

**Wiring the sources:**
- **Self-hosted apps.** Native ntfy targets were configured and tested from each app's settings. Saving a target also sends a test, so each test arrived twice, which is expected.
- **Intrusion prevention.** It got an HTTP notification plugin pointing at the security topic, batched to at most one message every two minutes so an attack wave doesn't flood the phone. Its token is injected from the secret store when the container starts. The first edit to the stock profiles file missed a commented `notifications:` block in the second profile, and the plugin showed as unused until both profiles referenced it.
- **The backup.** This needed a design change. The backup stops every container to get a consistent copy, and that includes the hub. A message sent mid-run would be lost. Results are now queued during the run and pushed after the containers are back. Retention (pruning) failures, which had previously been silent, now alert too.

### The watchdog

The watchdog was designed around one question: *what can't the apps report about themselves?* It is a Python script on a 5-minute systemd timer with a table of checks. Each check returns ok-or-detail and has a topic, priority, confirmation count and an optional run interval for daily checks.

The alerting logic is the important part:
- Alert **once** when a problem starts.
- Remind every **6 hours** while it lasts.
- Send **"Recovered"** when it clears.
- Flappy checks (tunnel, internet, public reachability) need 2 or 3 consecutive failures first.
- A check that throws is recorded in the state and treated as passing, so one bug can't silence everything.
- The state file is written atomically (temp file plus rename).
- A dry-run mode prints instead of sending and saves no state, so new checks can be tried safely.

Two checks had to be adapted to reality on the first day:
- **Internet.** The obvious probe was a TCP connection to public resolvers on port 53. It failed every time, because an outbound filter on the host refuses TCP 53. The probe moved to port 443 on the same hosts.
- **Data disk health.** SMART was the plan, but the disk's USB enclosure doesn't pass SMART through, including with the SAT pass-through mode. The watchdog reads the kernel log for I/O errors, resets and "offline" events on that device instead, the only early warning available. The system SSD does get a daily SMART check.

The first run was all green. Negative tests followed: a container was stopped on purpose and the containers check caught it on the next pass.

### Windows toasts (built from the gaming-pc side)

The request to the gaming-pc side was a precise spec:
- a long-lived JSON stream on all topics, resumed with `?since=<last id>` after a disconnect
- retry forever with backoff
- toasts with priority mapped to sound and persistence
- run inside the user's desktop session, not over SSH

The PWA idea from the plan was dropped at this point. Browsers only allow notifications over HTTPS, and the hub is deliberately plain HTTP on the LAN.

The gaming-pc fetched its token over its existing SSH key straight from the server's secret store, wrapped it with DPAPI so only that user on that machine can decrypt it, and never printed it. It then verified the token against the server's account endpoint. The subscriber uses WinRT toasts directly (no extra module) under a registered sender name, so toasts don't say "Windows PowerShell". It runs as an at-logon scheduled task with an interactive logon, restart on failure, hidden window.

The test was end to end: messages published on the server at priorities 2, 3, 4 and 5 all popped within about a second. Priority 5 stays on screen with an alarm sound until dismissed.

Two Windows traps:
- **PowerShell 5.1 needs UTF-8 with BOM.** Without it, the topic icons turned to mojibake. The installer now re-saves every script with a BOM.
- **PowerShell 5.1 over SSH strips inner quotes**, so a multi-word title passed to the Linux helper arrived as just its first word. It's harmless and was only seen in testing.

### The gaming-pc publishes too

The same token was then used the other way. A monitor task on the PC checks:
- the Hyper-V management service
- physical disk health and free space
- the health of selected VMs
- new `ERROR` lines in a watched log, which it reads by byte offset and which survives log rotation

Like the watchdog, it alerts only on change and sends a quiet "Resolved".

Testing it found a real bug elsewhere. The log it watches had never been writable by the account that writes to it remotely, so those calls "succeeded" but logged nothing. Fixing the folder permissions made the log, and therefore the monitor, trustworthy.

## 2026-10-06: the front door moved

The remote-access front door moved to a new VPS on a separate WireGuard tunnel. The watchdog's tunnel and bouncer checks were re-pointed to the new tunnel and bouncer. Its always-on services check covered *both* tunnels during the transition, so the rollback path stayed watched until the old VPS was retired.

## 2026-10-07: HTTP headers are ASCII-only

A client tool that sent alerts through ntfy lost every one of them in a single run. Its titles contained an em dash, and it sent the title as an HTTP `Title:` header. Header values must be ASCII, so every request was rejected, and because the notify call raised an exception, the failure cascaded into the tool's own work. Two fixes followed and became the rule for every publisher here:
- **publish as JSON**, which is UTF-8 safe
- **a notify function must never raise into its caller**

## 2026-10-13: the public version

For this repository:
- The watchdog was cut down to its generic checks. All application-specific checks were removed.
- Every site-specific value moved to a clearly marked config block at the top of each script.
- `hl-notify` was rewritten to publish JSON, applying the 2026-10-07 lesson.
- The token lookup now prefers a systemd credential when the caller is a unit.
