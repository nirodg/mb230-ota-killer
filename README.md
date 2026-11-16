# ota-killer — persistent OTA blocker for MB230

Blocks Vestel / Horizon / Medion **over-the-air firmware updates** on the
17MB230 (Linux 4.9, busybox). Plug&play: run one script once; it persists across
reboots and is fully reversible.

## Why

The OTA client is **inside `aurora.elf`** (the "Nebula" software-update
controller + OAD downloader + DCF processor), not a separate daemon. It has
several update paths (AWS IoT MQTT push, S3 HTTP download, DVB broadcast SSU,
USB, side-load), and this TV is actively being pushed `V.0.51.52.5`
(`/conf/ftpUpdateVersionFile.txt` = `V.0.51.19.0,V.0.51.52.5`, with repeated
`UPGRADE` wake reasons in `/conf/wakeup_reasons.txt`).

There is **no forced-update bypass of the network**: even `forceWebUpdate` must
download first. Cut the download and the flash never happens.

## What it does (three layers, all automatic)

1. **`/etc/hosts` override** — a generated hosts file is bind-mounted over the
   read-only `/etc/hosts`, sending the update hosts to `127.0.0.1`:
   - `aa8u5ipzaqyfu-ats.iot.eu-west-1.amazonaws.com` (AWS IoT MQTT push)
   - `s3-eu-west-1.amazonaws.com`, `vstlupdate.s3-…`, `qaupdate.s3-…`
   - **`d20j11dfuewm3u.cloudfront.net` / `d1jf4g5z1kouka.cloudfront.net`** —
     the `SWUPDATE_URL` / `SWUPDATE_TEST_URL` from `PortalUrlItem` in
     `settingsDB.db` (found 2026-11-16; these are the actual firmware CDN)
   - the `*.fxm6413857471.com` and `*.fxm9485766783.com` fallback hosts
     embedded in aurora / stored in `PortalUrlItem`
2. **iptables backstop** — resolves those names with an external DNS server and
   adds `OUTPUT … REJECT` rules for their IPs (catches hardcoded-IP calls).
3. **Deny the pending version** — writes `/conf/ftpUpdateVersionFile.txt`'s
   "available" field into the firmware's own
   `/conf/deniedSoftwareUpdateVersionFile.txt`. This is the safe version of the
   "unrealistic version" trick: a targeted deny, no global version spoof.

Persistence: installs to `/conf/ota-killer/`, adds a guarded hook at the top of
`/conf/opentv_payload` (before its `exec aurora`), and runs a keeper that
re-applies everything every 60 s — necessary because iptables rules and bind
mounts are volatile.

## Install (on the TV, as root)

```sh
cd /tmp
wget -O ota-killer.sh https://raw.githubusercontent.com/nirodg/mb230-ota-killer/main/ota-killer.sh
chmod +x ota-killer.sh
sh ota-killer.sh install
sh ota-killer.sh status
```

Or, from this submodule checkout: `sh install.sh` then `sh ota-killer.sh status`.

Expected `status` output: hosts mount ACTIVE, blocked hosts 8, some rejected
IPs, deny version = the pending version, payload hook ACTIVE, keeper RUNNING.

## Files (on TV, under `/conf/ota-killer/`)

| File | Purpose |
|---|---|
| `ota-killer.sh` | the self-contained script (commands: install/apply/keeper/status/uninstall) |
| `hosts` | generated hosts file, bind-mounted over `/etc/hosts` |
| `blocked.txt` | editable list of hostnames to block (one per line) |
| `added-ips.txt` | IPs the script added to iptables, so uninstall can remove exactly those |
| `deny-version.txt` | optional override; if present, this version is denied instead of auto-detected |
| `keeper.pid`, `ota-killer.log` | keeper state / log |

## Uninstall (fully reversible)

```sh
/conf/ota-killer/ota-killer.sh uninstall
```

Removes the payload hook (a backup of the original is at
`/conf/opentv_payload.bak.otakiller`), unmounts `/etc/hosts`, deletes only the
iptables rules it created, removes the deny-version file, and deletes
`/conf/ota-killer`.

## Settings-DB status (verified 2026-11-16)

Full analysis in [`SETTINGS_DB_ANALYSIS.md`](../../../SETTINGS_DB_ANALYSIS.md).

- `Settings.m_auto_upgrade_on = 0` **already** — periodic auto-update search is
  off; no DB patch is needed for that. (It was also 0 in the Nov 11 backup.)
- `m_USB_update_count` went 1 → 2 between the Nov 11 backup and now, while
  `m_http_update_count` stayed at 2 — i.e. the recent `UPGRADE` wake reasons
  are our own USB activity, not vendor HTTP pushes.
- The DB does contain the two CloudFront **SWUPDATE URLs**, now blocked above.
- DVB broadcast SSU remains the only network-independent vector; if you ever
  see SSU prompts, set `m_auto_upgrade_on = 0` (already the case here) and deny
  the offered version via `deny-version.txt`.

## Notes / limitations

- Binding `/etc/hosts` does not modify the read-only rootfs; it is a mount.
- iptables matches IPs, not names — that is why the hosts override is primary
  and the firewall is a backstop. AWS IPs rotate; the keeper re-resolves.
- A per-version deny file may be cleared by the client; the keeper rewrites it
  on every cycle from the "available" field of `ftpUpdateVersionFile.txt`.
- Verify no update chatter remains: watch `/conf/wakeup_reasons.txt` for `UPGRADE`
  and `/conf/reset_count.txt` for new entries.
