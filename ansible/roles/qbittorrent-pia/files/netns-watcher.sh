#!/bin/bash
# netns-watcher: restart qBittorrent when its PIA network parent is recreated.
#
# qBittorrent uses network_mode: "container:pia-wireguard-<instance>" to share
# the PIA container's network namespace. When PIA is recreated (by autoheal,
# RECONNECT, or manual restart), it gets a NEW netns, but Docker does NOT
# restart dependent containers. qBittorrent stays "Up" in the OLD dead netns;
# its WebUI listener vanishes from the new netns and becomes unreachable.
#
# This script runs as a sidecar with Docker socket access. It records the PIA
# container's StartedAt on boot, then polls every 15s. If StartedAt changes
# (PIA was recreated), it removes and recreates the qBittorrent container via
# docker compose so it re-joins the fresh netns. A simple docker restart does
# NOT work: the old PIA container (and its netns) is already gone, so the
# restart fails with "joining network namespace of container: No such container".
#
# Environment:
#   PIA_CONTAINER  name of the pia-wireguard container (required)
#   QBT_CONTAINER  name of the qbittorrent container (required)
#   QBT_INSTANCE   instance name, used to locate the compose file (required)
#   QBT_SERVICE    compose service name for qBittorrent (default: "qbittorrent")
#   WATCH_INTERVAL poll interval in seconds (default: 15)
#   STOP_TIMEOUT   SIGTERM grace before SIGKILL on qBittorrent stop (default: 150)

set -euo pipefail

PIA_CONTAINER="${PIA_CONTAINER:?PIA_CONTAINER must be set}"
QBT_CONTAINER="${QBT_CONTAINER:?QBT_CONTAINER must be set}"
QBT_INSTANCE="${QBT_INSTANCE:?QBT_INSTANCE must be set}"
QBT_SERVICE="${QBT_SERVICE:-qbittorrent}"
WATCH_INTERVAL="${WATCH_INTERVAL:-15}"
RESTART_GRACE=45  # seconds to wait for qBittorrent to come up (s6 + custom-init + qbt boot)
# Seconds of SIGTERM grace before SIGKILL when stopping qBittorrent. Must
# exceed the container's S6_*_GRACETIME (120s) so s6 finishes the service
# shutdown (session/fastresume save) before docker gives up:
STOP_TIMEOUT="${STOP_TIMEOUT:-150}"
COMPOSE_FILE="/opt/qbittorrent-${QBT_INSTANCE}/compose.yaml"

echo "[netns-watch] Watching '$PIA_CONTAINER' for recreation events..."
echo "[netns-watch] Will restart '$QBT_CONTAINER' when netns parent is recreated."
echo "[netns-watch] Poll interval: ${WATCH_INTERVAL}s"

# Record the initial StartedAt of the PIA container.
get_started_at() {
    docker inspect "$1" --format '{{.State.StartedAt}}' 2>/dev/null || echo ""
}

LAST_STARTED_AT="$(get_started_at "$PIA_CONTAINER")"
echo "[netns-watch] Initial $PIA_CONTAINER StartedAt: $LAST_STARTED_AT"

while true; do
    sleep "$WATCH_INTERVAL"

    CURRENT_STARTED_AT="$(get_started_at "$PIA_CONTAINER")"

    # If PIA container doesn't exist yet (StartedAt is empty or zero), skip.
    # A zero value (0001-01-01T00:00:00Z) means the container is mid-recreation
    # (Docker hasn't assigned a real StartedAt yet). Acting on this false trigger
    # would rm qBittorrent and then fail to recreate it (PIA netns not ready).
    if [ -z "$CURRENT_STARTED_AT" ] || [ "$CURRENT_STARTED_AT" = "0001-01-01T00:00:00Z" ]; then
        continue
    fi

    if [ "$CURRENT_STARTED_AT" != "$LAST_STARTED_AT" ]; then
        echo "[netns-watch] CHANGE DETECTED: $PIA_CONTAINER was recreated"
        echo "[netns-watch]   Old StartedAt: $LAST_STARTED_AT"
        echo "[netns-watch]   New StartedAt: $CURRENT_STARTED_AT"
        echo "[netns-watch] Restarting $QBT_CONTAINER to re-join fresh netns..."

        # Touch the port file so qBittorrent's init script sees a "fresh" port
        # immediately and doesn't wait 90s for a stale file to refresh.
        # (PORT_PERSIST=1 means PIA only writes port.dat once per container
        # lifetime; after PIA restart the file is old but still valid.)
        docker exec "$PIA_CONTAINER" touch /pia-shared/port.dat 2>/dev/null || true

        # docker restart FAILS when the old PIA container (whose netns qBittorrent
        # was sharing) has already been removed ("joining network namespace of
        # container: No such container"). A simple restart re-joins the OLD (dead)
        # netns reference. We must remove and recreate the container so it picks
        # up the NEW PIA container's netns. Using docker rm -f + compose up -d
        # (rather than docker restart) handles both cases: fresh netns parent
        # and already-removed old parent.
        #
        # Stop gracefully FIRST: docker rm -f is a SIGKILL, and qBittorrent only
        # writes fastresume for recently-added torrents on clean shutdown (or on
        # its periodic save). A SIGKILL drops any torrent added since the last
        # save from the session. The data stays on disk but seeding stops,
        # which earns hit-and-run warnings on private trackers. SIGTERM lets
        # qbt persist the session; rm -f afterwards is then just cleanup.
        echo "[netns-watch] Stopping $QBT_CONTAINER gracefully (SIGTERM, ${STOP_TIMEOUT}s timeout)..."
        docker stop -t "$STOP_TIMEOUT" "$QBT_CONTAINER" 2>/dev/null || true
        echo "[netns-watch] Removing $QBT_CONTAINER (stale netns)..."
        docker rm -f "$QBT_CONTAINER" 2>/dev/null || true
        echo "[netns-watch] Recreating $QBT_CONTAINER via docker compose up -d..."
        # Use the compose SERVICE name (QBT_SERVICE, e.g. "qbittorrent"), not
        # the container name (QBT_CONTAINER, e.g. "qbittorrent-movies-01").
        # docker compose identifies services by their service name in the compose
        # file, not by container_name. Using the container name here causes
        # "no such service" errors, leaving qBittorrent removed and not recreated.
        if ! docker compose -f "$COMPOSE_FILE" up -d --no-deps "$QBT_SERVICE"; then
            echo "[netns-watch] ERROR: Failed to recreate $QBT_CONTAINER via compose."
            echo "[netns-watch] Retrying with full stack up -d (will recreate all services)..."
            docker compose -f "$COMPOSE_FILE" up -d || true
        fi
        echo "[netns-watch] $QBT_CONTAINER recreated. Waiting ${RESTART_GRACE}s for WebUI to come up..."

        sleep "$RESTART_GRACE"

        # Verify the WebUI is listening on port 8080 in the PIA netns.
        if docker exec "$PIA_CONTAINER" ss -tlnp 2>/dev/null | grep -q ':8080'; then
            echo "[netns-watch] WebUI is listening on 8080. Recovery successful."
        else
            echo "[netns-watch] WARNING: WebUI not yet listening on 8080 after restart."
            echo "[netns-watch] qBittorrent may still be initializing (custom-init scripts)."
            echo "[netns-watch] It should come up shortly, check logs if it doesn't."
        fi

        LAST_STARTED_AT="$CURRENT_STARTED_AT"
        echo "[netns-watch] Resuming watch (new baseline StartedAt: $LAST_STARTED_AT)"
    fi
done