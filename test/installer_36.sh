#!/bin/sh
#
# ALSAmrec installer v3.4 for OpenWrt 24.10 and 25.12.
# CLI + CGI + LuCI, including the channel-label editor.
#
# Original recorder daemon by J. Bruce Fields, 2024.
# LuCI/CGI port and OpenWrt fixes by FORART, 2025-26.
# GPL v3 — see <https://www.gnu.org/licenses/>
#

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# The LuCI packages also cover OpenWrt images that ship without a web UI.
PACKAGES="rpcd uhttpd uhttpd-mod-ubus luci-base luci-mod-admin-full luci-theme-bootstrap
alsa-utils usbutils kmod-usb-audio kmod-usb-storage block-mount kmod-fs-exfat"

warn() { printf 'WARNING: %s\n' "$*" >&2; }

missing_packages() {
    awk -v packages="$PACKAGES" '
        NF { installed[$1] = 1 }
        END {
            n = split(packages, required, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
                if (!(required[i] in installed)) print required[i]
        }'
}

install_packages() {
    local manager action missing
    if command -v apk >/dev/null 2>&1; then
        manager=apk
        action=add
        missing=$(apk --no-network info 2>/dev/null | missing_packages)
    elif command -v opkg >/dev/null 2>&1; then
        manager=opkg
        action=install
        missing=$(opkg list-installed 2>/dev/null | missing_packages)
    else
        warn "Neither apk nor opkg was found. Skipping package installation."
        return
    fi

    # The names come from the constant PACKAGES list.
    set -- $missing
    if [ "$#" -eq 0 ]; then
        echo "[*] Required packages are already installed."
        return
    fi
    echo "[*] Updating package lists with $manager..."
    "$manager" update || warn "$manager update failed; trying installation anyway."
    "$manager" "$action" "$@" || warn "Some packages could not be installed."
}

backup_file() {
    if [ -e "$1" ] && [ ! -e "${1}.bak-autorecorder" ]; then
        cp -p "$1" "${1}.bak-autorecorder"
    fi
}

# Stage each file on the target filesystem so running services never read a
# partially written replacement. Keep the first backup across reinstalls.
pending=
trap '[ -z "$pending" ] || rm -f "$pending"' EXIT
trap 'exit 1' HUP INT TERM

install_file() {
    pending=$(mktemp "${1}.new.XXXXXX")
    cat > "$pending"
    chmod "$2" "$pending"
    mv -f "$pending" "$1"
    pending=
}

install_packages

echo "[*] Creating directories..."
mkdir -p \
    /usr/sbin \
    /etc/init.d \
    /etc/hotplug.d/block \
    /etc/hotplug.d/usb \
    /usr/libexec/rpcd \
    /usr/share/autorecorder \
    /usr/share/rpcd/acl.d \
    /usr/share/luci/menu.d \
    /www/luci-static/resources/view/autorecorder \
    /www/cgi-bin

echo "[*] Backing up existing files..."
for f in \
    /usr/share/autorecorder/common.sh \
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

echo "[*] Installing shared recorder functions..."
install_file /usr/share/autorecorder/common.sh 0644 <<'EOF_COMMON'
# Shared by the recorder, the CLI and the rpcd backend.
RECORDER=/usr/sbin/recorder
INIT=/etc/init.d/autorecorder
PIDFILE=/var/run/autorecorder.pid
MNT=/tmp/mnt

valid_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

is_recorder_process() {
    local arg
    {
        IFS= read -r -d '' arg || return 1
        [ "$arg" != "$RECORDER" ] || return 0
        if [ "${arg##*/}" = busybox ]; then
            IFS= read -r -d '' arg || return 1
        fi
        case "${arg##*/}" in
            sh|ash|bash)
                while IFS= read -r -d '' arg; do
                    case "$arg" in -*) continue;; esac
                    [ "$arg" = "$RECORDER" ]
                    return
                done
                ;;
        esac
        return 1
    } 2>/dev/null < "$1"
}

registered_pid() {
    if { IFS= read -r recorder_pids < "$PIDFILE"; } 2>/dev/null &&
        valid_uint "$recorder_pids" &&
        is_recorder_process "/proc/$recorder_pids/cmdline"
    then
        return 0
    fi
    recorder_pids=
    return 1
}

get_recorder_pids() {
    local pid candidates proc
    registered_pid && return 0

    # Also recognise a recorder that predates the PID file or was invoked
    # directly. OpenWrt provides pgrep, with a shell fallback for custom builds.
    if command -v pgrep >/dev/null 2>&1; then
        candidates=$(pgrep -f "(^|[[:space:]])$RECORDER([[:space:]]|$)" 2>/dev/null)
        for pid in $candidates; do
            if is_recorder_process "/proc/$pid/cmdline"; then
                recorder_pids="${recorder_pids:+$recorder_pids }$pid"
            fi
        done
    else
        for proc in /proc/[0-9]*/cmdline; do
            if is_recorder_process "$proc"; then
                pid=${proc#/proc/}
                recorder_pids="${recorder_pids:+$recorder_pids }${pid%/cmdline}"
            fi
        done
    fi
    [ -n "$recorder_pids" ]
}

lock_storage() {
    { exec 9>"$PIDFILE.lock"; } 2>/dev/null || return 1
    flock -x 9
}

unlock_storage() { exec 9>&-; }

first_audio_device() {
    LC_ALL=C arecord -l 2>/dev/null | awk '
        /^[[:space:]]*card[[:space:]]+[0-9]+:/ &&
        match($0, /,[[:space:]]+device[[:space:]]+[0-9]+:/) {
            dev = substr($0, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", dev)
            card = $2
            sub(/:$/, "", card)
            print card ":" dev
            exit
        }'
}

dump_audio_params() {
    # The dump is written to stderr. A one-sample raw capture avoids an
    # indefinite probe on devices that accept arecord's default settings.
    LC_ALL=C arecord -D "hw:$1,$2" --nonblock --dump-hw-params \
        --file-type=raw --samples=1 /dev/null 2>&1
}

find_exfat_volume() {
    local LC_ALL=C _major _minor _blocks name _rest candidate signature
    exfat_volume=
    while read -r _major _minor _blocks name _rest; do
        case "$name" in sd*|mmcblk*|nvme*) ;; *) continue;; esac
        candidate="/dev/$name"
        [ -b "$candidate" ] || continue

        # Read at most 11 bytes with BusyBox ash, with NUL as the delimiter.
        # The eight-byte exFAT signature starts at offset 3.
        { IFS= read -r -d '' -n 11 signature < "$candidate"; } 2>/dev/null || continue
        case "$signature" in
            ???'EXFAT   ')
                [ -z "$exfat_volume" ] || return 1
                exfat_volume=$candidate
                ;;
        esac
    done < /proc/partitions
    [ -n "$exfat_volume" ]
}

read_mount() {
    local path rest
    while read -r mount_source path mount_type rest; do
        [ "$path" != "$MNT" ] || return 0
    done < /proc/mounts
    return 1
}

mount_volume() {
    mounted_here=0
    find_exfat_volume || return 1
    if read_mount; then
        [ "$mount_source" = "$exfat_volume" ] && [ "$mount_type" = exfat ]
        return
    fi
    [ -d "$MNT" ] || mkdir -p "$MNT" || return 1
    mount -t exfat "$exfat_volume" "$MNT" || return 1
    mounted_here=1
}
EOF_COMMON

echo "[*] Installing recorder daemon..."
install_file /usr/sbin/recorder 0755 <<'EOF_RECORDER'
#!/bin/sh
# ALSAmrec recorder daemon — GPL v3

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /usr/share/autorecorder/common.sh

capture_pid=
capture_volume=
retry_pid=
retry_delay=2
scan_requested=0
registered=0

stop_capture() {
    if [ -n "$capture_pid" ]; then
        kill "$capture_pid" 2>/dev/null || :
        wait "$capture_pid" 2>/dev/null || :
        capture_pid=
    fi
}

close_volume() {
    if [ -n "$capture_volume" ] && read_mount && [ "$mount_source" = "$capture_volume" ]; then
        umount -l "$MNT" 2>/dev/null || :
    fi
    capture_volume=
}

on_hup() {
    scan_requested=1
    [ -z "$retry_pid" ] || kill "$retry_pid" 2>/dev/null || :
}

on_term() {
    trap '' HUP INT TERM
    stop_capture
    if [ -n "$retry_pid" ]; then
        kill "$retry_pid" 2>/dev/null || :
        wait "$retry_pid" 2>/dev/null || :
    fi
    close_volume
    if [ "$registered" -eq 1 ]; then
        rm -f "$PIDFILE"
    fi
    exit 0
}

trap on_hup HUP
trap on_term INT TERM

# Serialise startup with the stopped-only RPC storage operations.
[ -d "$MNT" ] || mkdir -p "$MNT" || exit 1
[ -d "${PIDFILE%/*}" ] || mkdir -p "${PIDFILE%/*}" || exit 1
lock_storage || exit 1
registered_pid && exit 1
printf '%s\n' "$$" > "$PIDFILE" || exit 1
registered=1
unlock_storage

read_hw_params() {
    dump_audio_params "$1" "$2" | awk '
        function last_number(line, n, parts, i) {
            sub(/^[^:]*:/, "", line)
            n = split(line, parts, /[^0-9]+/)
            for (i = n; i > 0; i--)
                if (parts[i] != "") return parts[i]
        }
        /^CHANNELS:/ { channels = last_number($0) }
        /^RATE:/     { rate = last_number($0) }
        /^FORMAT:/ {
            sub(/^FORMAT:[[:space:]]*/, "")
            gsub(/\[|\]/, "")
            format = $NF
        }
        END {
            printf "%s|%s|%s\n", channels, rate, format
        }'
}

write_sidecar() {
    local channel=1
    printf '{\n  "recording": "%s",\n  "channels": {\n' "$1" || return 1
    while [ "$channel" -le "$2" ]; do
        if [ "$channel" -gt 1 ]; then
            printf ',\n' || return 1
        fi
        printf '    "%s": "Channel %s"' "$channel" "$channel" || return 1
        channel=$((channel + 1))
    done
    printf '\n  }\n}\n'
}

has_capture_device() {
    local line
    [ -d /dev/snd ] || return 1
    [ -r /proc/asound/pcm ] || return 0
    while IFS= read -r line; do
        case "$line" in *": capture "[1-9]*) return 0;; esac
    done < /proc/asound/pcm
    return 1
}

start_capture() {
    local audio card device available params channels rate format timestamp outfile sidecar

    # There is nothing to enumerate until the kernel exposes ALSA nodes.
    has_capture_device || return 1
    audio=$(first_audio_device) || return 1
    card=${audio%%:*}
    device=${audio#*:}
    valid_uint "$card" && valid_uint "$device" || return 1

    mount_volume || return 1
    capture_volume=$exfat_volume
    available=$(df -Pk "$MNT" 2>/dev/null | awk 'NR == 2 { print $4; exit }')
    if ! valid_uint "$available" || [ "$available" -le 102400 ]; then
        [ "$retry_delay" -ge 5 ] || retry_delay=5
        return 1
    fi

    params=$(read_hw_params "$card" "$device")
    IFS='|' read -r channels rate format <<EOF_PARAMS
$params
EOF_PARAMS
    valid_uint "$channels" && [ "$channels" -gt 0 ] || channels=1
    valid_uint "$rate" && [ "$rate" -gt 0 ] || rate=48000
    [ "$rate" -le 48000 ] || rate=48000
    case "$format" in ''|*[!A-Za-z0-9_]*) format=S16_LE;; esac

    timestamp=$(date +%s) || return 1
    outfile="$MNT/${timestamp}_${channels}-${rate}-${format}.raw"
    sidecar="${outfile%.raw}.json"
    # Fast restarts can occur during the same second. Preserve both files
    # from the earlier recording and retry with a different timestamp.
    [ ! -e "$outfile" ] && [ ! -e "$sidecar" ] || return 1
    if ! write_sidecar "${outfile##*/}" "$channels" > "$sidecar"; then
        rm -f "$sidecar"
        return 1
    fi

    # Let ALSA negotiate period and buffer sizes for the selected settings.
    # The maximum values in the dump can imply a delay of several seconds.
    capture_node="/dev/snd/pcmC${card}D${device}c"
    arecord --device="hw:$card,$device" --channels="$channels" \
        --file-type=raw --format="$format" --rate="$rate" > "$outfile" 2>/dev/null &
    capture_pid=$!
    capture_started=$timestamp
}

wait_for_capture() {
    [ "$scan_requested" -ne 0 ] || wait "$capture_pid" 2>/dev/null || :
}

retry_capture() {
    if [ "$scan_requested" -eq 0 ]; then
        sleep "$retry_delay" &
        retry_pid=$!
        # A reload may have arrived before the child PID was assigned.
        if [ "$scan_requested" -eq 0 ]; then
            wait "$retry_pid" 2>/dev/null || :
        else
            kill "$retry_pid" 2>/dev/null || :
        fi
        wait "$retry_pid" 2>/dev/null || :
        retry_pid=
    fi

    if [ "$scan_requested" -ne 0 ]; then
        retry_delay=2
    elif [ "$retry_delay" -lt 30 ]; then
        retry_delay=$((retry_delay * 2))
        [ "$retry_delay" -le 30 ] || retry_delay=30
    fi
}

while :; do
    scan_requested=0
    if [ -n "$capture_pid" ]; then
        # Only a child exit or a reload reaches these checks while recording.
        if kill -0 "$capture_pid" 2>/dev/null && [ -c "$capture_node" ] &&
            find_exfat_volume && [ "$exfat_volume" = "$capture_volume" ] &&
            read_mount && [ "$mount_source" = "$capture_volume" ]
        then
            wait_for_capture
            continue
        fi
        stop_capture
        # A normal recording resets the delay. Repeated ALSA start failures
        # use the same bounded backoff as missing hardware.
        now=$(date +%s)
        [ "$((now - capture_started))" -lt 5 ] || retry_delay=2
    elif start_capture; then
        wait_for_capture
        continue
    fi
    close_volume
    retry_capture
done
EOF_RECORDER

echo "[*] Installing control CLI..."
install_file /usr/sbin/autorecorderctl 0755 <<'EOF_CTL'
#!/bin/sh
# ALSAmrec control helper: START, STOP, STATUS, PROBE.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /usr/share/autorecorder/common.sh

probe_device() {
    local device
    command -v arecord >/dev/null 2>&1 || { echo "arecord not installed"; return 1; }
    device=$(first_audio_device)
    if [ -z "$device" ]; then
        echo "No ALSA capture device found"
        echo "--- arecord -l output ---"
        arecord -l 2>&1 || :
        return 1
    fi
    dump_audio_params "${device%%:*}" "${device#*:}"
}

wait_for_state() {
    local running remaining=2
    while :; do
        running=0
        get_recorder_pids && running=1
        [ "$running" -eq "$1" ] && return 0
        [ "$remaining" -gt 0 ] || return 1
        sleep 1
        remaining=$((remaining - 1))
    done
}

case "${1:-}" in
    [sS][tT][aA][rR][tT])
        get_recorder_pids && { echo "Already running"; exit 0; }
        "$INIT" start >/dev/null 2>&1 || :
        wait_for_state 1 && echo "Started successfully" || { echo "Failed to start"; exit 1; }
        ;;
    [sS][tT][oO][pP])
        get_recorder_pids || { echo "Already stopped"; exit 0; }
        "$INIT" stop >/dev/null 2>&1 || :
        wait_for_state 0 && echo "Stopped successfully" || { echo "Failed to stop"; exit 1; }
        ;;
    [sS][tT][aA][tT][uU][sS])
        if get_recorder_pids; then
            printf 'RUNNING (PID: %s)\n' "$recorder_pids"
        else
            echo "STOPPED"
        fi
        ;;
    [pP][rR][oO][bB][eE])
        get_recorder_pids && { echo "WARNING: recorder is running, stop first to probe!"; exit 1; }
        probe_device
        ;;
    *)
        echo "Usage: $0 START|STOP|STATUS|PROBE"; exit 1
        ;;
esac
EOF_CTL

echo "[*] Installing init script..."
install_file /etc/init.d/autorecorder 0755 <<'EOF_INIT'
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
    procd_set_param reload_signal HUP
    procd_close_instance
}

reload_service() { procd_send_signal autorecorder '*' HUP; }
EOF_INIT

echo "[*] Installing hotplug handlers..."
install_file /etc/hotplug.d/block/49-autorecorder 0755 <<'EOF_HOTPLUG_BLOCK'
#!/bin/sh
logger -t autorecorder "block hotplug: ${ACTION:-unknown} ${DEVNAME:-unknown}"
/etc/init.d/autorecorder reload
EOF_HOTPLUG_BLOCK

install_file /etc/hotplug.d/usb/49-autorecorder 0755 <<'EOF_HOTPLUG_USB'
#!/bin/sh
logger -t autorecorder "usb hotplug: ${ACTION:-unknown} ${PRODUCT:-unknown}"
/etc/init.d/autorecorder reload
EOF_HOTPLUG_USB

echo "[*] Installing CGI endpoint..."
install_file /www/cgi-bin/cm 0755 <<'EOF_CGI'
#!/bin/sh
# ALSAmrec CGI endpoint: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl

printf 'Content-type: text/plain\n\n'
[ "${REQUEST_METHOD:-}" = "GET" ] || { echo "Error: Method not allowed"; exit 1; }
[ -n "${QUERY_STRING:-}" ] || { echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE"; exit 0; }

query=$QUERY_STRING
command=
while [ -n "$query" ]; do
    pair=${query%%&*}
    case "$pair" in
        cmnd=*) command=${pair#*=}; break;;
        cmnd) break;;
    esac
    if [ "$pair" = "$query" ]; then
        break
    fi
    query=${query#*&}
done

case "$command" in
    [sS][tT][aA][rR][tT]|[sS][tT][oO][pP]|[sS][tT][aA][tT][uU][sS]|[pP][rR][oO][bB][eE])
        exec "$CTL" "$command"
        ;;
    *) printf 'Unknown command: <empty>\nValid: START, STOP, STATUS, PROBE\n';;
esac
EOF_CGI
ln -sf /www/cgi-bin/cm /www/cgi-bin/controlweb_cgi

echo "[*] Installing RPCD backend..."
install_file /usr/libexec/rpcd/autorecorder 0755 <<'EOF_RPCD'
#!/bin/sh
# ALSAmrec rpcd plugin: recorder control and stopped-only channel labels.

PATH=/usr/sbin:/usr/bin:/sbin:/bin

case "${1:-}" in
    list)
        echo '{"status":{},"start":{},"stop":{},"probe":{},"recordings":{},"get_channels":{"recording":""},"save_channels":{"recording":"","channels":{}}}'
        exit 0
        ;;
    call) ;;
    *) echo "Usage: $0 list|call <method>" >&2; exit 1;;
esac

. /usr/share/autorecorder/common.sh

# LuCI polls this method. The PID list is numeric and space-separated.
if [ "${2:-}" = status ]; then
    if get_recorder_pids; then
        printf '{"running":true,"status":"RUNNING","pid":"%s","text":"RUNNING (PID: %s)"}\n' \
            "$recorder_pids" "$recorder_pids"
    else
        printf '{"running":false,"status":"STOPPED","pid":"","text":"STOPPED"}\n'
    fi
    exit 0
fi

CTL=/usr/sbin/autorecorderctl
mounted_here=0
temp_file=

. /usr/share/libubox/jshn.sh

load_json() {
    local commands
    # Check the parser exit status before evaluating its output.
    commands=$(jshn "$@" 2>/dev/null) || return 1
    eval "$commands"
}

reply_error() {
    json_init
    json_add_boolean success 0
    if [ "$#" -ge 2 ]; then
        json_add_boolean running "$2"
    fi
    if [ "$#" -ge 3 ]; then
        json_add_string recordings ""
    fi
    json_add_string message "$1"
    json_dump
}

reply_command() {
    local output success=0 running=0
    output=$("$CTL" "$1" 2>&1) && success=1
    get_recorder_pids && running=1
    json_init
    json_add_boolean success "$success"
    json_add_boolean running "$running"
    json_add_string message "$output"
    json_add_string pid "$recorder_pids"
    json_dump
}

reply_probe() {
    local output success=0
    output=$("$CTL" PROBE 2>&1) && success=1
    json_init
    json_add_boolean success "$success"
    json_add_string message "$output"
    json_add_string output "$output"
    json_dump
}

open_volume() {
    get_recorder_pids && return 2
    lock_storage || return 1
    get_recorder_pids && return 2
    mount_volume
}

release_storage() {
    if [ -n "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    if [ "$mounted_here" -eq 1 ] && read_mount && [ "$mount_source" = "$exfat_volume" ]; then
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || :
    fi
    unlock_storage
}

valid_recording_name() {
    case "$1" in
        ''|*..*|*[!A-Za-z0-9._-]*) return 1;;
        *.raw) return 0;;
        *) return 1;;
    esac
}

reply_recordings() {
    local name separator=
    open_volume
    case $? in
        0) ;;
        2) reply_error "Stop recording before editing channel labels." 1 recordings; return;;
        *) reply_error "No unique exFAT recording volume is available." 0 recordings; return;;
    esac

    # Stream a sorted directory listing. Valid recording names need no JSON
    # escaping, and no glob or growing shell variable holds the whole list.
    printf '{"success":true,"running":false,"recordings":"'
    LC_ALL=C ls -1t "$MNT" 2>/dev/null |
        while IFS= read -r name; do
            valid_recording_name "$name" || continue
            [ -f "$MNT/$name" ] && [ -f "$MNT/${name%.raw}.json" ] || continue
            printf '%s%s' "$separator" "$name"
            separator='\n'
        done
    printf '"}\n'
}

open_recording() {
    local running_message=$1 raw_file
    json_get_var recording recording
    if ! valid_recording_name "$recording"; then
        reply_error "Invalid recording filename."
        return 1
    fi
    open_volume
    case $? in
        0) ;;
        2) reply_error "$running_message" 1; return 1;;
        *) reply_error "Unable to mount the exFAT recording volume."; return 1;;
    esac

    raw_file="$MNT/$recording"
    json_file="${raw_file%.raw}.json"
    if [ ! -f "$raw_file" ] || [ ! -f "$json_file" ]; then
        reply_error "The recording or its channel-label JSON file was not found."
        return 1
    fi
}

get_sidecar_keys() {
    local old_prefix status=1
    expected_channels=
    json_set_namespace AR_SIDECAR_ old_prefix
    if load_json -R "$json_file" && json_select channels 2>/dev/null; then
        json_get_keys expected_channels
        status=0
    fi
    json_cleanup
    json_set_namespace "$old_prefix"
    return "$status"
}

reply_get_channels() {
    local request
    request=$(cat)
    load_json -r "$request" || { reply_error "Invalid recording filename."; return; }
    open_recording "Stop recording before editing channel labels." || return 0
    if ! get_sidecar_keys; then
        reply_error "The channel-label JSON file is invalid."
    elif [ -z "$expected_channels" ]; then
        reply_error "No channel definitions were found in the JSON file."
    else
        cat "$json_file"
    fi
}

reply_save_channels() {
    local request submitted_channels expected_count channel label label_type
    local tab='	'
    request=$(cat)
    load_json -r "$request" || { reply_error "Invalid JSON request."; return; }
    open_recording "Channel labels cannot be changed while recording is running." || return 0

    if ! get_sidecar_keys; then
        reply_error "The existing channel-label JSON file is invalid."
        return
    fi
    if [ -z "$expected_channels" ]; then
        reply_error "No channel definitions were found in the JSON file."
        return
    fi
    if ! json_select channels 2>/dev/null; then
        reply_error "No channel labels were submitted."
        return
    fi

    json_get_keys submitted_channels
    set -- $expected_channels
    expected_count=$#
    set -- $submitted_channels
    if [ "$expected_count" -ne "$#" ]; then
        reply_error "The submitted channel list does not match this recording."
        return
    fi

    for channel in $expected_channels; do
        if ! valid_uint "$channel"; then
            reply_error "Invalid channel key in the existing JSON file."
            return
        fi
        if ! json_get_type label_type "$channel"; then
            reply_error "A channel label is missing."
            return
        fi
        json_get_var label "$channel"
        if [ "$label_type" != string ] || [ "${#label}" -gt 80 ]; then
            reply_error "Channel labels must be text of at most 80 characters."
            return
        fi
        case "$label" in *"$tab"*|*'
'*)
            reply_error "Channel labels cannot contain tabs or line breaks."
            return;;
        esac
    done

    # Retain the original JSON encoding and publish it atomically. exFAT
    # presents file modes according to its mount options.
    if get_recorder_pids; then
        reply_error "Recording started; channel labels were not saved." 1
        return
    fi
    if ! temp_file=$(mktemp "$MNT/.autorecorder.XXXXXX") ||
        ! printf '%s\n' "$request" > "$temp_file" ||
        ! mv -f "$temp_file" "$json_file"
    then
        reply_error "Unable to write the channel-label JSON file."
        return
    fi
    temp_file=
    json_init
    json_add_boolean success 1
    json_add_boolean running 0
    json_add_string message "Channel names saved successfully."
    json_add_string recording "$recording"
    json_dump
}

case "${2:-}" in
    start) reply_command START;;
    stop) reply_command STOP;;
    probe) reply_probe;;
    recordings|get_channels|save_channels)
        trap release_storage EXIT
        trap 'exit 1' HUP INT TERM
        "reply_$2"
        ;;
    *)
        json_init
        json_add_boolean success 0
        json_add_string error "Unknown method: ${2:-}"
        json_dump
        ;;
esac
EOF_RPCD

echo "[*] Installing LuCI frontend..."
install_file /www/luci-static/resources/view/autorecorder/main.js 0644 <<'EOF_LUCI_JS'
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus = rpc.declare({ object: 'autorecorder', method: 'status' });
var callStart  = rpc.declare({ object: 'autorecorder', method: 'start'  });
var callStop   = rpc.declare({ object: 'autorecorder', method: 'stop'   });
var callProbe  = rpc.declare({ object: 'autorecorder', method: 'probe'  });
var callRecordings = rpc.declare({ object: 'autorecorder', method: 'recordings' });
var callGetChannels = rpc.declare({
    object: 'autorecorder', method: 'get_channels', params: [ 'recording' ]
});
var callSaveChannels = rpc.declare({
    object: 'autorecorder', method: 'save_channels', params: [ 'recording', 'channels' ]
});

return view.extend({
    render: function() {
        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText  = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em;' }, _('Loading...'));
        var probeOutput = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em; display: none;' });
        var buttons = [];
        var recorderRunning = null;
        var statusRequest = 0;
        var editorRequest = 0;
        var channelInputs = {};
        var channelsLoaded = false;
        var savingLabels = false;
        var editorMessage = E('div', { 'style': 'margin:.5em 0; white-space:pre-wrap;' }, _('Checking recorder status...'));
        var recordingSelect = E('select', { 'class': 'cbi-input-select', 'style': 'min-width: min(100%, 34em);' });
        var channelFields = E('div', { 'style': 'margin-top:.75em;' });
        var saveLabelsButton = E('button', {
            'class': 'btn cbi-button cbi-button-positive',
            'disabled': true,
            'click': function(ev) {
                ev.preventDefault();
                if (recorderRunning !== false || !channelsLoaded) {
                    ui.addNotification(null, E('p', {}, _('Stop the recorder before editing channel labels.')), 'warning');
                    return;
                }
                var recording = recordingSelect.value;
                var labels = {};
                Object.keys(channelInputs).forEach(function(channel) {
                    labels[channel] = channelInputs[channel].value;
                });
                savingLabels = saveLabelsButton.disabled = true;
                callSaveChannels(recording, labels).then(function(res) {
                    if (!res || res.success !== true) {
                        throw new Error((res && res.message) || _('Unable to save channel labels'));
                    }
                    ui.addNotification(null, E('p', {}, res.message || _('Channel names saved')), 'info');
                    if (recording === recordingSelect.value)
                        return loadChannels(recording);
                }).catch(function(err) {
                    ui.addNotification(null, E('p', {}, _('Save failed: ') + err), 'danger');
                }).then(function() {
                    savingLabels = false;
                    updateEditorState();
                });
            }
        }, _('Save channel names'));

        function setBadge(running, label) {
            statusBadge.textContent           = label || (running ? _('RUNNING') : _('STOPPED'));
            statusBadge.style.color           = '#fff';
            statusBadge.style.backgroundColor = running ? '#37a237' : '#a93737';
        }

        function updateEditorState() {
            var enabled = recorderRunning === false && channelsLoaded;
            recordingSelect.disabled = recorderRunning !== false || recordingSelect.options.length === 0;
            Object.keys(channelInputs).forEach(function(channel) {
                channelInputs[channel].disabled = !enabled;
            });
            saveLabelsButton.disabled = !enabled || savingLabels;
            if (recorderRunning === true) {
                editorMessage.textContent = _('Channel-label editing is locked while recording is running. Stop the recorder to edit labels.');
            }
            else if (recorderRunning === null) {
                editorMessage.textContent = _('Waiting for a reliable recorder status; editing remains locked.');
            }
            else if (!channelsLoaded) {
                if (!recordingSelect.options.length)
                    editorMessage.textContent = _('No recording with a channel-label JSON file was found.');
            }
            else {
                editorMessage.textContent = _('Edit the channel names below and save. Changes are written to the selected recording\'s JSON sidecar.');
            }
        }

        function clearChannelFields() {
            while (channelFields.firstChild)
                channelFields.removeChild(channelFields.firstChild);
            channelInputs = {};
            channelsLoaded = false;
            saveLabelsButton.disabled = true;
        }

        function loadChannels(recording) {
            var request = ++editorRequest;
            clearChannelFields();
            if (!recording || recorderRunning !== false) {
                updateEditorState();
                return Promise.resolve();
            }
            editorMessage.textContent = _('Loading channel labels...');
            return callGetChannels(recording).then(function(data) {
                if (request !== editorRequest || recorderRunning !== false)
                    return;
                if (!data || typeof data.channels !== 'object' || !data.channels)
                    throw new Error((data && data.message) || _('Unable to read channel labels'));
                var channels = data.channels || {};
                var keys = Object.keys(channels).sort(function(a, b) { return parseInt(a, 10) - parseInt(b, 10); });
                if (!keys.length)
                    throw new Error(_('No channels were found in this recording\'s JSON file'));
                var fields = document.createDocumentFragment();
                keys.forEach(function(channel) {
                    var input = E('input', {
                        'type': 'text',
                        'class': 'cbi-input-text',
                        'maxlength': '80',
                        'value': channels[channel] || '',
                        'style': 'width: min(100%, 28em);'
                    });
                    var row = E('div', { 'class': 'cbi-value', 'style': 'margin:.35em 0;' }, [
                        E('label', { 'class': 'cbi-value-title', 'style': 'display:inline-block; width:9em;' }, _('Channel ') + channel),
                        E('div', { 'class': 'cbi-value-field', 'style': 'display:inline-block;' }, [ input ])
                    ]);
                    channelInputs[channel] = input;
                    fields.appendChild(row);
                });
                channelFields.appendChild(fields);
                channelsLoaded = true;
                updateEditorState();
            }).catch(function(err) {
                if (request !== editorRequest || recorderRunning !== false)
                    return;
                clearChannelFields();
                editorMessage.textContent = _('Unable to load channel labels: ') + err;
                updateEditorState();
            });
        }

        function loadRecordings() {
            if (recorderRunning !== false)
                return Promise.resolve();
            var request = ++editorRequest;
            editorMessage.textContent = _('Looking for recordings...');
            return callRecordings().then(function(data) {
                if (request !== editorRequest || recorderRunning !== false)
                    return;
                if (!data || data.success !== true || data.running) {
                    if (data && data.running)
                        recorderRunning = true;
                    while (recordingSelect.firstChild)
                        recordingSelect.removeChild(recordingSelect.firstChild);
                    clearChannelFields();
                    editorMessage.textContent = (data && data.message) || _('Unable to list recordings.');
                    updateEditorState();
                    return;
                }
                while (recordingSelect.firstChild)
                    recordingSelect.removeChild(recordingSelect.firstChild);
                var names = data.recordings ? data.recordings.split('\n').filter(Boolean) : [];
                var options = document.createDocumentFragment();
                names.forEach(function(name) {
                    options.appendChild(E('option', { 'value': name }, name));
                });
                recordingSelect.appendChild(options);
                if (!names.length) {
                    clearChannelFields();
                    editorMessage.textContent = _('No recording with a channel-label JSON file was found.');
                    updateEditorState();
                    return;
                }
                recordingSelect.value = names[0];
                return loadChannels(names[0]);
            }).catch(function(err) {
                if (request !== editorRequest || recorderRunning !== false)
                    return;
                clearChannelFields();
                editorMessage.textContent = _('Unable to list recordings: ') + err;
                updateEditorState();
            });
        }

        recordingSelect.addEventListener('change', function() {
            if (recorderRunning === false)
                loadChannels(recordingSelect.value);
        });

        function refreshStatus() {
            var request = ++statusRequest;
            return callStatus().then(function(data) {
                if (request !== statusRequest)
                    return;
                var running = !!data.running;
                var changed = recorderRunning !== running;
                recorderRunning = running;
                var status = data.status || (running ? 'RUNNING' : 'STOPPED');
                var text = data.text || status;
                if (statusBadge.textContent !== status)
                    setBadge(running, status);
                if (statusText.textContent !== text)
                    statusText.textContent = text;
                if (changed) {
                    ++editorRequest;
                    updateEditorState();
                    if (!running)
                        return loadRecordings();
                }
            }).catch(function(err) {
                if (request !== statusRequest)
                    return;
                recorderRunning = null;
                ++editorRequest;
                setBadge(false, _('ERROR'));
                statusText.textContent = _('Unable to read recorder status: ') + err;
                updateEditorState();
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
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Channel labels (JSON editor)')),
                E('p', {}, _('Select a recording and edit its channel names. The editor is available only while the recorder is stopped.')),
                E('div', { 'class': 'cbi-value', 'style': 'margin:.5em 0;' }, [
                    E('label', { 'class': 'cbi-value-title', 'style': 'display:inline-block; width:9em;' }, _('Recording')),
                    E('div', { 'class': 'cbi-value-field', 'style': 'display:inline-block;' }, [ recordingSelect ])
                ]),
                editorMessage,
                channelFields,
                E('div', { 'style': 'margin-top:.75em;' }, [ saveLabelsButton ])
            ])
        ]);
    }
});
EOF_LUCI_JS

echo "[*] Installing LuCI menu and ACL..."
install_file /usr/share/luci/menu.d/autorecorder.json 0644 <<'EOF_MENU'
{
    "admin/autorecorder": {
        "title": "ALSAmrec",
        "action": { "type": "view", "path": "autorecorder/main" },
        "depends": { "acl": [ "luci-app-autorecorder" ] }
    }
}
EOF_MENU

install_file /usr/share/rpcd/acl.d/autorecorder.json 0644 <<'EOF_ACL'
{
    "luci-app-autorecorder": {
        "description": "Grant LuCI access to ALSAmrec",
        "read":  { "ubus": { "autorecorder": [ "status", "probe", "recordings", "get_channels" ] } },
        "write": { "ubus": { "autorecorder": [ "start", "stop", "save_channels" ] } }
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

LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null) || LAN_IP=
LAN_IP=${LAN_IP%%[[:space:]]*}
LAN_IP=${LAN_IP%%/*}
case "$LAN_IP" in
    '') LAN_IP='<your-ip>';;
    *:*) LAN_IP="[$LAN_IP]";;
esac

echo ""
echo "[*] Installation complete. Available endpoints:"
echo "    CGI ¦"
for cmd in START STOP STATUS PROBE; do
    echo "        http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done
echo "    CLI  ¦  autorecorderctl START|STOP|STATUS|PROBE"
echo "    Init ¦  /etc/init.d/autorecorder start|stop|reload|status"
echo "    LuCI ¦  ALSAmrec section (navbar)"
echo "    LuCI channel-label editor: enabled only while recording is stopped."
echo "    Each .raw recording has a matching editable .json channel-label file."
echo ""

printf "A reboot is recommended. Reboot now? [y/N]: "
read -r answer || answer=
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
