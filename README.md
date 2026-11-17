# Tailscale Tor Exit Node

This project automates the setup of a privacy-focused Tailscale Tor exit node using KVM virtualization. All VM traffic is routed through a transparent Tor proxy.

> **Connection Status**: Tor container is currently being worked on, even though it starts up in final build it cannot connect to the tor circuit.


## Architecture
### Host Structure:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host Server (KVM)                        │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Ubuntu 22.04 VM                        │  │
│  │                                                           │  │
│  │  ┌─────────────────────────┐  ┌─────────────────────────┐ │  │
│  │  │      Tailscale          │  │     Tor Container       │ │  │
│  │  │      Exit Node          │◄─┤   (Alpine + Tor)        │ │  │
│  │  │                         │  │                         │ │  │
│  │  │  • Exit routing         │  │  • TransPort: 9040      │ │  │
│  │  │  • Client mgmt          │  │  • DNSPort: 9053        │ │  │
│  │  │                         │  │  • SOCKS5: 9050         │ │  │
│  │  └─────────────────────────┘  └─────────────────────────┘ │  │
│  │            │                            ▲                 │  │
│  │            │          iptables          │                 │  │
│  │            └─────► Transparent Proxy ───┘                 │  │
│  │                    (NAT REDIRECT)                         │  │
│  │                                                           │  │
│  │  Traffic Flow: Client → Tailscale → iptables → Tor → Web  │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                 │                               │
│                        KVM NAT Network                          │
│               (192.168.100.0/24, configurable)                  │
│                                 │                               │
│                        Physical Network                         │
└─────────────────────────────────────────────────────────────────┘
```

### System Design:
![Tor Proxy Sistem Tasarımı](tor-proxy-systemdesign.png)

### How traffic is handled
- The Tor container (Alpine + Tor, client only) runs with Docker host networking, so the
  VM's own NAT table can `REDIRECT` traffic into Tor and Tor sees the original destination.
  No Docker network is created, and Docker runs without a bridge, its own iptables rules or
  IP forwarding.
- iptables owns the firewall; UFW stays disabled. The rules live in their own chains
  (`TORPROXY_PRE`, `TORPROXY_OUT`, `TORPROXY_IN`, `TORPROXY_EGR`, `TORPROXY_FWD`), are loaded
  atomically by `transparent-proxy.service` after Docker and tailscaled, and never flush the
  built-in chains.
- Client TCP from `tailscale0` goes to TransPort 9040 and client DNS (UDP 53, to any
  resolver) goes to DNSPort 9053. Other client UDP, ICMP and IPv6 are dropped. IP forwarding
  stays off, so nothing from clients is forwarded to the uplink.
- The VM's own traffic goes through Tor as well. Only Tor itself, loopback, DHCP, replies to
  inbound connections (such as SSH) and tailscaled's own control/DERP/WireGuard traffic are
  exempt.
- SocksPort 9050 listens on 127.0.0.1 only; 9040 and 9053 are only accepted from
  `tailscale0` and loopback. ControlPort is off.

## Features

### Privacy and Security
- **Transparent Tor Routing**: All VM traffic automatically routed through the Tor network
- **DNS Leak Protection**: DNS queries forced through Tor DNSPort (9053)
- **IPv6 Blocking**: Completely disabled to prevent IPv6 leaks
- **VM Isolation**: Complete isolation with KVM virtualization
- **System Hardening**: SSH, iptables firewall (UFW disabled), fail2ban, and automatic updates

### Container Security
- **Isolated Tor Container**: Docker-isolated, hardened Alpine Linux
- **Non-root User**: Container runs with non-root user
- **Read-only Filesystem**: Read-only filesystem for runtime security
- **Dropped Capabilities**: Minimal privilege principle compliance

### Monitoring and Maintenance
- **Prometheus Integration**: System metrics with node_exporter (the `monitoring` role is disabled in `ansible/playbook.yml` by default)
- **Custom Tor Metrics**: Connection status (with the `monitoring` role)
- **Automatic Log Rotation**: Disk space management
- **Watchdog Service**: `tor-monitor.service` checks Tor through SOCKS and restarts the container after repeated failures

## Requirements

### Host System
- Linux (Ubuntu 22.04+ recommended)
- KVM/QEMU virtualization support
- Libvirt installed and running
- Minimum 4GB RAM, 2 CPU cores
- 50GB disk space
- User with sudo privileges
- Internet connection

### Development Tools
- Terraform ≥ 1.0
- Ansible ≥ 2.9
- Python 3.8+
- Git
- Tailscale account

### KVM/Libvirt Installation

```bash
# For Ubuntu/Debian:
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst

# Add your user to libvirt group:
sudo usermod -a -G libvirt $USER

# Start and enable libvirt:
sudo systemctl enable --now libvirtd

# Verify installation:
sudo virsh list --all
```

## Quick Start

1. **Clone the repository**:
```bash
git clone https://github.com/metharda/tor-exit-node.git
cd tor-exit-node
```

2. **Check and install dependencies**:
```bash
make check-deps
```

3. **Install dependencies**:
```bash
make install-deps
```

4. **Get Tailscale auth key**:
   
   **Step 1**: Go to https://login.tailscale.com/admin/settings/keys
   
   **Step 2**: Click "Generate auth key" button
   
   **Step 3**: Configure settings:
   - **Reusable**: Check this (for reuse if deployment fails)
   - **Ephemeral**: Don't check (to keep device in tailnet)
   - **Tags**: Optional (e.g: `tag:exit-node`)
   - **Expiry**: Optional (default 90 days)
   
   **Step 4**: Click "Generate key" button
   
   **Step 5**: Copy the key (Format: `tskey-auth-k...`)
   
   ```
   Example format:
   tskey-auth-kABCDEF123-GJKLMNOP456QRSTUVWXYZ789abcdefghijklmnop
   ```
   
   **Important Notes**:
   - Store the auth key securely
   - Key is valid for 90 days (unless custom set)
   - Don't share the key with others
   - Copy-paste during deployment, don't type manually

5. **Start deployment**:
```bash
make deploy
```

6. **Enter VM configuration**:
   - VM name (e.g: my-tor-exit)
   - Username (default: ubuntu)
   - VM password (minimum 8 characters)
   - RAM size (MB, default: 2048)
   - CPU count (default: 2)
   - Disk size (GB, default: 20)
   - Libvirt storage pool (an existing pool; see `sudo virsh pool-list --all`)
   - VM network subnet (default: 192.168.100.0/24; the deploy refuses a subnet another libvirt network or route already uses)
   - Paste your Tailscale auth key (it is not echoed and is not written to the cloud-init disk, the inventory or the Terraform state)

7. **Wait for deployment completion** (~15-20 minutes):
   - Ubuntu 22.04 cloud image will be downloaded
   - VM will be created and started
   - Docker, Tailscale, Tor will be installed
   - Transparent proxy will be configured

8. **Approve exit node in Tailscale admin panel**:
   - Go to https://login.tailscale.com/admin/machines
   - Find your new machine and check "Enable as exit node" option

## Usage

### Exit Node Usage
```bash
# Configure Tailscale connection on a client device:
tailscale up --exit-node=<tailscale-ip>

# Test Tor routing:
curl https://check.torproject.org
curl https://ipinfo.io/ip

# Disable exit node:
tailscale up --exit-node=
```

### VM Management
```bash
# Check VM status:
sudo virsh list --all

# Display VM information:
sudo virsh dominfo <vm-name>

# SSH to VM:
ssh -i terraform/vm_key ubuntu@<vm-ip>

# Connect to VM console:
sudo virsh console <vm-name>

# Stop VM:
sudo virsh shutdown <vm-name>

# Start VM:
sudo virsh start <vm-name>

# Force shutdown VM:
sudo virsh destroy <vm-name>

# Delete VM:
sudo virsh undefine <vm-name> --remove-all-storage
```

### Monitoring and Verification
```bash
# Check transparent proxy status:
ssh -i terraform/vm_key ubuntu@<vm-ip> 'sudo systemctl status transparent-proxy'

# Check Tor container:
ssh -i terraform/vm_key ubuntu@<vm-ip> 'sudo docker logs tor-proxy'

# Check iptables rules:
ssh -i terraform/vm_key ubuntu@<vm-ip> 'sudo iptables-save'

# Check Tailscale status:
ssh -i terraform/vm_key ubuntu@<vm-ip> 'sudo tailscale status'

# Check IP address (should be Tor exit IP):
ssh -i terraform/vm_key ubuntu@<vm-ip> 'curl -s https://check.torproject.org/api/ip'

# Run leak test:
make test

# Verify deployment:
make verify
```

## Management

### Status Checking
```bash
# Tailscale status:
sudo tailscale status

# Tor container status:
sudo docker logs tor-proxy

# Iptables rules:
sudo iptables -t nat -L -n -v
```

### Removal
```bash
make destroy
```
`make destroy` deletes only what this deployment created: the resources in the Terraform
state (VM, disk, cloud-init ISO, base image volume, `<vm-name>-network`) and the generated
`terraform/vm_key`, `vm_key.pub`, `ansible/inventory.ini` and state. Without a state it only
looks for those exact names. It logs the VM out of Tailscale first, or tells you to remove the
device in the admin panel. Anything but `yes` at the prompt cancels.

## File Structure

```
.
├── ansible/                    # Ansible configuration files
│   ├── playbook.yml           # Main playbook
│   ├── inventory.ini.tpl      # Inventory template
│   └── roles/                 # Ansible roles
├── scripts/                   # Helper scripts
│   ├── deploy.sh             # Main deployment script
│   ├── destroy.sh            # Cleanup script
│   ├── check-dependencies.sh # Dependency check
│   └── maintenance/          # Maintenance scripts
├── terraform/                # Terraform configuration
└── Makefile                  # Build automation
```

## Security Notes

- Exit node is only accessible from your Tailscale network
- Client TCP and DNS go through Tor; other client UDP (for example QUIC) and ICMP are dropped
- IPv6 is disabled and dropped by ip6tables
- System hardening is automatically applied
- This reduces leaks; it does not make you anonymous against traffic correlation, and only the
  cases in `scripts/leak-test.sh` are checked

## Troubleshooting

### Log Files
```bash
# Tor container logs:
sudo docker logs tor-proxy

# System logs:
sudo journalctl -u tailscaled
sudo journalctl -u tor-monitor
sudo journalctl -u transparent-proxy

# Iptables status:
sudo iptables-save
```

### Common Problems

1. **Tor connection problem**: Restart the container
2. **DNS leak**: Check that `/etc/resolv.conf` is correct
3. **Tailscale auth error**: Get a new auth key

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b feature/new-feature`)
3. Commit your changes (`git commit -am 'Add new feature'`)
4. Push to the branch (`git push origin feature/new-feature`)
5. Create a Pull Request

## License

This project is published under the MIT license.

## Architecture

- **Host**: Ubuntu 22.04 LTS VM with Tailscale service
- **Container**: Hardened Tor client container (non-root, read-only, all capabilities dropped) with host networking
- **Networking**: Transparent proxy routing all Tailscale client traffic and the VM's own traffic through Tor
- **Security**: IPv4, IPv6 and DNS leak protection as described above, system hardening, container isolation

## Quick Start (short version)

> This project deploys to a local KVM/libvirt host only. An older cloud-provider
> (AWS/GCP/Azure) quick start used to be here; it no longer applies.

1. **Prerequisites**: A KVM/libvirt host as described in [Requirements](#requirements)

2. **Deploy**:
   ```bash
   make deploy
   ```
   Or directly:
   ```bash
   ./scripts/deploy.sh
   ```

3. **Verify**:
   ```bash
   make verify
   ```

4. **Test for leaks**:
   ```bash
   make test
   ```

5. **Destroy (when done)**:
   ```bash
   make destroy
   ```
   This destroys only this deployment's resources after a `yes` confirmation.


### Tailscale Setup
1. Get your Tailscale auth key from: https://login.tailscale.com/admin/settings/keys
2. Set it during deployment when prompted

## Usage

### Manual Commands
```bash
# Install dependencies
make install-deps

# Format and check code
make format
make check

# Deploy infrastructure (with pre-checks)
make deploy

# Test for leaks
make test

# Verify functionality
make verify

# Check status
make status

# View logs
make logs

# Destroy infrastructure safely
make destroy

# Clean temporary files
make clean
```

### Testing for Leaks

1. **Connect a client** to your Tailscale network
2. **Route through exit node**: `tailscale up --exit-node=EXIT_NODE_NAME`
3. **Test Tor routing**:
   ```bash
   curl https://check.torproject.org
   # Should return: "Congratulations. This browser is configured to use Tor."
   ```
4. **Test IP leak**:
   ```bash
   curl https://ipinfo.io
   # Should show Tor exit node IP, not your real IP
   ```
5. **Test DNS leak**:
   ```bash
   dig @9.9.9.9 example.com
   # Answered through Tor or not at all: UDP 53 is redirected to Tor DNSPort
   nslookup example.com
   # Should resolve through Tor DNS
   ```
6. **Test IPv6 leak**:
   ```bash
   curl -6 https://ipv6.google.com
   # Should fail (IPv6 disabled)
   ```

## Security Considerations

### Attack Vectors Mitigated

1. **IP Leaks**: All traffic forced through Tor container via iptables REDIRECT
2. **DNS Leaks**: DNS queries (UDP 53 to any resolver) redirected to Tor DNSPort
3. **IPv6 Leaks**: IPv6 disabled on the VM and dropped by ip6tables
4. **Container Escape**: Non-root user, dropped capabilities, read-only filesystem, Docker's default seccomp profile
5. **SSH Attacks**: Key-only authentication, custom port, rate limiting
6. **System Compromise**: iptables firewall, automatic security updates, minimal packages

### Tailscale ACLs

Restrict exit node access in your Tailscale admin panel:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:trusted-users"],
      "dst": ["tag:exit-node:*"]
    }
  ],
  "nodeAttrs": [
    {
      "target": ["tag:exit-node"],
      "attr": ["funnel"]
    }
  ]
}
```

### SELinux vs AppArmor

**Default**: Ubuntu AppArmor profiles are applied automatically.

**SELinux Option**: To enable SELinux instead:
```bash
sudo apt install selinux-utils selinux-basics
sudo selinux-activate
sudo reboot
```

**Trade-offs**:
- AppArmor: Simpler, Ubuntu-native, application-specific profiles
- SELinux: More granular, mandatory access control, better for high-security environments

## Monitoring

- **Node Exporter**: Prometheus metrics on port 9100 (with the `monitoring` role)
- **Watchdog**: `tor-monitor.service` restarts the Tor container after repeated failed checks through Tor
- **Health Checks**: the container is healthy only once a request through Tor succeeds

## Maintenance

- **Log Rotation**: Automated via systemd timer
- **Updates**: Automatic security updates enabled
- **Firewall**: iptables rules re-applied at boot and whenever tailscaled restarts (`transparent-proxy.service`)

## File Structure

```
terraform/              # VM provisioning
ansible/                # Configuration management
  roles/
    system-hardening/        # SSH, fail2ban, users (UFW disabled)
    tailscale/              # Tailscale setup
    tor-container/          # Docker + Tor container
    networking/             # Transparent proxy rules
    monitoring/             # Node exporter
scripts/                # Utility and deployment scripts
  deploy.sh                 # Main deployment script
  destroy.sh                # Safe infrastructure destruction
  check-dependencies.sh     # Dependency verification
  format-check.sh           # Code formatting
  verify-deployment.sh      # Deployment verification
  leak-test.sh              # Comprehensive leak testing
  maintenance/              # Maintenance scripts
```

## Troubleshooting

### Common Issues

1. **Tailscale not advertising as exit node**:
   ```bash
   sudo /usr/local/sbin/tailscale-setup.sh
   ```

2. **Traffic not routing through Tor**:
   ```bash
   sudo iptables -t nat -S TORPROXY_PRE
   sudo iptables -t nat -S TORPROXY_OUT
   # Check the REDIRECT rules are present
   ```

3. **Container not starting**:
   ```bash
   sudo docker logs tor-proxy
   # Check Tor configuration
   ```

4. **DNS leaks**:
   ```bash
   sudo iptables -t nat -S TORPROXY_OUT | grep 'dport 53'
   # Verify DNS traffic is redirected to 9053
   ```

5. **Infrastructure already exists error**:
   ```bash
   make destroy  # Remove existing infrastructure
   make clean    # Clean local files
   make deploy   # Deploy fresh
   ```

6. **Destroy fails to complete**:
   ```bash
   # Check for remaining resources of this deployment (exact names):
   sudo virsh dominfo <vm-name>
   sudo virsh net-info <vm-name>-network
   sudo virsh vol-list <storage-pool>
   make destroy  # retry; the state is kept until destroy succeeds
   ```
