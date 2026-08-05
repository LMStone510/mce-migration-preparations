<!--
  Copyright (c) 2026 Mission Critical Email LLC.  All rights reserved.
  This document is proprietary.  It may NOT be copied, modified, redistributed,
  or republished, in whole or in part, without the prior written permission of
  Mission Critical Email LLC.  See LICENSE.  (The operator scripts OP1/OP2/OP3 in
  this repository are separately MIT-licensed; this notice does not apply to them.)
-->

# Mission Critical Email — Zimbra Migration: Operator Guide

This repository holds the **preparation scripts** you run on your source Zimbra server before a migration, plus the operator guide for the **Mission Critical Email migration binary** that performs the backup and restore.

Even if you are not doing a Zimbra migration, it is good to clean up broken shares periodically using the MCE_OP2_broken_shares_checker.sh script.

If you stumbled on this repo and would like to discuss using our Migration Software binary, send an email to sales@missioncriticalemail.com.

The migration binary is a separately licensed product. It is **not** in this repository — Mission Critical Email provides your build directly. This guide tells you, in order, what to run and why it matters.

> Throughout, the binary is written as `mce-backup-restore`. Your delivered build will have a different filename; substitute its path.

**Also in this repository:**
- [MCE Zimbra Migration — Information Sheet (PDF)](MCE-Zimbra-Migration-Information-Sheet.pdf) — a two-page overview of the migration offering.
- [IMAPSYNC Server Preparation](MCE-IMAPSYNC-Server-Preparation.md) — how to avoid failed imapsyncs due to running out of inodes.
- [MCE License Count script](MCE_OP3_mailbox_license_count.sh) — run on the source server to determine how many seats to license.
- [MCE CoS Override Report](MCE_OP4_cos_override_report.sh) — run on the source server to list every account-level override of a CoS-managed policy attribute (see "What does not migrate").
- [Static Code Review & Control-Flow Analysis](MissionCriticalEmail_Migration_Software_Code_Review.txt) — the engineering review of the migration binary.

---

## 1. The migration in one picture

```
SOURCE (your live Zimbra)                    DESTINATION (the new Zimbra)
─────────────────────────                    ───────────────────────────
1. OP2  broken-shares cleanup
2. OP1  IMAP preflight  ──► apply fixes
3. mce-backup-restore -b … -mode pre|full
        (creates an export dir + IMAPSYNC bundle)
                    │
                    │  rsync the export to the destination Zimbra system
                    │  rsync the IMAPSYNC bundle to the imapsync server
                    ▼
                                   4. mce-backup-restore -r … -mode pre|full|post
                                      (recreates accounts, data, shares)
                                   5. IMAPSYNC bundle  ──► run on an IMAPSYNC host
                                      justfolders → premigration → postmigration
                                      (creates email folders & copies the mail blobs)
                                   6. cutover (move DNS / Elastic IP)
```

Two ways to sequence this — pick one **before** you start (Section 6):

- **Workflow A — Full mode.** One maintenance window. Simpler. Users see empty mailboxes for the first few hours while mail catches up. Good for a few hundred users or fewer.
- **Workflow B — Pre/Post mode (recommended).** Infrastructure and the bulk of mail move *before* cutover during business hours; the cutover window is just the final delta (typically 2–4 hours). Best when downtime must be minimal.

**Always run a full dry-run cycle first, and then wipe the destination before doing a production migration!**

---

## 2. What migrates — and what doesn't

The binary migrates your Zimbra **provisioning and mailbox data**; the IMAPSYNC bundle it generates creates **email folders** and migrates the **mail blobs**. Together they move a complete system — accounts, structure, sharing, and content — from source to destination. The list below is deliberately specific: on a migration, knowing *exactly* what carries over (and what doesn't) is what lets you — and your security team — sign off with confidence.

**Infrastructure**

- **Classes of Service (COS)**, with the full inheritance chain preserved. A COS whose name already exists on the destination is restored as `<name>_restored` rather than overwriting it, and the affected domains/accounts are pointed at the correct one.
- **Local domains and domain aliases**, and each domain's default COS.
- **Per-domain DKIM signing keys** for domains configured with DKIM — so signed mail keeps verifying at cutover with no DNS change.
- **Distribution lists**, their members, and DL aliases.
- **Resource accounts** (e.g. Conference Rooms).
- **External (virtual) accounts** — the off-Zimbra-domain users to whom internal folders or resources have been shared.

**User accounts** — each account is recreated with:

- Password.
- Display Name / Given Name / Surname.
- Email aliases.
- Work Title, Company.
- Complete address (street, city, state, ZIP).
- Telephone number.
- Spell-check "words to ignore".
- Personal Amavis block / allow lists.
- Trusted Senders list.
- Preferred "From" address and display name.
- Explicit per-account COS assignment.
- All account-level Zimbra Access Control Entries (ACEs).
- All Sieve scripts (filters).
- `zimbraId`.
- **Two-factor authentication (2FA)** — each user's TOTP shared secret, backup (scratch) codes, app-specific passwords, and enabled state, carried over verbatim so users keep their existing authenticator with **no re-enrollment**. Trusted-device tokens are not carried (users simply re-trust their devices). On a FOSS destination, install a 2FA add-on (e.g. [maldua](https://github.com/maldua-suite/zimbra-maldua-2fa)) to manage and enforce these settings.

**User mailbox content**

- **All address books** — every top-level contact folder *and* its subfolders, not just `/Contacts`; each exported and imported individually, with names preserved.
- **All calendars** — every top-level calendar folder *and* its subfolders, not just `/Calendar`; each exported and imported individually, with names preserved.
- **Briefcase** and **Tasks**.
- **Email signatures**.
- **Out-of-office auto-replies** — each user's vacation message (including multi-line and international text), external-sender handling, and the enabled state with its from/until dates, applied so auto-replies re-arm as cutover-day mail starts flowing. An expired vacation window stays off. *One footnote:* Zimbra's "reply once per sender" memory starts fresh on the new server, so a sender who was auto-replied to before cutover may receive one repeat auto-reply after the cutover.
- **RSS/Atom feed folders and ICS-subscribed calendars** — recreated with their subscription URLs *before* the folder-skeleton pass, so the destination keeps polling the feed while IMAPSYNC fills in the accumulated history. A migration that "just copies mailboxes" leaves these as dead folders that silently never update again.
- **Folder shares** — outgoing grants and incoming mountpoints, recreated in the correct dependency order — including shares accepted under an account's *alias* identity, and same-named shares disambiguated automatically.

**Mail**

- All mail messages, via the auto-generated IMAPSYNC bundle (see Section 8).

**What does not migrate** (by design):
- **Mail blobs travel via IMAPSYNC, not the provisioning path** — that is the architecture, not a gap (Section 8 explains why this is an advantage).
- GALsync accounts.
- ActiveSync/mobile, S/MIME, ZCO/EWS, and NE Backup settings are skipped automatically on a Network Edition → FOSS migration (they have no native FOSS equivalent and would otherwise fail account creation). *(Two-factor authentication is the exception — it **is** migrated; see "What migrates" above.)*
- Custom `localconfig` values, MTA settings, SSL certificates, branding/theming, and external auth integrations (Okta/JumpCloud/AD) — these belong to the destination's own build.
- **External domain authentication** (`zimbraAuthMech` = `ad`/`ldap`/`custom` — domains that authenticate users against Active Directory or another external LDAP directory). The `zimbraAuthLdap*` configuration names *your* directory infrastructure (servers, bind credentials, TLS trust) and must be pointed at deliberately, so it is not carried: every domain is recreated on the destination with internal (`zimbra`) authentication. The backup **warns for each external-auth domain it finds** and records them in `external_auth_domains.txt`; the restore repeats the list. **Reconfigure external authentication on the destination before users log in** — until you do, those users' directory passwords will not work there.
- Domain-level ACEs (account-level ACEs *do* migrate); and the admin-role flags themselves (`zimbraIsAdminAccount` / `zimbraIsDelegatedAdminAccount`) are intentionally not set on the destination — admins are exported for reference and reconstructed deliberately.
- Per-domain public-service hostname/port/protocol (you set those on the destination, since they often change as a result of the migration).
- **Account-level overrides of CoS-managed policy attributes that *loosen* policy, plus override cruft.** Those attributes belong at the Class of Service level, and account-level values are often forgotten one-off workarounds that silently exempt an account from its COS forever. The migration handles the class in tiers: overrides that **tighten security or encode operational policy** (password locks, forwarding-permission policy, per-seat feature grants like EWS and S/MIME, quotas, session lifetimes, 2FA-required/available = TRUE) **do migrate** — dropping those would silently weaken the destination — and every one applied is recorded by the restore in `applied_policy_overrides.txt`, with per-account **quota** overrides called out separately (they interact with COS-keyed billing plans). Overrides that **loosen** policy (e.g. a 2FA exemption on an application account) and provisioning leftovers are deliberately **not** migrated: they surface during your dry-run testing, where they can be fixed properly (that application account belongs on an **app-specific password**, which the migration *does* carry — not on a 2FA exemption). Run [MCE_OP4_cos_override_report.sh](MCE_OP4_cos_override_report.sh) on your source **before** the dry run: it lists exactly what will not migrate and generates an optional reapply batch for anything you conclude is load-bearing. *(User preferences — `zimbraPref*` — are not policy and migrate normally, as do account status and mail forwarding.)*

---

## 3. Prerequisites

Run everything as the **`zimbra`** user, on a single Zimbra **mailbox** server, inside a `screen` or `tmux` session (these runs are long); one mailbox server on each of the source and destination systems.

- **Source & destination:** a working Zimbra mailstore on each end. Do **not** pre-create Classes of Service on the destination — the binary migrates them (pre-creating them causes `_restored` duplicates). Configure the destination's MTA, anti-spam/AV, and server-wide `zimbraPublicServiceHostname/Port/Protocol` to the destination's own environment before restoring.
- **Maximum message sizes — destination must accept what the source holds.** Check that `zimbraMtaMaxMessageSize` and `zimbraFileUploadMaxSize` on the destination are **no smaller than on the source** — otherwise the `premigration` IMAPSYNC pass will likely fail to transfer the larger message blobs (and large attachment uploads can fail too). Compare with one command on each system, and raise the destination to at least the source's values:

  ```bash
  zmprov gacf zimbraFileUploadMaxSize zimbraMtaMaxMessageSize      # run on BOTH systems and compare
  zmprov mcf zimbraMtaMaxMessageSize <bytes>       # on the destination, if smaller than the source
  zmprov mcf zimbraFileUploadMaxSize <bytes>       # on the destination, if smaller than the source
  ```

- **Redo-log rollover — keep IMAPSYNC from filling the destination's disks.** Every message IMAPSYNC delivers is also written to the destination's redo log, and on Network Edition the rolled-over logs are kept in the redo-log archive directory — so a large migration writes a second copy of every blob and can fill the mailbox server's disk mid-run. Before running IMAPSYNC, on **every destination mailbox server**:

  ```bash
  zmprov mcf zimbraRedoLogDeleteOnRollover TRUE
  zmmailboxdctl restart
  ```

  With this set, redo logs are deleted at rollover instead of archived. **Revert it (set `FALSE`, restart mailboxd again) immediately before the cutover**, so the destination resumes keeping redo-log archives once it holds live mail.
- **Network Edition destinations on Zimbra 10.1+ (V3 licensing):** The licensing engine in Zimbra 10.1 takes a very strict approach to licensed features entitlements, and will block any accounts from being migrated if Classes of Service are configured such that one or more entitlements could possibly be exceeded. In practice, this happens only when the V3 license on the destination system contains Network Edition Standard seats, either exclusively or in combination with Network Edition Professional seats. Before launching the first dry-run migration, make sure that the new "default" Class of Service on the destination system as well as all of the Classes of Service on the source system, are configured to prevent you from even accidentally exceeding your entitlements for Mobile, Archiving, S/MIME, ZCO, EWS and EAS. See <https://www.missioncriticalemail.com/2025/06/09/zimbra-10-1-licensing-server-lds-best-practices/> for more detail.
- **Admin console reverse proxy (TCP 9071) — on both source and destination:** the binary runs on a single mailbox server but needs to reach all accounts in a multi-server environment, so we route this traffic through the proxy service (even on a single server). To proxy the Admin Console, run on every proxy server:

  ```bash
  /opt/zimbra/libexec/zmproxyconfig -e -w -C -H $(zmhostname) && zmproxyctl restart
  ```
- **The OP1/OP2/OP3 scripts** (this repo): all need `bash` and `zmprov`; OP1/OP2 additionally need `ldapsearch`, `zmmailbox`, `zmsoap`. `GNU parallel` is optional (OP2 falls back to sequential). OP3 needs only `zmprov`.
- **The IMAPSYNC host:** any box that can reach both servers' IMAP ports and has `imapsync` installed. `tmux` is strongly recommended. Don't run out of inodes! See: [IMAPSYNC Server Preparation](MCE-IMAPSYNC-Server-Preparation.md).
- **Data transfer:** the `zimbra` user has no password and its SSH keys must not be touched, so move the export with an unprivileged admin account that has an SSH key pair on both hosts and is a member of the `zimbra` group on the source.

---

## 4. Preparation scripts (run on the SOURCE, before any backup)

All three are **read-only** by themselves: OP1 and OP2 only ever generate a file you review and apply yourself, and OP3 only reports a count — none of them change your system on their own. The migration binary will prompt you to confirm the two fix scripts (OP1/OP2) have been run, and you should not answer "yes" until they have. OP3 (mailbox license count) is independent — run it whenever you need to size a license, including before you buy.

### 4.1 `MCE_OP2_broken_shares_checker.sh` — clean up broken shares first

Over years of use, Zimbra accumulates broken shares: mountpoints to folders that no longer exist, grants to deleted accounts, and stale ACL cache entries. Left in place, they corrupt mountpoint export and produce wrong IMAPSYNC excludes — which can **duplicate shared-folder data** onto the destination. Cleaning them up now moves the noise from mid-cutover (irrecoverable) to a quiet preflight.

```bash
bash MCE_OP2_broken_shares_checker.sh --output-dir /var/tmp
```

It writes three CSV reports and three **removal scripts** (inbound mountpoints, outbound grants, stale ACLs). Review the CSVs, then run the removal scripts you agree with.

Options: `--jobs N` (reachability-probe parallelism, default 4), `--delay`, `--timeout`, `--output-dir`.

### 4.2 `MCE_OP1_imap_preflight.sh` — make sure IMAP is on where it matters

IMAPSYNC copies mail by logging into each mailbox over IMAP. Any account with `zimbraImapEnabled=FALSE` cannot be authenticated, and **its email folder structure and mail blobs are silently skipped and not migrated**. Some COSes ship with IMAP off, and operators often disable it over the years.

```bash
bash MCE_OP1_imap_preflight.sh --output-dir /tmp
```

It finds every COS and account with IMAP disabled and writes a `zmprov -f` provisioning file. Review it, then apply on the source:

```bash
zmprov -f /tmp/MCE_OP1_imap_preflight_<timestamp>.zmp
```

> **External-account COSes are correctly excluded.** Zimbra's `defaultExternal` COS (and any custom external COS you add to `EXTERNAL_COS_SKIP` near the top of the script) is applied only to *external virtual share-target* accounts — stubs created when a user shares a folder to an outside address. Those should **not** have IMAP enabled, so the script reports them as excluded rather than flagging them.

### 4.3 `MCE_OP3_mailbox_license_count.sh` — count the mailboxes to license

Unlike OP1/OP2, this script applies nothing — it just **reports how many mailboxes a migration will require to be licensed**, reproducing the migration binary's own account enumeration exactly: `zmprov -l gaa`, minus Zimbra **system accounts** (galsync/ham./spam./virus-quarantine), minus **external virtual accounts** (`zimbraIsExternalVirtualAccount=TRUE`). The survivors are the licensable count. Run it on the source to size your license with certainty — no guesswork, no over- or under-buying.

```bash
bash MCE_OP3_mailbox_license_count.sh --output-dir /tmp
```

It prints a full breakdown (total → system excluded → external excluded → licensable) and writes a report plus the licensable account list for your records. LDAP-only and fast — needs only `zmprov`, no per-mailbox probing. The count is **deployment-wide** (LDAP is global, so any one mailstore sees the whole system): license that number to migrate the entire deployment, or license a subset if you are migrating only selected domains. Maybe license a few extra seats if you expect to add mailboxes right before the migration; **note that the binary will not run if there are more mailboxes present than were licensed!**

### 4.4 `MCE_OP4_cos_override_report.sh` — see which accounts break CoS inheritance

Read-only, like its siblings. It lists every account-level override of a CoS-managed policy attribute that the migration will deliberately **not** carry — the loosening exemptions and provisioning leftovers (Section 2, "What does not migrate"). Security-tightening and operational-policy overrides migrate automatically and are excluded here, as is `zimbraImapEnabled` (OP1's job) — so this report is exactly your review list, nothing more. Run it before your dry run so nothing surfaces as a surprise:

```bash
bash MCE_OP4_cos_override_report.sh --output-dir /var/tmp
```

It writes a CSV report (account, attribute, value) and a `zmprov -f` reapply batch. Review the CSV: most of what remains is redundant or forgotten; anything genuinely load-bearing is usually better fixed properly (dedicated COS, app-specific password) than re-applied — but the batch re-creates it on the destination after migration if you decide that is the right call.

---

## 5. The binary — complete command reference

One operation per run. You choose backup (`-b`) **or** restore (`-r`), never both. Single or double dashes are both accepted (`-mode` and `--mode` are identical).

| Switch | Side | Default | What it does |
|---|---|---|---|
| `-b <dir>` | SOURCE | — | **Backup.** Export directory. Selects the backup operation. |
| `-r <dir>` | DEST | — | **Restore.** Import directory. Selects the restore operation. |
| `-mode <pre\|full\|post\|shares>` | both | — | Phase to run (see below). Backup accepts `pre`, `full`, `post`. `shares` is restore-only. |
| `-j <N>` | both | `1` | Parallel workers. Guidance: **CPU cores − 2** (8 cores → `-j 6`). |
| `--imapsync-groups <N>` | backup `pre`/`full` | `4` | How many round-robin IMAPSYNC runner groups to generate (parallelism for the mail copy). Typical 2–10. |
| `--imapsync-only` | backup | off | Regenerate the IMAPSYNC bundle from an **existing** export, without re-running the backup. Used with `-b` and (optionally) `--imapsync-groups`; no `-mode`. |
| `-retries <N>` | restore | `3` | Retries for a failed folder or filter import (the curl-via-proxy data path). |
| `--record <dir>` | both | off | Write a JSON-lines transcript of **every external command** the binary runs to `<dir>/commands.jsonl`. A transparency/audit aid — nothing else changes. **Handle transcripts as secrets**: they capture command arguments verbatim, including credentials. |
| `-license` | either | — | Print this binary's embedded license — domain scope, source/destination hosts, seat cap, validity — and exit. Works on any machine; no Zimbra needed. The definitive answer to "which migration is this binary for?" |
| `-h` | — | — | Usage. |

**The four modes:**

- **`pre`** — infrastructure only: Classes of Service, per-domain DKIM, domains and aliases, accounts + passwords + COS assignments, external virtual accounts, conference rooms, distribution lists + members, email aliases.
- **`post`** — mailbox data (requires `pre` done): address books, calendars, briefcase, tasks, custom-folder skeletons, filters, advanced attributes, signatures, then **share grants and mountpoints** last.
- **`full`** — `pre` + `post` in one pass. The folder-skeleton and shares steps are run *separately* afterward (see Workflow A).
- **`shares`** — restore-only. Stand-alone re-run of grants-then-mountpoints. Safe to re-run anytime (already-applied grants log non-fatal and continue); uses `zmmailbox -z`, so no admin credentials needed.

**Prompts at the start of a run** (collected up front so you can walk away):

- Backup `pre`/`full`: confirm broken-share cleanup, then the **six IMAPSYNC values** — source IMAP host, dest IMAP host, source admin user/pass, dest admin user/pass. All six required; blank aborts.
- Backup `post`/`full` and restore `post`/`full`/`shares`: a Zimbra **admin user/password** (for the curl-via-proxy data path) and the proxy host.
- **Why we ask for two (potentially different) Admin accounts when doing exports.** You can use a 2FA-enabled Admin account for the IMAPSYNC server; just be sure to create an application-specific password and use that password. 2FA-enabled Admin accounts don't work for the work that goes through the Proxy (it's an auth token thing), so that Admin account cannot have 2FA enabled. It's not uncommon that the IMAPSYNC server is hosted someplace else, so the two sets of accounts enable you to use a protected/throwaway Admin account/password for the IMAPSYNCs, and not expose TCP port 9071 to the public Internet.

**Running unattended** (stdin not a TTY): the binary reads these env vars instead of prompting (interactive runs ignore them):

```bash
# curl-via-proxy data (backup post/full, restore post/full/shares)
ZIMBRA_ADMIN_USER   ZIMBRA_ADMIN_PASS   ZIMBRA_PROXY_HOST

# IMAPSYNC credentials (backup pre/full)
IMAP_HOST1  IMAP_HOST2  IMAP_AUTHUSER1  IMAP_PASSWORD1  IMAP_AUTHUSER2  IMAP_PASSWORD2
```

---

## 6. Workflow A — Full mode

Complete Sections 3–4 first, and back up with `-mode full`.

```bash
# STEP 5 (source) — backup example command
time nice -n 19 ionice -c2 -n7 \
  mce-backup-restore -b /opt/zimbra/export -j 6 -mode full
```

1. **Transfer** the export to the destination (rsync to staging, then move into `/opt/zimbra/import`, `chown -R zimbra:zimbra`, `chmod 700`).
2. **Restore (full):**
   ```bash
   time nice -n 19 ionice -c2 -n7 \
     mce-backup-restore -r /opt/zimbra/import -j 6 -mode full
   ```
   Recreates accounts and mailbox data. Does **not** restore shares or copy mail. Typically 1–3 hours.
3. **Place the IMAPSYNC bundle.** Copy the entire `imapsync/imapsync-multi/` directory (it is self-contained) to the IMAPSYNC host.
4. **Folder skeleton:** `bash launch-all-tmux.sh justfolders` — creates every custom folder on the destination (no mail). Minutes. Required before shares.
5. **Cutover:** block user access to the source (keep the IMAPSYNC host's access), move DNS / the Elastic IP to the destination.
6. **Shares:**
   ```bash
   mce-backup-restore -r /opt/zimbra/import -j 6 -mode shares
   ```
   All folders exist now (step 4), so every grant succeeds. 5–20 minutes.
7. **Mail:** `bash launch-all-tmux.sh premigration` — the long blob copy (hours to days). In Workflow A this is the single post-cutover mail run.
8. **Verify.**

---

## 7. Workflow B — Pre/Post mode (recommended)

Complete Sections 3–4 first, and back up with `-mode pre`.

**Phase 1 — before cutover (days ahead, business hours):**

1. Back up the source with `-mode pre`; transfer the export to the destination.
2. **Restore (pre):** `mce-backup-restore -r /opt/zimbra/import -j 6 -mode pre` — infrastructure only.
3. **Folder skeleton:** `bash launch-all-tmux.sh justfolders`.
4. **Bulk mail:** `bash launch-all-tmux.sh premigration` — re-run as often as you like over the coming days; each run moves only what changed.

**Phase 2 — cutover night (short window):**

5. Block user access to the source.
6. Back up the source with `-mode post`; transfer.
7. **Restore (post):** `mce-backup-restore -r /opt/zimbra/import -j 6 -mode post` — mailbox data **and** shares in one pass (the folders already exist from Phase 1, so shares restore inline; no separate shares step needed).
8. **Final delta:** `bash launch-all-tmux.sh postmigration` — picks up the last few days of mail (see Section 8). Move DNS / the Elastic IP.
9. **Verify.**

> **Same source/destination FQDN is normal** for an NE→FOSS migration or DR: you build the new server with the old server's identity and move the AWS Elastic IP at cutover, so the hostname never changes. Your licensed binary supports this.

---

## 8. The IMAPSYNC bundle — three phases

**The bundle does two jobs beyond copying mail**, and both are why a Zimbra migration that "just copies mailboxes" gets shared folders wrong:

1. **It builds your custom folder tree.** The binary creates each account and its default Zimbra folders (`/Inbox`, `/Sent`, …), but *custom* mail folders such as `/Inbox/Projects` are created by IMAPSYNC's `justfolders` phase. That is also why `justfolders` must run before shares are restored — a grant needs its folder to already exist.
2. **It refuses to re-copy shared folders.** When a folder is shared to a user it appears in their mailbox as a *mountpoint*, not a real folder. Left alone, IMAPSYNC would copy it as a real folder and duplicate the owner's mail into the grantee's account. The binary auto-generates a per-user folder-exclude list (from each user's live folder view at backup time) so every IMAPSYNC phase skips those mountpoints — the real share is recreated by the restore instead.

The backup generates this self-contained bundle under `<export>/imapsync/imapsync-multi/`. On the IMAPSYNC host you run three phases, **in this order**:

```bash
bash launch-all-tmux.sh justfolders     # Phase 1 — folder skeleton (minutes)
bash launch-all-tmux.sh premigration    # Phase 2 — bulk mail copy (hours–days)
bash launch-all-tmux.sh postmigration   # Phase 3 — final delta (minutes; Workflow B only)
```

Each invocation fans out one detached `tmux` session per group and writes a per-group log. **Always pass the phase name** — the launcher never guesses, because `premigration` includes imapsync's destructive `--delete2` and the wrong phase at the wrong time can lose data.

- **Parallelism** is set at backup time with `--imapsync-groups N` (default 4). Use the default unless the migration is small (< ~50 GB total mail) or the source is resource-constrained — then start at 1–2 and watch source load. To change the count after a backup, regenerate the bundle with `mce-backup-restore -b <export> --imapsync-only --imapsync-groups N`.
- **Postmigration window:** the final delta defaults to the last 7 days. Size it to the full span from when the *bulk* pass started to when this delta finishes, plus a day or two. Override per run:
  ```bash
  bash launch-all-tmux.sh postmigration --maxage 10
  ```
- **Site-specific imapsync flags.** Every generated group runner has an empty `EXTRA_OPTS` array near the top; any imapsync options you add there apply to every account, in every phase. Use it for quirks specific to your environment — the classic example is the destination rejecting messages at IMAP `APPEND` time because the source stored nonstandard message flags (the fix is a `--regexflag` rule that strips or maps the offending flags); other candidates are `--maxsize` to defer oversized messages, or extra `--exclude` patterns.
- **Repeated bulk passes are cheap:** the `premigration` and `postmigration` phases keep a persistent UID cache on the IMAPSYNC host, so reruns skip already-transferred messages without re-fetching headers. The cache needs a properly provisioned directory (inodes, not gigabytes) — set it up once per [IMAPSYNC Server Preparation](MCE-IMAPSYNC-Server-Preparation.md). On a rerun, each account's summary should show nearly everything as *skipped*; a near-zero skipped count means the cache isn't being found.
- **No tmux?** Run each group directly in its own terminal: `bash imapsync-group1.sh justfolders` (repeat per group, then move to the next phase). The launcher is a major convenience; tmux is strongly recommended!

---

## 9. Licensing & support

The migration binary is licensed per customer by Mission Critical Email and is bound to your server identity; the OP1/OP2/OP3 scripts in this repository are MIT (see `LICENSE`).

**Staged (multi-wave) migrations.** Hosting a multi-tenant Zimbra system and moving it a few domains at a time? Each wave gets its own binary, licensed for exactly the domains in that wave — the binary backs up and restores *only* those domains (other tenants' accounts, DKIM signing keys, and settings never travel in that wave's backup), refuses backups containing anything outside its scope, and identifies itself with `-license`. Cross-wave shares and aliases are handled: they connect automatically once their counterpart domain arrives in a later wave. Ask us about wave licensing when you order.

To size your license before you buy, run `MCE_OP3_mailbox_license_count.sh` on your source (Section 4.3) — it reports the exact mailbox count the migration will license. For a license, a build, or migration help:

**Mission Critical Email LLC** — sales@missioncriticalemail.com
