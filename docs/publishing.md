# Publishing the image

How the image reaches GitHub Container Registry, and the one manual step
GitHub requires before a router can pull it.

## What CI does

[`.github/workflows/publish.yml`](../.github/workflows/publish.yml) runs on
every push to `main`, on `v*` tags, and on manual dispatch. It:

1. cross-compiles the ARMv5 binary and assembles the image,
2. converts it to the legacy archive RouterOS imports,
3. **verifies** both — a non-ARMv5 binary or an unimportable archive fails the
   run rather than getting published,
4. pushes to `ghcr.io/<owner>/tailscale-armv5` as `:<tailscale-version>` and
   `:latest`,
5. uploads the tar as a workflow artifact, and on a tag, attaches it to the
   release.

The pushed image and the released tar are converted from the same OCI archive,
so they are the same image rather than two builds that ought to agree.

No secrets to configure: it authenticates with the automatic `GITHUB_TOKEN`.

## Check the package is publicly pullable

The router pulls anonymously, so the package has to be public. Published from
a public repository it generally already is, but confirm rather than assume —
a private package answers a router with a 401 and no useful explanation.

This is the check that matters, because it is what the router actually does:

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:<owner>/tailscale-armv5:pull&service=ghcr.io" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/<owner>/tailscale-armv5/manifests/latest
```

`200` means the router can pull it. A `401` means it is private — fix it at
the package page (**Package settings** → **Danger Zone** → **Change
visibility** → **Public**), reachable from the **Packages** section of your
profile.

Note the token endpoint hands out a token even for a package you cannot read,
so "did I get a token" proves nothing on its own. Check the manifest.

If you would rather keep it private, RouterOS can authenticate — set
`registry-user` and `registry-password` under `/container/config` with a
personal access token that has `read:packages`. A public package is simpler,
and the image contains no secrets.

## Linking the package to this repository

The image carries `org.opencontainers.image.source`, which CI sets from the
repository URL. GitHub reads that label to attach the package to the repo, so
the package page shows the README and the release history. Nothing to
configure — but if the package appears unlinked, that label is what to check.

## Publishing by hand

Useful for a fork, a private registry, or testing before pushing to CI.

```bash
export IMAGE_REGISTRY=ghcr.io/<owner>
export REGISTRY_AUTH="<owner>:<token-with-write:packages>"
./make.sh binaries image archive verify push
```

`REGISTRY_AUTH` is forwarded into the container by name, so the token never
appears in a command line on the host.

Any OCI registry works — Docker Hub, a self-hosted registry — by changing
`IMAGE_REGISTRY`.

## Versioning

Image tags track the **Tailscale** version, not this repository's version:
`1.102.3` and `latest`.

To publish a new Tailscale release, bump `TAILSCALE_VERSION` in
[`config.sh`](../config.sh) and push. Check the release's `go.mod` first — if
it needs a newer Go than `GO_IMAGE` provides, bump that too, or the build fails
with a toolchain error.

Tag the repository (`v*`) when you want the tar attached to a GitHub release;
routine pushes to `main` publish the image but create no release.
