#!/bin/sh
# Entrypoint for the RouterOS container.
#
# Two constraints shape this script:
#   - RouterOS containers get no /dev/net/tun, so tailscaled must run in
#     userspace networking mode. Kernel mode fails immediately at startup.
#   - RouterOS has no process supervisor for what runs inside a container, so
#     if tailscaled dies the container is simply dead until someone notices.
#     The loop at the bottom is what makes this survive unattended.
set -u

STATE_DIR="${TS_STATE_DIR:-/state}"
SOCKET="${TS_SOCKET:-/var/run/tailscale.sock}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
TS_DNS="${TS_DNS:-1.1.1.1}"

mkdir -p "$STATE_DIR" "$(dirname "$SOCKET")"

# RouterOS hands the container no resolver. Without one, every lookup for
# controlplane.tailscale.com fails and the node never reaches login. Only
# write the file when it is missing or empty, so a resolver supplied through
# the container config still wins.
if [ ! -s /etc/resolv.conf ]; then
    echo "nameserver ${TS_DNS}" > /etc/resolv.conf
fi

# Build the argument list once. Using "set --" rather than string
# concatenation keeps values with spaces intact.
set -- --hostname="$TS_HOSTNAME" --accept-dns=false
[ -n "$TS_ROUTES" ] && set -- "$@" --advertise-routes="$TS_ROUTES"
[ -n "$TS_AUTHKEY" ] && set -- "$@" --authkey="$TS_AUTHKEY"
# Intentionally unquoted: TS_EXTRA_ARGS is an escape hatch that must split
# into separate arguments (e.g. "--advertise-exit-node"). Flags belonging to
# features listed in TS_OMIT_FEATURES are not compiled in and will be
# rejected -- --ssh, for one.
# shellcheck disable=SC2086
[ -n "$TS_EXTRA_ARGS" ] && set -- "$@" $TS_EXTRA_ARGS

while :; do
    /usr/sbin/tailscaled \
        --state="${STATE_DIR}/tailscaled.state" \
        --socket="$SOCKET" \
        --tun=userspace-networking &
    daemon_pid=$!

    # Poll for the control socket rather than sleeping a fixed interval. On a
    # busy router first startup can take far longer than any constant worth
    # hardcoding, and a too-short sleep makes "tailscale up" fail on a
    # perfectly healthy daemon.
    waited=0
    while [ ! -S "$SOCKET" ] && [ "$waited" -lt 90 ]; do
        kill -0 "$daemon_pid" 2>/dev/null || break
        waited=$((waited + 1))
        sleep 1
    done

    if [ -S "$SOCKET" ]; then
        echo "tailscaled ready after ${waited}s; bringing the node up"
        # A failure here is not fatal: the daemon keeps running, and an
        # already-authenticated node reconnects on its own.
        /usr/bin/tailscale --socket="$SOCKET" up "$@" \
            || echo "warning: 'tailscale up' failed; daemon left running"
    else
        echo "warning: control socket never appeared after ${waited}s"
    fi

    wait "$daemon_pid"
    echo "tailscaled exited with status $?; restarting in 5s"
    sleep 5
done
