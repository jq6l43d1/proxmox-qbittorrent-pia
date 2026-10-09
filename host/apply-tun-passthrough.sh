#!/usr/bin/env bash
# Pass /dev/net/tun through to the qBittorrent LXCs. The PIA WireGuard container
# needs a tunnel device, and unprivileged LXCs don't get one by default.
#
# This edits /etc/pve/lxc/<vmid>.conf, which needs real root@pam (an API token
# can't do it), so it runs over root SSH instead of through Terraform.
# Idempotent: containers that already have the entry are skipped.
#
# Usage:
#   PVE=root@192.168.1.10 VMIDS="151 152 153 154" host/apply-tun-passthrough.sh
set -euo pipefail
PVE="${PVE:?set PVE, e.g. root@192.168.1.10}"
VMIDS="${VMIDS:?set VMIDS, e.g. \"151 152 153\"}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"

ssh -i "$KEY" "$PVE" VMIDS="$VMIDS" bash -s <<'REMOTE'
set -euo pipefail
for vmid in $VMIDS; do
  conf="/etc/pve/lxc/${vmid}.conf"
  # Match the actual directive, not a mention of /dev/net/tun in the CT description.
  if grep -q '^lxc.mount.entry: /dev/net/tun' "$conf"; then
    echo "ct$vmid: tun already configured"
  else
    cat >> "$conf" <<CONF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
CONF
    pct reboot "$vmid"
    echo "ct$vmid: tun passthrough added + rebooted"
  fi
done
REMOTE
