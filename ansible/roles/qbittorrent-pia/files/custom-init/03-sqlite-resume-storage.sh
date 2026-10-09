#!/usr/bin/with-contenv bash
# Switch resume-data storage from per-torrent fastresume files (BT_backup/) to
# qBittorrent's SQLite backend (torrents.db). The legacy backend loses torrents:
# with ~1700 torrents and /config on a network share, the shutdown
# resume-data sweep doesn't finish before s6/docker kill grace expires, and the
# periodic save (02-save-resume-interval.sh) demonstrably never writes files
# for newly-added torrents at all, so every restart (nightly auto-update,
# netns-watcher recreate) silently drops anything added since the last
# *completed* full save. I lost about a dozen private-tracker torrents this
# way before tracking it down. SQLite commits per-event and
# stores torrents at add time, closing the window. qBittorrent migrates the
# existing BT_backup files into torrents.db automatically on first start with
# this setting.

QBIT_CONF="/config/qBittorrent/qBittorrent.conf"

if [ ! -f "$QBIT_CONF" ]; then
    echo "[sqlite-resume] qBittorrent.conf not found yet, skipping (will apply next boot)"
    exit 0
fi

if grep -q "^Session\\\\ResumeDataStorageType=" "$QBIT_CONF"; then
    sed -i "s/^Session\\\\ResumeDataStorageType=.*/Session\\\\ResumeDataStorageType=SQLite/" "$QBIT_CONF"
else
    sed -i '/^\[BitTorrent\]/a Session\\ResumeDataStorageType=SQLite' "$QBIT_CONF"
fi
echo "[sqlite-resume] Session\\ResumeDataStorageType=SQLite"
