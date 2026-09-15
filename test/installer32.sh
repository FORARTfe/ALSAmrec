#!/bin/sh
#
# ALSAmrec installer v3.2
# CLI + CGI + LuCI — full stack, single installer.
#
# Original recorder daemon by J. Bruce Fields, 2024.
# LuCI/CGI port and OpenWrt fixes by FORART, 2025-26.
# GPL v3 — see <https://www.gnu.org/licenses/>
#
# v3.2 changes:
#   - shared helper library (/usr/lib/alsamrec/common.sh) removes the
#     triplicated pid/device/partition code
#   - recorder idle loop no longer blocks forever when no media is present
#   - START/STOP poll for the state change instead of sleeping a fixed 2 s
#   - apk and opkg are both supported (OpenWrt 25.12 dropped opkg)
#   - channel labels: TAKES / LABELS verbs, CGI + ubus + LuCI front ends
#

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

PACKAGES="rpcd luci-base alsa-utils usbutils kmod-usb-audio kmod-usb-storage block-mount kmod-fs-exfat"

warn()         { printf 'WARNING: %s\n' "$*" >&2; }
backup_file()  { [ -e "$1" ] && [ ! -e "${1}.bak-autorecorder" ] && cp -p "$1" "${1}.bak-autorecorder" || true; }
install_file() { cat > "$1"; chmod "$2" "$1"; }

echo "[*] Updating package lists..."
if command -v apk >/dev/null 2>&1; then
    apk update || warn "apk update failed; trying installation anyway."
    apk add $PACKAGES || warn "Some packages could not be installed."
elif command -v opkg >/dev/null 2>&1; then
    opkg update || warn "opkg update failed; trying installation anyway."
    opkg install $PACKAGES || warn "Some packages could not be installed."
else
    warn "Neither apk nor opkg found; skipping package installation."
fi

echo "[*] Creating directories..."
mkdir -p \
    /usr/sbin \
    /usr/lib/alsamrec \
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
    /usr/lib/alsamrec/common.sh \
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

echo "[*] Installing shared helper library..."
install_file /usr/lib/alsamrec/common.sh 0644 <<'EOF_COMMON'
#!/bin/sh
# ALSAmrec shared helpers — sourced by recorder, autorecorderctl and the
# rpcd plugin. Not executable on its own. GPL v3.
#
# Recording file name contract:  <epoch>_<channels>-<rate>-<format>.raw
# Channel labels file:           <epoch>_<channels>-<rate>-<format>.labels.json

ALSAMREC_MNT=${ALSAMREC_MNT:-/tmp/mnt}
ALSAMREC_RECORDER=/usr/sbin/recorder
ALSAMREC_MIN_FREE_KB=102400
ALSAMREC_MAX_TAKES=50          # cap the ubus/CLI listing, not the media

valid_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

# --- process state ----------------------------------------------------------

find_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$ALSAMREC_RECORDER" 2>/dev/null || true
        return
    fi
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)
        case "$cmd" in *"$ALSAMREC_RECORDER"*) printf '%s\n' "${proc#/proc/}" ;; esac
    done
}

pid_list()   { find_pids | awk 'NF{printf "%s%s",sep,$1;sep=" "}END{print ""}'; }
is_running() { [ -n "$(pid_list)" ]; }

# --- hardware discovery -----------------------------------------------------

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

# --- media mount ------------------------------------------------------------
# media_hold() mounts only if nobody else has; media_release() unmounts only
# what media_hold() mounted, so callers never pull the media out from under a
# running recorder.

media_is_mounted() { grep -qs " $ALSAMREC_MNT " /proc/mounts; }

media_hold() {
    if media_is_mounted; then
        ALSAMREC_MOUNTED_BY_US=0
        return 0
    fi
    disk=$(find_single_exfat_partition || true)
    [ -n "$disk" ] || return 1
    mkdir -p "$ALSAMREC_MNT"
    mount "$disk" "$ALSAMREC_MNT" 2>/dev/null || return 1
    ALSAMREC_MOUNTED_BY_US=1
}

media_release() {
    [ "${ALSAMREC_MOUNTED_BY_US:-0}" = 1 ] && umount -l "$ALSAMREC_MNT" 2>/dev/null
    ALSAMREC_MOUNTED_BY_US=0
    return 0
}

# --- takes ------------------------------------------------------------------

take_list()   { ls -1 "$ALSAMREC_MNT" 2>/dev/null | grep '\.raw$' | sort -r; }
latest_take() { take_list | head -n 1; }

# Reject anything that is not a plain take file living on the media: the take
# name reaches us from an unauthenticated CGI query string.
take_valid() {
    case "${1:-}" in
        ''|*/*|*..*) return 1 ;;
        *.raw)       ;;
        *)           return 1 ;;
    esac
    [ -f "$ALSAMREC_MNT/$1" ]
}

# <epoch>_<channels>-<rate>-<format>.raw  ->  field
take_meta() { base=${1%.raw}; case "$base" in *_*) printf '%s' "${base#*_}" ;; esac; }
take_channels() { m=$(take_meta "$1"); c=${m%%-*}; valid_uint "$c" && printf '%s\n' "$c"; }
take_rate()     { m=$(take_meta "$1"); r=${m#*-}; r=${r%%-*}; valid_uint "$r" && printf '%s\n' "$r"; }
take_format()   { m=$(take_meta "$1"); f=${m#*-}; case "$f" in *-*) printf '%s\n' "${f#*-}" ;; esac; }

# --- channel labels ---------------------------------------------------------

labels_path() { printf '%s/%s.labels.json\n' "$ALSAMREC_MNT" "${1%.raw}"; }
labels_exist() { [ -f "$(labels_path "$1")" ]; }

# Drop control characters, escape for a JSON string. Deliberately byte-safe:
# no truncation, so a multi-byte UTF-8 name is never cut in half.
json_escape() {
    printf '%s' "${1:-}" | tr '[:cntrl:]' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_unescape() { printf '%s' "${1:-}" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'; }

# labels_write <take> [name1 name2 ...]
# Missing names become empty strings; extra names are ignored. Written to a
# temp file and renamed so a half-written file never replaces a good one.
labels_write() {
    take=$1; shift
    ch=$(take_channels "$take") || return 1
    out=$(labels_path "$take")
    tmp="${out}.tmp"

    { printf '{\n'
      i=1
      while [ "$i" -le "$ch" ]; do
          [ "$i" -lt "$ch" ] && sep=',' || sep=''
          printf '  "CHANNEL%s": "%s"%s\n' "$i" "$(json_escape "${1:-}")" "$sep"
          [ "$#" -gt 0 ] && shift
          i=$((i + 1))
      done
      printf '}\n'
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

    mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 1; }
    sync
}

# Create an all-empty labels file, but never clobber an existing one.
labels_skeleton() { labels_exist "$1" && return 0; labels_write "$1"; }

# labels_read <take> — one value per channel, one per line, always exactly
# <channels> lines. Parses the layout labels_write() produces; a hand-edited
# file in a different layout yields empty values rather than an error.
labels_read() {
    take=$1
    ch=$(take_channels "$take") || return 1
    f=$(labels_path "$take")
    i=1
    while [ "$i" -le "$ch" ]; do
        if [ -f "$f" ]; then
            v=$(sed -n "s/^[[:space:]]*\"CHANNEL$i\"[[:space:]]*:[[:space:]]*\"\(.*\)\",\{0,1\}[[:space:]]*$/\1/p" "$f" | head -n 1)
        else
            v=""
        fi
        json_unescape "$v"
        printf '\n'
        i=$((i + 1))
    done
}
EOF_COMMON

echo "[*] Installing recorder daemon..."
install_file /usr/sbin/recorder 0755 <<'EOF_RECORDER'
#!/bin/sh
# ALSAmrec recorder daemon — GPL v3

PATH=/usr/sbin:/usr/bin:/sbin:/bin
COMMON=/usr/lib/alsamrec/common.sh
[ -r "$COMMON" ] || { logger -t autorecorder "missing $COMMON"; exit 1; }
. "$COMMON"

MNT=$ALSAMREC_MNT
ERRLOG=/tmp/alsamrec.err
recorder=""

cleanup_recorder() {
    [ -n "$recorder" ] || return
    kill "$recorder" 2>/dev/null || true
    wait "$recorder" 2>/dev/null || true
    recorder=""
}

cleanup_mount() {
    grep -qs " $MNT " /proc/mounts && umount -l "$MNT" 2>/dev/null || true
}

on_term() {
    cleanup_recorder
    cleanup_mount
    exit 0
}

trap :       HUP       # wakes wait()/sleep on procd reload or hotplug
trap on_term INT TERM

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

while :; do
    # Reap a recorder that exited on its own (disk full, device unplugged).
    if [ -n "$recorder" ] && [ ! -e "/proc/$recorder" ]; then
        recorder=""
        cleanup_mount
    fi

    audio_dev=$(find_audio_device || true)
    disk=$(find_single_exfat_partition || true)

    # Not ready — poll. SIGHUP from hotplug cuts the sleep short.
    if [ -z "$audio_dev" ] || [ -z "$disk" ]; then
        cleanup_recorder
        cleanup_mount
        sleep 5
        continue
    fi

    # Already recording — block here until arecord exits or hotplug wakes us.
    if [ -n "$recorder" ]; then
        wait "$recorder" 2>/dev/null || true
        continue
    fi

    card_num=${audio_dev%%:*}; dev_num=${audio_dev##*:}
    valid_uint "$card_num" || continue
    valid_uint "$dev_num"  || continue

    mkdir -p "$MNT"
    grep -qs " $MNT " /proc/mounts || mount "$disk" "$MNT" || { sleep 5; continue; }

    avail_kb=$(df -k "$MNT" 2>/dev/null | awk 'NR==2{print $4}')
    if ! valid_uint "${avail_kb:-}" || [ "$avail_kb" -le "$ALSAMREC_MIN_FREE_KB" ]; then
        logger -t autorecorder "not enough free space on $disk"
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

    # stderr kept in /tmp so a failed capture can be diagnosed after the fact.
    if valid_uint "$buf_time" && valid_uint "$buf_size"; then
        arecord --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" --file-type=raw --format="$bitfmt" \
            --rate="$max_rate" --buffer-time="$buf_time" --buffer-size="$buf_size" \
            > "$outfile" 2>"$ERRLOG" &
    else
        arecord --device="hw:${card_num},${dev_num}" \
            --channels="$max_ch" --file-type=raw --format="$bitfmt" \
            --rate="$max_rate" \
            > "$outfile" 2>"$ERRLOG" &
    fi
    recorder=$!
    logger -t autorecorder "recording ${max_ch}ch ${max_rate}Hz ${bitfmt} -> $outfile"
done
EOF_RECORDER

echo "[*] Installing control CLI..."
install_file /usr/sbin/autorecorderctl 0755 <<'EOF_CTL'
#!/bin/sh
# ALSAmrec control helper: START, STOP, STATUS, PROBE, TAKES, LABELS.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
COMMON=/usr/lib/alsamrec/common.sh
[ -r "$COMMON" ] || { echo "missing $COMMON" >&2; exit 1; }
. "$COMMON"

INIT=/etc/init.d/autorecorder
WAIT_SECS=10

usage() {
    cat >&2 <<USAGE
Usage: autorecorderctl <command>
  START | STOP | STATUS | PROBE
  TAKES                              list recordings and their label state
  LABELS [-t <take>] [name ...]      write <take>.labels.json (latest take
                                     by default); recorder must be stopped
USAGE
    exit 1
}

# wait_state running|stopped <seconds>
wait_state() {
    i=0
    while [ "$i" -lt "$2" ]; do
        case "$1" in
            running) is_running && return 0 ;;
            stopped) is_running || return 0 ;;
        esac
        sleep 1
        i=$((i + 1))
    done
    return 1
}

probe_device() {
    command -v arecord >/dev/null 2>&1 || { echo "arecord not installed"; return 1; }
    audio_dev=$(find_audio_device || true)
    if [ -z "$audio_dev" ]; then
        echo "No ALSA capture device found"
        echo "--- arecord -l output ---"
        arecord -l 2>&1 || true
        return 1
    fi
    arecord -D "hw:${audio_dev%%:*},${audio_dev##*:}" --dump-hw-params 2>&1
}

# Called right after a successful STOP: pre-create the empty labels file for
# the take that just ended, so there is always something to fill in.
post_stop_labels() {
    media_hold || { echo "Note: no exFAT media found, labels file not created."; return 0; }
    take=$(latest_take)
    if [ -z "$take" ]; then
        echo "Note: no recordings on media, labels file not created."
    elif labels_exist "$take"; then
        echo "Labels file: $(labels_path "$take") (kept)"
    elif labels_skeleton "$take"; then
        echo "Labels file: $(labels_path "$take") ($(take_channels "$take") empty channels)"
    else
        echo "WARNING: could not write labels file for $take" >&2
    fi
    media_release
}

cmd_takes() {
    media_hold || { echo "No exFAT media mounted"; return 1; }
    found=0
    for take in $(take_list | head -n "$ALSAMREC_MAX_TAKES"); do
        found=1
        labels_exist "$take" && state="labelled" || state="unlabelled"
        printf '%s  %sch  %sHz  %s  %s\n' \
            "$take" "$(take_channels "$take")" "$(take_rate "$take")" \
            "$(take_format "$take")" "$state"
    done
    [ "$found" -eq 1 ] || echo "No recordings found"
    media_release
}

cmd_labels() {
    is_running && { echo "WARNING: recorder is running, stop it before writing labels!"; return 1; }

    take=""
    if [ "${1:-}" = "-t" ]; then
        [ "$#" -ge 2 ] || usage
        take=$2; shift 2
    fi

    media_hold || { echo "No exFAT media mounted"; return 1; }

    [ -n "$take" ] || take=$(latest_take)
    if [ -z "$take" ]; then
        echo "No recordings found"; media_release; return 1
    fi
    if ! take_valid "$take"; then
        echo "Not a valid take: $take"; media_release; return 1
    fi

    ch=$(take_channels "$take") || { echo "Cannot read channel count from $take"; media_release; return 1; }
    if [ "$#" -gt "$ch" ]; then
        echo "Note: $take has $ch channels, $(($# - ch)) extra name(s) ignored."
    fi

    if labels_write "$take" "$@"; then
        echo "Wrote $(labels_path "$take") ($ch channels)"
        rc=0
    else
        echo "Could not write labels file (media full or read-only?)" >&2
        rc=1
    fi
    media_release
    return $rc
}

[ "$#" -ge 1 ] || usage
cmd=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
shift

case "$cmd" in
    START)
        is_running && { echo "Already running"; exit 0; }
        "$INIT" start >/dev/null 2>&1 || true
        wait_state running "$WAIT_SECS" || { echo "Failed to start"; exit 1; }
        echo "Started successfully"
        ;;
    STOP)
        is_running || { echo "Already stopped"; exit 0; }
        "$INIT" stop >/dev/null 2>&1 || true
        wait_state stopped "$WAIT_SECS" || { echo "Failed to stop"; exit 1; }
        echo "Stopped successfully"
        post_stop_labels
        ;;
    STATUS)
        pids=$(pid_list)
        [ -n "$pids" ] && echo "RUNNING (PID: $pids)" || echo "STOPPED"
        ;;
    PROBE)
        is_running && { echo "WARNING: recorder is running, stop first to probe!"; exit 1; }
        probe_device
        ;;
    TAKES)
        cmd_takes
        ;;
    LABELS)
        cmd_labels "$@"
        ;;
    *)
        usage
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
    procd_set_param reload_signal SIGHUP
    procd_close_instance
}

reload_service() { procd_send_signal autorecorder; }
EOF_INIT

echo "[*] Installing hotplug handlers..."
install_file /etc/hotplug.d/block/49-autorecorder 0755 <<'EOF_HOTPLUG_BLOCK'
#!/bin/sh
case "${ACTION:-}" in add|remove) ;; *) exit 0 ;; esac
logger -t autorecorder "block hotplug: ${ACTION} ${DEVNAME:-unknown}"
service autorecorder reload
EOF_HOTPLUG_BLOCK

install_file /etc/hotplug.d/usb/49-autorecorder 0755 <<'EOF_HOTPLUG_USB'
#!/bin/sh
case "${ACTION:-}" in add|remove) ;; *) exit 0 ;; esac
logger -t autorecorder "usb hotplug: ${ACTION} ${PRODUCT:-unknown}"
service autorecorder reload
EOF_HOTPLUG_USB

echo "[*] Installing CGI endpoint..."
install_file /www/cgi-bin/cm 0755 <<'EOF_CGI'
#!/bin/sh
# ALSAmrec CGI endpoint:
#   /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE|TAKES
#   /cgi-bin/cm?cmnd=LABELS&take=<file>&ch1=<name>&ch2=<name>...
# take= is optional and defaults to the most recent recording.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl
MAX_CH=64

echo "Content-type: text/plain"
echo ""

[ "${REQUEST_METHOD:-}" = "GET" ] || { echo "Error: Method not allowed"; exit 1; }
[ -n "${QUERY_STRING:-}" ]        || { echo "Usage: /cgi-bin/cm?cmnd=START|STOP|STATUS|PROBE|TAKES|LABELS"; exit 0; }

# Robust key=value parser — handles multiple params in any order.
get_param() {
    qs=${QUERY_STRING:-}
    while [ -n "$qs" ]; do
        pair=${qs%%&*}; [ "$pair" = "$qs" ] && qs="" || qs=${qs#*&}
        [ "${pair%%=*}" = "$1" ] && { printf '%s' "${pair#*=}"; return 0; }
    done
    return 1
}

# %XX and + decoding, byte-wise so UTF-8 names survive intact.
urldecode() {
    printf '%s' "${1:-}" | awk '
        function hexval(h,   d, i, c, v) {
            d = 0
            for (i = 1; i <= length(h); i++) {
                c = tolower(substr(h, i, 1))
                v = index("0123456789abcdef", c) - 1
                d = d * 16 + v
            }
            return d
        }
        {
            gsub(/\+/, " ")
            out = ""; n = length($0); i = 1
            while (i <= n) {
                c = substr($0, i, 1)
                if (c == "%" && i + 2 <= n) {
                    h = substr($0, i + 1, 2)
                    if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
                        out = out sprintf("%c", hexval(h)); i += 3; continue
                    }
                }
                out = out c; i++
            }
            printf "%s", out
        }'
}

CMND=$(get_param cmnd 2>/dev/null | tr '[:lower:]' '[:upper:]')
case "$CMND" in
    START|STOP|STATUS|PROBE|TAKES)
        "$CTL" "$CMND"
        ;;
    LABELS)
        take=$(urldecode "$(get_param take 2>/dev/null || true)")

        # Highest chN actually present decides how many names we pass, so a
        # deliberately empty middle channel is preserved.
        last=0; i=1
        while [ "$i" -le "$MAX_CH" ]; do
            get_param "ch$i" >/dev/null 2>&1 && last=$i
            i=$((i + 1))
        done

        set --
        i=1
        while [ "$i" -le "$last" ]; do
            set -- "$@" "$(urldecode "$(get_param "ch$i" 2>/dev/null || true)")"
            i=$((i + 1))
        done

        if [ -n "$take" ]; then
            "$CTL" LABELS -t "$take" "$@"
        else
            "$CTL" LABELS "$@"
        fi
        ;;
    *)
        printf 'Unknown command: %s\nValid: START, STOP, STATUS, PROBE, TAKES, LABELS\n' "${CMND:-<empty>}"
        ;;
esac
EOF_CGI
ln -sf /www/cgi-bin/cm /www/cgi-bin/controlweb_cgi

echo "[*] Installing RPCD backend..."
install_file /usr/libexec/rpcd/autorecorder 0755 <<'EOF_RPCD'
#!/bin/sh
# ALSAmrec rpcd plugin — exposes status/start/stop/probe/takes/labels over ubus.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/autorecorderctl
COMMON=/usr/lib/alsamrec/common.sh

. /usr/share/libubox/jshn.sh
[ -r "$COMMON" ] && . "$COMMON"

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

# Reads the media directly rather than parsing CLI output, so the LuCI view
# gets the channel count and the existing names in one round trip.
reply_takes() {
    tmp_takes=/tmp/alsamrec-takes.$$
    tmp_names=/tmp/alsamrec-names.$$

    if media_hold; then
        take_list | head -n "$ALSAMREC_MAX_TAKES" > "$tmp_takes" 2>/dev/null || : > "$tmp_takes"
    else
        : > "$tmp_takes"
    fi

    json_init
    json_bool success 1
    json_add_array takes
    while IFS= read -r take; do
        [ -n "$take" ] || continue
        ch=$(take_channels "$take") || continue
        json_add_object ""
        json_add_string file "$take"
        json_add_int channels "$ch"
        json_add_string rate "$(take_rate "$take")"
        json_add_string format "$(take_format "$take")"
        labels_exist "$take" && json_bool labelled 1 || json_bool labelled 0
        json_add_array names
        labels_read "$take" > "$tmp_names" 2>/dev/null || : > "$tmp_names"
        while IFS= read -r name; do json_add_string "" "$name"; done < "$tmp_names"
        json_close_array
        json_close_object
    done < "$tmp_takes"
    json_close_array
    json_dump

    media_release
    rm -f "$tmp_takes" "$tmp_names"
}

# Args: { "take": "<file>", "names": [ "CHANNEL1", "CHANNEL2", ... ] }
# Delegates to the CLI so the write path — and the "recorder must be stopped"
# rule — lives in exactly one place.
reply_labels() {
    args=$(cat)
    take=""
    set --
    if json_load "$args" 2>/dev/null; then
        json_get_var take take 2>/dev/null || take=""
        if json_select names 2>/dev/null; then
            idx=1
            while json_get_type ntype "$idx" 2>/dev/null && [ "$ntype" = string ]; do
                json_get_var nval "$idx"
                set -- "$@" "$nval"
                idx=$((idx + 1))
            done
            json_select .. 2>/dev/null
        fi
    fi

    if [ -n "$take" ]; then
        output=$($CTL LABELS -t "$take" "$@" 2>&1); rc=$?
    else
        output=$($CTL LABELS "$@" 2>&1); rc=$?
    fi

    json_init
    [ "$rc" -eq 0 ] && json_bool success 1 || json_bool success 0
    json_add_string message "$output"
    json_dump
}

case "${1:-}" in
    list)
        echo '{"status":{},"start":{},"stop":{},"probe":{},"takes":{},"labels":{"take":"","names":[]}}'
        ;;
    call)
        case "${2:-}" in
            status) reply_status       ;;
            start)  reply_command START ;;
            stop)   reply_command STOP  ;;
            probe)  reply_probe         ;;
            takes)  reply_takes         ;;
            labels) reply_labels        ;;
            *)
                json_init; json_bool success 0
                json_add_string error "Unknown method: ${2:-}"; json_dump ;;
        esac ;;
    *) echo "Usage: $0 list|call <method>" >&2; exit 1 ;;
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
var callTakes  = rpc.declare({ object: 'autorecorder', method: 'takes'  });
var callLabels = rpc.declare({ object: 'autorecorder', method: 'labels', params: [ 'take', 'names' ] });

return view.extend({
    render: function() {
        var statusBadge = E('span', { 'class': 'badge' }, _('Unknown'));
        var statusText  = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em;' }, _('Loading...'));
        var probeOutput = E('pre',  { 'style': 'white-space: pre-wrap; margin-top: 1em; display: none;' });
        var buttons = [];

        var takes       = [];
        var labelInputs = [];
        var takeSelect  = E('select', { 'class': 'cbi-input-select' });
        var labelRows   = E('div', { 'style': 'margin-top: 1em;' });
        var labelHint   = E('div', { 'class': 'cbi-value-description', 'style': 'display: none;' },
            _('Stop the recorder to edit channel labels.'));
        var saveButton;
        var reloadButton;

        function setBadge(running, label) {
            statusBadge.textContent           = label || (running ? _('RUNNING') : _('STOPPED'));
            statusBadge.style.color           = '#fff';
            statusBadge.style.backgroundColor = running ? '#37a237' : '#a93737';
        }

        function setLabelsEnabled(enabled) {
            takeSelect.disabled  = !enabled;
            saveButton.disabled  = !enabled || !takeSelect.value;
            labelHint.style.display = enabled ? 'none' : '';
            for (var i = 0; i < labelInputs.length; i++)
                labelInputs[i].disabled = !enabled;
        }

        function refreshStatus() {
            return callStatus().then(function(data) {
                var running = !!data.running;
                setBadge(running, data.status || (running ? 'RUNNING' : 'STOPPED'));
                statusText.textContent = data.text || (running ? 'RUNNING' : 'STOPPED');
                setLabelsEnabled(!running);
            }).catch(function(err) {
                setBadge(false, _('ERROR'));
                statusText.textContent = _('Unable to read recorder status: ') + err;
            });
        }

        function currentTake() {
            for (var i = 0; i < takes.length; i++)
                if (takes[i].file === takeSelect.value) return takes[i];
            return null;
        }

        function rebuildLabelInputs() {
            labelRows.innerHTML = '';
            labelInputs = [];

            var take = currentTake();
            if (!take) return;

            for (var c = 0; c < take.channels; c++) {
                var names = take.names || [];
                var input = E('input', {
                    'type': 'text',
                    'class': 'cbi-input-text',
                    'value': names[c] || '',
                    'placeholder': _('unnamed'),
                    'maxlength': 64
                });
                labelInputs.push(input);
                labelRows.appendChild(E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, 'CHANNEL' + (c + 1)),
                    E('div', { 'class': 'cbi-value-field' }, input)
                ]));
            }
        }

        function refreshTakes() {
            return callTakes().then(function(data) {
                var previous = takeSelect.value;
                takes = Array.isArray(data.takes) ? data.takes : [];
                takeSelect.innerHTML = '';

                if (!takes.length) {
                    takeSelect.appendChild(E('option', { 'value': '' }, _('No recordings found')));
                    labelRows.innerHTML = '';
                    labelInputs = [];
                    saveButton.disabled = true;
                    return;
                }

                takes.forEach(function(t) {
                    takeSelect.appendChild(E('option', { 'value': t.file },
                        t.file + '  (' + t.channels + ' ch, ' + (t.labelled ? _('labelled') : _('unlabelled')) + ')'));
                });

                takeSelect.value = previous;
                if (!takeSelect.value) takeSelect.value = takes[0].file;

                rebuildLabelInputs();
                saveButton.disabled = takeSelect.disabled;
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Unable to list recordings: ') + err), 'warning');
            });
        }

        function saveLabels() {
            var take = takeSelect.value;
            if (!take) return Promise.resolve();

            var names = labelInputs.map(function(input) { return input.value || ''; });
            saveButton.disabled = true;

            return callLabels(take, names).then(function(res) {
                ui.addNotification(null, E('p', {}, res.message || _('Channel labels saved')),
                    res.success === false ? 'warning' : 'info');
                return refreshTakes();
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Could not save labels: ') + err), 'danger');
            }).then(function() {
                saveButton.disabled = false;
            });
        }

        function setButtonsDisabled(disabled) {
            for (var i = 0; i < buttons.length; i++) buttons[i].disabled = disabled;
        }

        function runCommand(fn, doneMessage, showProbe, reloadTakes) {
            setButtonsDisabled(true);
            probeOutput.style.display = 'none';
            return fn().then(function(res) {
                var msg = res.message || doneMessage;
                ui.addNotification(null, E('p', {}, msg), res.success === false ? 'warning' : 'info');
                if (showProbe) { probeOutput.style.display = ''; probeOutput.textContent = res.output || msg; }
                return refreshStatus().then(function() {
                    return reloadTakes ? refreshTakes() : null;
                });
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, _('Command failed: ') + err), 'danger');
            }).then(function() { setButtonsDisabled(false); });
        }

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'click': function(ev) { ev.preventDefault(); return runCommand(callStart, _('Start command sent'), false, false); }
        }, _('START')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-negative', 'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return runCommand(callStop, _('Stop command sent'), false, true); }
        }, _('STOP')));

        buttons.push(E('button', {
            'class': 'btn cbi-button cbi-button-neutral', 'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return runCommand(callProbe, _('Probe completed'), true, false); }
        }, _('PROBE')));

        saveButton = E('button', {
            'class': 'btn cbi-button cbi-button-save',
            'click': function(ev) { ev.preventDefault(); return saveLabels(); }
        }, _('Save labels'));

        reloadButton = E('button', {
            'class': 'btn cbi-button cbi-button-neutral', 'style': 'margin-left:.5em;',
            'click': function(ev) { ev.preventDefault(); return refreshTakes(); }
        }, _('Reload list'));

        takeSelect.addEventListener('change', rebuildLabelInputs);

        refreshStatus();
        refreshTakes();
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
                E('h3', {}, _('Channel labels')),
                E('div', { 'class': 'cbi-section-descr' },
                    _('Name the channels of a recording. Saved next to the take on the media as <take>.labels.json.')),
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, _('Recording')),
                    E('div', { 'class': 'cbi-value-field' }, [ takeSelect, reloadButton ])
                ]),
                labelHint,
                labelRows,
                E('div', { 'style': 'margin-top:1em;' }, saveButton)
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
        "read":  { "ubus": { "autorecorder": [ "status", "probe", "takes" ] } },
        "write": { "ubus": { "autorecorder": [ "start",  "stop",  "labels" ] } }
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
[ -r /usr/share/libubox/jshn.sh ]  || warn "jshn.sh not found — the ubus/LuCI backend will not work."

LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '<your-ip>')

echo ""
echo "[*] Installation complete. Available endpoints:"
echo "    CGI  ¦"
for cmd in START STOP STATUS PROBE TAKES; do
    echo "        http://${LAN_IP}/cgi-bin/cm?cmnd=${cmd}"
done
echo "        http://${LAN_IP}/cgi-bin/cm?cmnd=LABELS&ch1=Kick&ch2=Snare"
echo "    CLI  ¦  autorecorderctl START|STOP|STATUS|PROBE|TAKES"
echo "         ¦  autorecorderctl LABELS [-t <take>] <name1> <name2> ..."
echo "    Init ¦  /etc/init.d/autorecorder start|stop|reload|status"
echo "    LuCI ¦  ALSAmrec section (navbar) — status + channel labels"
echo ""
echo "    Every STOP issued through autorecorderctl (CLI, CGI or LuCI) creates"
echo "    an empty <take>.labels.json next to the recording, ready to fill in."
echo ""

printf "A reboot is recommended. Reboot now? [y/N]: "
read -r answer
case "$answer" in
    [yY]*) echo "Rebooting..."; reboot ;;
    *)     echo "Please reboot manually when ready." ;;
esac
