#!/usr/bin/env bash
#
# Produces a Tailscale container image that a MikroTik hEX Refresh (EN7562CT
# SoC) can actually execute, packaged in the archive format RouterOS imports.
#
# Everything runs inside containers -- the only host requirement is Docker.
# Nothing is installed on the machine you run this from.
#
# Usage:  ./make.sh [stage ...]
# Stages: binaries | image | archive | verify | push | all | clean
#
# "push" needs IMAGE_REGISTRY and REGISTRY_AUTH; "all" does not include it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck source=config.sh
. ./config.sh

STAGE_DIR="staging"
CACHE_DIR=".cache"
OCI_TAR="${STAGE_DIR}/oci.tar"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
pass() { printf '     \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '     \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is required but was not found"
    docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
}

# --------------------------------------------------------------------------
# Stage 1 -- cross-compile the ARMv5 binaries.
#
# Tailscale publishes no ARMv5 build, but Go cross-compiles to it cleanly, so
# the binaries are made here rather than pulled. The module and compiler
# caches are kept under .cache so a re-run after changing only start.sh costs
# seconds instead of minutes.
#
# Only one binary is produced. ts_include_cli links the CLI into the daemon,
# and the ts_omit_* tags drop features a headless subnet router cannot reach.
# See TS_OMIT_FEATURES in config.sh.
# --------------------------------------------------------------------------
build_tags() {
    printf 'ts_include_cli%s' \
        "$(printf '%s' "$TS_OMIT_FEATURES" | tr ' ' '\n' \
            | sed '/^$/d; s/^/,ts_omit_/' | tr -d '\n')"
}

stage_binaries() {
    require_docker
    mkdir -p "$STAGE_DIR" "${CACHE_DIR}/go" "${CACHE_DIR}/gobuild"

    local tags
    tags="$(build_tags)"

    log "Cross-compiling Tailscale ${TAILSCALE_VERSION} for linux/arm/v5"
    # Run as the invoking user rather than the image's root. On Linux a bind
    # mount keeps real ownership, so a root-owned staging/tailscaled is one
    # the caller can no longer chmod or clean up -- which is a build failure
    # on CI. macOS hides this by remapping ownership to the host user.
    #
    # HOME, GOPATH and GOCACHE are redirected because the image's defaults
    # (/root, /go) are not writable once we are not root.
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "${ROOT}/${STAGE_DIR}:/out" \
        -v "${ROOT}/${CACHE_DIR}:/cache" \
        -e HOME=/cache \
        -e GOPATH=/cache/go \
        -e GOCACHE=/cache/gobuild \
        -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm -e GOARM=5 \
        "$GO_IMAGE" \
        sh -euc "
            go install -trimpath -tags '${tags}' -ldflags='-s -w' \
                'tailscale.com/cmd/tailscaled@${TAILSCALE_VERSION}'
            cp \"\${GOPATH}/bin/linux_arm/tailscaled\" /out/
        "
    chmod 0755 "${STAGE_DIR}/tailscaled"
}

# --------------------------------------------------------------------------
# Stage 2 -- assemble the image.
#
# The staging directory is the entire build context, so the image contains
# exactly three files and nothing incidental from the repository.
# --------------------------------------------------------------------------
stage_image() {
    require_docker
    [ -f "${STAGE_DIR}/tailscaled" ] || die "binaries missing -- run: ./make.sh binaries"

    # The exec bit has to be set on the host. The Dockerfile cannot chmod,
    # because any RUN would drag in ARMv5 emulation.
    install -m 0755 start.sh "${STAGE_DIR}/start.sh"
    install -m 0755 tailscale-cli.sh "${STAGE_DIR}/tailscale"
    chmod 0755 "${STAGE_DIR}/tailscaled"

    log "Assembling ${IMAGE_REF} (routes=${TS_ROUTES} hostname=${TS_HOSTNAME})"
    rm -f "$OCI_TAR"
    docker buildx build \
        --platform linux/arm/v5 \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        --build-arg "TS_ROUTES=${TS_ROUTES}" \
        --build-arg "TS_HOSTNAME=${TS_HOSTNAME}" \
        --build-arg "SOURCE_URL=${SOURCE_URL}" \
        --build-arg "IMAGE_VERSION=${IMAGE_TAG}" \
        --build-arg "TS_VERSION=${TAILSCALE_VERSION}" \
        --tag "$IMAGE_REF" \
        --file Dockerfile \
        --output "type=oci,dest=${OCI_TAR}" \
        "$STAGE_DIR"
}

# --------------------------------------------------------------------------
# Stage 3 -- convert to the archive format RouterOS understands.
#
# RouterOS reads only the legacy docker-archive layout (<hash>/layer.tar plus
# manifest.json). Modern buildx emits an OCI layout (blobs/sha256/...), and
# feeding that to /container/add fails with "error getting layer file".
# skopeo does the conversion; it runs from a container so nothing has to be
# installed on the host.
# --------------------------------------------------------------------------
stage_archive() {
    require_docker
    [ -f "$OCI_TAR" ] || die "OCI archive missing -- run: ./make.sh image"

    mkdir -p "$(dirname "$OUTPUT_TAR")"
    rm -f "$OUTPUT_TAR"

    log "Converting OCI layout to legacy docker-archive"
    docker run --rm -v "${ROOT}:/work" -w /work "$SKOPEO_IMAGE" \
        copy --insecure-policy \
        "oci-archive:${OCI_TAR}" \
        "docker-archive:${OUTPUT_TAR}:${IMAGE_REF}"
}

# --------------------------------------------------------------------------
# Stage 4 -- verify.
#
# Both ways this build fails are invisible until the image is already on the
# router: a wrong-architecture binary dies with "signal 4 (Illegal
# instruction)", and a wrong archive layout fails on import. Checking here
# turns a round trip through the router into a local error message.
#
# Note this does NOT use `file`. Its "EABI5" output describes the ABI
# version, which reads identically for GOARM=6 and GOARM=7 builds, so it
# cannot actually confirm the CPU target. The Go build metadata embedded in
# the binary can.
# --------------------------------------------------------------------------
stage_verify() {
    require_docker
    [ -f "${STAGE_DIR}/tailscaled" ] || die "binaries missing -- run: ./make.sh binaries"
    [ -f "$OUTPUT_TAR" ] || die "archive missing -- run: ./make.sh archive"
    FAILURES=0

    log "Verifying binaries"
    local info
    info="$(docker run --rm -v "${ROOT}/${STAGE_DIR}:/w" "$GO_IMAGE" \
                go version -m /w/tailscaled)"

    grep -q 'GOARCH=arm$'   <<<"$info" && pass "GOARCH is arm"        || bad "GOARCH is not arm"
    grep -q 'GOARM=5'       <<<"$info" && pass "GOARM is 5"           || bad "GOARM is not 5 -- this image would crash with SIGILL"
    grep -q 'CGO_ENABLED=0' <<<"$info" && pass "statically linked"    || bad "CGO is enabled -- busybox has no libc to link against"
    grep -q "tailscale.com.*${TAILSCALE_VERSION}" <<<"$info" \
        && pass "version is ${TAILSCALE_VERSION}" || bad "version does not match ${TAILSCALE_VERSION}"

    # Without this tag the binary has no CLI, and start.sh cannot run
    # "tailscale up" -- the container would come up and never authenticate.
    grep -q 'ts_include_cli' <<<"$info" \
        && pass "CLI linked into the daemon" || bad "ts_include_cli missing -- /usr/bin/tailscale would not work"
    [ -x "${STAGE_DIR}/tailscale" ] \
        && pass "CLI wrapper staged" || bad "CLI wrapper missing or not executable"

    log "Verifying image metadata"
    # RouterOS selects the image by the architecture and variant recorded here.
    # The binaries can be correct while this is wrong, so it is checked
    # separately rather than inferred.
    local manifest config_name config
    manifest="$(tar xOf "$OUTPUT_TAR" manifest.json)"
    config_name="$(tr ',' '\n' <<<"$manifest" | grep -o '"Config":"[^"]*"' | cut -d'"' -f4)"
    config="$(tar xOf "$OUTPUT_TAR" "$config_name")"

    grep -q '"architecture":"arm"' <<<"$config" && pass "image declares architecture arm" || bad "image does not declare architecture arm"
    grep -q '"variant":"v5"'       <<<"$config" && pass "image declares variant v5"       || bad "image does not declare variant v5 -- RouterOS will reject or mis-run it"

    log "Verifying archive layout"
    local listing layers missing count
    listing="$(tar tf "$OUTPUT_TAR")"

    # Anchored with an optional "./" because tar archives may or may not carry
    # that prefix depending on how they were produced.
    grep -qE '^(\./)?manifest\.json$' <<<"$listing" && pass "manifest.json at archive root" || bad "manifest.json missing"
    grep -qE '^(\./)?blobs/'          <<<"$listing" && bad "OCI blobs/ present -- conversion did not take effect" || pass "no OCI blobs/ directory"

    # The real test of the format: every layer the manifest points at must
    # actually exist in the archive. An OCI layout fails this, which is what
    # RouterOS reports as "error getting layer file".
    layers="$(tr ',' '\n' <<<"$manifest" | grep -o '"[^"]*\.tar"' | tr -d '"')"
    missing=0
    count=0
    while read -r layer; do
        [ -z "$layer" ] && continue
        count=$((count + 1))
        grep -qxF -e "$layer" -e "./${layer}" <<<"$listing" || missing=$((missing + 1))
    done <<<"$layers"

    if [ "$count" -eq 0 ]; then
        bad "manifest lists no layers"
    elif [ "$missing" -ne 0 ]; then
        bad "${missing} of ${count} referenced layers are absent from the archive"
    else
        pass "all ${count} referenced layers present"
    fi

    echo
    if [ "$FAILURES" -ne 0 ]; then
        die "${FAILURES} check(s) failed"
    fi
    log "All checks passed"
    printf '\n  Artifact: %s (%s)\n  Image:    %s\n\n' \
        "$OUTPUT_TAR" "$(du -h "$OUTPUT_TAR" | cut -f1 | tr -d ' ')" "$IMAGE_REF"
    printf '  Next: upload it to the router and follow docs/routeros-install.md\n\n'
}

# --------------------------------------------------------------------------
# Stage 5 -- publish to a container registry.
#
# Pushed from the same OCI archive that stage_archive converts, so the image
# people pull and the tar attached to a release are the same bytes rather than
# two separate builds that merely ought to agree.
#
# This is what lets RouterOS install with remote-image= and skip the manual
# upload entirely: it asks the registry for arch=arm archVariant=v5, and
# unlike the official Tailscale image, this one has that variant.
#
# Credentials come from REGISTRY_AUTH ("user:token"). It is forwarded into the
# container by name and read there, so the secret never appears in a command
# line on either side.
# --------------------------------------------------------------------------
stage_push() {
    require_docker
    [ -f "$OCI_TAR" ] || die "OCI archive missing -- run: ./make.sh image"
    [ -n "$IMAGE_REGISTRY" ] || die "IMAGE_REGISTRY is not set (e.g. ghcr.io/youruser)"
    [ -n "${REGISTRY_AUTH:-}" ] || die "REGISTRY_AUTH is not set (expected \"user:token\")"

    local dest tag
    dest="${IMAGE_REGISTRY}/${IMAGE_NAME}"

    for tag in "$IMAGE_TAG" $PUSH_EXTRA_TAGS; do
        log "Pushing ${dest}:${tag}"
        # --all copies the whole index rather than the entry matching this
        # host, which is never the ARMv5 one. Without it the push either
        # fails or silently sends the wrong thing.
        docker run --rm -e REGISTRY_AUTH -v "${ROOT}:/work" -w /work \
            --entrypoint sh "$SKOPEO_IMAGE" -c \
            'exec skopeo copy --insecure-policy --all \
                 --dest-creds "$REGISTRY_AUTH" "$1" "$2"' \
            _ "oci-archive:${OCI_TAR}" "docker://${dest}:${tag}"
    done

    printf '\n  Pull with:  %s:%s\n\n' "$dest" "$IMAGE_TAG"
}

stage_clean() {
    log "Removing generated files"
    rm -rf "$STAGE_DIR" dist
    printf '  Kept %s (delete it by hand to force a full recompile)\n' "$CACHE_DIR"
}

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

main() {
    local stages=("$@")
    [ ${#stages[@]} -eq 0 ] && stages=(all)

    for stage in "${stages[@]}"; do
        case "$stage" in
            binaries) stage_binaries ;;
            image)    stage_image ;;
            archive)  stage_archive ;;
            verify)   stage_verify ;;
            push)     stage_push ;;
            clean)    stage_clean ;;
            all)      stage_binaries; stage_image; stage_archive; stage_verify ;;
            -h|--help|help) usage 0 ;;
            *)        printf 'error: unknown stage %s\n\n' "$stage" >&2; usage 1 ;;
        esac
    done
}

main "$@"
