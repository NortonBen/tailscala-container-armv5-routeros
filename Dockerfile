# Tailscale for MikroTik routers on the EN7562CT SoC (hEX Refresh / hEX S).
#
# Those routers execute ARMv5 only, and no published Tailscale image targets
# it -- every official and community image is v6 or newer, which is why they
# die with "signal 4 (Illegal instruction)" on this hardware. Alpine is not an
# option either: it publishes arm/v6 and arm/v7 and no ARMv5 variant at all.
# busybox is one of the few bases that still ships arm/v5.
ARG BASE_PLATFORM=linux/arm/v5
ARG BASE_IMAGE=busybox:stable
FROM --platform=${BASE_PLATFORM} ${BASE_IMAGE}

# There is deliberately no RUN instruction anywhere in this file. A RUN would
# force buildx to execute ARMv5 code through emulation, which is exactly the
# thing this hardware target makes unreliable. Everything that needs doing --
# including setting the executable bit -- is done on the host beforehand.
#
# One binary, not two: make.sh links the CLI into the daemon, so this single
# file provides both. /usr/bin/tailscale is a small wrapper that re-invokes it
# in CLI mode, because COPY would dereference a symlink and store the whole
# binary twice.
COPY tailscaled /usr/sbin/tailscaled
COPY tailscale  /usr/bin/tailscale
COPY start.sh   /start.sh

ARG TS_ROUTES
ARG TS_HOSTNAME
ARG SOURCE_URL

# image.source is what makes a GitHub Container Registry package link back to
# the repository that produced it.
LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.title="Tailscale for MikroTik ARMv5" \
      org.opencontainers.image.description="Tailscale subnet router for RouterOS on EN7562CT (hEX Refresh), the ARMv5 target no official image supports"

# Defaults only. RouterOS can override any of these through /container/envs,
# so renumbering the LAN does not mean rebuilding the image.
ENV TS_ROUTES="${TS_ROUTES}" \
    TS_HOSTNAME="${TS_HOSTNAME}" \
    TS_STATE_DIR="/state"

# Mount this on the router so the node keeps its identity when the container
# is recreated. Without it, re-adding the container means authenticating again.
VOLUME /state

ENTRYPOINT ["/bin/sh", "/start.sh"]
