#!/bin/sh

# ALSAmrec uninstaller for the v3.2 installer

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '[*] %s\n' "$*"; }

restore_or_remove() {
    target="$1"
    backup="${target}.bak-autorecorder"

    if [ -e "$backup" ]; then
        info "Restoring $target from backup"
        mv -f "$backup" "$target"
    elif [ -L "$target" ] || [ -e "$target" ]; then
        info "Removing $target"
        rm -f "$target"
    fi
}

remove_if_empty_dir() {
    dir="$1"
    [ -d "$dir" ] || return 0
    rmdir "$dir" 2>/dev/null || true
}

info "Stopping ALSAmrec service"
/etc/init.d/autorecorder stop >/dev/null 2>&1 || true
/etc/init.d/autorecorder disable >/dev/null 2>&1 || true
killall recorder 2>/dev/null || true

info "Removing CGI compatibility symlink"
rm -f /www/cgi-bin/controlweb_cgi

info "Restoring or removing installed files"
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
    restore_or_remove "$f"
done

info "Restarting rpcd"
/etc/init.d/rpcd restart >/dev/null 2>&1 || \
service rpcd restart >/dev/null 2>&1 || \
warn "Could not restart rpcd"

info "Cleaning up empty directories if possible"
remove_if_empty_dir /www/luci-static/resources/view/autorecorder

info "Uninstall complete"
info "Packages installed by the original installer were not removed."
info "Remove them manually if desired:"
info "opkg remove rpcd luci-base alsa-utils usbutils kmod-usb-audio kmod-usb-storage block-mount kmod-fs-exfat"
