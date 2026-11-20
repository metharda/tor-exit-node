# Operations

Running the exit node after `make deploy`: checking it, changing it, keeping it healthy and fixing it. Every command runs from the repository root on the machine that deployed the VM.

## Commands

| Command | What it does |
| --- | --- |
| `make deploy` | Create and configure the VM. Prompts, or reads [environment variables](#deployment-settings). |
| `make configure` | Re-apply the Ansible configuration. Idempotent: an unchanged node reports no changes and Tor isn't restarted. No auth key needed once the node has joined. |
| `make verify` | Run `tor-exit-check` on the VM. |
| `make status` | Terraform outputs, Tor container status, firewall status, `tailscale status`. |
| `make logs` | The last 40 Tor log lines, plus watchdog and transparent-proxy journal entries. |
| `make ssh` | Shell on the VM as the admin user. |
| `make destroy` | Delete the VM, its disk, storage pool and network. |
| `make lint` | Static checks; see [development.md](development.md). |
| `make clean` | Remove local Terraform caches. Refuses while a VM is deployed. |

## Verifying

`make verify` runs `/usr/local/sbin/tor-exit-check` on the VM. Ansible also runs it at the end of every play. It exits non-zero if a required check fails; warnings don't fail it.

| Check | Passes when |
| --- | --- |
| tor-proxy container is bootstrapped | The container health check reports *healthy*, i.e. Tor bootstrapped to 100 %. |
| check.torproject.org confirms Tor | A request through Tor's SOCKS port returns `"IsTor": true` (retried twice). |
| iptables redirects and leak guards are installed | `transparent-proxy status` finds every hook. |
| DNS sent to any server is answered by Tor | A query to `192.0.2.53`, a reserved address with no DNS server, returns an IPv4 answer. Only the redirect to Tor can produce one. |
| the system resolver works through Tor | `getent` resolves a name through the normal resolver path. |
| DNS over TCP cannot bypass Tor | A TCP DNS query to `1.1.1.1` fails. |
| IPv6 is disabled | `net.ipv6.conf.all.disable_ipv6 = 1`. |
| connected to the tailnet | tailscaled reports `Running`. |
| exit node is advertised | The node advertises `0.0.0.0/0`. |
| tailscaled leaves iptables to the transparent proxy | `NetfilterMode` is off. |
| tailscaled does not manage the system resolver | `CorpDNS` (accept-dns) is off. |
| exit node is approved in the tailnet | *Warning only:* the admin console hasn't approved the exit route yet. |

To check from a client device, select the exit node and run:

```bash
curl https://check.torproject.org/api/ip           # "IsTor": true
curl https://icanhazip.com                         # a Tor exit IP, never yours
tailscale dns query example.com                    # resolver: http://<exit-node-ip>:<port>/dns-query
ping -c1 1.1.1.1                                   # fails: Tor does not carry ICMP
```

## Approving and sharing the exit node

New exit nodes need approval: in the [admin console](https://login.tailscale.com/admin/machines), open the machine's **⋯** menu, choose *Edit route settings* and tick *Use as exit node*. To approve automatically, tag the auth key (for example `tag:exit-node`) and add to your tailnet policy:

```json
{
  "tagOwners":     { "tag:exit-node": ["autogroup:admin"] },
  "autoApprovers": { "exitNode": ["tag:exit-node"] }
}
```

Devices also need policy access to `autogroup:internet` to use an exit node; the default policy allows everyone.

## Self-healing and repairs

- **Container exits:** Docker restarts it (`restart: unless-stopped`).
- **Tor stalls but keeps running:** after three failed health checks (about 90 seconds) the container is *unhealthy*. `tor-watchdog.timer` runs every two minutes and restarts it. Logs: `journalctl -u tor-watchdog`.
- **Firewall rules removed:** the watchdog reinstalls them while `transparent-proxy.service` is active.
- **Container or image missing, or anything else broken:** run `make configure`. If Tor isn't healthy, the play enters **maintenance mode**: it takes the node off the tailnet (`tailscale down`), removes the redirects so the VM can resolve names, rebuilds Tor, then reinstalls the redirects and brings Tailscale back. Clients can't use the node while it is being repaired.

## Updates

- **Ubuntu packages:** security updates install automatically (unattended-upgrades). `make configure` also runs a full upgrade.
- **Tor:** the image is rebuilt whenever `Dockerfile`, `torrc` or `docker-compose.yml` change. To pick up a newer Tor package without changing files:

  ```bash
  make ssh
  cd /opt/tor-proxy && sudo docker compose build --pull && sudo docker compose up -d
  ```

- **Configuration changes:** edit the roles, then `make configure`.

## Monitoring (optional)

Monitoring is off by default. To turn it on:

```bash
cd ansible && ansible-playbook playbook.yml -e monitoring_enabled=true
```

This installs Prometheus `node_exporter` on port 9100, reachable only over the tailnet, plus three metrics refreshed every minute through the textfile collector:

| Metric | 1 when |
| --- | --- |
| `tor_bootstrapped` | The Tor container is healthy |
| `tailscale_running` | tailscaled reports `Running` |
| `transparent_proxy_rules_present` | `transparent-proxy status` succeeds |

## Deployment settings

`make deploy` prompts for these, or reads them from the environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `VM_NAME` | `tailscale-tor-exit` | VM, libvirt pool/network prefix and Tailscale hostname |
| `VM_USERNAME` | `ubuntu` | Admin user in the VM |
| `VM_PASSWORD` | *(required)* | Console password, at least 8 characters |
| `VM_MEMORY_MB` | `2048` | Memory |
| `VM_VCPUS` | `2` | vCPUs |
| `VM_DISK_GB` | `20` | Disk size |
| `TS_AUTHKEY` | *(first run only)* | Tailscale auth key |

Terraform settings, overridden with `TF_VAR_<name>`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `network_cidr` | `192.168.100.0/24` | The VM's private NAT network. Change it if the subnet is in use on the host. |
| `pool_path` | `/var/lib/libvirt/images` | Directory for the VM's storage pool |
| `libvirt_uri` | `qemu:///system` | libvirt connection |

## Destroying

```bash
make destroy                          # asks you to type the VM name
CONFIRM=tailscale-tor-exit make destroy   # no prompt
```

This removes the VM, its disk, storage pool and network, plus the local SSH key and inventory. It also works for a partly created deployment. Remove the machine from the [admin console](https://login.tailscale.com/admin/machines) afterwards (ephemeral nodes disappear on their own).

## Troubleshooting

| Symptom | Check / fix |
| --- | --- |
| *Cannot reach qemu:///system* or permission denied | Run as root, or add your user to the `libvirt` group and log in again. |
| Terraform: *network … overlaps*, or the VM gets no IP | `192.168.100.0/24` is in use on the host. Redeploy with `TF_VAR_network_cidr=192.168.150.0/24`. |
| Terraform: *xsltproc* or *mkisofs: executable file not found* | `sudo apt install xsltproc genisoimage` on the machine running Terraform. The libvirt provider calls both. |
| Ansible fails at *Wait until the container health check passes* | Tor couldn't bootstrap; the task prints Tor's log. Common causes: no outbound internet from the VM, a wrong clock, or a network that blocks Tor (bridges are not configured). Fix it, then `make configure`. |
| *This node has not joined the tailnet yet* | Export `TS_AUTHKEY` and run `make configure`. |
| A device can't pick the exit node | Approve it (see above) and check that your policy grants `autogroup:internet`. |
| Exit node works, but names don't resolve on a device | Turn on *Use Tailscale DNS* on that device (`tailscale set --accept-dns=true`), then check `tailscale dns query example.com`. |
| Exit node selected, but nothing loads | `make verify`. If Tor is unhealthy, `make logs`. The watchdog restarts it within minutes, or `make ssh` and `sudo docker restart tor-proxy`. |
| Pages load, but slowly | That's Tor. `sudo docker restart tor-proxy` builds fresh circuits. |
| Want to inspect the rules | `make ssh`, then `sudo iptables -t nat -L TOR_CLIENTS -nv` and `sudo iptables -L TOR_FORWARD -nv`. |
| Locked out of SSH | On the KVM host: `sudo virsh console <vm-name>`, and log in with the VM password. |
