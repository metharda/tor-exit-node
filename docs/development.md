# Development

## Repository layout

```text
.
├── Makefile                  entry point (make help)
├── terraform/                libvirt VM: storage pool, NAT network, cloud-init, disk
│   └── disk-driver.xsl       sets the disk driver to qcow2 (see architecture.md)
├── ansible/
│   ├── playbook.yml          role order, maintenance mode, final check
│   ├── inventory.ini.tpl     rendered by Terraform
│   └── roles/
│       ├── system-hardening/ SSH, UFW, fail2ban, sysctl
│       ├── docker/           Docker Engine and Compose v2
│       ├── tor-container/    Tor image, compose file, watchdog
│       ├── networking/       transparent-proxy firewall, tor-exit-check
│       ├── tailscale/        exit-node login
│       └── monitoring/       optional node_exporter
├── scripts/                  deploy, destroy, check-dependencies (+ shared helpers)
└── docs/
    ├── *.md                  these docs
    └── demo/                 VHS tapes and the GIFs they render
```

## Workflow

1. Change a role or script.
2. `make lint`. It must pass: shellcheck, `terraform validate`, `terraform fmt -check` and ansible-lint at the `production` profile.
3. `make configure` against a deployed VM.
4. `make verify`. `tor-exit-check` is the end-to-end acceptance test.
5. Run `make configure` once more; it should report `changed=0`.

Conventions:

- Roles are idempotent; a re-run doesn't restart Tor or touch the firewall.
- Ansible modules use fully qualified names (`ansible.builtin.copy`, …).
- Firewall changes go in `transparent-proxy.sh`'s own `TOR_*` chains, never in tables owned by Docker, UFW or tailscaled.
- Anything that can leak must fail closed; add a check to `tor-exit-check` for new guarantees.

For changes to the data path, also try the failure cases by hand on a test VM:

- `sudo docker stop tor-proxy`: client traffic and DNS must fail, not go direct.
- `sudo systemctl stop transparent-proxy`: client traffic must be dropped.
- `sudo docker pause tor-proxy`: the watchdog should restart it within about four minutes.
- Reboot: `make verify` must pass again.

## Demo recordings

The GIFs in [`demo/`](demo) are rendered with [VHS](https://github.com/charmbracelet/vhs) from real sessions. Run the tapes from the repository root:

| Tape | Where to record it | Notes |
| --- | --- | --- |
| `client.tape` | A tailnet device with the `tailscale` CLI, `curl` and `jq` | Switches the device to the exit node and back. Prints only `IsTor` before switching, so the device's real IP stays out of the recording. |
| `deploy.tape` | The KVM host, with no VM deployed in that checkout | Export `VM_PASSWORD` and `TS_AUTHKEY` first so no secret is typed on camera. Plays back 10× faster. |
| `verify.tape` | The KVM host, with a deployed VM | |
| `fail-closed.tape` | The KVM host, with a deployed VM | Briefly stops the Tor container on the VM. |

```bash
vhs docs/demo/verify.tape
```

The raw deploy recording is large because the text scrolls constantly, so it is re-encoded at 8 fps with a tuned palette:

```bash
ffmpeg -i deploy.gif -vf "fps=8,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" deploy-small.gif
```
