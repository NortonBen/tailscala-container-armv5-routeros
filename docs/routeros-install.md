# Installing the image on RouterOS

Router-side steps for the artifact produced by `./make.sh`. Written against
RouterOS 7.24.1 on a hEX Refresh (`E50UG`, firmware-type `en7562`).

Everything here writes to a USB drive. The internal flash on these routers is
small and, on the unit this was written for, degrading — see
[Keeping data off internal flash](#keeping-data-off-internal-flash), which is
the step most worth not skipping.

---

## 1. Confirm the hardware target

```
/system/routerboard/print
```

`model: E50UG` with `firmware-type: en7562` confirms the EN7562CT SoC that this
image is built for. A different model likely runs ARMv7 or ARM64, where the
official `tailscale/tailscale` image works and this project is unnecessary.

## 2. Enable the packages

```
/system/package/enable container
/system/package/enable rose-storage
/system/package/apply-changes
```

`container: yes` under `/system/device-mode/print` is only permission, not
software — the package still has to be enabled separately. `rose-storage`
provides ext4 formatting.

Note `apply-changes` replaced the old "enable then reboot" sequence; the router
reboots on its own.

## 3. Prepare the USB drive

Verify the drive is recognised as a real disk **before** anything writes to it:

```
/file/print where type=disk
```

You need a row with `TYPE = disk`. If the slot name shows as `directory`
instead, that is not a disk — see
[Keeping data off internal flash](#keeping-data-off-internal-flash).

Take the slot name from `/disk/print` rather than assuming it is `usb1`.

Formatting **erases the drive**:

```
/disk/format usb1 file-system=ext4 mbr-partition-table=no
```

## 4. Give the container a network

```
/interface/veth/add name=veth-ts address=172.30.95.2/24 gateway=172.30.95.1
/ip/address/add address=172.30.95.1/24 interface=veth-ts
/ip/firewall/nat/add chain=srcnat action=masquerade src-address=172.30.95.0/24
```

Without the masquerade rule the container starts normally but never reaches
`controlplane.tailscale.com`, which looks like a Tailscale problem and is not.

## 5. Persist the node identity

```
/container/mounts/add list=ts-state src=usb1/ts-state dst=/state
```

The container writes its node key to `/state`. Mounting it means the node keeps
its identity when the container is recreated — without this, every upgrade
means re-authenticating and approving routes again.

> RouterOS 7.20 renamed several container parameters (`name=` became `list=`,
> `mounts=` became `mountlists=`). If you get `bad parameter`, append `?` to
> see what the command actually accepts on your version:
> `/container/mounts/add ?`

## 6. Install the container

Two ways in. **Method 1 is easier and avoids the upload entirely** — use it
unless you specifically want to run an image you built yourself.

Either way, first confirm the USB slot is a real disk. If the name does not
exist, RouterOS silently creates a directory of that name **in internal flash**
and writes there instead:

```
/file/print where type=disk
```

---

## Method 1 — pull from the registry

CI publishes the image to GitHub Container Registry, so the router can download
it itself. Nothing is uploaded by hand and nothing transits internal flash.

This is the same mechanism that failed with the official Tailscale image, and
it fails there for a reason worth understanding: RouterOS asks the registry for
`arch=arm archVariant=v5`, no official image has that variant, and RouterOS
falls back to an ARMv6 or v7 build that the CPU cannot execute. This image
publishes a genuine ARMv5 variant, so the same request now resolves correctly.

Point the container system at ghcr.io and keep its scratch space on USB:

```
/container/config/set registry-url=https://ghcr.io tmpdir=usb1/ts-tmp
```

`tmpdir` is the one people forget. Without it the compressed layers are
unpacked into internal flash during the pull, which on a nearly-full or
failing NAND is exactly the wrong place.

```
/container/add remote-image=nortonben/tailscale-armv5:0.2.0 \
    interface=veth-ts root-dir=usb1/ts-root mountlists=ts-state \
    logging=yes start-on-boot=yes hostname=hex-router
```

> The router pulls anonymously, so the package has to be public — otherwise it
> gets a 401. Published from a public repository it normally already is; the
> check is in [publishing.md](publishing.md).

Watch it download and unpack:

```
/log/print where topics~"container"
```

Then skip to [step 7](#7-authenticate-and-approve-the-routes).

**Always name a version.** There is deliberately no `latest` tag: a moving tag
means a container you recreate later can come back with a different Tailscale,
and if that goes wrong you are no longer on the network to fix it. Which
Tailscale each release contains is listed in
[the version map](versions.md).

---

## Method 2 — import a tar you built yourself

Build it with `./make.sh`, then move the ~23 MB artifact across. **Get it onto
the USB drive directly** — do not let it land in internal flash on the way,
which is what a plain WinBox drag-and-drop does.

### Option A — router pulls it over HTTP (recommended)

Nothing lands in flash, and it needs no extra software on either side. Serve
the file from the machine that built it:

```bash
cd dist && python3 -m http.server 8000 --bind <your-lan-ip>
```

Then on the router, substituting that address:

```
/tool/fetch url="http://<your-lan-ip>:8000/tailscale-armv5-routeros.tar" \
    dst-path=usb1/tailscale-armv5-routeros.tar
```

Stop the server with Ctrl-C when the transfer finishes.

### Option B — SFTP

Also writes straight to the USB drive. Requires the SSH service to be enabled
(`/ip/service/print`):

```bash
sftp admin@<router-ip>
put dist/tailscale-armv5-routeros.tar usb1/tailscale-armv5-routeros.tar
```

The `usb1/` prefix is the whole point — without it the file goes to flash.

### Option C — WinBox, last resort

Dragging into the Files window drops the file in internal flash, and you then
have to move it:

```
/file/set [find name="tailscale-armv5-routeros.tar"] name=usb1/tailscale-armv5-routeros.tar
```

This needs ~23 MB free in flash for the duration. Avoid it if the router is
short on space or reporting bad blocks.

### Confirm the upload

Byte count must match the file you built:

```
/file/print detail where name~"tailscale"
```

Record the free space before creating the container — you will compare against
it in step 8:

```
/system/resource/print
```

Then:

```
/container/add file=usb1/tailscale-armv5-routeros.tar interface=veth-ts \
    root-dir=usb1/ts-root mountlists=ts-state \
    logging=yes start-on-boot=yes hostname=hex-router
```

Wait for `/container/print` to move from `extracting` to `stopped`. **Do not
start it while it is still extracting** — the container ends up corrupt and has
to be removed and recreated.

```
/container/start [find]
/log/print where topics~"container"
```

Use `[find]` rather than a number; container numbering shifts.

## 7. Authenticate and approve the routes

The log prints a login URL. Open it, sign in, then in the
[admin console](https://login.tailscale.com/admin/machines) find the new node
and:

- **Approve the subnet route.** Menu (⋯) → Edit route settings → tick the
  advertised subnet. Until you do, the node shows as connected but no traffic
  reaches the LAN. This looks exactly like a misconfiguration and is not one.
- **Disable key expiry.** Menu (⋯) → Disable key expiry. Otherwise the node
  drops off after 180 days, typically while you are away and relying on it.

To authenticate without the interactive URL, set an auth key before starting:

```
/container/envs/add list=ts-env key=TS_AUTHKEY value=tskey-auth-xxxxx
```

then add `envlist=ts-env` to `/container/add`. Confirm the parameter names with
`/container/envs/add ?` — this is one of the menus RouterOS renamed.

## 8. Keeping data off internal flash

This is the step that protects the router.

If a slot name does not exist, RouterOS **does not report an error**. It
silently creates an ordinary directory of that name in internal flash and
writes there instead. The container then fills the flash while you believe it
is running from USB.

Compare against the figure from step 6:

```
/system/resource/print
```

If `free-hdd-space` is unchanged, everything landed on USB. If it dropped by
tens of megabytes, stop and remove the container now.

Confirm directly:

```
/file/print where name~"usb1"
```

The `root-dir` must show type `container store`.

Three separate paths can fall back to internal flash, and missing any one is
enough:

| Path | Set in | Holds |
|------|--------|-------|
| `tmpdir` | `/container/config` | compressed layers during import |
| `root-dir` | `/container/add` | the extracted filesystem — by far the largest |
| mount `src` | `/container/mounts` | persistent state |

## 9. Verify from a remote device

```
tailscale ping <hostname>
ping 192.168.0.1
```

Reaching the router's LAN address means the whole subnet is reachable.

Devices on the LAN must use the router as their default gateway, or replies
take a different path and connections hang.

---

## Runtime configuration

The image reads these; all are optional and none require a rebuild. Set them
through `/container/envs` and restart the container.

| Variable | Default | Purpose |
|----------|---------|---------|
| `TS_ROUTES` | `192.168.0.0/24` | Subnet advertised to the tailnet |
| `TS_HOSTNAME` | `hex-router` | Name shown in the admin console |
| `TS_AUTHKEY` | *(unset)* | Non-interactive authentication |
| `TS_EXTRA_ARGS` | *(unset)* | Extra `tailscale up` flags, e.g. `--advertise-exit-node` |

| `TS_DNS` | `1.1.1.1` | Resolver, used only if the container has none |
| `TS_STATE_DIR` | `/state` | Where the node key is written |

### Features not compiled in

The image is built at ~23 MB by omitting features a headless subnet router
cannot use. The ones most likely to be missed:

- **Tailscale SSH** (`--ssh`)
- **`tailscale serve` and Funnel**
- **Taildrop** file transfer and **Taildrive**
- **The built-in web UI**

Subnet routing, exit-node advertising, and MagicDNS are all present. Passing a
flag for an omitted feature through `TS_EXTRA_ARGS` fails with an unknown-flag
error rather than being silently ignored.

To restore any of them, delete the corresponding entry from
`TS_OMIT_FEATURES` in `config.sh` and rebuild.

## Upgrading Tailscale

State lives in the mount from step 5, so the node keeps its identity and its
approved routes across an upgrade.

```bash
TAILSCALE_VERSION=v1.103.0 ./make.sh
```

Then on the router:

```
/container/stop [find]
/container/remove [find]
```

Upload the new tar and repeat step 6. Keep `mountlists=ts-state`.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `signal 4 (Illegal instruction)` | Image is not ARMv5. `./make.sh verify` catches this before upload |
| Same, but logged as `tailscale:latest` running `containerboot` | That is the **official** image from a previous attempt, not this one. It crash-loops and holds disk space until removed — see below |
| `error getting layer file` | Archive is OCI, not legacy docker-archive. Also caught by `./make.sh verify` |
| `bad parameter <name>` | Pre-7.20 syntax. Append `?` to the command to see valid parameters |
| `no such item` on start | Container numbering changed — use `/container/start [find]` |
| Container has no internet | Missing masquerade rule from step 4 |
| Connected, but LAN unreachable | Subnet route not approved in the admin console (step 7) |
| Authentication lost after reboot | `/state` is not mounted to the USB drive (step 5) |
| Free space dropped after import | Something is writing to internal flash (step 8) |

Start over cleanly:

```
/container/stop [find]
/container/remove [find]
```
