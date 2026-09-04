#!/bin/sh
# Installed as /usr/bin/tailscale.
#
# The daemon and the CLI are linked into one binary (the ts_include_cli build
# tag), which is what keeps the image at roughly half the size it would
# otherwise be. tailscaled runs as the CLI when it is invoked under the name
# "tailscale" or when TS_BE_CLI is set.
#
# A symlink would be the tidier trigger, but Docker's COPY dereferences
# symlinks -- it would store a second full copy of the binary and give back
# every byte the combined build saved. Hence the environment variable.
exec env TS_BE_CLI=1 /usr/sbin/tailscaled "$@"
