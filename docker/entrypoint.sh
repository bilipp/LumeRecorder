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
    server_id="$(setpriv --reuid=lume --regid=lume --init-groups "$BIN" server-id --data-dir "$DATA_DIR")"
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

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$DATA_DIR"
    if [ "$(stat -c %u "$DATA_DIR")" != "$(id -u lume)" ]; then
        chown -R lume:lume "$DATA_DIR"
    fi
    if bonjour_enabled; then
        start_avahi
    fi
    exec setpriv --reuid=lume --regid=lume --init-groups "$BIN" "$@"
fi

exec "$BIN" "$@"
