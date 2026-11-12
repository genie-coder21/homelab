# History

## 2026-11-11: the cluster goes live next to Compose

The owner asked for the k3s migration to start while the app kept running, with the server as the main
machine and the gaming-pc as a place worker pods can be moved to. The gaming-pc side was prepared separately: a WSL2 Ubuntu with systemd and mirrored networking, host
firewall rules limited to the server's address, a keep-alive task, SSH into the distro, and host facts.

On the server, in order: a health snapshot; the k3s server config written to the repo and installed
(binary checksum verified by the installer); the VPN DNS trap analysed from the live rule set and the
nftables unmark table written before k3s was started; k3s started; snapshot diffed (clean); DNS and
reachability proven from a pod. Then the registry with its own CA and basic auth, the credstore-to-Secrets
bridge, the haproxy LAN proxy for the database and queue with a source allow-list, the Helm chart (one
release per node, one StatefulSet per worker), and the deploy script.

What broke: the first pod could open a TCP connection to the proxy but died at the TLS handshake,
because its source address was the Compose network gateway, which the proxy was not expecting. The
deploy script timed out waiting for the heartbeat and correctly put every hold back as it had found it.
After the allow-list fix the proxy did not pick up the new config until forced to recreate. The first
template render also failed on an optional map being null. All three fixed the same evening.

The first pod ran, heartbeated into the shared queue beside the Compose workers, and picked up queued work
at once, which was not the plan for a smoke test; it was paused through the app's pause mechanism until
the owner decides what it should run. AIDE was re-baselined after the system changes.

Open: the gaming-pc node itself, its NFS exports, seeding browser profiles into the new per-worker volumes, and later moving the database, queue
and UI into the cluster, still on the server's disk.

## 2026-11-11, later: the gaming-pc side begins

Installed WSL 2 on the gaming-pc so it can join the server's Kubernetes cluster as a second worker node;
it finishes after the next reboot. The WSL configuration caps the distro's memory and CPU, uses mirrored
networking so the distro shares the host's LAN address, and a logon task keeps the distro alive so the
agent does not stop when no terminal is open. Host firewall rules for the cluster ports accept only the
server. With the host's memory shared by two game VMs and a local LLM, the worker memory limit on that
node is set lower than on the server, and workers are added in steps with free memory checked each time.

## 2026-11-11, night: the second node joins, and WSL's networking teaches a lesson

The gaming-pc's WSL 2 distro joined the cluster as an agent within minutes. Then the pod overlay turned out to
be one-way: the distro's encapsulated packets reached the server and were answered, but the answers never
arrived. WSL's mirrored networking hands inbound traffic only to real Linux listening sockets; the overlay's
kernel socket, the kernel NFS client and Kubernetes' iptables-only hostPorts are all invisible to it. The
distro also renames its network interfaces across restarts, so nothing may reference an interface name.

The fix that covers all of it at once: a dedicated WireGuard tunnel between the server and the distro, with
the distro end running the userspace implementation and initiating with a keepalive. Windows then sees a
single outbound flow from an ordinary socket, and the overlay, the kubelet port and NFS ride inside it. The
agent uses the tunnel interface and address, which never change. Changing a node's address after it has
registered needs a delete and re-register, or the kubelet certificate and the node record disagree and log
and exec calls fail with a certificate error.

NFS had a second trap: nested exports on one filesystem inherit the parent's read-only flag, so a read-write
child under a read-only parent came out read-only. Each export is now its own bind mountpoint, read-only
where it should be, enforced by the kernel rather than by the export flag.

The remote-display links for that node's workers are served by a small gateway pod on the server, which
publishes one port per worker and forwards over the overlay. The first worker pod on the gaming-pc came up
paused, heartbeating into the shared queue, with the server's folders mounted over the tunnel. A shutdown
and restart of the distro brought the tunnel and the agent back on their own in under half a minute.
Reaching the gaming-pc's local LLM from inside its own node did not work under mirrored networking and was
dropped by the owner; those workers use the cloud models like everything else.

## 2026-11-12: ports locked to the second node

Restricted the Kubernetes control, overlay and storage ports on the server so only the second node can
reach them; everything else on the LAN is unchanged. The registry and the database proxy got the same
treatment at the Docker layer. The lock-down script was reviewed and run by the gaming-pc's assistant with
the owner's explicit yes, and it found two bugs in the script on the way: a presence check that read a
root-only file without privileges (so a re-run would have duplicated the block) and a rule match that
ignored the firewall tool's column padding. Both fixed; the script is safely re-runnable.
