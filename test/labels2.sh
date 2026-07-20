#!/bin/sh
#
# ALSAmrec installer v3.3
# CLI + CGI + LuCI — full stack, single installer.
#
# v3.3: [FIX-C] LuCI label inputs no longer lose focus/cursor during the
#       5s status poll. [FIX-L] Channel labels are now actually persisted:
#       rpcd delivers ubus call data on the plugin's stdin, not via an
#       (nonexistent) RPC_INPUT env var; labels are stored as JSON named
#       after the current .raw recording instead of a static filename.
#
# Original recorder daemon by J. Bruce Fields, 2024.
# LuCI/CGI port and OpenWrt fixes by FORART, 2025-26.
# GPL v3 — see <https://www.gnu.org/licenses/>
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
# ALSAmrec recorder daemon — GPL v3

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

sleep 2147483647 &
dummy=$!

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

    if [ -n "${recorder:-}" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""; cleanup_mount
    fi

    if [ -z "$audio_dev" ] || [ -z "$disk" ]; then
        cleanup_recorder; cleanup_mount; sleep 2; continue
    fi

    [ -n "${recorder:-}" ] && continue

    card_num=${audio_dev%%:*}; dev_num=${audio_dev##*:}
    valid_uint "$card_num" || continue
    valid_uint "$dev_num"  || continue

    mkdir -p "$MNT"
    grep -qs " $MNT " /proc/mounts || mount "$disk" "$MNT" || continue

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
# ALSAmrec control helper: START, STOP, STATUS, PROBE, LABELSINFO, WRITELABELS.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder
MNT=/tmp/mnt

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
is_running() { [ -n "$(pid_list)" ]; }
valid_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

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

channel_count_from_probe() {
    probe_device | awk '
        index($0, "CHANNELS:") == 1 {
            gsub(/[^0-9]+/, " ", $0)
            n = split($0, a, /[ ]+/)
            for (i = n; i >= 1; i--) if (a[i] != "") { print a[i]; exit }
        }'
}

# current_labels_file: the label sidecar is named after whichever .raw
# recording is newest in $MNT (epoch-prefixed filenames sort correctly as
# plain text, so this does not depend on filesystem mtime fidelity).
# Prints nothing if no .raw recording exists yet. [FIX-L]
current_labels_file() {
    raw=$(ls "$MNT"/*.raw 2>/dev/null | sort | tail -n1)
    [ -n "$raw" ] && printf '%s\n' "${raw%.raw}.json"
}

read_labels_json() {
    # $1 = path to an existing labels JSON file; prints "<index><TAB><label>"
    [ -f "$1" ] || return 0
    (
        json_init
        json_load_file "$1" 2>/dev/null || exit 0
        json_select labels 2>/dev/null || exit 0
        json_get_keys idx_keys
        for k in $idx_keys; do
            json_get_var v "$k" ""
            printf '%s\t%s\n' "$k" "$v"
        done
    )
}

write_labels_json() {
    # $1 = target file, $2 = channel count; reads "idx=label" lines from stdin
    file=$1
    channels=$2
    tmpfile=$(mktemp)
    (
        json_init
        json_add_int channels "$channels"
        json_add_object labels
        while IFS= read -r line; do
            idx=${line%%=*}
            raw=${line#*=}
            valid_uint "$idx" || continue
            [ "$idx" -ge 1 ] 2>/dev/null || continue
            [ "$idx" -le "$channels" ] 2>/dev/null || continue
            json_add_string "$idx" "$raw"
        done
        json_close_object
        json_dump
    ) > "$tmpfile"
    mv "$tmpfile" "$file"
}

labels_info() {
    is_running && { echo "ERROR: recorder is running, stop first"; return 1; }
    [ -d "$MNT" ] || { echo "ERROR: recordings directory $MNT is not available"; return 1; }
    ch=$(channel_count_from_probe || true)
    valid_uint "${ch:-}" || ch=1
    file=$(current_labels_file || true)
    echo "CHANNELS=$ch"
    echo "FILE=$file"
    if [ -n "$file" ]; then
        read_labels_json "$file" | while IFS="$(printf '\t')" read -r idx lbl; do
            printf 'LABEL[%s]=%s\n' "$idx" "$lbl"
        done
    fi
    return 0
}

write_labels_from_stdin() {
    is_running && { echo "ERROR: recorder is running, stop first"; return 1; }
    [ -d "$MNT" ] || { echo "ERROR: recordings directory $MNT is not available"; return 1; }
    ch=$(channel_count_from_probe || true)
    valid_uint "${ch:-}" || { echo "ERROR: unable to detect channel count"; return 1; }
    file=$(current_labels_file || true)
    [ -n "$file" ] || { echo "ERROR: no recorded .raw file found to attach labels to"; return 1; }
    write_labels_json "$file" "$ch"
    echo "Labels saved to $file"
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
    LABELSINFO)
        labels_info
        ;;
    WRITELABELS)
        write_labels_from_stdin
        ;;
    *)
        echo "Usage: $0 START|STOP|STATUS|PROBE|LABELSINFO|WRITELABELS"; exit 1
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
# ALSAmrec rpcd plugin — exposes status/start/stop/probe/channel labels over ubus.

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
json_bool() { [ "$2" -eq 1 ] 2>/dev/null && json_add_boolean "$1" 1 || json_add_boolean "$1" 0; }
valid_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

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

reply_labels_get() {
    output=$($CTL LABELSINFO 2>&1); rc=$?; json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    channels=$(printf '%s\n' "$output" | awk -F= '/^CHANNELS=/{print $2; exit}')
    file=$(printf '%s\n' "$output" | awk -F= '/^FILE=/{sub(/^FILE=/, "", $0); print; exit}')
    valid_uint "${channels:-}" || channels=0
    pids=$(pid_list)
    [ -n "$pids" ] && json_bool running 1 || json_bool running 0
    json_add_int channels "$channels"
    json_add_string file "${file:-}"
    json_add_string message "$output"
    json_add_object labels
    label_lines=$(printf '%s\n' "$output" | awk '/^LABEL\[[0-9]+\]=/ { print }')
    if [ -n "$label_lines" ]; then
        # Fed via here-doc rather than piped into the loop: a pipeline's
        # tail stage runs in a subshell, which would silently discard every
        # json_add_string call the instant the loop ended.
        while IFS= read -r line; do
            key=${line#LABEL[}; key=${key%%]*}
            val=${line#*=}
            json_add_string "$key" "$val"
        done << EOF
$label_lines
EOF
    fi
    json_close_object
    json_dump
}

reply_labels_set() {
    input=$(cat)
    json_load "$input"
    tmpfile=$(mktemp)
    if json_select labels 2>/dev/null; then
        json_get_keys keys
        for key in $keys; do
            json_get_var val "$key" ""
            printf '%s=%s\n' "$key" "$val" >> "$tmpfile"
        done
        json_select ..
    fi
    output=$($CTL WRITELABELS < "$tmpfile" 2>&1)
    rc=$?
    rm -f "$tmpfile"
    json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    json_add_string message "$output"
    json_dump
}

case "${1:-}" in
    list) echo '{"status":{},"start":{},"stop":{},"probe":{},"labels_get":{},"labels_set":{}}' ;;
    call)
        case "${2:-}" in
            status)     reply_status        ;;
            start)      reply_command START ;;
            stop)       reply_command STOP  ;;
            probe)      reply_probe         ;;
            labels_get) reply_labels_get    ;;
            labels_set) reply_labels_set    ;;
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

var callStatus    = rpc.declare({ object: 'autorecorder', method: 'status'     });
var callStart     = rpc.declare({ object: 'autorecorder', method: 'start'      });
var callStop      = rpc.declare({ object: 'autorecorder', method: 'stop'       });
var callProbe     = rpc.declare({ object: 'autorecorder', method: 'probe'      });
var callLabelsGet = rpc.declare({ object: 'autorecorder', method: 'labels_get' });
var callLabelsSet = rpc.declare({ object: 'autorecorder', method: 'labels_set', params: [ 'labels' ] });

return view.extend({
    render: function() {
        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText  = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em;' }, _('Loading...'));
        var probeOutput = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em; display: none;' });
        var labelsInfo  = E('div',  { 'style': 'margin:.5em 0 1em 0; color:#666;' }, _('Loading channel metadata...'));
        var labelsWrap  = E('div',  { 'style': 'overflow-x:auto;' });
        var saveButton;
        var buttons = [];
        var currentChannels = 0;
        var currentRunning = true;
        var currentFile = '';

        function setBadge(running, label) {
            statusBadge.textContent           = label || (running ? _('RUNNING') : _('STOPPED'));
            statusBadge.style.color           = '#fff';
            statusBadge.style.backgroundColor = running ? '#37a237' : '#a93737';
            statusBadge.style.padding         = '.2em .6em';
            statusBadge.style.borderRadius    = '999px';
            statusBadge.style.display         = 'inline-block';
            statusBadge.style.marginTop       = '.25em';
        }

        function setButtonsDisabled(disabled) {
            var i, inputs;
            for (i = 0; i < buttons.length; i++)
                buttons[i].disabled = disabled;
            if (saveButton)
                saveButton.disabled = disabled || currentRunning || currentChannels < 1 || !currentFile;
            inputs = labelsWrap.querySelectorAll('input[data-channel]');
            for (i = 0; i < inputs.length; i++)
                inputs[i].disabled = disabled || currentRunning;
        }

        function collectLabels() {
            var out = {};
            var inputs = labelsWrap.querySelectorAll('input[data-channel]');
            for (var i = 0; i < inputs.length; i++)
                out[inputs[i].getAttribute('data-channel')] = inputs[i].value || '';
            return out;
        }

        function buildLabelsTable(channels, labels, file) {
            labelsWrap.innerHTML = '';
            currentChannels = channels || 0;
            currentFile = file || '';

            if (!channels || channels < 1) {
                labelsInfo.textContent = _('No channel information available. Stop the recorder, connect storage, and try again.');
                setButtonsDisabled(false);
                return;
            }

            var cols = Math.ceil(channels / 4);
            var rows = Math.min(4, channels);
            var table = E('table', {
                'class': 'table',
                'style': 'width:auto; min-width:100%; border-collapse:separate; border-spacing:.5em;'
            });
            var tbody = E('tbody');

            for (var r = 0; r < rows; r++) {
                var tr = E('tr');
                for (var c = 0; c < cols; c++) {
                    var ch = c * 4 + r + 1;
                    var td = E('td', {
                        'style': 'vertical-align:top; border:1px solid #ddd; padding:.5em; min-width:180px;'
                    });
                    if (ch <= channels) {
                        td.appendChild(E('div', { 'style': 'display:flex; flex-direction:column; gap:.35em;' }, [
                            E('div', { 'style': 'font-weight:600;' }, _('channel ') + String(ch)),
                            E('input', {
                                'type': 'text',
                                'data-channel': String(ch),
                                'value': (labels && labels[String(ch)]) ? labels[String(ch)] : '',
                                'placeholder': _('Enter label'),
                                'style': 'width:100%;'
                            })
                        ]));
                    }
                    tr.appendChild(td);
                }
                tbody.appendChild(tr);
            }

            table.appendChild(tbody);
            labelsWrap.appendChild(table);
            labelsInfo.textContent = file
                ? _('Detected channels: ') + String(channels) + _(' — labels will be saved as ') + file.split('/').pop()
                : _('Detected channels: ') + String(channels) + _(' — no recording found yet; record and stop the recorder first.');
            setButtonsDisabled(false);
        }

        function isEditingLabels() {
            var active = document.activeElement;
            return !!(active && active.matches && active.matches('input[data-channel]'));
        }

        function refreshLabels() {
            // A poll tick lands every ~5s regardless of what the user is doing.
            // Rebuilding the table while a label field is focused would replace
            // that input with a fresh, unfocused node — the cursor disappears
            // and whatever was mid-typed gets discarded. Skip this cycle instead;
            // the next poll after the user blurs the field will resync normally.
            if (isEditingLabels())
                return Promise.resolve();

            return callLabelsGet().then(function(res) {
                if (res.success === false) {
                    labelsInfo.textContent = res.message || _('Unable to load labels information.');
                    currentChannels = 0;
                    currentFile = '';
                    labelsWrap.innerHTML = '';
                    setButtonsDisabled(false);
                    return;
                }
                buildLabelsTable(res.channels || 0, res.labels || {}, res.file || '');
            }).catch(function(err) {
                labelsInfo.textContent = _('Unable to load labels information: ') + err;
                currentChannels = 0;
                currentFile = '';
                labelsWrap.innerHTML = '';
                setButtonsDisabled(false);
            });
        }

        function refreshStatus() {
            return callStatus().then(function(data) {
                currentRunning = !!data.running;
                setBadge(currentRunning, data.status || (currentRunning ? 'RUNNING' : 'STOPPED'));
                statusText.textContent = data.text || (currentRunning ? 'RUNNING' : 'STOPPED');
                return refreshLabels();
            }).catch(function(err) {
                currentRunning = true;
                setBadge(false, _('ERROR'));
                statusText.textContent = _('Unable to read recorder status: ') + err;
                setButtonsDisabled(false);
            });
        }

        function runCommand(fn, doneMessage, showProbe) {
            setButtonsDisabled(true);
            probeOutput.style.display = 'none';
            return fn().then(function(res) {
                var msg = res.message || doneMessage;
                ui.addNotification(null, E('p', {}, msg), res.success === false ? 'warning' : 'info');
                if (showProbe) {
                    probeOutput.style.display = '';
                    probeOutput.textContent = res.output || msg;
                }
                return refreshStatus();
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Command failed: ') + err), 'danger');
            }).then(function() {
                setButtonsDisabled(false);
            });
        }

        function saveLabels(ev) {
            ev.preventDefault();
            if (currentRunning) {
                ui.addNotification(null, E('p', {}, _('Stop the recorder before saving channel labels.')), 'warning');
                return;
            }
            if (!currentFile) {
                ui.addNotification(null, E('p', {}, _('No recording found yet — record something first.')), 'warning');
                return;
            }
            setButtonsDisabled(true);
            return callLabelsSet(collectLabels()).then(function(res) {
                ui.addNotification(null, E('p', {}, res.message || _('Labels saved.')), res.success === false ? 'warning' : 'info');
                return refreshLabels();
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Saving labels failed: ') + err), 'danger');
            }).then(function() {
                setButtonsDisabled(false);
            });
        }

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'click': function(ev) { ev.preventDefault(); return runCommand(callStart, _('Start command sent'), false); }
        }, _('START')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-negative',
            'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return runCommand(callStop, _('Stop command sent'), false); }
        }, _('STOP')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-neutral',
            'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return runCommand(callProbe, _('Probe completed'), true); }
        }, _('PROBE')));

        saveButton = E('button', {
            'class': 'btn cbi-button cbi-button-apply',
            'click': saveLabels
        }, _('Save channel labels'));

        refreshStatus();
        poll.add(refreshStatus, 5);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('ALSAmrec')),
            E('div', { 'class': 'cbi-map-descr' },
                _('Control the autorecorder daemon and store channel labels as JSON, named after the current recording, inside the recordings directory. Channel-label editing is enabled only when the recording service is stopped.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Status')), statusBadge, statusText,
                E('div', { 'style': 'margin-top:1em;' }, buttons),
                probeOutput
            ]),
            E('div', { 'class': 'cbi-section', 'style': 'margin-top:2em;' }, [
                E('h3', {}, _('Channel labels')),
                E('p', {}, _('Each cell contains a fixed channel number and a free text field. The table is laid out in up to 4 rows and as many columns as needed to cover all detected channels.')),
                labelsInfo,
                labelsWrap,
                E('div', { 'style': 'margin-top:1em;' }, [ saveButton ])
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
        "read":  { "ubus": { "autorecorder": [ "status", "probe", "labels_get" ] } },
        "write": { "ubus": { "autorecorder": [ "start", "stop", "labels_set" ] } }
    }
}
EOF_ACL

echo "[*] Enabling and starting services..."
/etc/init.d/autorecorder enable  >/dev/null 2>&1 || warn "Could not enable autorecorder"
/etc/init.d/autorecorder restart >/dev/null 2>&1 || \
    /etc/init.d/autorecorder start >/dev/null 2>&1 || warn "Could not start autorecorder"
/etc/init.d/rpcd restart >/dev/null 2>&1 || \
    service rpcd restart  >/dev/null 2>&1 || warn "Could not restart rpcd"

command -v arecord >/dev/null 2>&1 || warn "arecord not found — install alsa-utils before using the recorder."

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')

echo ""
echo "[*] Installation complete. Available endpoints:"
echo "    CGI ¦"
for cmd in START STOP STATUS PROBE; do
    echo "        http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done
echo "    CLI  ¦  autorecorderctl START|STOP|STATUS|PROBE|LABELSINFO|WRITELABELS"
echo "    Init ¦  /etc/init.d/autorecorder start|stop|reload|status"
echo "    LuCI ¦  ALSAmrec section (navbar)"
echo ""

printf "A reboot is recommended. Reboot now? [y/N]: "
read answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
