#!/bin/sh
# LumeRecorder container entrypoint.
#
# As root: fix /data ownership, advertise _lume-recorder._tcp via avahi (needs
# `network_mode: host` to be useful), then drop to the unprivileged `lume`
# user. Started with `--user`, it skips avahi and runs the server directly.
set -eu

PORT="${PORT:-8090}"
DATA_DIR="${DATA_DIR:-/data}"
BIN=/usr/local/bin/lume-recorder

bonjour_enabled() {
    case "$(echo "${BONJOUR:-1}" | tr '[:upper:]' '[:lower:]')" in
        0 | false | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

start_avahi() {
    server_id="$(run_as "$BIN" server-id --data-dir "$DATA_DIR")"
    version="$("$BIN" --version)"
    if [ -n "${SERVER_NAME:-}" ]; then
        name="$(xml_escape "$SERVER_NAME")"
    else
        name="%h"
    fi
    mkdir -p /etc/avahi/services /run/avahi-daemon
    cat > /etc/avahi/services/lume-recorder.service <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">${name}</name>
  <service>
    <type>_lume-recorder._tcp</type>
    <port>${PORT}</port>
    <txt-record>id=${server_id}</txt-record>
    <txt-record>version=${version}</txt-record>
    <txt-record>api=1</txt-record>
  </service>
</service-group>
EOF
    rm -f /run/avahi-daemon/pid
    if avahi-daemon --daemonize --no-chroot; then
        echo "Bonjour: advertising _lume-recorder._tcp on port ${PORT} via avahi"
    else
        echo "Bonjour: avahi-daemon failed to start; add the server manually by host:port" >&2
    fi
}

# `serve` (or bare flags, which mean `serve --flag…`) gets the full setup;
# other subcommands (pair, server-id, --version) run as-is.
case "${1:-serve}" in
    serve) ;;
    --help | -h | --version) exec "$BIN" "$@" ;;
    -*) set -- serve "$@" ;;
    *) exec "$BIN" "$@" ;;
esac
[ $# -eq 0 ] && set -- serve

# The identity the server runs as, decided below. `run_as` runs a command as it.
RUN_UID=""
RUN_GID=""
run_as() {
    if [ "$RUN_UID" = "0" ]; then
        "$@"
    elif [ "$RUN_UID" = "$(id -u lume)" ]; then
        setpriv --reuid=lume --regid=lume --init-groups "$@"
    else
        setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups "$@"
    fi
}

can_write() { # uid gid
    if [ "$1" = "0" ]; then
        test -w "$DATA_DIR"
    else
        setpriv --reuid="$1" --regid="$2" --clear-groups test -w "$DATA_DIR"
    fi
}

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$DATA_DIR"
    lume_uid="$(id -u lume)"
    lume_gid="$(id -g lume)"
    # Best effort: bind mounts shared from a VM (Docker Desktop, Apple
    # `container`) refuse chown, which must not stop the container.
    if [ "$(stat -c %u "$DATA_DIR")" != "$lume_uid" ]; then
        chown -R lume:lume "$DATA_DIR" 2>/dev/null || true
    fi
    owner_uid="$(stat -c %u "$DATA_DIR")"
    owner_gid="$(stat -c %g "$DATA_DIR")"
    if can_write "$lume_uid" "$lume_gid"; then
        RUN_UID="$lume_uid"
        RUN_GID="$lume_gid"
    elif [ "$owner_uid" != "0" ] && can_write "$owner_uid" "$owner_gid"; then
        echo "Data: ${DATA_DIR} can't be handed to the lume user; running as its owner (uid ${owner_uid})"
        RUN_UID="$owner_uid"
        RUN_GID="$owner_gid"
    else
        echo "Data: ${DATA_DIR} is only writable as root; running the server as root" >&2
        RUN_UID=0
        RUN_GID=0
    fi
    if bonjour_enabled; then
        start_avahi
    fi
    # exec, so tini's signals (docker stop) reach the server directly.
    if [ "$RUN_UID" = "0" ]; then
        exec "$BIN" "$@"
    elif [ "$RUN_UID" = "$lume_uid" ]; then
        exec setpriv --reuid=lume --regid=lume --init-groups "$BIN" "$@"
    else
        exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups "$BIN" "$@"
    fi
fi

exec "$BIN" "$@"
