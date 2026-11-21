# Kubernetes: a two-node k3s cluster next to a live Docker host

The roadmap's "two-node k3s" item became real on 2026-11-11. The goal: run the worker pods of a browser
automation app on **both** the server and the gaming-pc, with every stateful piece (database, queue, web
UI, files, secrets) staying on the always-on server, and the gaming-pc acting only as extra capacity
that pods can be moved onto and back off again. It had to be built **without stopping the running
Docker Compose deployment** of the same app.

## Shape

| Piece | Where | Notes |
|---|---|---|
| k3s server (control plane) | server, native k3s | bundled Traefik and service load balancer disabled (remote-display sidecars use hostPorts), Secrets encryption at rest on, flannel vxlan over the LAN |
| Database, queue, UI | **still Docker Compose on the server** for now | pods reach them through a small haproxy container that publishes the two ports on the LAN behind a **source allow-list**; the database and queue containers themselves were not touched |
| Worker pods | one Helm release per node, one StatefulSet per worker | pod = app container + display sidecar sharing an X socket; per-worker local volume for browser profiles; shared folders by hostPath on the server and NFS from the other node |
| Gaming-pc node | WSL2 Ubuntu as a k3s **agent** (owner's choice over a Hyper-V VM) | mirrored networking so the distro shares the host's LAN address; systemd on; joined to the server through a **dedicated WireGuard tunnel** (userspace on the WSL side, which initiates), because mirrored mode delivers inbound traffic only to real Linux sockets, never to the overlay's kernel socket or to iptables hostPorts |
| Remote display for that node's workers | a small gateway pod on the server | one port per worker, forwarded over the overlay; the node itself can't publish hostPorts |
| Images | a private registry on the server, TLS with the homelab's own CA, basic auth | both nodes trust the CA through k3s's `registries.yaml`; pods pull with an image-pull Secret |
| Secrets | the TPM-bound credstore stays the single source of truth | `hl-k3s-secrets` renders Kubernetes Secrets from it straight into `kubectl apply` on stdin, nothing on disk; the other node holds no credstore and no copies |

## Why native k3s on a box that already runs Docker, UFW and a VPN

An earlier k3s lab here used k3d (k3s inside Docker) precisely to keep k3s's iptables and modules away
from the host. A second machine cannot join a k3d cluster, so the real cluster needed a native server.
The host-side effects were measured with a health snapshot taken before and after (every container's
state, DNS resolution from inside three containers, the HTTP endpoints of the main services, the
WireGuard handshake, the VPN's egress, the firewall rule sets hashed) and the diff was clean. What k3s
does change on the host, and what we live with: the bridge-netfilter sysctls go to 1 (Docker's own
default on most systems), and the kubelet sets `kernel.panic`, `panic_on_oops` and
`vm.overcommit_memory` to Kubernetes' defaults. kube-proxy was told to leave the conntrack table size
alone, since Docker, UFW and the VPN share it.

## The trap: a desktop VPN client hijacks pod DNS

The VPN client's split-tunnel feature marks **every forwarded packet** in the mangle table and then, in
the nat table, redirects any marked DNS query to the home router. That is meant for other devices routed
through the box. Pods are forwarded traffic too, and the VPN's jump sits ahead of kube-proxy's in the
nat PREROUTING chain, so a pod's query to CoreDNS would land on the router and fail to resolve any
cluster name. (The k3d lab had shown the same symptom and worked around it per node.)

The fix leaves the VPN's rules alone. A tiny nftables table (`scripts/vpn-unmark.nft`) hooks
**prerouting at priority -120**, between mangle (-150) and nat (-100), and clears the mark on packets
from the pod CIDR. Because hook priority, not rule position, decides the order, it keeps working however
often the VPN client rewrites its chains. A oneshot unit loads it, is required by the k3s unit and
ordered before it, and gets the usual sandbox drop-in from the Ansible role. Proven from a test pod:
cluster names, public names, the notification server on the host and the LLM on the gaming-pc all
reachable. Never unload bridge modules to "clean up" (that once took every Docker bridge down).

### Keeping the real client address for containers

A packet mark set by other software on the host can contain the bit the CNI port-mapping plugin uses to
say "masquerade this packet". The plugin's rule matches on that bit alone, so it would masquerade more
than hostPort traffic. A second chain in the same table, in the **postrouting hook at priority 90** (just
ahead of nat), clears only that bit, and only for packets not headed to the pod CIDR. Routing has already
been decided at that point, so nothing that routes on the mark is affected, and Docker containers on the
same host keep seeing the original client address. Rule changes are applied atomically, without
restarting any unit. Checked with a health snapshot before and after (identical).

## The platform layer: management UI, entry point, GitOps, shared database, storage

Added once the first workloads were stable, as the base for moving the remaining Compose services over.

| Piece | Choice | Why |
|---|---|---|
| Management UI | Rancher, installed with Helm, single replica on the server | the UI used in a lot of real environments; worth learning on a cluster that matters |
| Terminal UI | k9s (release binary, checksum verified) | fast day-to-day view of pods, logs and events |
| Entry point | Traefik on the server's host network, one entry point per service port | the host firewall keeps deciding who reaches each port; a service keeps its address wherever its pod runs |
| TLS | cert-manager with a private CA (self-signed root, CA issuer) | certificates for in-house names and addresses, renewed automatically |
| GitOps | a private repository of manifests, deployed by Rancher Fleet, drift correction on | the cluster is changed by changing a file; a hand edit is put back |
| Updates | pinned image versions; Renovate, self-hosted as a scheduled job in the cluster, opens pull requests | every update is a reviewed commit and a revert away from the old version; no third-party service is given access to the manifests repository |
| Shared database | one PostgreSQL StatefulSet on the server's local disk, reachable only from labelled namespaces (NetworkPolicy), nightly dump into the existing backup | apps that support PostgreSQL keep their state there, so the app pod itself holds nothing that must stay on one node |
| Shared files | two NFS exports from the server to the second node, carried inside the node tunnel | config folders and the data drive look the same from either node |
| Boot order | k3s waits for the data drive's mount unit | pods never start against an empty mountpoint |

**Movable apps.** The server stays the control plane and the home of all data. An app whose database is in
PostgreSQL and whose files are on NFS can run on either node: it can be moved by hand, rebalanced by a
descheduler when one node is under load, and it restarts on the server if the second node goes away. Apps
that only support an embedded file database stay pinned to the server, because that kind of database does
not belong on a network filesystem.

**Why Traefik sits on the host network.** A proxy on the host network is an ordinary listening socket, so
the host firewall rules that protect everything else apply to it unchanged. The cost is that the proxy is
pinned to one node, which is fine here: so is the data.

**How a movable app is put together.** One replica with a recreate strategy, so two copies never run at
once. Its volumes are host paths that exist under the same names on both nodes: real disks on the server,
the NFS exports mounted at the same paths on the second node, so one manifest fits either node and the
server keeps native disk speed. An init container checks for a marker file in each volume and refuses to
start the app on an empty mountpoint. Short tolerations for an unreachable node bring the app back on the
server about a minute after the second node disappears, and a small DaemonSet keeps every movable app's
image on both nodes so a move never waits for a download. Moving one by hand is a cordon, a rollout restart,
and an uncordon; the service address does not change.

**Rebalancing.** The descheduler runs every few minutes on real usage from metrics-server. When one node is
above its CPU or memory target and the other is well below, it evicts a single labelled pod from the busy
node; priority classes decide which apps go first, and a minimum pod age stops anything from bouncing
back and forth. Pods without the label are never touched.

### Traps

- **A memory limit without a request reserves the whole limit.** On a node whose memory is already
  reserved on paper, such a pod never schedules, however idle the node really is. Give small pods an
  explicit small request.
- **Copying a file into a new directory with a file mode sets that mode on the directory too.** Create
  the directory first, or a non-root process cannot enter it.

- **An HTTP route changes what an app sees of its clients.** A proxy adds forwarding headers, and apps
  that make decisions from the client address behave differently behind it. Test the app's own access
  rules through the new route before switching.
- **Hand-written EndpointSlices need explicit endpoint conditions.** Otherwise the API server adds an
  empty value, the GitOps controller sees drift, and the bundle is redeployed forever. Check that every
  bundle settles after a change.
- **A pod's source address depends on the node it runs on.** Test address-based rules from every node
  the app may run on.
- **Rehearse a data conversion on an isolated copy.** Give the copy no outbound network and read-only
  data, so a rehearsal can never change anything real.

- **A NetworkPolicy lags a brand-new pod.** The policy controller adds a new pod's address to the allow-set
  a moment after the pod starts. A short job that connects to the database in its first second is refused.
  The backup job now waits for the database to answer before dumping; any short-lived client must retry.
- **Chart defaults that collide on a host network.** A proxy on the host network binds its internal ports
  on the host too. The health and metrics entry points were moved or switched off where they clashed with
  ports already in use.
- **Rendering a chart offline can fail a version check the real install passes.** The Helm client assumes
  its own Kubernetes version when templating; pass the cluster's version explicitly.
- **The management UI's first minutes look worse than they are.** Its GitOps component is installed by
  helper pods; the first attempts can fail on a hook that races the custom resource definitions, and the
  retry succeeds on its own.
- **Mount propagation and WSL2.** A volume that asks for host-to-container mount propagation will not
  start on the WSL2 node, because its mounts are private. The marker-file check does the job instead.
- **Converting an embedded database.** The loader needs a writable copy of a database file that is in
  write-ahead-log mode; a read-only mount of the original fails to open.
- **Leave nothing half-migrated on the Compose side.** A helper that restarts stopped containers after
  backups will happily restart the old copy; remove the old container and park its compose file.
- **Drift correction is real.** An object changed by hand during debugging was put back within half a
  minute. Debug with that in mind.

## Deploying

A deploy script runs the test suite as a gate, builds and pushes the images tagged with the git commit,
pauses the release's workers through the app's own pause mechanism and waits for each to reach a safe
point, runs `helm upgrade --install` so **every worker of that release recreates at once** (the owner's
rule), waits for fresh heartbeats, resumes what it paused and restores any per-worker holds exactly as
they were. Helm's rollback gives the previous images back in one command.

## Traps found on day one

- A fresh worker is **not idle**: it picks up queued work within a minute. Pause first, or assign work, before the first install.
- Pods on the server node reach a Docker-published port masqueraded as the Compose network's gateway, so the proxy's allow-list had to account for that masquerade, or the TCP handshake succeeded and the next packet was dropped.
- Docker Compose does not recreate a service when only an inline `configs:` content changes; force it.
- Never give a pod a hostPort that Docker already publishes on the same host; the two DNAT chains fight. The k3s sidecars got their own port range.
- Helm's `index` on a nil map fails; guard optional maps with a default. And `default` treats `false` as empty, so a boolean switch must be tested directly.
- WSL 2 mirrored mode: only userspace listening sockets receive inbound traffic; interface names change across restarts; the host's own address is the distro from inside. A tunnel the distro initiates sidesteps all three for the cluster.
- NFSv4: nested exports on one filesystem inherit the parent's options; export separate bind mountpoints.
- Changing a node's IP after registration: delete the node object and re-register, or the kubelet cert no longer matches.
