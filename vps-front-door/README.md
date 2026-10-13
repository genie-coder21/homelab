# VPS front door

A small cloud VM (Oracle Cloud Always Free) acts as the public entrance to a home server.
The home network forwards **no ports at all**: the home server dials *out* to the VPS over
WireGuard, and the VPS reverse-proxies public HTTPS traffic back down that tunnel to a short
list of self-hosted web services. The VPS is also where hostile traffic gets blocked, and it
doubles as the Tailscale subnet router for reaching the home network from personal devices.

## Why

- **No inbound ports at home.** The home router stays closed; the only thing that ever
  arrives from outside is traffic the home server's own outbound tunnel carries.
- **The internet-facing box is disposable.** If the VPS were ever compromised, the tunnel
  only lets it reach the handful of services it fronts, nothing else on the home server.
- **Real visitor IPs survive.** The proxy forwards client addresses, and the home services
  trust the VPS's tunnel address as a proxy, so logs and the IDS see real public IPs.
- **Free.** The whole front door runs inside Oracle's Always Free allowance.

## Architecture

```
                         ┌──────────────────── vps (cloud) ──────────────────────┐
  visitors ──https──────▶│ host firewall (only web + tunnel + mgmt open)         │
                         │ CrowdSec bouncer (nftables drop)  ◀── ban decisions ──┼──┐
                         │ CrowdSec agent (proxy + auth logs) ──── alerts ───────┼─┐│
                         │ reverse proxy (TLS, real-IP headers)                  │ ││
  personal devices ─────▶│ Tailscale subnet router ──▶ SNAT to a dedicated       │ ││
  (tailnet)              │                             tunnel address            │ ││
                         └───────────────────────┬───────────────────────────────┘ ││
                                    WireGuard    │  (dialled OUT from home)        ││
                         ┌───────────────────────▼───────── server (home) ───────┐ ││
                         │ UFW + DOCKER-USER: per-source, per-port allow lists    │ ││
                         │ self-hosted web services (containers)                  │ ││
                         │ CrowdSec local API + database ("the brain") ◀──────────┼─┘│
                         │   decisions ──────────────────────────────────────────┼──┘
                         │ tunnel health check (systemd timer)                    │
                         └────────────────────────────────────────────────────────┘
```

### Who can reach what (by design)

| Source | Reaches | Enforced by |
|---|---|---|
| Internet visitors | only the hostnames the proxy serves | VPS firewall, CrowdSec bouncer, proxy |
| The VPS itself (its tunnel address) | only the fronted services + the CrowdSec API | home UFW + DOCKER-USER, per port |
| Tailnet devices (arrive as a separate tunnel address) | the home network, like a LAN device | home UFW + DOCKER-USER |
| Anything else inbound on the tunnel | nothing | explicit drop |

## Design decisions

### WireGuard, dialled from home
The home side has the VPS as its only peer and routes only the tunnel subnet into it, so
normal home traffic is untouched. `PersistentKeepalive` keeps the NAT mapping open, which
is what lets a box with zero port forwards be reachable at all.

### Reverse proxy on the VPS
The proxy terminates TLS (Let's Encrypt, HTTP-01, auto-renewing) and passes `X-Real-IP`,
`X-Forwarded-For` and `X-Forwarded-Proto`. Each home service is configured to trust the
VPS's tunnel address as a known proxy, so per-user logging and brute-force detection work
on real client addresses. Plain HTTP only redirects to HTTPS. A template is in
`templates/proxy-site.conf.example`.

### CrowdSec split: decide at home, block at the edge
Running CrowdSec only at home doesn't work: every visitor arrives from the VPS's tunnel
address, so home would see one "attacker" and banning it would cut off everyone. Running it
only on the VPS loses the home services' own logs (login failures). So:

- **Home:** the local API + database, plus an agent reading the home services' auth logs.
  It also pulls the community blocklist and holds a central allowlist for trusted
  addresses (an allowlist beats every ban source, including the community list;
  a parser whitelist would not).
- **VPS:** an agent only (its own local API disabled) reading the proxy and SSH logs, plus
  the nftables firewall bouncer. Both report to and pull from the home API **over the
  tunnel**, so attackers are dropped before they reach the proxy or the tunnel.
- Private ranges are always whitelisted, and a small parser whitelist ignores 404s on
  image/artwork endpoints that the apps' own clients generate, which otherwise look like
  scanning and ban real users.
- New bans are pushed to a self-hosted notification service, batched.

If the tunnel or the home box is down, the bouncer keeps the bans it already has and
resumes pulling when the tunnel returns.

### Home firewall: UFW plus DOCKER-USER
Docker publishes container ports **around** UFW, so UFW alone does not protect containers.
The home server uses UFW for host services (default deny inbound) and a block in
`/etc/ufw/after.rules` for the `DOCKER-USER` chain that applies the same policy to
container traffic: established traffic, the LAN and the Docker networks are allowed; from
the tunnel, the VPS address may reach only its specific ports, matched on the *original*
destination port (`conntrack --ctorigdstport`, because DNAT has already rewritten the port
by the time `DOCKER-USER` sees it); everything else arriving on the tunnel or the WAN
interface is dropped. Template: `templates/ufw-after.rules.docker-user.example`.

Risky firewall changes are made behind a dead-man switch: a transient systemd timer that
disables the firewall after a few minutes unless it is cancelled once access is verified.

### Tailscale through the VPS
The home server is not itself a tailnet node; the VPS advertises the home LAN and tunnel
subnets as a subnet router and forwards into WireGuard. Two non-obvious pieces:

1. Traffic from tailnet devices is **SNATed to a dedicated tunnel address** (not the VPS's
   own). Without a rewrite, packets arrive at home from a CGNAT address home has no route
   back to and connections hang. Using a *separate* address lets the home firewall give
   tailnet devices LAN-level access while the VPS's own address stays restricted.
2. **Tailscale's built-in subnet SNAT must be off**, otherwise it rewrites the traffic to
   the VPS's own address before your rule runs, and home treats your phone as the
   restricted VPS.

### Key-only SSH, management over the tunnel
Both machines use public-key-only SSH with root login disabled and a short auth window,
set in a drop-in rather than the main config (`templates/sshd-hardening.conf.example`).
Administrative SSH to the VPS goes **through the tunnel**, which is in a private range
CrowdSec always whitelists, so the IDS can never lock the admin out even if the admin's
public exit address lands on a blocklist.

### Tunnel health check
`scripts/hl-tunnel-healthcheck` runs from a systemd timer every 5 minutes. It checks the
two things that failed silently once (see traps): the interface still has its address,
and the VPS answers on TCP. If either fails it restarts `wg-quick`. `wg-quick` is
`Type=oneshot`, so a drop-in adds `Restart=on-failure` (permitted for oneshot) so a failed
cold boot retries instead of staying dead.

### Keeping a free VM alive
Oracle reclaims Always Free instances that sit idle (CPU utilisation under a threshold over
a week). A low-priority hourly load job keeps the VM above it. A brief burst was enough on
the old micro shape but not on the larger Ampere shape, which needed a longer one.

## Migration to an Ampere A1 instance

The original front door was the free `VM.Standard.E2.1.Micro` shape. Measuring each leg
showed the home uplink was several times faster than anything going through the tunnel:
the micro shape is capped at about **50 Mbps for all remote users combined**. Average use
was far below that, but the provider's throttle-drop metric showed clients downloading in
bursts that hit the cap on several days.

The free **Ampere A1** shape (up to 2 OCPU / 12 GB per tenancy at the time) has far more
network bandwidth, but free A1 capacity is notoriously scarce. Two dead ends worth knowing:

- **Another region doesn't help**: Always Free resources only exist in the tenancy's home
  region, and free accounts can't subscribe to more.
- **Upgrading to pay-as-you-go** usually gets capacity faster. It was planned (with a
  tenancy quota capping compute at the free amounts and a $1 budget alert as guard rails)
  but turned out to be unnecessary.

### The capacity hunter
`scripts/hl-a1-hunt` (with `hl-a1-hunt.service` / `.timer`) retried instance creation
every ~5 minutes until it succeeded, which took about 300 attempts over a day and a half.
Properties that mattered:

- **Never creates a duplicate.** Each run first lists non-terminated instances with the
  target name. If that lookup fails, *or its reply can't be parsed*, the run does nothing.
  (An early version fell through to launching on a parse error; it was harmless that time
  but is now an explicit abort.)
- **Fails fast.** Launches use `--no-retry`, so an "Out of host capacity" answer returns in
  seconds instead of the CLI backing off for minutes and overlapping the next run. Each
  availability domain is tried once per round. A `flock` guards against overlap anyway.
- **Confirms before declaring victory.** A successful launch is only reported once a later
  round sees the instance `RUNNING` and an SSH login works. It then writes a result file,
  sends a notification and disables its own timer.
- **Cloud credentials never sit on disk.** `scripts/hl-oci` wraps the OCI CLI: the API key
  lives in an encrypted credential store and is decrypted per call into a private
  directory on tmpfs, then shredded. Each call gets its *own* directory, because a single
  fixed path let nested calls delete each other's key. Under a systemd unit there is no
  per-user runtime dir, so it falls back to `/dev/shm`.

### Building alongside, then cutting over
The new VPS was built **next to** the live one on a **second, separate tunnel** with its
own interface and subnet at home, so nothing live changed during the build: proxy config
and certificates copied over, a CrowdSec agent + bouncer registered with the home API, home
firewall rules added for the new tunnel, the services' known-proxy lists extended. It was
tested end to end against the new address, with DNS overridden only on the test client,
while the old VPS still served everyone: health endpoints, TLS verification, redirect, real client IP in the logs,
and a test ban (a TEST-NET address) reaching the new bouncer within seconds. A real transfer
then measured roughly **5x** the throughput through the new VPS.

Cutover was a DNS change with a short TTL; rollback is the same change in reverse, so the
old VPS and tunnel are kept untouched as a rollback path for a while before retirement.

### Retiring a front-door VPS (checklist)
1. Move the Tailscale subnet router to the new VPS (needs an approval in the admin console).
2. **Delete every DNS record that still points at the old public IP before releasing it**:
   the provider will hand that IP to someone else, and a stale record becomes a subdomain
   takeover.
3. Revoke any credentials that lived only on the old VM.
4. Remove the old tunnel interface and its firewall rules at home; point monitoring at the
   new tunnel.
5. Delete the instance and its boot-volume backup.

## Traps and lessons

- **A tunnel can be "up" and carry nothing.** NetworkManager adopted the `wg-quick`
  interface as an assumed connection and later "disconnected" it, which flushed the
  interface address. WireGuard kept handshaking, `systemctl` said active, `wg show` showed
  a fresh handshake, and yet the VPS was unreachable: with the address gone the on-link
  route vanished and a broader route from another VPN interface swallowed the subnet. Fix:
  list the WireGuard interface under NetworkManager's `unmanaged-devices`. This is why the
  health check tests the address and a TCP connection, not the service state.
- **Don't diagnose the tunnel with ping.** The VPS filters ICMP; ping fails while the tunnel
  is fine. Test a TCP port.
- **Testing the subnet router from the VPS itself lies.** Locally generated traffic skips
  Tailscale's SNAT path, so it passes while real tailnet clients fail. Test from a real
  device, or watch the SNAT rule's packet counter climb.
- **Docker bypasses UFW.** Without the `DOCKER-USER` block, published container ports are
  open regardless of UFW. And `iptables-restore` (used by `ufw reload`) rejects a trailing
  `# comment` on a rule line in `after.rules`; comments go on their own line.
- **Too-narrow container allow rules break container-to-host traffic** through the host's
  LAN address (one service calling another). Allow the Docker networks as a source.
- **Whichever VM runs the dynamic-DNS updater owns the names.** With the IP left blank, the
  updater registers its own address, so a manual change on the DNS provider's site is
  reverted within minutes by the other VM's cron. Cutover = disable it on one, enable on
  the other.
- **CrowdSec's machine-registration command writes the credentials to stderr** (1.8.x), not
  stdout, so redirecting its standard output captures an empty file.
- **CrowdSec's stock `profiles.yaml`** has commented-out `notifications:` lines between
  `decisions:` and `on_success:`; add the real block directly above `on_success: break` or
  notifications silently stay disabled.
- **The cloud image's default iptables ends in a REJECT rule**; new allow rules must go
  *above* it and be persisted, or they do nothing.
- **Recovering a VM whose SSH key was lost**: stop it, attach its boot volume to a helper
  instance (or use "replace boot volume"), let cloud-init inject a new key, copy configs
  and certificates off, then move the disk back. Delete the helper and its volume
  afterwards so it doesn't eat the free storage allowance.
- **Measure each leg separately** (home uplink direct, home to VPS through the tunnel, VPS to
  internet) before blaming the backend services.

## Files

| Path | What |
|---|---|
| `scripts/hl-tunnel-healthcheck` + `.service` / `.timer` | tunnel health check |
| `scripts/wg-quick-override.conf` | `Restart=on-failure` drop-in for `wg-quick@` |
| `scripts/hl-a1-hunt` + `.service` / `.timer` | A1 capacity hunter |
| `scripts/hl-oci` | OCI CLI wrapper with per-call ephemeral key |
| `templates/` | placeholder-only examples: WireGuard (both ends), proxy site, CrowdSec agent/bouncer/acquisition/whitelist, DOCKER-USER rules, NAT rule for the subnet router, SSH hardening |

Everything in `templates/` uses `<PLACEHOLDER>` tokens and RFC 5737 / documentation-range
addresses; no keys or real values are included.
