# tailscala

Builds a Tailscale container image for MikroTik routers on the **EN7562CT** SoC
(hEX Refresh, hEX S), and packages it in the archive format RouterOS can import.

## Why this exists

These routers execute **ARMv5 only**, and nobody publishes an ARMv5 Tailscale
image — every official and community build targets v6 or newer. RouterOS pulls
one anyway, the CPU hits an instruction it does not implement, and the container
dies immediately:

```
tailscale:latest: *** downloading and extracting remote image:
    registry=https://ghcr.io arch=arm archVariant=v5
tailscale:latest: exited with signal 4 (Illegal instruction)
```

Go cross-compiles to ARMv5 cleanly, so this project builds the binaries itself.

## Image size

The artifact is about **23 MB**. A straightforward build of the same thing is
51 MB; the difference comes from two decisions, both in
[`config.sh`](config.sh).

| | Size |
|--|--|
| `tailscaled` + `tailscale`, built separately | 45.0 MB |
| Linked into one binary (`ts_include_cli`) | 34.6 MB |
| Plus unused features compiled out (`ts_omit_*`) | **19.3 MB** |

Tailscale ships the daemon and the CLI as separate programs that share most of
their code, so linking them together removes the duplication — the same trick
Tailscale's own comment describes as being "for space savings reasons".
`/usr/bin/tailscale` is then a 582-byte wrapper that re-enters the binary in
CLI mode.

The rest comes from `TS_OMIT_FEATURES`, which compiles out things a headless
subnet router cannot reach anyway — Taildrive, Taildrop, the web UI, the
system tray, Kubernetes and AWS state stores, and so on. Prune that list if you
want any of them back; each entry you remove only makes the image larger.

### Why not Alpine

Alpine cannot work here, and would not help if it could:

- **It publishes no `arm/v5` image.** Alpine's ARM builds are `arm/v6` and
  `arm/v7` only, which is precisely the `Illegal instruction` crash this
  project exists to avoid. busybox is one of the few bases still shipping
  ARMv5.
- **The base is not where the size is.** The binaries are ~92% of the image
  and busybox contributes roughly 4 MB, so even a hypothetical zero-byte base
  would save under 10%. Alpine is also *larger* than busybox.

Compressing the binary with UPX would shrink the file further, but it has to
decompress into RAM at every start — a poor trade on a router with 32 MB of
working memory under load.

## Install it on a router

CI publishes the image, so the router can pull it directly — no building, no
uploading:

```
/container/config/set registry-url=https://ghcr.io tmpdir=usb1/ts-tmp
```

```
/container/add remote-image=nortonben/tailscale-armv5:0.2.0 interface=veth-ts root-dir=usb1/ts-root logging=yes start-on-boot=yes
```

Full procedure, including the network and USB setup those commands assume:
[docs/routeros-install.md](docs/routeros-install.md).

Everything below is for building it yourself.

## Requirements

Docker, and nothing else. The Go toolchain and skopeo both run from containers —
neither is installed on your machine.

## Usage

```bash
./make.sh
```

Produces `dist/tailscale-armv5-routeros.tar`, then verifies it. First run takes
a few minutes; later runs reuse the cached Go modules under `.cache/`.

Individual stages, when you only want to redo part of it:

```bash
./make.sh binaries   # cross-compile the combined tailscaled for GOARM=5
./make.sh image      # assemble the container image
./make.sh archive    # convert OCI layout to the legacy format RouterOS reads
./make.sh verify     # check the artifact before it goes near the router
./make.sh push       # publish to a registry (needs IMAGE_REGISTRY, REGISTRY_AUTH)
./make.sh clean      # remove staging/ and dist/
```

`all` runs everything except `push`.

Settings live in [`config.sh`](config.sh) and can be overridden per run:

```bash
TAILSCALE_VERSION=v1.102.2 TS_ROUTES=10.44.7.0/24 ./make.sh
```

`TS_ROUTES` and `TS_HOSTNAME` are only baked-in *defaults* — RouterOS can
override both at runtime, so renumbering your LAN does not mean rebuilding.

Then follow [`docs/routeros-install.md`](docs/routeros-install.md) to get it
onto the router.

## Why verify matters

Both ways this build goes wrong are invisible until the image is already on the
router — a wrong-architecture binary crashes with `SIGILL`, and a wrong archive
layout fails at `/container/add` with `error getting layer file`. `verify` checks
for both locally, so a mistake costs a re-run instead of a trip through WinBox.

It reads the Go build metadata embedded in the binary rather than trusting
`file`, whose `EABI5` output describes the ABI version and reads identically for
GOARM=6 and GOARM=7 builds.

## Layout

| Path | |
|------|--|
| `make.sh` | The whole pipeline |
| `config.sh` | Pinned versions, defaults, and the feature-omit list |
| `Dockerfile` | Three files onto an ARMv5 busybox base |
| `start.sh` | Container entrypoint — userspace networking, restart loop |
| `tailscale-cli.sh` | Wrapper that re-enters the combined binary in CLI mode |
| `.github/workflows/publish.yml` | Builds, verifies and publishes to ghcr.io |
| `docs/routeros-install.md` | Router-side procedure |
| `docs/publishing.md` | How the image is published |
| `docs/versions.md` | Which release contains which Tailscale, and how to cut one |

## Worth knowing before you commit to this

**Throughput tops out around 54 Mbit/s** on this SoC — the same link measures
435 Mbit/s untunnelled. Fine for SSH, administration and file access; not for
heavy streaming.

**This is unsupported.** MikroTik does not ship Tailscale, and the image is one
you build yourself. Upgrades mean re-running `./make.sh` and recreating the
container.

**Running Tailscale on a Linux box inside the LAN is the easier answer** if you
have one that stays on — `tailscale up --advertise-routes=...` on any always-on
machine does the same job with no cross-compilation and full line speed. This
project is for when you want the router itself to be the way in, independent of
any other host.
