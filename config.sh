# Single source of truth for this project. Sourced by make.sh.
# Override any value from the environment:
#
#   TAILSCALE_VERSION=v1.102.2 ./make.sh
#
# No secrets belong in this file. The Tailscale auth key, if you use one, is
# passed on the router via /container/envs and never stored here.

# Pin the Tailscale release. Never use @latest: an unpinned image is not
# reproducible, and when the router misbehaves you cannot tell whether the
# image changed or the router did.
TAILSCALE_VERSION="${TAILSCALE_VERSION:-v1.102.3}"

# Toolchain images. golang:1.26 ships go1.26.7; Tailscale v1.102.x needs
# >= 1.26.6, so do not pin this lower without first checking the go.mod of
# the release you are targeting.
GO_IMAGE="${GO_IMAGE:-golang:1.26}"
BASE_IMAGE="${BASE_IMAGE:-busybox:stable}"
SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"

# Baked into the image as defaults. Both stay overridable at runtime through
# RouterOS /container/envs, so a LAN renumber needs no new image.
TS_ROUTES="${TS_ROUTES:-192.168.0.0/24}"
TS_HOSTNAME="${TS_HOSTNAME:-hex-router}"

# Size control. The binaries are ~92% of the image, so this is the only place
# where meaningful savings exist -- the busybox base is about 4 MB of the
# total, and no smaller ARMv5 base is worth chasing.
#
# Two things happen here. The daemon and the CLI are linked into a single
# binary, and features a headless subnet router cannot use are compiled out.
# Together they take the binaries from 45 MB to roughly 19 MB.
#
# Removing an entry only makes the image bigger, so prune freely. But do not
# add "netstack" (userspace networking depends on it, and RouterOS containers
# have no /dev/net/tun) or "advertiseroutes" (that is the entire purpose of
# this container) -- either one produces a build that compiles and then does
# not work.
TS_OMIT_FEATURES="${TS_OMIT_FEATURES:-\
aws bird kube tap drive taildrop webclient systray desktop_sessions \
completion qrcodes synology dbus networkmanager resolved capture \
clientupdate wakeonlan captiveportal relayserver appconnectors acme tpm \
syspolicy oauthkey serve ssh tailnetlock portlist posture outboundproxy \
identityfederation flashappliance netlog sdnotify}"

IMAGE_NAME="${IMAGE_NAME:-tailscale-armv5}"
IMAGE_TAG="${IMAGE_TAG:-${TAILSCALE_VERSION#v}}"

# Registry to publish to, without the image name -- e.g. "ghcr.io/youruser".
# Only the push stage reads it; local builds do not need it set. The push
# stage also needs REGISTRY_AUTH ("user:token") in the environment.
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"

# Tags published alongside IMAGE_TAG.
PUSH_EXTRA_TAGS="${PUSH_EXTRA_TAGS:-latest}"

# Recorded in the image so a registry can link the package back to the
# repository it was built from.
SOURCE_URL="${SOURCE_URL:-}"

# Final artifact to upload to the router.
OUTPUT_TAR="${OUTPUT_TAR:-dist/tailscale-armv5-routeros.tar}"
