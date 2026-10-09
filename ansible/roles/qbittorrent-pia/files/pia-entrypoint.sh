#!/bin/bash
# Region-rotation entrypoint for thrnz/docker-wireguard-pia.
#
# Why: PIA's port-forward API can die while the tunnel itself still works
# (I hit this when a whole PIA cluster connected fine but refused :19999, so
# PF failed on every server in two regions at once). The image's own LOC fallback
# list is only consulted when *registration* fails, so it reconnects to the
# same broken region forever. PORT_FATAL=1 can't save us either: upstream
# launches `pf.sh | sed &` and captures sed's PID, so a pf.sh death is seen
# as exit 0 and the container never exits. Recovery comes from autoheal
# restarting the unhealthy container.
#
# This wrapper turns that restart loop into region failover. LOC_POOL is a
# comma-separated region list (preferred first). Each container start consumes
# the next index from /pia-shared/loc-index; if the run stays healthy for
# STICKY_SECS (pf.sh alive), the index is written back so the working region
# sticks across routine restarts (nightly auto-update, reboots).
IDX_FILE=/pia-shared/loc-index
STICKY_SECS=600

IFS=', ' read -ra POOL <<< "$LOC_POOL"
if [ "${#POOL[@]}" -eq 0 ]; then
    echo "[loc-rotate] LOC_POOL is empty; falling back to LOC=$LOC"
    exec /scripts/run
fi

idx=$(cat "$IDX_FILE" 2>/dev/null)
[[ "$idx" =~ ^[0-9]+$ ]] || idx=0
idx=$(( idx % ${#POOL[@]} ))
export LOC="${POOL[$idx]}"
echo "[loc-rotate] region ${LOC} (index ${idx} of pool: ${LOC_POOL})"

# Pre-advance so a crash-restart tries the next region; the sticky check below
# undoes this once the current region proves itself.
echo $(( (idx + 1) % ${#POOL[@]} )) > "$IDX_FILE"
(
    sleep "$STICKY_SECS"
    if pidof pf.sh > /dev/null; then
        echo "$idx" > "$IDX_FILE"
        echo "[loc-rotate] region ${LOC} healthy for ${STICKY_SECS}s, sticking"
    fi
) &

exec /scripts/run
