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
