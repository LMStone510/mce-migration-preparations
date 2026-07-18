<!--
  Copyright (c) 2026 Mission Critical Email LLC.  All rights reserved.
  This document is proprietary.  It may NOT be copied, modified, redistributed,
  or republished, in whole or in part, without the prior written permission of
  Mission Critical Email LLC.  See LICENSE.
-->

# IMAPSYNC Server Preparation — the persistent UID cache

Migration binaries from late July 2026 (v15.4.0 and later — the version is
in the first line of every generated runner script and the bundle's
`README.txt`) generate an IMAPSYNC bundle whose `premigration` and
`postmigration` phases use **imapsync's persistent UID cache**
(`--usecache`). Bundles from earlier binaries run uncached and need none of
this document, though the host guidance in Section 1 still applies to them.
The first bulk pass builds the cache; every pass
after that skips already-transferred messages **without re-fetching message
headers from either server**. On a large system, repeated bulk passes spend
most of their wall-clock time re-*identifying* mail that already moved — the
cache removes exactly that cost, so the passes you re-run during the
pre-cutover window (and the final delta on cutover night) start fast and
stay fast.

The cache is deliberately an *accelerator*, not the source of truth: message
identification still falls back to header matching, so a lost or purged
cache only means a slower run — never duplicate messages, and never
unexpected deletions during a `--delete2` pass. Deletions on the source
still propagate on the next pass; the cache cannot mask them.

**The one thing the cache asks of you** is a properly provisioned directory
on the IMAPSYNC host, because of how it stores its state:

> The cache is **one empty file per transferred message**. A migration with
> 20 million messages needs ~20 million *inodes* on the cache filesystem —
> almost no disk *space*, but an inode count that can exhaust a
> default-formatted ext4 volume (or a RAM-backed `/tmp`) while `df -h` still
> shows plenty free.

The bundle's runner scripts and launcher check this before every bulk pass
and **abort with instructions** if the cache directory is RAM-backed or low
on inodes. This document explains how to provision your IMAPSYNC server so
it will pass the runner scripts' tests.

---

## 1. The IMAPSYNC host — high-level requirements

**A.** You will need a Linux box that can reach both servers' IMAP ports,
with `imapsync` installed (`tmux` recommended) and at least 2 CPU cores and
8 GB of RAM. Syncing large mailboxes can cause each imapsync process to
consume 1 GB or more of RAM, so 8 GB might not be enough if you are running
ten parallel imapsync processes covering mailboxes each with tens of GB of
data and hundreds of thousands of email blobs.

**B.** Place the IMAPSYNC host network-close to the source and destination
Zimbra mailbox servers to be used by the migration software — same
VPC/subnet if in the cloud — and address the servers by **stable
identifiers (IP address or FQDN) that will not change mid-migration**.
Whatever host identification strings you give the backup's IMAPSYNC prompts
are baked into the bundle *and into the cache's directory layout* — they
must stay the same for the whole migration, and with the bundle they
automatically do.

**C.** The IMAPSYNC server will need a specially formatted disk to store
its cache, with lots and lots of free inodes; instructions below.

---

## 2. Sizing: count messages, not gigabytes

Rough rule: **free inodes ≥ total messages being migrated, plus 20%
headroom.**

An estimate is fine — the point is order of magnitude, and the easiest
estimate is **total mail volume ÷ average message size (~75 KB)**: 1 TB of
mail is roughly 10–15 million messages, so plan for tens of millions of
inodes on multi-TB systems. (For an exact figure, your source's per-mailbox
message counts are visible in the Zimbra admin console's mailbox listing,
but the estimate is all the provisioning decision needs.)

**Filesystem choice matters more than size:**

| Filesystem | Inode behavior | Verdict |
|---|---|---|
| **XFS** | Dynamic — inodes allocated as needed, no fixed cap | **Recommended** |
| ext4 (defaults) | Fixed at `mkfs` time (1 inode per 16 KB) — a 100 GB volume caps at ~6.5 M inodes | Avoid, or `mkfs.ext4 -i 4096` |
| tmpfs / RAM-backed `/tmp` | Evaporates on reboot; consumes RAM | **Never** — the runners abort on it |

A **20 GB XFS volume comfortably holds a cache for tens of millions of
messages** (the files are empty; only metadata consumes space).

---

## 3. Provisioning walkthrough (AWS example)

Attach a small dedicated EBS volume (gp3, 20 GB is plenty) to the IMAPSYNC
instance, then:

```bash
# 1. Identify the new device (example: /dev/xvdf — check `lsblk`)
lsblk

# 2. Format XFS (dynamic inode allocation — no inode cap to exhaust)
sudo mkfs.xfs /dev/xvdf

# 3. Mount at the bundle's default cache location
sudo mkdir -p /mnt/imapsync-cache
sudo mount -o noatime /dev/xvdf /mnt/imapsync-cache

# 4. Make it survive reboots (use the UUID from `blkid /dev/xvdf`)
echo 'UUID=<uuid-from-blkid>  /mnt/imapsync-cache  xfs  noatime,nofail  0 2' \
  | sudo tee -a /etc/fstab

# 5. Restrict it to the user who runs the bundle
sudo chown <migration-user>:<migration-user> /mnt/imapsync-cache
sudo chmod 700 /mnt/imapsync-cache
```

Notes:

- **`noatime`** matters here: with tens of millions of files, per-access
  timestamp updates are pure metadata churn.
- **`nofail`** keeps the instance bootable if the volume is ever detached.
- **`0700` and a dedicated directory are a security measure, not tidiness:**
  imapsync's *default* cache location is a predictable, world-writable path
  under `/tmp` (CVE-2023-34204). The bundle never uses the default — it
  always passes an explicit `--tmpdir` — and a tightly-permissioned
  dedicated mount keeps the cache both private and isolated from the OS
  disk's inode pool.
- Not on AWS? Any disk-backed volume or partition works the same way —
  format XFS, mount at `/mnt/imapsync-cache`, `chmod 700`.
- No spare volume at all? You can point the cache at any disk-backed
  directory with `IMAPSYNC_TMPDIR=/path` (see below) — just never tmpfs,
  and check inodes first: `df -i /path`.

---

## 4. How the bundle uses it (nothing to configure)

With `/mnt/imapsync-cache` mounted, the IMAPSYNC bundle created for you by
the migration software works with **zero configuration**: every
`premigration` and `postmigration` run, in every group, in every phase,
uses that one directory. The cache is internally
namespaced by *(source host, user, destination host, user, folder)*, so all
parallel groups share it safely, and an account moving between groups (or a
bundle regenerated with a different group count) always finds its own cache.

Keep it **the same directory for the entire migration** — from your first
bulk pass through the final cutover-night delta.

Environment knobs, honored by `launch-all-tmux.sh` (and passed through to
every tmux session) as well as by direct `imapsync-groupN.sh` invocations:

| Variable | Default | Purpose |
|---|---|---|
| `IMAPSYNC_TMPDIR` | `/mnt/imapsync-cache` | Cache location |
| `IMAPSYNC_SKIP_CACHE=1` | off | Run uncached (identical to pre-v15.4.0 behavior) |
| `IMAPSYNC_MIN_FREE_INODES` | `1000000` | Preflight abort floor; lower it for genuinely small systems |
| `IMAPSYNC_FOLDERSIZES=1` | off | Re-enable imapsync's folder-size scans (progress/ETA display) at the cost of a full pre/post scan of every folder |

The preflight aborts (before any mail moves) when the cache directory is on
`tmpfs`/`ramfs`, or when the filesystem's free-inode count is below the
floor. Each abort message names the fix; `IMAPSYNC_SKIP_CACHE=1` is always
available as the explicit "run without the cache" escape hatch.

---

## 5. Validating that the cache is working

On the **second and later** `premigration` runs, look at each account's
end-of-run imapsync summary: the **skipped** message count should be
approximately the mailbox's already-transferred total, and the run should be
dramatically faster than the first pass.

A skipped count **at or near zero on a rerun means the cache is not being
found** — a changed `IMAPSYNC_TMPDIR`, a remounted or replaced volume, or a
purged directory. Nothing is being damaged (identification falls back to
header matching), but you are about to pay full-scan time on every mailbox:
stop, fix the mount, and rerun.

Quick health checks at any time:

```bash
df -i  /mnt/imapsync-cache    # free inodes trending down as the cache grows
df -h  /mnt/imapsync-cache    # space stays near-empty — that's normal
find /mnt/imapsync-cache -type f | head   # files appear under host/user paths
```

---

## 6. Cache lifecycle

- **During one migration:** never delete it. The cache directory is the
  speedup.
- **Between distinct migrations** (a new customer engagement, or a re-do
  from scratch after wiping the destination): purge it —
  `rm -rf /mnt/imapsync-cache/*` (or re-`mkfs` the volume). A stale cache
  from a previous engagement that happens to share host/user strings is a
  needless variable.
- **After cutover:** once the final `postmigration` pass is verified, the
  cache has no further value — purge or detach the volume at your leisure.

---

*Questions, or sizing help for a specific system:*
**Mission Critical Email LLC** — sales@missioncriticalemail.com
