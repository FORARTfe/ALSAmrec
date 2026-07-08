#!/bin/sh
#
# ALSAmrec installer v3.1
# CLI + CGI + LuCI â€” full stack, single installer.
#
# Original recorder daemon by J. Bruce Fields, 2024.
# LuCI/CGI port and OpenWrt fixes by FORART, 2025-26.
# GPL v3 â€” see <https://www.gnu.org/licenses/>
#

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

PACKAGES="rpcd luci-base alsa-utils usbutils kmod-usb-audio kmod-usb-storage block-mount kmod-fs-exfat"

warn()        { printf 'WARNING: %s\n' "$*" >&2; }
backup_file() { [ -e "$1" ] && [ ! -e "${1}.bak-autorecorder" ] && cp -p "$1" "${1}.bak-autorecorder" || true; }
install()     { cat > "$1"; chmod "$2" "$1"; }

echo "[*] Updating package lists..."
if command -v opkg >/dev/null 2>&1; then
    opkg update  || warn "opkg update failed; trying installation anyway."
    opkg install $PACKAGES || warn "Some packages could not be installed."
else
    warn "opkg not found; skipping package installation."
fi

echo "[*] Creating directories..."
mkdir -p \
    /usr/sbin \
    /etc/init.d \
    /etc/hotplug.d/block \
    /etc/hotplug.d/usb \
    /usr/libexec/rpcd \
    /usr/share/rpcd/acl.d \
    /usr/share/luci/menu.d \
    /www/luci-static/resources/view/autorecorder \
    /www/cgi-bin

echo "[*] Backing up existing files..."
for f in \
    /usr/sbin/recorder \
    /usr/sbin/autorecorderctl \
    /etc/init.d/autorecorder \
    /etc/hotplug.d/block/49-autorecorder \
    /etc/hotplug.d/usb/49-autorecorder \
    /usr/libexec/rpcd/autorecorder \
    /usr/share/rpcd/acl.d/autorecorder.json \
    /usr/share/luci/menu.d/autorecorder.json \
    /www/luci-static/resources/view/autorecorder/main.js \
    /www/cgi-bin/cm
do
    backup_file "$f"
done

echo "[*] Installing recorder daemon..."
install /usr/sbin/recorder 0755 <<'EOF_RECORDER'
#!/bin/sh
# ALSAmrec recorder daemon â€” GPL v3

PATH=/usr/sbin:/usr/bin:/sbin:/bin
MNT=/tmp/mnt
recorder=""
dummy=""

cleanup_recorder() {
    [ -z "${recorder:-}" ] && return
    kill "$recorder" 2>/dev/null || true
    wait "$recorder" 2>/dev/null || true
    recorder=""
}

cleanup_mount() {
    grep -qs " $MNT " /proc/mounts && umount -l "$MNT" 2>/dev/null || true
}

on_term() {
    cleanup_recorder
    kill "${dummy:-}" 2>/dev/null || true
    cleanup_mount
    exit 0
}

trap :        HUP       # wakes wait() on procd reload / hotplug
trap on_term  INT TERM

# BusyBox sleep does not reliably support "infinity" on all OpenWrt builds.
sleep 2147483647 &
dummy=$!

# Returns "card_num:dev_num" for the first ALSA capture device.
# awk-based to handle localised arecord -l output and spacing variations.
find_audio_device() {
    command -v arecord >/dev/null 2>&1 || return 1
    arecord -l 2>/dev/null | awk '
        /^[[:space:]]*card[[:space:]]+[0-9]+:/ {
            card=""; dev=""
            if (match($0, /card[[:space:]]+[0-9]+/)) {
                card = substr($0, RSTART, RLENGTH); sub(/.* /, "", card)
            }
            if (match($0, /device[[:space:]]+[0-9]+/)) {
                dev = substr($0, RSTART, RLENGTH); sub(/.* /, "", dev)
            }
            if (card != "" && dev != "") { print card ":" dev; exit }
        }'
}

# Returns device path only when exactly one exFAT partition exists.
find_single_exfat_partition() {
    count=0; found=""
    while read -r _maj _min _blocks name _rest; do
        case "$name" in sd*|mmcblk*|nvme*) ;; *) continue ;; esac
        dev="/dev/$name"; [ -b "$dev" ] || continue
        if dd if="$dev" bs=1 skip=3 count=5 2>/dev/null | grep -q 'EXFAT'; then
            count=$((count + 1)); found="$dev"
        fi
    done < /proc/partitions
    [ "$count" -eq 1 ] && printf '%s\n' "$found"
}

last_number_from_line() {
    printf '%s\n' "$arecord_out" | awk -v label="$1" '
        index($0, label ":") == 1 {
            gsub(/[^0-9]+/, " ", $0); n = split($0, a, /[ ]+/)
            for (i = n; i >= 1; i--) if (a[i] != "") { print a[i]; exit }
        }'
}

format_from_dump() {
    printf '%s\n' "$arecord_out" | awk '
        /^FORMAT:/ {
            sub(/^FORMAT:[ \t]*/, "", $0); gsub(/[\[\]]/, "", $0)
            n = split($0, a, /[ \t]+/)
            for (i = n; i >= 1; i--) if (a[i] != "") { print a[i]; exit }
        }'
}

valid_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

first=1
while :; do
    [ "$first" -eq 1 ] && first=0 || wait "${recorder:-$dummy}" 2>/dev/null || true

    audio_dev=$(find_audio_device || true)
    disk=$(find_single_exfat_partition || true)

    # Reap recorder PID if it exited on its own.
    if [ -n "${recorder:-}" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""; cleanup_mount
    fi

    # Not ready â€” sleep to avoid busy-spin.
    if [ -z "$audio_dev" ] || [ -z "$disk" ]; then
        cleanup_recorder; cleanup_mount; sleep 2; continue
    fi

    [ -n "${recorder:-}" ] && continue

    card_num=${audio_dev%%:*}; dev_num=${audio_dev##*:}
    valid_uint "$card_num" || continue
    valid_uint "$dev_num"  || continue

    mkdir -p "$MNT"
    grep -qs " $MNT " /proc/mounts || mount "$disk" "$MNT" || continue

    # Require at least 100 MB free.
    avail_kb=$(df -k "$MNT" 2>/dev/null | awk 'NR==2{print $4}')
    if ! valid_uint "${avail_kb:-}" || [ "$avail_kb" -le 102400 ]; then
        cleanup_mount; sleep 5; continue
    fi

    arecord_out=$(arecord -D "hw:${card_num},${dev_num}" --dump-hw-params 2>&1 || true)

    max_ch=$(last_number_from_line CHANNELS);  valid_uint "$max_ch"   || max_ch=1
    bitfmt=$(format_from_dump);                [ -n "$bitfmt" ]       || bitfmt=S16_LE
    max_rate=$(last_number_from_line RATE);    valid_uint "$max_rate" || max_rate=48000
    [ "$max_rate" -gt 48000 ] && max_rate=48000

    buf_time=$(last_number_from_line BUFFER_TIME)
    buf_size=$(last_number_from_line BUFFER_SIZE)

    outfile="${MNT}/$(date +%s)_${max_ch}-${max_rate}-${bitfmt}.raw"

    if valid_uint "$buf_time" && valid_uint "$buf_size"; then
        arecord --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" --file-type=raw --format="$bitfmt" \
            --rate="$max_rate" --buffer-time="$buf_time" --buffer-size="$buf_size" \
            > "$outfile" 2>/dev/null &
    else
        arecord --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" --file-type=raw --format="$bitfmt" \
            --rate="$max_rate" \
            > "$outfile" 2>/dev/null &
    fi
    recorder=$!
done
EOF_RECORDER

echo "[*] Installing control CLI..."
install /usr/sbin/autorecorderctl 0755 <<'EOF_CTL'
#!/bin/sh
# ALSAmrec control helper: START, STOP, STATUS, PROBE.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder

find_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$RECORDER" 2>/dev/null || true; return
    fi
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)
        case "$cmd" in *"$RECORDER"*) printf '%s\n' "${proc#/proc/}";; esac
    done
}

pid_list() { find_pids | awk 'NF{printf "%s%s",sep,$1;sep=" "}END{print ""}'; }
is_running() { [ -n "$(pid_list)" ]; }

# Returns "card_num:dev_num" for the first ALSA capture device.
first_audio_device() {
    command -v arecord >/dev/null 2>&1 || return 1
    arecord -l 2>/dev/null | awk '
        /^[[:space:]]*card[[:space:]]+[0-9]+:/ {
            card=""; dev=""
            if (match($0, /card[[:space:]]+[0-9]+/)) {
                card = substr($0, RSTART, RLENGTH); sub(/.* /, "", card)
            }
            if (match($0, /device[[:space:]]+[0-9]+/)) {
                dev = substr($0, RSTART, RLENGTH); sub(/.* /, "", dev)
            }
            if (card != "" && dev != "") { print card ":" dev; exit }
        }'
}

probe_device() {
    command -v arecord >/dev/null 2>&1 || { echo "arecord not installed"; return 1; }
    audio_dev=$(first_audio_device || true)
    if [ -z "$audio_dev" ]; then
        echo "No ALSA capture device found"
        echo "--- arecord -l output ---"
        arecord -l 2>&1 || true
        return 1
    fi
    arecord -D "hw:${audio_dev%%:*},${audio_dev##*:}" --dump-hw-params 2>&1
}

cmd=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
case "$cmd" in
    START)
        is_running && { echo "Already running"; exit 0; }
        "$INIT" start >/dev/null 2>&1 || true; sleep 2
        is_running && echo "Started successfully" || { echo "Failed to start"; exit 1; }
        ;;
    STOP)
        is_running || { echo "Already stopped"; exit 0; }
        "$INIT" stop >/dev/null 2>&1 || true; sleep 2
        is_running && { echo "Failed to stop"; exit 1; } || echo "Stopped successfully"
        ;;
    STATUS)
        pids=$(pid_list)
        [ -n "$pids" ] && echo "RUNNING (PID: $pids)" || echo "STOPPED"
        ;;
    PROBE)
        is_running && { echo "WARNING: recorder is running, stop first to probe!"; exit 1; }
        probe_device
        ;;
    *)
        echo "Usage: $0 START|STOP|STATUS|PROBE"; exit 1
        ;;
esac
EOF_CTL

echo "[*] Installing init script..."
install /etc/init.d/autorecorder 0755 <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=99
STOP=1
USE_PROCD=1
PROG=/usr/sbin/recorder

start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param reload_signal SIGHUP
    procd_close_instance
}

reload_service() { procd_send_signal autorecorder; }
EOF_INIT

echo "[*] Installing hotplug handlers..."
install /etc/hotplug.d/block/49-autorecorder 0755 <<'EOF_HOTPLUG_BLOCK'
#!/bin/sh
logger -t autorecorder "block hotplug: ${ACTION:-unknown} ${DEVNAME:-unknown}"
service autorecorder reload
EOF_HOTPLUG_BLOCK

install /etc/hotplug.d/usb/49-autorecorder 0755 <<'EOF_HOTPLUG_USB'
#!/bin/sh
logger -t autorecorder "usb hotplug: ${ACTION:-unknown} ${PRODUCT:-unknown}"
service autorecorder reload
EOF_HOTPLUG_USB

echo "[*] Installing CGI endpoint..."
install /www/cgi-bin/cm 0755 <<'EOF_CGI'
#!/bin/sh
# ALSAmrec CGI endpoint: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl

echo "Content-type: text/plain"
echo ""

[ "${REQUEST_METHOD:-}" = "GET" ] || { echo "Error: Method not allowed"; exit 1; }
[ -n "${QUERY_STRING:-}" ]        || { echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE"; exit 0; }

# Robust key=value parser â€” handles multiple params in any order.
get_param() {
    qs=${QUERY_STRING:-}
    while [ -n "$qs" ]; do
        pair=${qs%%&*}; [ "$pair" = "$qs" ] && qs="" || qs=${qs#*&}
        [ "${pair%%=*}" = "$1" ] && { printf '%s' "${pair#*=}"; return 0; }
    done
    return 1
}

CMND=$(get_param cmnd 2>/dev/null | tr '[:lower:]' '[:upper:]')
case "$CMND" in
    START|STOP|STATUS|PROBE) "$CTL" "$CMND" ;;
    *) printf 'Unknown command: %s\nValid: START, STOP, STATUS, PROBE\n' "${CMND:-<empty>}" ;;
esac
EOF_CGI
ln -sf /www/cgi-bin/cm /www/cgi-bin/controlweb_cgi

echo "[*] Installing RPCD backend..."
install /usr/libexec/rpcd/autorecorder 0755 <<'EOF_RPCD'
#!/bin/sh
# ALSAmrec rpcd plugin â€” exposes status/start/stop/probe over ubus.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl
RECORDER=/usr/sbin/recorder

. /usr/share/libubox/jshn.sh

find_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$RECORDER" 2>/dev/null || true; return
    fi
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)
        case "$cmd" in *"$RECORDER"*) printf '%s\n' "${proc#/proc/}";; esac
    done
}

pid_list() { find_pids | awk 'NF{printf "%s%s",sep,$1;sep=" "}END{print ""}'; }

json_bool() {
    [ "$2" -eq 1 ] 2>/dev/null && json_add_boolean "$1" 1 || json_add_boolean "$1" 0
}

reply_status() {
    pids=$(pid_list); json_init
    if [ -n "$pids" ]; then
        json_bool running 1; json_add_string status "RUNNING"
        json_add_string pid "$pids"; json_add_string text "RUNNING (PID: $pids)"
    else
        json_bool running 0; json_add_string status "STOPPED"
        json_add_string pid ""; json_add_string text "STOPPED"
    fi
    json_dump
}

reply_command() {
    output=$($CTL "$1" 2>&1); rc=$?; pids=$(pid_list); json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    [ -n "$pids" ]  && json_bool running 1 || json_bool running 0
    json_add_string message "$output"; json_add_string pid "$pids"
    json_dump
}

reply_probe() {
    output=$($CTL PROBE 2>&1); rc=$?; json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    json_add_string message "$output"; json_add_string output "$output"
    json_dump
}

case "${1:-}" in
    list) echo '{"status":{},"start":{},"stop":{},"probe":{}}' ;;
    call)
        case "${2:-}" in
            status) reply_status        ;;
            start)  reply_command START  ;;
            stop)   reply_command STOP   ;;
            probe)  reply_probe          ;;
            *)
                json_init; json_bool success 0
                json_add_string error "Unknown method: ${2:-}"; json_dump ;;
        esac ;;
    *) echo "Usage: $0 list|call <method>" >&2; exit 1 ;;
esac
EOF_RPCD

echo "[*] Installing LuCI frontend..."
install /www/luci-static/resources/view/autorecorder/main.js 0644 <<'EOF_LUCI_JS'
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus = rpc.declare({ object: 'autorecorder', method: 'status' });
var callStart  = rpc.declare({ object: 'autorecorder', method: 'start'  });
var callStop   = rpc.declare({ object: 'autorecorder', method: 'stop'   });
var callProbe  = rpc.declare({ object: 'autorecorder', method: 'probe'  });

return view.extend({
    render: function() {
        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText  = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em;' }, _('Loading...'));
        var probeOutput = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em; display: none;' });
        var buttons = [];

        function setBadge(running, label) {
            statusBadge.textContent           = label || (running ? _('RUNNING') : _('STOPPED'));
            statusBadge.style.color           = '#fff';
            statusBadge.style.backgroundColor = running ? '#37a237' : '#a93737';
        }

        function refreshStatus() {
            return callStatus().then(function(data) {
                var running = !!data.running;
                setBadge(running, data.status || (running ? 'RUNNING' : 'STOPPED'));
                statusText.textContent = data.text || (running ? 'RUNNING' : 'STOPPED');
            }).catch(function(err) {
                setBadge(false, _('ERROR'));
                statusText.textContent = _('Unable to read recorder status: ') + err;
            });
        }

        function setButtonsDisabled(disabled) {
            for (var i = 0; i < buttons.length; i++) buttons[i].disabled = disabled;
        }

        function runCommand(fn, doneMessage, showProbe) {
            setButtonsDisabled(true);
            probeOutput.style.display = 'none';
            return fn().then(function(res) {
                var msg = res.message || doneMessage;
                ui.addNotification(null, E('p', {}, msg), res.success === false ? 'warning' : 'info');
                if (showProbe) { probeOutput.style.display = ''; probeOutput.textContent = res.output || msg; }
                return refreshStatus();
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Command failed: ') + err), 'danger');
            }).then(function() { setButtonsDisabled(false); });
        }

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'click': function(ev) { ev.preventDefault(); return runCommand(callStart, _('Start command sent'), false); }
        }, _('START')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-negative', 'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return runCommand(callStop, _('Stop command sent'), false); }
        }, _('STOP')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-neutral', 'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return runCommand(callProbe, _('Probe completed'), true); }
        }, _('PROBE')));

        refreshStatus();
        poll.add(refreshStatus, 5);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('ALSAmrec')),
            E('div', { 'class': 'cbi-map-descr' },
                _('Control the autorecorder daemon. Exposes the same START, STOP, STATUS and PROBE functions as the CGI endpoint.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Status')), statusBadge, statusText,
                E('div', { 'style': 'margin-top:1em;' }, buttons),
                probeOutput
            ])
        ]);
    }
});
EOF_LUCI_JS

echo "[*] Installing LuCI menu and ACL..."
install /usr/share/luci/menu.d/autorecorder.json 0644 <<'EOF_MENU'
{
    "admin/autorecorder": {
        "title": "ALSAmrec",
        "action": { "type": "view", "path": "autorecorder/main" },
        "depends": { "acl": [ "luci-app-autorecorder" ] }
    }
}
EOF_MENU

install /usr/share/rpcd/acl.d/autorecorder.json 0644 <<'EOF_ACL'
{
    "luci-app-autorecorder": {
        "description": "Grant LuCI access to ALSAmrec",
        "read":  { "ubus": { "autorecorder": [ "status", "probe" ] } },
        "write": { "ubus": { "autorecorder": [ "start",  "stop"  ] } }
    }
}
EOF_ACL

echo "[*] Enabling and starting services..."
/etc/init.d/autorecorder enable  >/dev/null 2>&1 || warn "Could not enable autorecorder"
/etc/init.d/autorecorder restart >/dev/null 2>&1 || \
    /etc/init.d/autorecorder start >/dev/null 2>&1 || warn "Could not start autorecorder"
/etc/init.d/rpcd restart >/dev/null 2>&1 || \
    service rpcd restart  >/dev/null 2>&1 || warn "Could not restart rpcd"

command -v arecord >/dev/null 2>&1 || warn "arecord not found â€” install alsa-utils before using the recorder."

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')

echo ""
echo "[*] Installation complete. Available endpoints:"
echo "    CGI Â¦"
for cmd in START STOP STATUS PROBE; do
    echo "        http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done
echo "    CLI  Â¦  autorecorderctl START|STOP|STATUS|PROBE"
echo "    Init Â¦  /etc/init.d/autorecorder start|stop|reload|status"
echo "    LuCI Â¦  ALSAmrec section (navbar)"
echo ""

printf "A reboot is recommended. Reboot now? [y/N]: "
read answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
