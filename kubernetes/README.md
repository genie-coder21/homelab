# Kubernetes: a two-node k3s cluster next to a live Docker host

The roadmap's "two-node k3s" item became real on 2026-11-11. The goal: run the worker pods of a browser
automation app on **both** the server and the gaming-pc, with every stateful piece (database, queue, web
UI, files, secrets) staying on the always-on server, and the gaming-pc acting only as extra capacity
that pods can be moved onto and back off again. It had to be built **without stopping the running
Docker Compose deployment** of the same app.

## Shape

| Piece | Where | Notes |
|---|---|---|
| k3s server (control plane) | server, native k3s | Traefik and the service load balancer disabled (nothing is ingressed; remote-display sidecars use hostPorts), Secrets encryption at rest on, flannel vxlan over the LAN |
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
