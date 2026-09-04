# Version map

Image tags are **release numbers**, not Tailscale versions — `:0.2.0` is a
release of this project, and does not say which Tailscale is inside. This page
is where that mapping lives.

| Image tag | Tailscale | Base | RouterOS tested | Notes |
|-----------|-----------|------|-----------------|-------|
| `0.2.0` | 1.102.3 | busybox:stable | 7.24.1 | Release-numbered tags; `latest` no longer published |
| `1.102.3` *(retired)* | 1.102.3 | busybox:stable | 7.24.1 | Old scheme, tagged by Tailscale version |
| `latest` *(retired)* | 1.102.3 | busybox:stable | 7.24.1 | Withdrawn — see [Why there is no `latest`](#why-there-is-no-latest) |

"RouterOS tested" records where a release was actually exercised. It is not a
compatibility limit: the image is a plain ARMv5 container and does not depend
on the RouterOS version.

## Checking an image instead of trusting this table

Every image records its own versions, so you never have to take the table's
word for it:

```bash
docker manifest inspect ghcr.io/nortonben/tailscale-armv5:0.2.0 >/dev/null
```

Read the labels directly from the registry, with no pull and no Docker:

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:nortonben/tailscale-armv5:pull&service=ghcr.io" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
DIGEST=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/nortonben/tailscale-armv5/manifests/0.2.0 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["digest"])')
curl -sL -H "Authorization: Bearer $TOKEN" \
  https://ghcr.io/v2/nortonben/tailscale-armv5/blobs/$DIGEST \
  | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c["architecture"], c["variant"]); print(c["config"]["Labels"])'
```

That prints `arm v5` along with `org.opencontainers.image.version` (the
release) and `tailscale.version` (what is actually inside).

On the router itself:

```
/container/shell [find]
tailscale version
```

## Why there is no `latest`

A moving tag hides which build a router pulled. Recreate a container six
months on and `latest` can bring a different Tailscale with it — and the thing
being changed is the way back into the network. If it comes up wrong, you are
not on the network to fix it.

Pinning a release tag means a container you recreate is the container you had.

## Cutting a release

1. Bump `TAILSCALE_VERSION` in [`config.sh`](../config.sh) if the Tailscale
   version is changing. Check the release's `go.mod` first — a newer Go
   requirement means bumping `GO_IMAGE` too, or the build fails on the
   toolchain.
2. Add a row to the table above.
3. Tag and push:

```bash
git tag -a v0.3.0 -m "v0.3.0 — Tailscale 1.x.y" && git push origin v0.3.0
```

CI builds, verifies, publishes `:0.3.0`, and attaches the tar to the release.
Nothing is published from an untagged commit.

## Numbering

Release numbers describe *this project*, not Tailscale:

- **patch** — packaging or docs fix, same Tailscale
- **minor** — new Tailscale version, or a change to what the image contains
  (feature-omit list, base image)
- **major** — a change that breaks existing installs, such as renaming an
  environment variable the container reads

A Tailscale bump is a minor here even when Tailscale itself calls it a patch,
because from a router's point of view the contents changed.
