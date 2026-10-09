#!/usr/bin/with-contenv bash

echo "[qbit-auto-config] Starting qBittorrent auto-configuration..."

QBIT_CONF="/config/qBittorrent/qBittorrent.conf"
PORT_FILE="/pia-shared/port.dat"

# Wait for config directory to exist
mkdir -p /config/qBittorrent

# Wait for port file to be available and fresh (max 90 seconds).
# With PORT_PERSIST=1, PIA writes port.dat once when the port is first
# forwarded and doesn't rewrite it on rebind. So after a PIA container
# restart, the file is stale but the port is still valid. The netns-watcher
# sidecar touches the file when it restarts qBittorrent, so a stale file
# here means PIA is still initializing OR we missed the touch. We wait
# briefly for a fresh file, then fall back to the existing (stale) port.
WAIT_TIME=0
MAX_WAIT=90
FILE_AGE=999
FOUND_FRESH=0

echo "[qbit-auto-config] Waiting for PIA to establish port forwarding..."

while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    if [ -f "$PORT_FILE" ]; then
        FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$PORT_FILE" 2>/dev/null || echo 0) ))

        if [ $FILE_AGE -lt 60 ]; then
            echo "[qbit-auto-config] Found fresh port file (${FILE_AGE}s old)"
            FOUND_FRESH=1
            break
        else
            echo "[qbit-auto-config] Port file exists but is stale (${FILE_AGE}s old), waiting for update... ($WAIT_TIME/$MAX_WAIT)"
        fi
    else
        echo "[qbit-auto-config] Waiting for port file... ($WAIT_TIME/$MAX_WAIT)"
    fi

    sleep 3
    WAIT_TIME=$((WAIT_TIME + 3))
done

if [ $FOUND_FRESH -ne 1 ] && [ -f "$PORT_FILE" ]; then
    echo "[qbit-auto-config] No fresh port file after ${MAX_WAIT}s, using existing port (PORT_PERSIST=1, port may still be valid)"
fi

# Read the forwarded port
if [ -f "$PORT_FILE" ]; then
    FORWARDED_PORT=$(cat "$PORT_FILE")

    # Validate port number
    if [ -z "$FORWARDED_PORT" ] || ! [[ "$FORWARDED_PORT" =~ ^[0-9]+$ ]]; then
        echo "[qbit-auto-config] WARNING: Invalid or empty port in file, using default 6881"
        FORWARDED_PORT=6881
    else
        echo "[qbit-auto-config] Found PIA forwarded port: $FORWARDED_PORT (file age: ${FILE_AGE}s)"
    fi

    # Wait for qBittorrent config to be created
    WAIT_TIME=0
    while [ ! -f "$QBIT_CONF" ] && [ $WAIT_TIME -lt 30 ]; do
        echo "[qbit-auto-config] Waiting for qBittorrent config file... ($WAIT_TIME/30)"
        sleep 2
        WAIT_TIME=$((WAIT_TIME + 2))
    done

    if [ -f "$QBIT_CONF" ]; then
        echo "[qbit-auto-config] Updating qBittorrent configuration..."

        # Update Session\Port (the key qBittorrent v5+ actually uses)
        if grep -q "^Session\\\\Port=" "$QBIT_CONF"; then
            sed -i "s/^Session\\\\Port=.*/Session\\\\Port=$FORWARDED_PORT/" "$QBIT_CONF"
        else
            sed -i '/^\[BitTorrent\]/a Session\\Port='"$FORWARDED_PORT" "$QBIT_CONF"
        fi

        # Also update legacy Connection\PortRangeMin key
        if grep -q "^Connection\\\\PortRangeMin=" "$QBIT_CONF"; then
            sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$FORWARDED_PORT/" "$QBIT_CONF"
        fi

        # Ensure VPN interface is set
        if ! grep -q "^Connection\\\\Interface=wg0" "$QBIT_CONF"; then
            echo "[qbit-auto-config] Setting network interface to wg0..."
            sed -i '/^\[Preferences\]/a Connection\\Interface=wg0\nConnection\\InterfaceName=wg0\nConnection\\InterfaceAddress=' "$QBIT_CONF"
        fi

        # Ensure UPnP is disabled
        sed -i "s/^Connection\\\\UPnP=.*/Connection\\\\UPnP=false/" "$QBIT_CONF"

        # Force WebUI to bind IPv4 wildcard. qBittorrent 5+ (Qt 6) maps
        # WebUI\Address=* to QHostAddress::Any, which creates an IPv6
        # dual-stack listener [::]:port. The PIA wireguard image sets
        # disable_ipv6=1 on eth0 as a leak-prevention measure, and the kernel
        # then refuses to deliver IPv4 SYNs arriving on eth0 to the v6
        # listener. Docker's port-publish DNATs to the container's IPv4 on
        # eth0, so the WebUI becomes unreachable. Binding 0.0.0.0 explicitly
        # sidesteps the dual-stack mapping.
        if grep -q "^WebUI\\\\Address=" "$QBIT_CONF"; then
            sed -i 's|^WebUI\\Address=.*|WebUI\\Address=0.0.0.0|' "$QBIT_CONF"
        else
            sed -i '/^\[Preferences\]/a WebUI\\Address=0.0.0.0' "$QBIT_CONF"
        fi

        # Configure WebUI port if provided
        if [ -n "$WEBUI_PORT" ]; then
            echo "[qbit-auto-config] Configuring WebUI port to $WEBUI_PORT..."
            if grep -q "^WebUI\\\\Port=" "$QBIT_CONF"; then
                sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$WEBUI_PORT/" "$QBIT_CONF"
            else
                sed -i '/^\[Preferences\]/a WebUI\\Port='"$WEBUI_PORT" "$QBIT_CONF"
            fi
        fi

        # Configure default save path if provided (Session\DefaultSavePath is the key qBittorrent
        # v5 actually uses). Uses | as the sed delimiter since the value is a path.
        if [ -n "${QBT_SAVE_PATH:-}" ]; then
            echo "[qbit-auto-config] Configuring default save path to $QBT_SAVE_PATH..."
            if grep -q "^Session\\\\DefaultSavePath=" "$QBIT_CONF"; then
                sed -i "s|^Session\\\\DefaultSavePath=.*|Session\\\\DefaultSavePath=$QBT_SAVE_PATH|" "$QBIT_CONF"
            else
                sed -i '/^\[BitTorrent\]/a Session\\DefaultSavePath='"$QBT_SAVE_PATH" "$QBIT_CONF"
            fi
        fi

        # Enable an alternative WebUI (e.g. VueTorrent, staged at /vuetorrent by the Ansible
        # role) if a root folder is provided. | delimiter since the value is a path.
        if [ -n "${QBT_ALT_WEBUI_ROOT:-}" ]; then
            echo "[qbit-auto-config] Enabling alternative WebUI at $QBT_ALT_WEBUI_ROOT..."
            if grep -q "^WebUI\\\\AlternativeUIEnabled=" "$QBIT_CONF"; then
                sed -i "s|^WebUI\\\\AlternativeUIEnabled=.*|WebUI\\\\AlternativeUIEnabled=true|" "$QBIT_CONF"
            else
                sed -i '/^\[Preferences\]/a WebUI\\AlternativeUIEnabled=true' "$QBIT_CONF"
            fi
            if grep -q "^WebUI\\\\RootFolder=" "$QBIT_CONF"; then
                sed -i "s|^WebUI\\\\RootFolder=.*|WebUI\\\\RootFolder=$QBT_ALT_WEBUI_ROOT|" "$QBIT_CONF"
            else
                sed -i '/^\[Preferences\]/a WebUI\\RootFolder='"$QBT_ALT_WEBUI_ROOT" "$QBIT_CONF"
            fi
        fi

        # Set the WebUI instance name ([Application]\InstanceName). VueTorrent uses it as the
        # browser tab title (the stock WebUI prepends it too). Handle key-exists / section-exists /
        # neither (append the section). | delimiter so values with slashes are safe.
        if [ -n "${QBT_INSTANCE_NAME:-}" ]; then
            echo "[qbit-auto-config] Setting WebUI instance name to $QBT_INSTANCE_NAME..."
            if grep -q "^InstanceName=" "$QBIT_CONF"; then
                sed -i "s|^InstanceName=.*|InstanceName=$QBT_INSTANCE_NAME|" "$QBIT_CONF"
            elif grep -q "^\[Application\]" "$QBIT_CONF"; then
                sed -i '/^\[Application\]/a InstanceName='"$QBT_INSTANCE_NAME" "$QBIT_CONF"
            else
                printf '\n[Application]\nInstanceName=%s\n' "$QBT_INSTANCE_NAME" >> "$QBIT_CONF"
            fi
        fi

        # Append .!qB to incomplete files (Session\UseIncompleteFileExtension) when QBT_INCOMPLETE_EXT
        # is set. In-progress downloads get a .!qB suffix so finished files are distinguishable by name
        # (handy for scripts that post-process finished downloads). Re-applied every start, so it survives recreation.
        if [ -n "${QBT_INCOMPLETE_EXT:-}" ]; then
            echo "[qbit-auto-config] Enabling incomplete-file extension (.!qB)..."
            if grep -q "^Session\\\\UseIncompleteFileExtension=" "$QBIT_CONF"; then
                sed -i "s/^Session\\\\UseIncompleteFileExtension=.*/Session\\\\UseIncompleteFileExtension=true/" "$QBIT_CONF"
            else
                sed -i '/^\[BitTorrent\]/a Session\\UseIncompleteFileExtension=true' "$QBIT_CONF"
            fi
        fi

        # Set the WebUI password (PBKDF2 hash). Ensures all instances share the
        # same password. The hash is passed via QBT_WEBUI_PASSWORD_PBKDF2 env var
        # (pre-computed from the shared plaintext password in group_vars). Without
        # this, new/recreated instances fall back to the LSIO temporary password.
        if [ -n "${QBT_WEBUI_PASSWORD_PBKDF2:-}" ]; then
            echo "[qbit-auto-config] Setting WebUI password..."
            PBKDF2_LINE='WebUI\\Password_PBKDF2="@ByteArray('${QBT_WEBUI_PASSWORD_PBKDF2}')"'
            if grep -q '^WebUI\\Password_PBKDF2=' "$QBIT_CONF"; then
                sed -i "s|^WebUI\\\\Password_PBKDF2=.*|${PBKDF2_LINE}|" "$QBIT_CONF"
            else
                sed -i "/^\[Preferences\]/a ${PBKDF2_LINE}" "$QBIT_CONF"
            fi
        fi

        echo "[qbit-auto-config] Configuration updated successfully!"
        echo "[qbit-auto-config] - BitTorrent Port: $FORWARDED_PORT"
        echo "[qbit-auto-config] - Incomplete ext (.!qB): ${QBT_INCOMPLETE_EXT:+enabled}"
        echo "[qbit-auto-config] - WebUI Address: 0.0.0.0"
        echo "[qbit-auto-config] - WebUI Port: ${WEBUI_PORT:-8080}"
        echo "[qbit-auto-config] - Save Path: ${QBT_SAVE_PATH:-<default>}"
        echo "[qbit-auto-config] - Alt WebUI: ${QBT_ALT_WEBUI_ROOT:-<stock>}"
        echo "[qbit-auto-config] - Instance Name: ${QBT_INSTANCE_NAME:-<none>}"
        echo "[qbit-auto-config] - Interface: wg0"
        echo "[qbit-auto-config] - UPnP: disabled"
        if [ -n "${QBT_WEBUI_PASSWORD_PBKDF2:-}" ]; then
            echo "[qbit-auto-config] - Password: set"
        else
            echo "[qbit-auto-config] - Password: <not set>"
        fi
    else
        echo "[qbit-auto-config] Warning: qBittorrent config file not found, will use defaults"
    fi
else
    echo "[qbit-auto-config] Warning: PIA port file not found, using default port 6881"
fi

echo "[qbit-auto-config] Auto-configuration complete!"
