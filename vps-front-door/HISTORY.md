# History

How the VPS front door was recovered, hardened, debugged and then moved to a bigger free
instance. It covers what was tried, what failed and why, and how each fix held up. Oldest
first.

Reference projects: [WireGuard](https://www.wireguard.com/),
[CrowdSec](https://docs.crowdsec.net/), [Tailscale subnet routers](https://tailscale.com/kb/1019/subnets),
[UFW](https://help.ubuntu.com/community/UFW),
[Docker and iptables](https://docs.docker.com/engine/network/packet-filtering-firewalls/),
[OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm).

---

## 2026-09-21: Archaeology, recovering a VPS we were locked out of

The home server's system disk had been wiped and rebuilt. Remote access to the
self-hosted web services had stopped, and nobody remembered exactly how it used to work.
The one clue was a cloud VM that was still running and still billed against the free
tier. Its only SSH key had been on the wiped disk, so we couldn't log in.

**Approach.** A cloud VM without a working key isn't lost, because its boot disk is just a
volume. We used the provider's "replace boot volume" path to boot that disk on a temporary
helper instance. Cloud-init on the helper injected a fresh SSH key, which gave us access to
the old filesystem. Before changing anything, we copied every config file, certificate and
log off it into a locked-down folder at home, and we kept a boot-volume backup in the cloud.
Then the disk went back to its original instance.

**What the configs revealed.** The VM had been a front door. A WireGuard tunnel ran to the
home server, and a reverse proxy published a few self-hosted web services through it.

**Rebuilding the tunnel.** The home end of the tunnel had to be recreated from scratch. We
generated a new keypair at home and swapped the old peer key on the VPS for the new one
rather than reusing anything. We also kept a dated backup of the VPS's previous tunnel
config. The home side dials out with a keepalive, so the home router needs no port
forwards at all. The two main public services were reachable again the same day.

## 2026-09-22: Locking it down

With access restored, the next job was making sure the tunnel couldn't become a liability.

**Home firewall.** We wanted the VPS to be able to reach only the specific services it
publishes. That way, even a fully compromised VPS gets nothing else on the home server.
UFW handles host services, but Docker writes its own iptables rules, and published
container ports bypass UFW completely. Writing only UFW rules would have looked secure
and wasn't. So the policy was written twice: once in UFW for the host, and once in a
`DOCKER-USER` block inside UFW's `after.rules` for containers.

Inside `DOCKER-USER`, the rules match on the *original* destination port through
conntrack, because Docker's DNAT has already rewritten the port by the time the packet
gets there. The order is: allow established traffic, the LAN and the Docker networks;
allow the VPS's tunnel address only to its specific ports; drop everything else arriving
on the tunnel or the WAN.

Enabling a default-deny firewall on a remote headless box is the classic way to lock
yourself out. We armed a dead-man timer first, which turns the firewall off again after
five minutes unless it is cancelled. Then we tested every path, including negative tests
showing the VPS is *refused* on SSH and on unrelated services, before cancelling the timer.

**Real visitor IPs.** The proxy was already sending the forwarding headers, but the home
services ignored them. Every visitor therefore looked like the VPS. We marked the VPS's
tunnel address as a trusted proxy in each service and confirmed that real public IPs now
appear in their logs. This mattered for the next step.

**CrowdSec, attempt one: everything on the VPS.** The VPS logs showed thousands of SSH
brute-force attempts a day and constant probing for config files. We installed CrowdSec
natively on the VPS with the nftables firewall bouncer, the community blocklist, and
collections for the proxy, SSH and generic HTTP attacks. App clients produce a stream of
404s when artwork is missing, and those looked like scanning, so a small local parser
whitelist exempts 404s on image endpoints. A manual ban of a TEST-NET address showed up in
the nftables set within seconds.

**Attempt two: back to the original split.** In the recovered files we found a leftover
bouncer config that pointed at a CrowdSec API *at home*, so the original design had been
split. Thinking it through showed why:
- A CrowdSec running only at home sees every visitor as the VPS and can't block anyone
  at the edge.
- A CrowdSec running only on the VPS can't read the home services' own login logs, which
  is where password guessing shows up.

The fix is to put the decisions where the logs are and the blocking where the traffic
enters. We moved the local API and database into a container at home. A home agent reads
the services' auth logs, which now contain real IPs. The VPS became an agent plus bouncer,
with its own local API switched off, and it talks to the home API over the tunnel. We
added a central allowlist for trusted addresses. An allowlist entry overrides every ban source, including the community
blocklist, which a parser whitelist does not. We tested the whole chain both ways: a ban
created at home appeared on the VPS within seconds, and a manual ban against the
allowlisted address was refused.

**Other VPS cleanup.** We closed the ports of services that no longer existed. Admin SSH to the VPS now goes *through the tunnel*.
Tunnel addresses are in a private range that CrowdSec always whitelists, so the IDS can
never lock out its own administrator.

## 2026-09-23: Tailscale via the VPS, and two subtle bugs

Personal devices on the tailnet needed to reach the home network. Running Tailscale on the
home server itself clashed with other routing on that box. The pre-wipe design avoided
this by making the **VPS** the tailnet node, advertising the home LAN and tunnel subnets
and forwarding into WireGuard. We rebuilt that design: routes advertised and approved,
forwarding enabled, and forward rules between the Tailscale and WireGuard interfaces.

**First failure: connections hung.** Packets reached home with a Tailscale CGNAT source
address, and home had no route back to it. The fix is SNAT on the VPS. We deliberately
rewrote to a **dedicated extra tunnel address**, not the VPS's own one. That keeps tailnet
devices distinguishable at home, so the home firewall can give them LAN-level access while
the VPS's own address stays restricted. The home side's allowed range was widened from a
single host to the tunnel subnet so replies route back.

**Second failure: tailnet devices behaved like the VPS.** Everything except the published
services was refused. It turned out Tailscale was applying its *own* subnet-route SNAT and
rewriting traffic to the VPS's address before our rule could run. Turning off Tailscale's
built-in SNAT fixed it.

This was hard to see because testing from the VPS itself skips that SNAT path, so local
tests passed while real devices failed. The method that worked was to test from a real
device and watch whether the packet counter on the SNAT rule climbs.

The same round of testing turned up an unrelated firewall mistake. The home rule allowing
the Docker networks had been limited to a single port, which blocked one container from
calling another through the host's LAN address. That rule now allows all ports from the
Docker networks. The fix was confirmed from a phone on cellular. Afterwards we wrote a
single page holding the full access matrix and every security layer in order.

## 2026-09-27: The tunnel that was up and carrying nothing

**Symptom.** Remote access was gone, yet every status check was green: the service was
active and the tunnel showed a handshake a few seconds old.

**Investigation.** The first instinct was to ping the VPS through the tunnel, which
failed. That was a blind alley, because the VPS filters ICMP and ping fails even on a
healthy tunnel. Looking at the interface itself was more useful: it had **no IP address**.
The system log explained why. NetworkManager had treated the `wg-quick` interface as an
"assumed" connection at boot, created a profile for it, and later *disconnected* it, which
removed the address. WireGuard carried on handshaking regardless. With the address gone
the on-link route vanished, and a broader route belonging to another VPN interface on the
box captured the tunnel subnet.

**Fix, in layers.**
1. Root cause: the WireGuard interface was added to NetworkManager's unmanaged-devices
   list. That also takes it out of the desktop network menu, where nobody should be
   toggling it anyway.
2. Boot resilience: `wg-quick` is a oneshot unit, so a failed start at boot stays failed
   forever. A drop-in adds `Restart=on-failure`, which is allowed for oneshot units, to
   retry when the network isn't ready yet.
3. Detection: the dangerous part was that nothing noticed. A new health-check timer runs
   every five minutes. It checks the two things that were silently wrong, whether the
   address is present and whether the VPS answers on a TCP port, and restarts the tunnel
   if either fails. It deliberately ignores service state and handshake age, because both
   looked healthy during the outage.

## 2026-09-30: The fix survives a reboot

After a planned reboot the tunnel came back by itself and the health check stayed quiet.
This was the first real proof that the NetworkManager fix survives a restart.

## 2026-10-04: Finding the real bottleneck

Remote users reported occasional stutter. Before touching the services, we measured each
leg of the path on its own:
- the home uplink directly to the internet ran at several hundred Mbps;
- home to the VPS through the tunnel ran at about 45 Mbps;
- the VPS out to the internet ran at about 49 Mbps.

The cause was the VPS. The free micro shape is capped at about 50 Mbps, shared by every
remote user at once, and the backend was nowhere near its own limits. As a stop-gap we set
a per-client rate limit in the backend so a single heavy client couldn't fill the pipe.

**Cloud CLI without keys on disk.** To manage the cloud account from the home server, we
installed the OCI CLI in a virtualenv. The API key went into the TPM-backed encrypted
credential store and the plaintext copy was shredded. A small wrapper decrypts the key into
a private tmpfs directory for one command and deletes it on exit.

The first version used one fixed path. When one call was piped into another, the inner
call's cleanup deleted the outer call's key mid-run. Each call now gets its own
`mktemp` directory. A later fix added a fallback to `/dev/shm`, because systemd services
have no per-user runtime directory.

**Cleanup.** The recovery helper instance from 2026-09-21 was still holding free-tier
storage. Before deleting it with its boot volume, we checked that the volume really was the
helper's and not the live VPS's. Afterwards we confirmed only the intended resources were
left.

**First attempt at a bigger instance.** The free Ampere A1 shape gets roughly 1 Gbps of
network per OCPU. This account's free A1 allowance turned out to be 2 OCPU / 12 GB, not
the 4 / 24 that older guides mention. The launch failed with "Out of host capacity" in
every availability domain.

That first manual launch also took over five minutes to fail, because the CLI quietly
retries with backoff. Changing regions isn't an option, since Always Free resources only
exist in the tenancy's home region and free accounts can't add regions.

**The capacity hunter.** Capacity comes and goes, so the answer was to keep asking. A
systemd timer runs a script about every five minutes. It was designed around one rule:
*never create two instances*.
- Each run first lists non-terminated instances with the target name and stops if that
  lookup fails for any reason.
- Launches use the CLI's no-retry flag, so a "no capacity" answer comes back in seconds and
  runs don't overlap. A lock file guards against overlap anyway.
- Each availability domain is tried once per round.
- A successful launch isn't treated as a win straight away. The next round has to see the
  instance RUNNING and log in over SSH. Only then does the script write a result file, send
  a notification and disable its own timer.

**Notifications.** The same day, CrowdSec bans were wired into the self-hosted notification
hub, batched so a burst of bans arrives as one message. The monitoring watchdog also
alerts if the VPS bouncer stops pulling decisions.

One small trap: the stock CrowdSec profiles file has commented-out notification lines in
an unexpected spot. The first edit missed them, and notifications showed as disabled until
the real block was moved directly above the final `on_success` line.

## 2026-10-05: Deciding with data, then pausing

Before spending money or risk, we pulled 30 days of the provider's network metrics and
proxy logs. Traffic was a few percent of the free monthly egress, and the average rate was
low. But the throttle-drop metric showed drops on six days: clients download in bursts,
and the bursts were hitting the cap even when the average was low. So the cap was real,
and it would become a hard limit with a handful of simultaneous users.

The overnight hunter had made over a hundred attempts, all "no capacity". Upgrading the
account to pay-as-you-go usually gets capacity sooner, so we wrote a plan with guard rails:
- a tenancy quota pinning compute and storage to the free amounts, so overspending is
  impossible rather than merely alerted on;
- a $1 budget alert as a second line;
- a clear list of what would ever be billable.

The owner paused that plan. The hunter kept running on the free account in the meantime.

## 2026-10-06: Got it, built it beside the old one, cut over

**Capacity at last.** The hunter succeeded on attempt 304. The next round confirmed the
instance was RUNNING and accepted SSH, sent the notification, and switched itself off. We
checked that exactly one instance existed. The paid upgrade was no longer needed.

While reviewing the logs we found a latent bug in the hunter. In one round the existence
check had returned something that wasn't valid JSON, and the script had treated "couldn't
parse" as "doesn't exist" and gone on to launch. Nothing existed yet, so no harm was done,
but it broke the script's one rule. A parse failure now aborts the round.

**Build without risk.** Rather than rebuilding the live VPS in place, we built the new one
**alongside** it on a **second, independent tunnel**, with its own interface and subnet at
home. The live path was never touched during the build:
- the proxy site config and existing certificates were copied over;
- a CrowdSec agent and bouncer were registered with the home API under new names;
- the home firewall got equivalent rules for the new tunnel in both UFW and `DOCKER-USER`;
- the new tunnel address was added to each service's trusted-proxy list.

The cloud image's default iptables ruleset ends in a REJECT, so the new web and tunnel
allows had to sit above it and be saved to persist.

Registering the new CrowdSec agent produced a surprise. The registration command writes the
generated credentials to stderr rather than stdout, so the first attempt copied an empty
file across. We caught it and redid the step, and checked that the home API's own
credentials were untouched.

Two other things changed for the new shape:
- The larger instance needed a stronger anti-idle job. The short hourly burst that kept
  the micro instance above the provider's idle-reclaim threshold wasn't enough for it.
- Tailscale was installed on the new VPS but left logged out, because two subnet routers
  advertising the same routes would have changed live routing.

**Testing before any DNS change.** We pinned the public names to the new address on the
test client only, then checked:
- health endpoints, TLS verification, and the HTTP-to-HTTPS redirect;
- that the backends logged the real client IP;
- that a test ban of a TEST-NET address reached the new bouncer in under 15 seconds.

A real transfer ran about five times faster than through the old VPS, and the new
bottleneck was the home uplink, as expected.

**Cutover.** The public names are kept current by a dynamic-DNS updater that registers
whatever address it runs from. That explained an earlier puzzle: editing the record by
hand was undone within minutes by the old VPS's updater. Cutover meant turning the updater
off on the old VPS and on for the new one, with a short TTL so either direction takes
effect quickly. Rollback is the same change in reverse.

Once DNS moved, we confirmed both services were reachable through public DNS. We then
raised the per-client rate limit, since the pipe was no longer the limit, and pointed the
monitoring at the new tunnel and bouncer.

**Retirement planning.** Once an instance is deleted, the provider will reassign its public
IP. Any DNS record still pointing at it would then belong to a stranger's server, which is a
subdomain takeover. So removing every such record is step one of the retirement checklist,
ahead of deleting the instance.

**One more narrow route.** Later that day an internal tool needed to receive webhooks from
outside. Rather than exposing anything general, the proxy got one exact-path location that
accepts only POST with a body-size limit. The home firewall got a single-port allow from
the new VPS's tunnel address only, and the receiving service checks a token as well.

A small lesson from that edit: the proxy config had trailing whitespace on a blank line,
so exact-text edits failed to match until it was accounted for. Separately, a rule added
to UFW's `after.rules` with a trailing `# comment` was rejected by `iptables-restore`.
Comments in that file must go on their own lines.

## 2026-10-24: Routine patching

The front-door instance had unattended security upgrades running daily, which is why
nothing urgent was outstanding. What *had* piled up was the rest: a few dozen regular
bug-fix updates, a newer mesh-VPN client, and a kernel update waiting for the reboot that
activates it. Automatic security upgrades do not reboot by themselves, so a reboot was
scheduled. The standby instance got the same treatment.

The procedure, worth writing down because it is the one to repeat:

1. Confirm nobody is streaming (no media connections through the tunnel, only scanner
   noise in the proxy logs).
2. Full upgrade, autoremove and snap refresh, non-interactively and keeping existing config
   files. One package was *phased* (Ubuntu's gradual rollout holds it back) and had to be
   named explicitly.
3. Turn off anything listening that nothing uses. An unused RPC service that nothing
   depended on was disabled. One less daemon is one less thing to patch.
4. Reboot. It came back in under a minute.
5. After the reboot, check the things that could silently stay down: the saved firewall
   rules were restored with the final reject rule in place, the tunnel re-handshaked, the
   proxy served the media server's health endpoint through the tunnel and the public names
   answered, the mesh-VPN node came up, and the CrowdSec agent and firewall bouncer were
   active with their ban tables back. The home-side CrowdSec API showed the agent
   heartbeating and the bouncer pulling.

**One small trap:** right after boot, CrowdSec and its bouncer lag the tunnel by half a
minute to a minute, and a check at that moment shows them "activating" and "inactive".
Check again before fixing anything; they recover on their own once the tunnel is up.

The audit found nothing else to change: SSH is key-only and certificates renew on a timer
with plenty of margin.

---

## 2026-10-26: Self-hosted email aliases, with the VPS as the mail exchanger

The alias service had gone with the home server's old system disk, and since the rebuild
the domain's mail had been handled by a hosted forwarding service. That is a one-way
arrangement: replies leave from the personal inbox rather than from the alias. Bringing it
back took three pieces.

**At home:** the alias service in Compose (web app, SMTP handler, background job runner and
a Postgres database), a fresh DKIM keypair, registration disabled, a single admin account,
and the domain's aliases recreated. The home firewall gained two per-port allows from the
VPS's tunnel address, one for the SMTP handler and one for the web UI.

**On the VPS:** Postfix as the mail exchanger, holding nothing. The domain is a relay domain
with a transport map pointing down the tunnel; the tunnel network is trusted to relay
outward; and everything bound for the internet is submitted to an authenticated external
relay, because the cloud provider blocks outbound SMTP on the standard port. A
per-destination TLS policy requires encryption on that relay leg. Inbound STARTTLS carries a
Let's Encrypt certificate, and a certbot deploy hook reloads Postfix after each renewal. The
host firewall now accepts inbound mail alongside web and tunnel traffic. The alias service's
web UI became another reverse-proxied hostname with HTTPS from certbot.

**In DNS:** the forwarding service was switched off and its records removed, the MX now
names the VPS, and SPF, DKIM and DMARC records were published for the domain.

**What went wrong along the way:** the app's own migration command did not work in a recent
release, so the migration tool was run directly and the init script afterwards; the DKIM
signer stays silent and signs nothing when given a PKCS#8 key, and wants the traditional
PKCS#1 encoding instead; Compose rejected the env file over an unquoted value that contained
a space; and the web login seemed broken until it was tried over https, since the app
issues a secure-only session cookie when its configured URL is https.

**Verified:** a message sent from outside was accepted by the exchanger, carried down the
tunnel and forwarded; a relay attempt for a foreign domain was turned away; STARTTLS shows
the real certificate; and the web login page answers over HTTPS through the proxy.


## 2026-10-26: Tailscale patch check

A Tailscale security bulletin about a distrusted certificate authority prompted a check of
both front-door instances against the current stable release.

**Result:** nothing to install. The recent routine patching run had already brought both to
the required release; the running daemon version was confirmed separately from the CLI
version, since the two can differ until the service restarts, and neither OS trust store
still carried a certificate from the affected CA.

Tailscale's self-updater is now set to check and apply on both instances, so client
security releases install between the regular patch rounds.

## 2026-10-26: Subnet router moved to the new VPS

The last service still anchored to the old front door was the Tailscale subnet router. The
new VPS already had the client installed but signed out, and the home side had been
prepared during the cutover build: a return route for the whole new tunnel subnet and
firewall allowances for the dedicated rewrite address.

**On the new VPS:** the same three pieces as before, pointed at the new tunnel. A source
rewrite of tailnet traffic leaving through the tunnel to a dedicated tunnel address,
forwarding rules between the Tailscale interface and the tunnel, the client's own subnet
SNAT switched off, and the LAN plus the new tunnel subnet advertised as routes. All of it
persisted with the rest of the firewall.

**Sign-in without a shared password:** the client prints a one-time authorization link.
It was opened from a device already signed into the tailnet account, so
the node was authorised with two clicks and nothing was typed. The routes were then
approved on the machine's page in the admin console.

**Cutover:** the old VPS was told to stop advertising its routes. The tailnet made the new
VPS primary for both routes within seconds, with no change on the client devices.

**What went wrong:** the client's `up` command, run with only a hostname, silently
discarded the route preferences that had been stored while signed out, so the admin
console reported that the machine exposed no routes. Setting the routes again after
sign-in fixed it; the lesson is to pass every preference on the `up` line or re-apply
them afterwards.

**Verified:** from the new VPS, a request bound to its own tailnet address reached a home service and the rewrite counter climbed. That test is valid here because the
client's own SNAT is off, so the firewall rule applies to local traffic the same way it
applies to forwarded traffic.

## 2026-10-27: two To headers, and a hold filter for notification mail

**The bounce.** A day after the alias service went live, the mailbox started receiving
"could not be delivered" notices for a handful of forwards, several of them from a social
network's notification sender. The relay log showed the relay refusing them as not
RFC 5322 compliant: two `To` headers. The outbound header rewrite prepends a `To` with the
alias service's reply address and replaces the original `To` that names the alias. The
replace rule only matched a bare address. Senders who write a display name in `To` slipped
past it, so their original `To` survived next to the new one. The rule now matches any
`To` line that contains an address at the domain. It was checked with Postfix's own table
lookup against bare, display-name and multi-address forms before the reload, and the lost
mails were re-injected from a local copy and delivered.

A smaller trap on the way: editing the regex table through a remote shell inside a
double-quoted heredoc produced a file that looked right but never matched. Copying the file
over with scp fixed it. Test a table with the lookup tool, not by eye.

**The hold filter.** The address collects a lot of automated mail: one-time codes that have
already served their purpose by the time they reach the mailbox, and "we received your message" acknowledgements. Each one
counted against the external relay's daily allowance and buried real mail. The fix is a
Postfix pipe content filter on the mailbox copy only, selected by a `FILTER` action on the
mailbox recipient, placed first in the recipient restrictions (a `permit` earlier in the
list would end evaluation before the filter was chosen). Only the mailbox copy is filtered; the copy kept by the alias
service's own store is routed by the transport map and is untouched.

The filter is deliberately conservative. It holds nothing unless the mail is an
alias-service forward from a no-reply or notification sender, contains no wording a person
would act on, and is a one-time code or an acknowledgement. Any error passes the mail
through, and a failed re-injection returns the temporary-failure code so Postfix retries.
It was run offline against three days of stored mail first, then with test forwards through
the SMTP port, and it starts in a dry-run mode that logs and keeps copies but still
delivers, with a daily digest of what it would have held.

One more thing the live test caught: a forward whose `To` carries no alias at all (the
alias was only in Cc or Bcc) would still get a second `To` from the prepend rule. The filter
now sets such a `To` to the reply address itself before re-injecting, keeping the original
in a side header.

## 2026-10-28: forwards show the real sender again

**Problem.** Every forwarded mail showed up in the owner's mailbox as "me". The mailbox
provider's SMTP relay, the only outbound path from the VPS, replaces From with the account
owner and there is no mailbox setting that undoes it.

**Approach.** Stop relaying the mailbox copy and import it with the provider's API instead.
The hold filter already sits in front of that one recipient, so it grew an `import` step:
on success the message is in the mailbox with its headers intact; on any failure it is
re-injected and goes through the relay as before, and the failure is logged so the
monitoring timer can raise an alert. A small helper does the one-time OAuth authorization
(consent URL in, redirect URL back) and stores the refresh token in a file only
the filter's user can read. The API import also lifts the relay's daily allowance off ordinary
forwards; the relay now carries only replies and the fallback.

**What broke.** Three things, each found by sending a test through the real path and
reading the raw message in the mailbox. (1) The provider's OAuth redirect lands on the loopback of the
machine running the browser, which was not the server, so the code had to be pasted by
hand; the first code expired before it was pasted. (2) The imported mail showed the bare
alias address instead of the sender's name: the earlier From rewrite had put the real
address inside the display name, and the mailbox hides any display name that contains an
address. (3) The same rewrite had been breaking the alias service's DKIM signature all
along; the relay used to re-sign everything, so nobody noticed until the import exposed
`dkim=fail`.

**Fix.** Dropped the From rewrite on the VPS (empty header table kept so the main config
is unchanged) and switched the alias service to its built-in "name only" sender format.
A third test showed the sender's name, landed in the inbox and passed DKIM. A bare test
message with no sending chain went to spam, which confirmed the provider's spam check
still runs on imported mail. Open point: a sender with no display name now shows as the
bare alias address; acceptable so far, revisit if it is common.

Later the same morning the first real forward through the import landed in the spam
folder: an imported message carries no sending IP, so the mailbox's classifier had nothing
to trust and filed it on similarity alone. The hand-made tests had passed because they
looked nothing like bulk mail. The import call has a flag that tells the mailbox to skip
its spam decision for that message; it is now set, on the grounds that the alias service
forwards only mail addressed to the owner's own aliases and a wrongly delivered message
is cheaper than a lost one. Lesson: test the delivery path with a real third-party message,
not a hand-written one.

