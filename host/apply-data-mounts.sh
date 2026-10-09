#!/usr/bin/env bash
# Bind-mount the shared storage into each qBittorrent LXC at /data, and create
# the per-instance config dir on it.
#
# The compose stack mounts /data/appdata/qbittorrent-<instance> as /config and
# /data as /data, so torrents keep the same save paths no matter which LXC
# runs them, and a rebuilt LXC picks its torrents straight back up.
#
# qBittorrent runs as uid/gid 1000 inside Docker, inside an UNPRIVILEGED LXC
# whose default idmap shifts uids by 100000, so the host-side owner has to be
# 101000:101000.
#
# Bind mounts need real root@pam (forbidden for API tokens), so this runs over
# root SSH. `pct set` overwrites the same mp0 slot, so it's safe to rerun.
# Every run reboots the listed CTs, so when adding one instance pass just its id.
#
# Usage:
#   PVE=root@192.168.1.10 STORAGE=/tank \
#   INSTANCES="151:movies 152:tv 153:books 154:games" host/apply-data-mounts.sh
set -euo pipefail
PVE="${PVE:?set PVE, e.g. root@192.168.1.10}"
STORAGE="${STORAGE:?set STORAGE, the shared storage path on the Proxmox host}"
INSTANCES="${INSTANCES:?set INSTANCES as vmid:instance pairs, e.g. \"151:movies 152:tv\"}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"

ssh -i "$KEY" "$PVE" STORAGE="$STORAGE" INSTANCES="$INSTANCES" bash -s <<'REMOTE'
set -euo pipefail
for pair in $INSTANCES; do
  vmid="${pair%%:*}"; name="${pair#*:}"
  mkdir -p "$STORAGE/appdata/qbittorrent-$name"
  chown 101000:101000 "$STORAGE/appdata" "$STORAGE/appdata/qbittorrent-$name"
  pct set "$vmid" -mp0 "$STORAGE,mp=/data"
  pct reboot "$vmid" || { pct stop "$vmid"; pct start "$vmid"; }
  echo "ct$vmid ($name): $STORAGE -> /data applied"
done
REMOTE
