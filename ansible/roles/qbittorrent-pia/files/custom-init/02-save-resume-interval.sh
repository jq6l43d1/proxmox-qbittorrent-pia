#!/usr/bin/with-contenv bash
# Persist session/fastresume data every 5 minutes instead of qBittorrent's
# 60-minute default. When the container dies uncleanly (netns-watcher recreate
# after a PIA reconnect, autoheal, OOM), any torrent added since the last
# resume-data save silently vanishes from the session on next boot. The data
# stays on disk but the client stops seeding it, which earns hit-and-run
# warnings on private trackers. A 5-minute interval shrinks that loss window ~12x; the write only
# covers torrents whose state changed, so it's cheap even with thousands of
# torrents loaded.

QBIT_CONF="/config/qBittorrent/qBittorrent.conf"
INTERVAL=5

if [ ! -f "$QBIT_CONF" ]; then
    # First boot: conf doesn't exist yet; qBittorrent creates it with defaults.
    # The next container start (this script runs on every boot) will set it.
    echo "[save-resume-interval] qBittorrent.conf not found yet, skipping (will apply next boot)"
    exit 0
fi

if grep -q "^Session\\\\SaveResumeDataInterval=" "$QBIT_CONF"; then
    sed -i "s/^Session\\\\SaveResumeDataInterval=.*/Session\\\\SaveResumeDataInterval=$INTERVAL/" "$QBIT_CONF"
else
    sed -i '/^\[BitTorrent\]/a Session\\SaveResumeDataInterval='"$INTERVAL" "$QBIT_CONF"
fi
echo "[save-resume-interval] Session\\SaveResumeDataInterval=$INTERVAL"
