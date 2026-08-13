#!/bin/bash

###############################################################################################################
#                                                                                                             #
# Description     : Mailbox license-count calculator for a Zimbra migration.  Reports the number of           #
#                   mailboxes that the Mission Critical Email migration Software counts against a license,    #
#                   so a prospective customer can license precisely the right quantity -- no guesswork.       #
#                   Read-only: it inspects the source system and changes nothing.                             #
# Usage           : MCE_OP3_mailbox_license_count.sh [--domains LIST] [--output-dir DIR] [-o FILE] [-h]       #
# Last Updated    : 12 Aug 2026 (v1.1.0 - --domains scope filter for per-wave / domain-scoped licensing)      #
# Copyright 2026  : Mission Critical Email LLC. All rights reserved.                                          #
#                                                                                                             #
# What it does    :                                                                                           #
#   Reproduces the migratable-account enumeration the migration Software performs, and reports how many       #
#   mailboxes that comes to.  The pipeline is entirely LDAP-based and fast:                                   #
#                                                                                                             #
#     1. zmprov -l gaa                        -> every provisioned account in the deployment (LDAP mode)      #
#     2. drop Zimbra SYSTEM accounts          -> galsync / ham. / spam. / virus-quarantine                    #
#     3. subtract EXTERNAL VIRTUAL accounts   -> zimbraIsExternalVirtualAccount=TRUE (share stubs, no mail)   #
#                                                                                                             #
#   The surviving set is the LICENSABLE mailbox count.  The tool prints a full breakdown                      #
#   (total -> system excluded -> external excluded -> licensable) so the delta at every stage is visible,     #
#   and writes a report file plus the account list for your records.                                          #
#                                                                                                             #
# Scope note:                                                                                                 #
#   zmprov -l gaa is deployment-wide (LDAP is global), so running this on ANY one mailstore counts the        #
#   WHOLE deployment.  The number reported is for migrating the ENTIRE system.  For a DOMAIN-SCOPED           #
#   (per-wave) license, pass the wave's domains via --domains: only accounts whose primary address is in      #
#   one of those domains are counted -- the same scoping the migration Software's domain-scoped binaries      #
#   enforce.  List the PRIMARY (local) domains; alias domains ride along in the Software automatically and    #
#   never change the count (accounts are counted once, by primary address).                                   #
#                                                                                                             #
# Run as          : the 'zimbra' user, on a Zimbra mailstore in the SOURCE deployment.                        #
#                                                                                                             #
###############################################################################################################
#                                                                                                             #
# MIT License                                                                                                 #
#                                                                                                             #
# Copyright (c) 2026 Mission Critical Email LLC                                                               #
#                                                                                                             #
# Permission is hereby granted, free of charge, to any person obtaining a copy                                #
# of this software and associated documentation files (the "Software"), to deal                               #
# in the Software without restriction, including without limitation the rights                                #
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell                                   #
# copies of the Software, and to permit persons to whom the Software is                                       #
# furnished to do so, subject to the following conditions:                                                    #
#                                                                                                             #
# The above copyright notice and this permission notice shall be included in                                  #
# all copies or substantial portions of the Software.                                                         #
#                                                                                                             #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR                                  #
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,                                    #
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE                                 #
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER                                      #
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,                               #
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN                                   #
# THE SOFTWARE.                                                                                               #
#                                                                                                             #
###############################################################################################################

set -u

VERSION="1.1.0"

# ---------- defaults ----------

OUTPUT_FILE=""
OUTPUT_DIR=""
DOMAINS=""            # comma/space-separated primary domains; empty = whole deployment

# System-account exclusion pattern.  This MUST stay identical to the migration
# Software's enumeration (Go internal/backup/accounts.go, mirroring bash
# v14.2.15's `grep -vE`): local-part 'galsync' anywhere, or a leading
# 'ham.' / 'spam.' / 'virus-quarantine' with the dots ESCAPED (the v14.2.13
# data-loss fix -- an unanchored match silently dropped real users like
# graham.smith@ and whole domains like durham.ac.uk).
SYSTEM_ACCOUNT_RE='^([^@]*galsync|ham\.|spam\.|virus-quarantine[@.])'

# ---------- argument parsing ----------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      shift
      OUTPUT_FILE="${1:-}"
      shift
      ;;
    --output-dir)
      shift
      OUTPUT_DIR="${1:-}"
      shift
      ;;
    --domains)
      shift
      DOMAINS="${DOMAINS:+$DOMAINS,}${1:-}"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--domains LIST] [--output-dir DIR] [-o FILE]

Reports the number of mailboxes a Zimbra source will count against a migration
license, reproducing the migration Software's own enumeration (LDAP-only, fast):

  zmprov -l gaa  ->  [domain scope]  ->  drop system accounts
                 ->  subtract external-virtual
                 ->  LICENSABLE count = surviving accounts

Options:
  --domains LIST     Count ONLY accounts whose primary address is in one of
                     these domains (comma- or space-separated; repeatable).
                     Use this to size a DOMAIN-SCOPED (per-wave) license --
                     it applies the same scoping the migration Software's
                     domain-scoped binaries enforce.  List the PRIMARY (local)
                     domains; alias domains ride along in the Software and
                     never change the count.
  --output-dir DIR   Directory for the auto-named report file.  Default: /tmp
                     Ignored if -o is also given.
  -o FILE            Full path for the report file.
  -h, --help         Show this help.

Run as the 'zimbra' user on a mailstore in the SOURCE deployment.

Exit codes:
  0  Count produced successfully
  2  Setup / environment error
  3  No accounts found
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Run with -h for usage." >&2
      exit 2
      ;;
  esac
done

# ---------- preconditions ----------

if ! command -v zmprov >/dev/null 2>&1; then
  echo "ERROR: zmprov not found in PATH. Run this script as the 'zimbra' user on a Zimbra mailstore." >&2
  exit 2
fi

# ---------- output file path ----------

TS_FILE=$(date +%Y%m%d-%H%M%S)
if [[ -z "$OUTPUT_FILE" ]]; then
  if [[ -n "$OUTPUT_DIR" ]]; then
    if [[ ! -d "$OUTPUT_DIR" || ! -w "$OUTPUT_DIR" ]]; then
      echo "ERROR: --output-dir does not exist or is not writable: $OUTPUT_DIR" >&2
      exit 2
    fi
    OUTPUT_FILE="${OUTPUT_DIR}/MCE_OP3_mailbox_count_${TS_FILE}.txt"
  else
    OUTPUT_FILE="/tmp/MCE_OP3_mailbox_count_${TS_FILE}.txt"
  fi
fi
ACCOUNTS_FILE="${OUTPUT_FILE%.txt}_accounts.txt"

# ---------- temp files ----------

TMP_GAA=$(mktemp)   || { echo "ERROR: mktemp failed" >&2; exit 2; }
TMP_EXT=$(mktemp)   || { echo "ERROR: mktemp failed" >&2; exit 2; }
TMP_CAND=$(mktemp)  || { echo "ERROR: mktemp failed" >&2; exit 2; }
cleanup() { rm -f "$TMP_GAA" "$TMP_EXT" "$TMP_CAND"; }
trap cleanup EXIT

# ---------- step 1: all provisioned accounts ----------

echo "Enumerating accounts (zmprov -l gaa)..." >&2
if ! zmprov -l gaa > "$TMP_GAA" 2>/dev/null; then
  echo "ERROR: 'zmprov -l gaa' failed. Are you the 'zimbra' user on a running mailstore?" >&2
  exit 2
fi
# Normalize: drop blank lines, trim surrounding whitespace.
grep -v '^[[:space:]]*$' "$TMP_GAA" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' > "${TMP_GAA}.n" || true
mv "${TMP_GAA}.n" "$TMP_GAA"
TOTAL=$(grep -c . "$TMP_GAA" || true)

if [[ "$TOTAL" -eq 0 ]]; then
  echo "ERROR: No accounts returned by 'zmprov -l gaa'." >&2
  exit 3
fi

# ---------- step 1.5: domain scope (optional, mirrors the Software's F3 domain-scoped licensing) ----------

SCOPE_EXCLUDED=0
SCOPE_LIST=""
SCOPE_CSV=""
if [[ -n "$DOMAINS" ]]; then
  # Normalize the operator's list: commas/spaces -> newlines, lowercase, dedupe.
  SCOPE_LIST=$(printf '%s' "$DOMAINS" | tr ', ' '\n\n' | tr '[:upper:]' '[:lower:]' | grep -v '^[[:space:]]*$' | sort -u)
  if [[ -z "$SCOPE_LIST" ]]; then
    echo "ERROR: --domains was given but no domain names could be parsed from it." >&2
    exit 2
  fi
  # Comma-joined copy for awk -v (BSD awk rejects embedded newlines there).
  SCOPE_CSV=$(printf '%s' "$SCOPE_LIST" | tr '\n' ',')
  echo "Applying domain scope..." >&2
  # Keep only accounts whose primary address is in a scoped domain (match on
  # the part after the last '@', case-insensitive -- same rule the Software's
  # domain-scoped enumeration applies).
  awk -v doms="$SCOPE_CSV" '
    BEGIN { n = split(doms, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    { d = tolower($0); sub(/^.*@/, "", d); if (d in want) print }
  ' "$TMP_GAA" > "${TMP_GAA}.s" || true
  mv "${TMP_GAA}.s" "$TMP_GAA"
  IN_SCOPE=$(grep -c . "$TMP_GAA" || true)
  SCOPE_EXCLUDED=$(( TOTAL - IN_SCOPE ))
  if [[ "$IN_SCOPE" -eq 0 ]]; then
    echo "ERROR: No accounts have a primary address in the scoped domain(s)." >&2
    echo "       List PRIMARY (local) domains -- alias domains hold no primary addresses." >&2
    exit 3
  fi
  BASE=$IN_SCOPE
else
  BASE=$TOTAL
fi

# ---------- step 2: drop system accounts ----------

grep -vE "$SYSTEM_ACCOUNT_RE" "$TMP_GAA" > "$TMP_CAND" || true
AFTER_SYSTEM=$(grep -c . "$TMP_CAND" || true)
SYSTEM_EXCLUDED=$(( BASE - AFTER_SYSTEM ))

# ---------- step 3: subtract external-virtual accounts ----------

zmprov sa zimbraIsExternalVirtualAccount=TRUE 2>/dev/null \
  | grep -v '^[[:space:]]*$' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' > "$TMP_EXT" || true
EXTERNAL_TOTAL=$(grep -c . "$TMP_EXT" || true)

if [[ "$EXTERNAL_TOTAL" -gt 0 ]]; then
  # exact, whole-line, fixed-string subtraction (mirrors the Software's set-membership removal)
  grep -vxF -f "$TMP_EXT" "$TMP_CAND" > "${TMP_CAND}.f" 2>/dev/null || true
  mv "${TMP_CAND}.f" "$TMP_CAND"
fi
LICENSABLE=$(grep -c . "$TMP_CAND" || true)
EXTERNAL_EXCLUDED=$(( AFTER_SYSTEM - LICENSABLE ))

# licensable account list, sorted, for the operator's records
sort "$TMP_CAND" > "$ACCOUNTS_FILE"

# ---------- report ----------

TS_HUMAN=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOST=$(hostname 2>/dev/null || echo "unknown")

write_report() {
  echo "Mission Critical Email -- Zimbra Mailbox License Count"
  echo "======================================================"
  echo "Generated by : MCE_OP3_mailbox_license_count.sh (v${VERSION})"
  echo "Generated at : $TS_HUMAN"
  echo "Mailstore    : $HOST"
  echo ""
  printf '  %-42s %8d\n' "Total accounts (zmprov -l gaa):" "$TOTAL"
  if [[ -n "$SCOPE_LIST" ]]; then
    printf '  %-42s %8d   %s\n' "  - Out-of-scope accounts excluded:" "$SCOPE_EXCLUDED" "(--domains scope)"
  fi
  printf '  %-42s %8d   %s\n' "  - System accounts excluded:" "$SYSTEM_EXCLUDED" "(galsync / ham. / spam. / virus-quarantine)"
  printf '  %-42s %8d   %s\n' "  - External virtual accounts excluded:" "$EXTERNAL_EXCLUDED" "(zimbraIsExternalVirtualAccount=TRUE)"
  echo "  ============================================================"
  printf '  %-42s %8d\n' "  LICENSABLE MAILBOXES:" "$LICENSABLE"
  echo ""
  if [[ -n "$SCOPE_LIST" ]]; then
    echo "  Domain scope (licensable mailboxes per domain):"
    awk -v doms="$SCOPE_CSV" '
      BEGIN { n = split(doms, a, ",") }
      { d = tolower($0); sub(/^.*@/, "", d); cnt[d]++ }
      END {
        for (i = 1; i <= n; i++) {
          if (a[i] == "") continue
          note = (cnt[a[i]] + 0 == 0) ? "   <- zero; alias domain or typo?" : ""
          printf "    %-40s %8d%s\n", a[i] ":", cnt[a[i]] + 0, note
        }
      }
    ' "$ACCOUNTS_FILE"
    echo ""
    echo "  This is the count to license for a DOMAIN-SCOPED (wave) binary covering"
    echo "  the domain(s) above."
  else
    echo "  This is the count to license for migrating the ENTIRE deployment."
    echo "  To migrate only a subset of domains, re-run with --domains."
  fi
}

{
  write_report
  echo ""
  echo "  Licensable account list: $ACCOUNTS_FILE"
  echo "  This report:             $OUTPUT_FILE"
} | tee "$OUTPUT_FILE"

exit 0
