# Kids' gaming VMs: Hyper-V on the gaming PC, run from the server

Two small Windows VMs for the kids (kid1 and kid2), used for Minecraft, old 1990s/2000s
educational CD-ROM games and the odd Steam title. They live in Hyper-V on the **gaming-pc**,
which sleeps when nobody is using it. The always-on Ubuntu **server** controls them. A kid
taps one button, from a browser or an iPad, and lands on their own Windows desktop within
seconds. That works even if the gaming-pc was asleep and the VM was saved to disk.

Nothing in the kid's path asks for a password. The VMs are saved again automatically when
nobody is using them, and then the gaming-pc goes back to sleep.

## Architecture

```
   kid on a laptop / tablet / iPad                     (home LAN only)
        |                         |
        | 1. tap "Start"          | 1b. iOS Shortcut: GET /go/<kid>
        v                         v
 +---------------------------------------+                    +-------------------------------+
 |  server (Ubuntu, always on)           |   wake-on-LAN      |  gaming-pc (Windows 11 Pro)   |
 |                                       | -----------------> |  sleeps when idle             |
 |  kids-launcher   (stdlib Python)      |                    |                               |
 |  vmctl           (all SSH->PowerShell)|   SSH +            |  Hyper-V                      |
 |  kids-vm-watchdog (every minute)      |   PowerShell       |   +-----------+ +-----------+ |
 |  Guacamole + guacd + Postgres         | -----------------> |   | kid1 VM   | | kid2 VM   | |
 |                                       |   Start/Save-VM,   |   | Win 10    | | Win 10    | |
 |                                       |   keepawake on/off |   | VNC       | | VNC       | |
 |                                       |                    |   | Sunshine  | | Sunshine  | |
 |                                       |  <---- VNC ------- |   +-----------+ +-----------+ |
 +---------------------------------------+                    |  keepawake task (SYSTEM)      |
        |                                                     +-------------------------------+
        | 2. pre-authenticated Guacamole URL                          ^
        v                                                             | 3. Moonlight streams
   browser shows the VM desktop                     iPad Moonlight ---+    directly from Sunshine
```

### The pieces

| Piece | Where | What it does |
|---|---|---|
| `server/launcher/launcher.py` | server, systemd service | The picker page plus plain-text endpoints. It wakes the gaming-pc if needed, resumes the VM, holds the host awake, waits until the guest answers, then hands the browser to Guacamole with a pre-signed one-connection token. |
| `server/sbin/vmctl` | server | The one place where SSH-to-PowerShell happens: list/state/start/save/ip/sessions, host-up, wake, keepawake. It has a **stub mode** that simulates Hyper-V from a local JSON file. |
| `server/sbin/kids-vm-watchdog` + timer | server, every minute | Counts real sessions inside each running VM. It saves a VM after 30 idle minutes and releases keepawake once the last VM is saved. |
| `server/guacamole/compose.yaml` | server, Docker | Guacamole web app, guacd and Postgres. The `guacamole-auth-json` extension is enabled so the kids never see a login page. |
| `server/sbin/guac-set-admin-password`, `guac-token` | server | Replace the shipped default admin password with a TPM-held one through the REST API. Build an auth-json token by hand for testing. |
| `gaming-pc/keepawake/` | gaming-pc | `keepawake.ps1 -Mode on/off/status` starts and stops a SYSTEM scheduled task that holds a power request while VMs run. |
| `gaming-pc/guest/` | gaming-pc, run on the host | Guest provisioning over **PowerShell Direct**: base install (winget + TightVNC), debloat, Steam/Epic/WinCDEmu, Sunshine, the kid account, the game-disc staging and fixed-letter mounting, and an internet on/off switch. |

### Two ways in

1. **Browser (Guacamole).** The kid opens the launcher page and taps their name. The
   launcher resumes the VM and redirects to Guacamole, which shows the desktop over VNC.
2. **Moonlight (Sunshine in the guest).** This is better for games and controllers. Moonlight
   cannot start a stopped VM, so on the iPad a **Shortcut** calls the launcher's `/go/<kid>`
   endpoint first. It replies instantly ("Waking kid1's PC…"), and by the time the kid
   has switched to Moonlight the VM is online.

## Design decisions

- **Compute on the GPU box, control plane on the always-on box.** The server is a 35 W mini
  PC with no PCIe slot. The gaming-pc has a 16-core CPU and plenty of RAM, but it sleeps.
  So the VMs live where the power is, and everything that has to be awake runs on the server.
- **No GPU virtualisation.** The owner did not want the discrete GPU shared, and the CPU's
  integrated Radeon graphics can't be partitioned (Hyper-V GPU-P effectively supports only
  NVIDIA and Intel). Software rendering (WARP) with 4 vCPUs of a fast desktop CPU is
  plenty for the target games. It also removes the fragile layer entirely: no guest
  drivers that must match the host's exactly, and nothing breaks when the host's driver
  updates. Sunshine uses software encoding.
- **On demand, not always on.** VMs are **saved** (Hyper-V's hibernate: RAM to disk, memory
  returned to the host) when idle, and resumed in a few seconds. The host keeps its normal
  sleep behaviour.
- **VNC, not RDP, for the browser path.** An RDP login takes over the console session that
  Sunshine streams, so the two would fight. VNC attaches to the same console desktop, so
  both paths coexist.
- **Native systemd services, not containers, for the launcher and watchdog.** They need an
  SSH key to the gaming-pc and a broadcast socket for wake-on-LAN. As a container that
  would mean host networking, raw-socket capabilities and a mounted private key, which is
  a container in name only. They use only the standard library, so there are no pip
  dependencies to rot.
- **Secrets through systemd credentials.** The VNC password and the Guacamole JSON signing
  key are `systemd-creds` encrypted (TPM-bound). The launcher unit loads them with
  `LoadCredentialEncrypted=`, so the plaintext only exists in a private tmpfs that one
  service can read, and the service never needs sudo. On the Windows side, credentials
  are DPAPI files that only the host account can decrypt.
- **No passwords for the kids, by design.** The launcher builds a JSON descriptor for exactly
  one VNC connection, signs it (HMAC-SHA256) and encrypts it (AES-128-CBC) with the shared
  key, and posts it to Guacamole's `/api/tokens`. Guacamole returns a session containing
  only that connection. The VNC credential travels server to server inside the encrypted
  blob and never reaches the browser. Each blob is scoped to one VM and expires after 60
  seconds.
- **Guest hardening.** The kids use standard (non-admin) accounts. Each guest's firewall
  only accepts VNC from the server and the host. An internet switch (`guest-internet.ps1`)
  blocks all outbound traffic except the home LAN by default, and the kids can't change
  it. Ads, Copilot, web search and consumer "suggestions" are removed machine-wide and in
  the Default profile, so new accounts inherit the settings.
- **Keepawake changes no power settings.** The gaming-pc owner switches power plans with
  desktop shortcuts, so a hold built on `powercfg` would get undone or would overwrite
  the plan. Instead, a SYSTEM task holds a `SetThreadExecutionState` request, and Windows
  drops it the moment the process ends. The task also releases itself after 10 minutes
  with no running VM, so a crashed watchdog can't pin the PC awake.
- **Unknown means "in use".** If the watchdog can't tell whether someone is connected, it
  leaves the VM running. Interrupting a child mid-game is worse than leaving a VM up a
  bit longer.

## Wake-on-LAN: why it failed and how it was fixed

The server already woke the gaming-pc for nightly backups, and the launcher reuses the same
magic packet. For a while it never worked. The full investigation is in HISTORY.md. In short:

- **The network was fine.** With the PC awake, a packet capture on its NIC received 48 of 48
  test packets (broadcast and unicast). The mesh router forwards broadcasts between nodes
  correctly.
- **The Windows NIC settings were not enough.** These were all correct, but the PC still
  didn't wake: wake on magic packet on, the "WoL & shutdown link speed" set so the link
  doesn't drop to 10 Mb in sleep, and Green Ethernet and power saving off.
- **The cause was the firmware.** *ErP Ready* (the EU standby-power mode) cut standby power
  to the onboard NIC in S3. Disabling ErP and enabling *Resume by PCI-E device* fixed it.
  The PC now wakes about 1 s after the first packet from S3, and in about 40 s from
  hibernate.
- ***Wake on pattern match* was then turned off** so that only a magic packet can wake the
  PC, not stray LAN traffic. That also made the final proof clean: silent magic-packet
  bursts with no other traffic from the server still woke it.

### Traps from that work

- **Windows' "last wake source" lies on this board.** After a genuine wake-on-LAN wake from S3 it
  reports "Power Button", because the firmware signals the PCIe wake through the
  fixed-feature power-button event. Judge by timing, not by that label.
- **ARP is not a liveness test in sleep.** The NIC doesn't answer ARP in S3, even with ARP
  offload enabled, but it still wakes on a magic packet. A "quick ARP pre-check" would
  have reported WoL broken after it had already been fixed.
- **Make the test show the cause, not just the result.** Early tests pinged the host after
  every burst. With pattern match on, the ping might have been what woke it. The
  conclusive test used silent bursts and no other traffic.
- **A verdict script needs timing.** One test script nearly announced "woke" when the
  reply came 5 minutes after the last packet. That was the power button.
- **Moonlight's "Wake PC" button on iOS sends nothing.** An A/B capture (30 s idle vs 30 s
  tapping) showed zero magic packets either way. That is why the iPad path uses a
  Shortcut that calls the launcher.

## Measured timings

Every launch logs each phase, so tuning is based on evidence.

| Phase | Cold (host asleep) | Warm |
|---|---|---|
| decide host is asleep | 1.5 s (connect timeout) | ~0 s |
| host wakes from S3 until SSH answers | ~8 s | - |
| `Start-VM` restoring 8 GB of saved state | 4-8 s | 4-5 s |
| guest answers VNC | 0 s (it answers before `Start-VM` returns) | 0 s |
| **total** | **~14-15 s** | **~4-5 s** |

About 1.4 s of every remote call is `powershell.exe` starting on the host, not SSH. SSH
connection reuse (`ControlMaster`) saved only ~0.2 s.

## Traps and lessons (the valuable part)

**Talking to Windows over SSH**
- The Windows OpenSSH default shell is `cmd.exe`. The semicolon is not a separator, and the
  pipe character gets parsed by cmd before PowerShell sees it, so a pipeline listing the
  VMs returned **nothing, with exit code 0**. Send everything as `-EncodedCommand` (base64 UTF-16LE),
  which contains no shell metacharacters.
- Hyper-V's `State` comes back from `ConvertTo-Json` as an **enum number** (2 = Running,
  6 = Saved, 9 = Paused), not a name.
- PowerShell's progress stream leaks into SSH output as CLIXML. Silence the progress
  preference, and do it **inside** PowerShell Direct script blocks too, because they have
  their own defaults.
- On Windows, an admin account's SSH key must go in the system-wide administrators key
  file, not the user's own. The firewall rule that OpenSSH Server's setup creates may only
  cover the "Private" profile.
- The execution policy blocked `.ps1` files over SSH, while interactive tests passed. The
  failure was silent and made keepawake look like it was working. vmctl now sets a
  process-scoped bypass, and the host's machine policy was fixed too.
- A key-based SSH logon can't decrypt DPAPI secrets protected for an interactive logon.
  Plan secret hand-offs around that.

**PowerShell 5.1**
- Taking the count of a filtered result returns **nothing** when exactly one object
  matches, because a single result isn't an array. With one connected player that read
  as "cannot tell". Forcing the result into an array makes the count work for 0, 1 and
  many.

**Watchdog correctness**
- **Count only the ports that mean "in use"**: VNC (5900) and Sunshine's RTSP (48010, a
  live stream). Moonlight keeps 47984/47989 open just to show "PC online", so counting
  those meant an iPad left with Moonlight open kept the VM, and the host, awake forever.
- **"Unreachable" must never look like "not found".** At first, a failed SSH call returned
  an empty VM list, which read as "nothing is running". The watchdog would then have
  released keepawake mid-game. Now vmctl raises an error and the watchdog changes nothing
  on that pass.
- **Test the watchdog as the service user, never with sudo.** Only that user holds the SSH
  key, so root reports "Unreachable", which looks like a fault that isn't there.
- **Default to stub/dry-run, and go live deliberately.** vmctl defaults to stub mode. At
  first no unit set it to live, so everything was quietly driving the simulator.

**Launcher and clients**
- **systemd strips the double quotes from inline JSON** in `Environment=` lines, and the
  service crashed with a JSON decode error. The kid map lives in `kids.json` (see
  `kids.example.json`), which is re-read on every request.
- Small `systemd-run` wrappers to read secrets **fail for a non-root service**
  ("Interactive authentication required"). Give the unit its own `LoadCredentialEncrypted=`.
- **iOS Shortcuts errors if an endpoint returns JSON** (it parses the response into a
  Dictionary and then can't display it). Every endpoint a Shortcut calls returns plain text.
- **Reply first, work later.** `/wake/<kid>` waits until the VM is ready. `/go/<kid>` does the
  same work but replies in ~10 ms. The wait is identical, but the second one feels far
  quicker.
- **When measured and perceived latency disagree, look before the request arrives.** Users
  felt much longer waits than the logs showed. The cause was IPv6: the router handed out
  ULA addresses with no default route, so every connection stalled ~4 s before falling
  back to IPv4. The launcher now logs `REQUEST IN` on arrival.
- **Check the guest's VNC port before handing off.** Then a kid never lands on a Guacamole
  error page while the VM is mid-reboot.
- **A resumed VM and working browser access are separate outcomes.** Moonlight needs only
  the first, so the launcher reports them separately.

**Hyper-V and guests**
- **A guest can't see the host's TPM.** Windows 11 guests need the VM's own vTPM.
- **Never clone Sunshine.** Install it per VM after copying, or both VMs share an identity
  and pairing breaks. Clone Windows with export/import and new IDs.
- The external virtual switch moves the host's IP onto a virtual adapter that inherits the
  physical MAC. Re-test wake-on-LAN after creating it.
- **iPad "can't find host" with the right IP** was iOS's *Local Network* permission for
  Moonlight being off. Check that before touching any firewall.
- **Moonlight shows the picture but input is dead** after someone used "Switch user"
  inside the VM. Sunshine injects input into the console session. Restart the Sunshine
  service, and sign the admin out instead of switching users.
- **Moonlight's on-screen gamepad killed the mouse** until a virtual gamepad driver
  (ViGEmBus) was installed in the guest.
- **Old educational games remember the CD drive letter they were installed from.** Each disc
  image is re-mounted at a fixed letter by a startup task. A `.cue` file that names a
  renamed `.bin` gets refused, so fix the `FILE` line.
- **Testing a game from PowerShell Direct gives false passes.** That runs in session 0,
  where some 2002-era titles don't crash. Test on the kid's real interactive desktop, and
  check what the window actually is: a "cannot find CD" dialog keeps the process alive too.

## Files

```
server/
  launcher/launcher.py           picker page + /go /wake /healthz /api/*
  launcher/kids.example.json     VM name -> label, IP, VNC port (placeholders)
  sbin/vmctl                     the only SSH->PowerShell path
  sbin/kids-vm-watchdog          idle saver + keepawake release
  sbin/guac-set-admin-password   replace the default Guacamole admin password
  sbin/guac-token                build an auth-json token (debug helper)
  systemd/                       launcher service, watchdog service + timer
  guacamole/compose.yaml         Guacamole stack (no secrets; injected at start)
gaming-pc/
  keepawake/                     keepawake.ps1, its holder, one-time installer
  guest/                         provisioning scripts run on the host via PowerShell Direct
```

All site-specific values are `<PLACEHOLDER>` config variables at the top of each file or in
the systemd units.
