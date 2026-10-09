#!/usr/bin/with-contenv bash
# Wipe stale single-instance state left behind by a previous container.
#
# qBittorrent uses /config/qBittorrent/lockfile + ipc-socket to enforce
# single-instance. On graceful shutdown it does NOT clean these up, and
# on an ungraceful kill (SIGKILL, OOM, host reboot) it can't. The lockfile records the previous container's
# hostname; on the next `compose up` the new container has a different
# hostname (docker assigns the container ID as hostname), so qbt reads
# the lockfile, sees a "foreign machine" lock, and refuses to start. It
# logs only "qBittorrent termination initiated" / "is now ready to exit"
# then exits cleanly, which fools s6 into restarting it every second
# for the full 5-minute notifyoncheck window before the stack finally
# converges. Removing both files here makes startup deterministic.
#
# Safe: only one qbt runs per container, no concurrent writer to race
# against. The /config mount preserves all real state (torrents,
# settings, BT_backup); these two files are session-scoped IPC artifacts.

CONFIG_DIR=/config/qBittorrent

if [ -e "$CONFIG_DIR/lockfile" ] || [ -e "$CONFIG_DIR/ipc-socket" ]; then
    echo "[clean-stale-locks] removing stale lockfile/ipc-socket from prior container"
    rm -f "$CONFIG_DIR/lockfile" "$CONFIG_DIR/ipc-socket"
fi
