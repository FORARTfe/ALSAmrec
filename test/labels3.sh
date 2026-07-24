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
# ALSAmrec control helper: START, STOP, STATUS, PROBE, PERFORMANCEINFO, SAVEPERFORMANCE.

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

latest_raw_file() {
    ls "$MNT"/*.raw 2>/dev/null | sort | tail -n1
}

# Pulls epoch/channels/rate/format straight out of a recorder-generated
# filename (<epoch>_<channels>-<rate>-<format>.raw) — no ALSA re-probe
# needed, since the filename already records exactly what was used for
# that take. Prints the four fields tab-separated.
parse_raw_name() {
    base=$(basename "$1" 2>/dev/null)
    base=${base%.raw}
    epoch=${base%%_*}
    rest=${base#*_}
    channels=${rest%%-*}
    rest=${rest#*-}
    rate=${rest%%-*}
    format=${rest#*-}
    valid_uint "$epoch" || return 1
    valid_uint "$channels" || return 1
    valid_uint "$rate" || return 1
    [ -n "$format" ] || return 1
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$channels" "$rate" "$format"
}

# Human-readable UTC rendering, e.g. "Wednesday, July 22, 2026 02:00:22 PM UTC"
epoch_to_display() {
    disp=$(date -u -d "@$1" +'%A, %B %d, %Y %I:%M:%S %p' 2>/dev/null) || return 1
    printf '%s UTC\n' "$disp"
}

# Makes arbitrary user text safe to use directly as a filename: collapses
# path separators/newlines/tabs to "_", strips leading dots (no hidden
# files, no ".." traversal), and caps the length.
sanitize_filename() {
    out=$(printf '%s' "$1" | tr '/\n\r\t' '____')
    while [ "${out#.}" != "$out" ]; do out=${out#.}; done
    printf '%s' "$out" | cut -c1-180
}

performance_info() {
    raw=$(latest_raw_file || true)
    if [ -z "$raw" ]; then
        echo "RAW="
        return 0
    fi
    meta=$(parse_raw_name "$raw") || { echo "RAW="; return 0; }
    channels=$(printf '%s' "$meta" | cut -f2)
    rate=$(printf '%s' "$meta" | cut -f3)
    format=$(printf '%s' "$meta" | cut -f4)
    epoch=$(printf '%s' "$meta" | cut -f1)
    echo "RAW=$(basename "$raw")"
    echo "CHANNELS=$channels"
    echo "RATE=$rate"
    echo "FORMAT=$format"
    echo "RECORDED_AT=$(epoch_to_display "$epoch" || true)"
    return 0
}

save_performance() {
    is_running && { echo "ERROR: recorder is running, stop first"; return 1; }
    raw=$(latest_raw_file || true)
    [ -n "$raw" ] || { echo "ERROR: no recorded .raw file found yet"; return 1; }
    meta=$(parse_raw_name "$raw") || { echo "ERROR: unable to parse recording metadata from $(basename "$raw")"; return 1; }
    epoch=$(printf '%s' "$meta" | cut -f1)
    channels=$(printf '%s' "$meta" | cut -f2)
    rate=$(printf '%s' "$meta" | cut -f3)
    format=$(printf '%s' "$meta" | cut -f4)

    input=$(cat)

    # Pass 1: pull everything needed out of the *incoming* request into plain
    # shell variables. jshn holds one document at a time, and pass 2 below
    # needs a second, independent document to build the output.
    json_init
    json_load "$input" 2>/dev/null
    json_get_var performance performance ""
    i=1
    while [ "$i" -le "$channels" ]; do
        val=""
        if json_select labels 2>/dev/null; then
            json_get_var val "$i" ""
            json_select ..
        fi
        eval "label_$i=\$val"
        i=$((i + 1))
    done

    performance=$(sanitize_filename "$performance")
    [ -n "$performance" ] || performance=$(basename "${raw%.raw}")
    outdir=$(dirname "$raw")
    outfile="$outdir/${performance}.json"
    tmpfile=$(mktemp "$outdir/.performance.XXXXXX")

    # Pass 2: build the output document fresh. Every channel gets a "labels"
    # entry regardless of what the caller submitted — blank ones become "".
    (
        json_init
        json_add_string performance "$performance"
        json_add_int recordedAtEpoch "$epoch"
        json_add_string recordedAt "$(epoch_to_display "$epoch" || true)"
        json_add_int channels "$channels"
        json_add_int sampleRate "$rate"
        json_add_string format "$format"
        json_add_object labels
        i=1
        while [ "$i" -le "$channels" ]; do
            eval "val=\$label_$i"
            json_add_string "$i" "$val"
            i=$((i + 1))
        done
        json_close_object
        json_dump
    ) > "$tmpfile"
    mv "$tmpfile" "$outfile"
    echo "Performance data saved to $outfile"
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
    PERFORMANCEINFO)
        performance_info
        ;;
    SAVEPERFORMANCE)
        save_performance
        ;;
    *)
        echo "Usage: $0 START|STOP|STATUS|PROBE|PERFORMANCEINFO|SAVEPERFORMANCE"; exit 1
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

reply_performance_info() {
    output=$($CTL PERFORMANCEINFO 2>&1); rc=$?; json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    raw=$(printf '%s\n' "$output" | awk -F= '/^RAW=/{sub(/^RAW=/, "", $0); print; exit}')
    channels=$(printf '%s\n' "$output" | awk -F= '/^CHANNELS=/{print $2; exit}')
    rate=$(printf '%s\n' "$output" | awk -F= '/^RATE=/{print $2; exit}')
    format=$(printf '%s\n' "$output" | awk -F= '/^FORMAT=/{sub(/^FORMAT=/, "", $0); print; exit}')
    recorded_at=$(printf '%s\n' "$output" | awk -F= '/^RECORDED_AT=/{sub(/^RECORDED_AT=/, "", $0); print; exit}')
    valid_uint "${channels:-}" || channels=0
    valid_uint "${rate:-}" || rate=0
    json_add_string raw "${raw:-}"
    json_add_int channels "$channels"
    json_add_int sampleRate "$rate"
    json_add_string format "${format:-}"
    json_add_string recordedAt "${recorded_at:-}"
    json_add_string message "$output"
    json_dump
}

reply_performance_save() {
    output=$(cat | $CTL SAVEPERFORMANCE 2>&1)
    rc=$?
    json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    json_add_string message "$output"
    json_dump
}

case "${1:-}" in
    list) echo '{"status":{},"start":{},"stop":{},"probe":{},"performance_info":{},"performance_save":{}}' ;;
    call)
        case "${2:-}" in
            status)           reply_status           ;;
            start)            reply_command START    ;;
            stop)             reply_command STOP     ;;
            probe)            reply_probe            ;;
            performance_info) reply_performance_info ;;
            performance_save) reply_performance_save ;;
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

var callStatus  = rpc.declare({ object: 'autorecorder', method: 'status'  });
var callStart   = rpc.declare({ object: 'autorecorder', method: 'start'   });
var callStop    = rpc.declare({ object: 'autorecorder', method: 'stop'    });
var callProbe   = rpc.declare({ object: 'autorecorder', method: 'probe'   });
var callPerformanceInfo = rpc.declare({ object: 'autorecorder', method: 'performance_info' });
var callPerformanceSave = rpc.declare({
    object: 'autorecorder',
    method: 'performance_save',
    params: [ 'performance', 'labels' ]
});

return view.extend({
    render: function() {
        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText  = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em;' }, _('Loading...'));
        var probeOutput = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em; display: none;' });
        var formInfo    = E('div',  { 'style': 'margin:.5em 0 1em 0; color:#666;' }, _('Loading recording metadata...'));
        var formWrap    = E('div',  { 'style': 'overflow-x:auto;' });
        var saveButton;
        var buttons = [];
        var currentRunning  = true;
        var currentRaw      = null;   // identity of the recording the form currently reflects
        var currentChannels = 0;

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
                saveButton.disabled = disabled || currentRunning || currentChannels < 1 || !currentRaw;
            inputs = formWrap.querySelectorAll('input');
            for (i = 0; i < inputs.length; i++)
                inputs[i].disabled = disabled || currentRunning;
        }

        function collectPerformanceName() {
            var input = formWrap.querySelector('input[data-role="performance"]');
            return input ? (input.value || '') : '';
        }

        function collectLabels() {
            var out = {};
            var inputs = formWrap.querySelectorAll('input[data-channel]');
            for (var i = 0; i < inputs.length; i++)
                out[inputs[i].getAttribute('data-channel')] = inputs[i].value || '';
            return out;
        }

        function buildPerformanceForm(info) {
            currentChannels = info.channels || 0;
            currentRaw      = info.raw || '';
            formWrap.innerHTML = '';

            if (!info.raw) {
                formInfo.textContent = _('No recording found yet. Start and stop the recorder to create one, then come back here to name it and label its channels.');
                setButtonsDisabled(false);
                return;
            }

            var defaultName = info.raw.replace(/\.raw$/i, '');
            var metaBits = [];
            if (info.recordedAt) metaBits.push(info.recordedAt);
            metaBits.push(String(currentChannels) + _(' channel(s)'));
            if (info.sampleRate) metaBits.push(String(info.sampleRate) + ' Hz');
            if (info.format) metaBits.push(info.format);
            formInfo.textContent = _('Recording: ') + metaBits.join(' — ');

            formWrap.appendChild(E('div', { 'style': 'margin-bottom:1em;' }, [
                E('div', { 'style': 'font-weight:600; margin-bottom:.25em;' }, _('Performance')),
                E('input', {
                    'type': 'text',
                    'data-role': 'performance',
                    'value': defaultName,
                    'maxlength': '180',
                    'style': 'width:100%; max-width:480px;'
                })
            ]));

            var cols = Math.ceil(currentChannels / 4);
            var rows = Math.min(4, currentChannels);
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
                    if (ch <= currentChannels) {
                        td.appendChild(E('div', { 'style': 'display:flex; flex-direction:column; gap:.35em;' }, [
                            E('div', { 'style': 'font-weight:600;' }, _('Channel ') + String(ch)),
                            E('input', {
                                'type': 'text',
                                'data-channel': String(ch),
                                'placeholder': _('Channel ') + String(ch),
                                'style': 'width:100%;'
                            })
                        ]));
                    }
                    tr.appendChild(td);
                }
                tbody.appendChild(tr);
            }

            table.appendChild(tbody);
            formWrap.appendChild(table);
            setButtonsDisabled(false);
        }

        function refreshPerformanceInfo() {
            return callPerformanceInfo().then(function(res) {
                if (res.success === false) {
                    formInfo.textContent = res.message || _('Unable to read recording metadata.');
                    currentChannels = 0;
                    currentRaw = '';
                    formWrap.innerHTML = '';
                    setButtonsDisabled(false);
                    return;
                }
                // Only rebuild when there is actually something different to
                // show — i.e. a new recording appeared since the last poll.
                // Channel count, rate and format are all parsed from the raw
                // filename itself, so if the filename is unchanged none of
                // them can have changed either. Skipping the rebuild is what
                // keeps a field the user is mid-typing into completely
                // undisturbed, rather than reactively checking focus.
                if ((res.raw || '') === currentRaw)
                    return;
                buildPerformanceForm(res);
            }).catch(function(err) {
                formInfo.textContent = _('Unable to read recording metadata: ') + err;
                currentChannels = 0;
                currentRaw = '';
                formWrap.innerHTML = '';
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

        function savePerformance(ev) {
            ev.preventDefault();
            if (currentRunning) {
                ui.addNotification(null, E('p', {}, _('Stop the recorder before saving performance data.')), 'warning');
                return;
            }
            if (!currentRaw) {
                ui.addNotification(null, E('p', {}, _('No recording found yet — record something first.')), 'warning');
                return;
            }
            setButtonsDisabled(true);
            return callPerformanceSave(collectPerformanceName(), collectLabels()).then(function(res) {
                ui.addNotification(null, E('p', {}, res.message || _('Performance data saved.')), res.success === false ? 'warning' : 'info');
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Saving performance data failed: ') + err), 'danger');
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
            'click': savePerformance
        }, _('Save performance data'));

        refreshStatus();
        poll.add(refreshStatus, 5);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('ALSAmrec')),
            E('div', { 'class': 'cbi-map-descr' },
                _('Control the autorecorder daemon. Once it is stopped, name the take and label each channel; the data — plus the recording date/time, channel count, sample rate and format read from the .raw filename — is saved as JSON named after the performance, in the recordings directory.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Status')), statusBadge, statusText,
                E('div', { 'style': 'margin-top:1em;' }, buttons),
                probeOutput
            ]),
            E('div', { 'class': 'cbi-section', 'style': 'margin-top:2em;' }, [
                E('h3', {}, _('Performance data')),
                E('p', {}, _('Shown once the recorder is stopped and a recording exists. Leave a channel blank to store it as an empty string.')),
                formInfo,
                formWrap,
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
        "read":  { "ubus": { "autorecorder": [ "status", "probe", "performance_info" ] } },
        "write": { "ubus": { "autorecorder": [ "start", "stop", "performance_save" ] } }
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
echo "    CLI  ¦  autorecorderctl START|STOP|STATUS|PROBE|PERFORMANCEINFO|SAVEPERFORMANCE"
echo "    Init ¦  /etc/init.d/autorecorder start|stop|reload|status"
echo "    LuCI ¦  ALSAmrec section (navbar)"
echo ""

printf "A reboot is recommended. Reboot now? [y/N]: "
read answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
