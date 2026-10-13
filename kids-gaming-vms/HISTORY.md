# History: how the kids' VMs were built

This is an engineering log written as a story. It covers what we tried, why, what broke
and how each problem was fixed. Two Claude Code instances did the work together: one on
the server and one on the gaming-pc, coordinating through a shared append-only message
board, with the owner making every real decision. Roles are used instead of hostnames
throughout.

---

## 2026-09-25: Wake-on-LAN, the foundation nobody knew was broken

The kids' VMs didn't exist yet, but the problem that would decide whether they were
practical did. The server's nightly backup job sends a wake-on-LAN packet to the
gaming-pc before writing to it, and the packet had **never once** woken it.

**First, rule things out with evidence, not guesses.** The gaming-pc side read the Windows
event log for the failed nights. The machine had been in **S3 sleep, not shut down**, which
eliminated the first theory (Windows Fast Startup only affects shutdown). The server side
checked its own half: packet format (six 0xFF bytes followed by the MAC sixteen times),
the correct MAC, the broadcast route on the right interface, and that the local firewall
allowed the broadcast out. All correct.

**Theory 1: the NIC drops its link in sleep.** The onboard 2.5 GbE NIC was set to renegotiate
down to 10 Mb in sleep, with Green Ethernet and power saving on. If the switch port
wouldn't do 10 Mb, the link would go dark. The owner approved changing all three. Nothing
was tested yet.

**Theory 2: the mesh router drops broadcasts.** The LAN is a consumer mesh system, and mesh
backhauls sometimes drop or rate-limit broadcast frames. Rather than put the PC to sleep
to test this, the two sides designed an **awake capture test**. The gaming-pc ran a
packet capture on its NIC. The server sent twelve bursts, ten seconds apart, each with a
broadcast and a unicast magic packet on UDP 7 and 9. The unicast copies were a control:
if they showed up but the broadcasts didn't, the router was guilty, and if nothing showed
up, the capture itself was broken. Result: **48 of 48 arrived.** The network was cleared,
and the router theory was dropped.

**Sleep test #1** was scheduled with transient systemd timers, because the owner (and the SSH
session) would vanish the moment the PC slept. The PC slept, the server fired bursts on a
timer and logged ping, SMB and ARP state every ten seconds. Result: **no wake**. The ARP
entry went from cached to unanswered about 90 s after sleep. The server's own verdict
script almost reported success because the PC replied at last. That reply came five
minutes after the final packet, though, and it was the owner pressing the power button.
The script was stopped before it posted, and the lesson was recorded: a verdict needs
timing, not just "it replied".

**The fix was in the firmware.** With every Windows-side setting correct, what remained
was the board cutting standby power to the NIC. The owner changed two BIOS settings:
**ErP Ready → Disabled** (the EU standby-power mode that powers off PCIe devices in sleep)
and **Resume by PCI-E Device → Enabled**. **Sleep test #2** woke the PC about two seconds
after the first burst.

**Two traps came out of that success.**
- Windows reported the wake source as **"Power Button"**. On this board the firmware signals
  a PCIe wake through the power-button event. Anyone who trusted that label would
  conclude WoL was still broken.
- The NIC **still didn't answer ARP while asleep**, yet it woke on the magic packet. The
  server side had earlier proposed a five-second "ARP pre-check" as a cheap substitute for
  a sleep test. It would have returned a false negative after the fix was already in, so
  it was withdrawn in writing. The earlier claim that "no ARP reply means the link is
  dead" was corrected on the record too.

**Then came a doubt about the cause.** The server side noticed that *Wake on pattern match* was
on and that both tests pinged the host after every burst. The ping, not the magic packet,
might have done the waking. The owner had pattern match **disabled**, which is also what
they wanted, since stray LAN traffic shouldn't wake a sleeping PC. An **isolation test**
then sent twelve silent bursts and nothing else for thirty seconds. Wake began about **1 s
after the first packet**. This settled it: the magic packet alone wakes the PC.

Later tests covered hibernate (S4), which woke in about 40 s with Windows naming the NIC
correctly this time, and a genuinely unattended run. Nobody touched the locked PC, and
the server woke it and completed its whole storage check within 24 seconds. An earlier
"unattended" test had been voided because the owner had already signed in, which made
it not the real condition.

## 2026-09-26 to 2026-09-27: WoL proven in production

One more failure turned out not to be WoL at all. The PC woke, but a persistent network
mount on the server had gone stale while the PC slept, and fresh mounts failed with
"device busy". The retry loop also checked the mount state only once, outside the loop,
so it could never recover. Both were fixed, and the next unattended nightly run woke the
PC and completed. From then on, wake-on-LAN was a solved building block, ready to reuse.

## 2026-09-27: Planning, and moving the VMs to the right machine

The first draft put the VMs on the server itself, with no GPU and a light workload. The
owner then proposed the split that stuck: **the gaming-pc hosts the VMs, and the server
orchestrates them.** Both machines were measured over SSH. The server is a 35 W six-core
mini PC with no full-size PCIe slot. The gaming-pc has a 16-core CPU and four times the
free RAM. Not a close call.

The plan had three headline risks, each written down before any work started:
1. Enabling Hyper-V makes Windows a root partition, which can upset some anti-cheat
   software. That was the owner's call.
2. GPU partitioning on a brand-new NVIDIA card is fragile, because guest drivers must match
   the host's exactly.
3. If the host sleeps mid-session, the running VM dies.

**The GPU question went away the same day.** The owner didn't want the discrete GPU shared
at all and asked about the CPU's integrated Radeon instead. It's a two-compute-unit display
adapter, and AMD consumer GPUs don't support Hyper-V GPU-P. So the decision was **software
rendering, nothing passed through**. On that CPU, for Minecraft and 1990s educational
titles, it's a reasonable bet, and it deletes the whole fragile driver layer. The plan
named a checkpoint: build **one** VM and actually test the games before building more.

**The server side built everything it could before any VM existed.** That covered the
Guacamole stack (web app, guacd, Postgres; schema generated from the official image; the
default admin password replaced immediately through the REST API with a TPM-held secret),
the launcher service and `vmctl`. vmctl's **stub mode** simulated Hyper-V from a local
JSON file, so the whole start → keepawake → ready → save flow could be proven end to end
against placeholder VMs. A numbered test plan (T1-T6) was posted for when the real VMs
arrived. Each test isolated one link: SSH and `Get-VM`, start and save, IP discovery, VNC
reachability, the keepawake round trip, and finally the real round trip from a sleeping
host.

The first trap happened here. The kid-name map started as inline JSON in a systemd
`Environment=` line. **systemd strips the double quotes**, and the service died on startup.
The map moved into a separate `kids.json`.

## 2026-09-28: Hyper-V enabled

The gaming-pc side checked the actual risk before the owner decided. The hypervisor was
**already running** under Windows' virtualisation-based security (Memory Integrity), so the
Hyper-V role mostly added the management service, not a new hypervisor. The owner said
yes, Hyper-V was enabled, and after a reboot it ran cleanly.

The guest OS plan moved from Windows 7 (for old games) to **Windows 10**. Windows 7 would
have forced Gen 1 VMs, and Sunshine doesn't run on it, which would have meant no Moonlight.
Windows 10 fixed both.

## 2026-09-29: The first VM, the network switch, and the no-password requirement

The first VM was built: Gen 2, 4 vCPU, 8 GB, a dynamic disk, automatic checkpoints off.
A few things were learned along the way:
- The first boots failed with "no bootloader". The installer DVD was already first in boot
  order, and the "press any key to boot from CD" prompt had simply been missed.
- **PowerShell Direct** became the management tool. It runs commands inside a guest through
  the hypervisor, with no guest network needed. The host account was added to "Hyper-V
  Administrators" so no elevation is needed, and the guest admin credential is stored as
  a DPAPI file only that account can read.
- The **external virtual switch** was created with an automatic rollback guard: a scheduled
  task would remove the switch if the router and server became unreachable. The host's
  IP moved onto a virtual adapter that inherited the physical MAC, so nothing else noticed.
  The guard confirmed the network was healthy and removed itself.
- `Get-VMNetworkAdapter` reported the guest's LAN address, which proved that the launcher
  could discover IPs from the host.

Then came the base software, all scripted through PowerShell Direct. winget had to be
provisioned, because the guest image shipped without it. TightVNC was installed as a
service with password auth, and its firewall rule accepts only the server and the host. A
Windows Update loop task in the guest installed, rebooted and repeated until nothing was
left, then disabled itself. Then came the **debloat**: Copilot, Cortana, web search, ads,
consumer suggestions, the Edge sidebar and shopping, and the preinstalled junk apps
including OneDrive. The Store and Xbox apps stayed for Minecraft. The policies were
applied machine-wide and to the Default profile, so future kid accounts inherit them.

The second VM was made by **export and import with new IDs**, then renamed inside. Sunshine
was installed **per VM after the copy**, never cloned, so each keeps its own identity. Each
kid got a **standard account** with automatic sign-in and no lock screen inside the VM,
because the host decides when VMs sleep. An **internet switch** was added so the VMs can be
offline by default while still reachable on the LAN.

**The owner set a firm requirement: a kid must never see a password.** That covered
Guacamole, VNC and Windows. The server side solved the Guacamole part with the
**`guacamole-auth-json`** extension, which ships in the image. The launcher builds a
descriptor for exactly one connection, signs and encrypts it with a shared key held as a
TPM-bound systemd credential, and exchanges it for a session token. The browser lands
directly on the desktop. The VNC credential never reaches the browser, and the blob
expires in 60 seconds. This was verified against a documentation-range fake host, so no
real VM was touched while proving it.

Secret delivery hit one trap. Small `systemd-run` wrapper scripts work for root but fail for
an unprivileged service ("interactive authentication required"). The fix, which is also
cleaner, was to have the launcher's own unit load its credentials. The VNC password
itself was handed from one machine to the other by the owner directly. It was never
posted on the board or anywhere in writing.

## 2026-09-30: Going live, and a long day of silent failures

**Addresses moved.** DHCP gave both guests new addresses after reboots, so the launcher's
config was stale. The owner chose static addresses inside the guests, and the config was
corrected. The launcher still falls back to asking Hyper-V when an address is blank.

**Moonlight pairing problems:**
- The iPad couldn't find the host even with the right address. iOS's **Local Network**
  permission for Moonlight was off. Nothing was wrong on the server side.
- An mDNS firewall rule was added in the guests so Moonlight discovery works.
- The picture came through but input was dead after someone used "Switch user" inside
  the VM. Sunshine injects input into the console session. Restarting the Sunshine service
  fixed it, and the house rule became "sign out, don't switch user".
- Moonlight's on-screen gamepad killed the mouse until the **ViGEmBus** virtual gamepad
  driver was installed in the guests.

**Keepawake was built on the gaming-pc.** It is a SYSTEM scheduled task holding a Windows
power request. No power settings are changed, so "off" can't leave sleep disabled, and
it releases itself after ten minutes with nothing running. One quirk: it takes about 15
seconds to show up as an active power request.

**The Moonlight "Wake PC" relay, and why it was deleted.** The owner wanted Moonlight's own
"Wake PC" button to work. The idea was that Moonlight broadcasts a magic packet for the
*VM's* MAC, which does nothing by itself, and the server could hear it and do the real
work. The server built a listener on a raw packet socket that matched the magic-packet
*payload* instead of guessing ports. That also meant no firewall changes, because a
packet socket sees frames before netfilter. It ran as an unprivileged user with only
the raw-network capability, debounced repeats, ignored its own packets, and started in
dry-run mode.

Then it was tested properly, with every frame captured while the owner tapped the
button. **Zero magic packets.** The owner noticed the only traffic at the moment of the tap
was mDNS: Moonlight repeatedly asks for the host's service name while the host is
offline. The relay was rebuilt to trigger on that, and it worked. But a second A/B
capture (30 s not tapping, 30 s tapping) showed the mDNS rate was **identical either way**.
The trigger was really "Moonlight is open", not "the kid asked". VMs would start whenever
the app was merely open, and the owner called it a fail. **The relay was removed
completely** (unit, code and config).

**The replacement was the owner's idea: an iOS Shortcut** that calls the launcher. A new
`/wake/<kid>` endpoint accepts either the friendly label or the VM name and replies in
plain text that Siri can read aloud. It works from the home screen, from Siri and from
Back Tap.

**Going live surfaced four bugs, and every one failed silently:**
1. Scripts passed to PowerShell as plain command text over SSH were mangled by `cmd.exe`,
   which parsed the pipe character itself. A pipeline listing the VMs returned
   **nothing with exit code 0**. The fix was
   `-EncodedCommand` (base64 UTF-16LE), which has no metacharacters to misparse.
2. vmctl defaulted to stub mode and **no unit set it to live**, so everything would have
   driven the simulator.
3. Hyper-V's state came back as an **enum number**, not a name.
4. The gaming-pc's **execution policy blocked keepawake over SSH**, even though it passed when
   tested interactively. It was worked around with a process-scoped bypass, then fixed
   properly on the host.

A design fault was found too: the old relay **claimed the host was held awake without
checking**. A false success there means the PC sleeps mid-game. The code now reports the
failure.

**The idle watchdog** was built to run every minute. It counts real connections inside
each running guest (via PowerShell Direct), saves a VM after 30 idle minutes, and
releases keepawake when the last VM is saved. The rule that unknown means "in use" was
set from the start. The watchdog and the start path went live **together**, because a
live starter with a dry-run saver would start VMs that nothing ever saves.

**Cold-wake timing.** Every launch phase was instrumented, and fixed sleeps were replaced
with polling. Then the gaming-pc was put to sleep on a schedule and the owner tapped the
Shortcut on the real iPad:
- **Cold run #1: 18.5 s.** The host woke in **8 s**, not the ~60 s everyone had assumed. That
  figure had been the backup job's own fixed wait, not the hardware.
- **Tuning followed.** The "is it asleep?" connect timeout dropped from 4 s to 1.5 s, since an
  awake host answers in about 3 ms and the 4 s was paid in full on every cold wake. The
  poll interval dropped from 2 s to 1 s. SSH connection reuse was added, and keepawake was
  moved off the critical path onto a background thread.
- **Cold runs #2 and #3: 13.9 s and 15.2 s.** A human-triggered run reproduced 15.2 s exactly.
  The warm path is about 4-5 s.
- The guest answered VNC **before** `Start-VM` even returned, every time, so there was no
  boot phase to optimise.
- Measuring showed SSH reuse saved only ~0.2 s, which exposed the rest: **~1.4 s per call is
  `powershell.exe` starting on the host**. That was judged not worth chasing. Keeping
  paused VMs in RAM (`Suspend-VM` instead of `Save-VM`) was proposed as a way to cut
  resume time further, at the cost of host memory. It was left as an open trade-off for
  the owner.

**The delay the owner actually felt was IPv6.** The owner kept saying it felt much longer
than the numbers. They were right, but the missing time was **before the request reached
the server**. The router was handing out IPv6 ULA addresses with no IPv6 default route, so
every connection, on the iPad and on the server, stalled about 4 s on a dead IPv6 attempt
before falling back. After the owner fixed the router, the same tap felt "much faster"
with no code change. The launcher now logs `REQUEST IN` on arrival. Two smaller things
came up in the same session:
- **`/go/<kid>`** was added. It does the same work as `/wake/` but replies in about 10 ms, so
  the kid gets an instant acknowledgement and the PC is ready by the time they switch
  apps.
- `/healthz` had returned JSON, and **iOS Shortcuts errored** trying to display it, so every
  endpoint now returns plain text.

There were also two self-inflicted editing bugs. A block replacement in the launcher
swallowed the Guacamole hand-off functions, and the restore used a backwards slice that
extracted nothing. Both showed up only at runtime, as `NameError`. Another fix in the same
period: `/wake/` reported "could not start" when the VM had started fine but browser
access wasn't configured yet. A running VM and working browser access are now reported
as separate outcomes.

**The second VM exposed three bugs that a single VM had hidden:**
1. **The PowerShell 5.1 `.Count` trap.** With exactly one connection, the result was a single
   object, not an array, so `.Count` produced nothing. One VM read "0", the other "cannot
   tell", only because one had a single connection. Wrapping in `@()` fixed it.
2. **The idle timer could never fire.** The session count included two Sunshine ports that
   Moonlight holds open just to show "PC online". A kid leaving Moonlight open would pin
   the VM, and the host, awake forever. Now only VNC and Sunshine's stream-setup port
   count.
3. **"Unreachable" looked like "not found".** A failed SSH call returned an empty list, so a
   broken key would have read as "nothing is running", and keepawake would be released
   mid-game. vmctl now raises an error, and the watchdog changes nothing on that pass.
   This also led to a recorded trap: running the watchdog under sudo looks exactly like
   this fault, because only the service user has the SSH key.

**Old games.** The 1990s educational titles remember the **exact CD drive letter** they were
installed from, and the letters differ per game. A startup task in each guest now
re-mounts every disc image at its fixed letter. ISO files use Windows' own mounting, and
BIN/CUE files use WinCDEmu. One archive's `.cue` named a `.bin` that had since been
renamed, and the mounter refused it until the `FILE` line was fixed. WinCDEmu's installer
hung on a driver-trust prompt when run unattended, so the owner installed it by hand
once.

Two 2002-era titles crashed only on the interactive desktop, never in session 0 where
PowerShell Direct runs. That made remote testing actively misleading. Windows 98
compatibility mode looked like a fix at first. It was a **false pass**: the "process still
alive" check was really the game sitting on a "cannot find CD" dialog. The verdict was
retracted, and an automated in-guest tester that ran on the real desktop also proved
unreliable. The lesson recorded was to ask a human to look at the screen. One title
became disc-independent by copying its resource folder into the install directory.

## 2026-10-04: Monitoring and one more silent failure

The gaming-pc gained a small health monitor that sends push notifications. It covers
Hyper-V down, a kid VM in an abnormal state, keepawake errors, and, inside running guests,
disc-mount failures and VNC or Sunshine being down. Testing it found one more quiet bug:
the keepawake log folder was writable only by SYSTEM and admins. Calls from the server's
non-elevated SSH user worked but **logged nothing**, because the log write was set to fail
silently. Users were given modify rights on that folder, and the installer in this repo
now does that up front.

---

## What made this work

- **Build against a stub before the real thing exists.** The server side was complete and
  tested two days before the first VM booted.
- **Number the tests so a failure points at one link.** T1-T6 for the wiring; awake capture,
  then sleep, then isolation for wake-on-LAN.
- **Distrust anything that can fail silently.** Exit code 0 with empty output, a success
  message nobody checked, a log write with errors suppressed, a default that points at the
  simulator: every one of these happened here.
- **Correct mistakes in writing.** Wrong theories (the router, ARP as a liveness test, the
  game fix) were retracted explicitly on the board, so nobody would rediscover them as
  facts later.
