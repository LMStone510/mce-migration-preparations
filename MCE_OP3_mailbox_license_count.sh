#!/bin/bash

###############################################################################################################
#                                                                                                             #
# Description     : Mailbox license-count calculator for a Zimbra migration.  Reports the number of           #
#                   mailboxes that the Mission Critical Email migration Software counts against a license,    #
#                   so a prospective customer can license precisely the right quantity -- no guesswork.       #
#                   Read-only: it inspects the source system and changes nothing.                             #
# Usage           : MCE_OP3_mailbox_license_count.sh [--output-dir DIR] [-o FILE] [-h]                        #
# Last Updated    : 01 Jul 2026 (v1.0.0 - initial release)                                                    #
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
#   WHOLE deployment.  The number reported is for migrating the ENTIRE system; if you plan to migrate only    #
#   a subset of accounts, license that subset.                                                                #
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

VERSION="1.0.0"

# ---------- defaults ----------

OUTPUT_FILE=""
OUTPUT_DIR=""

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
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--output-dir DIR] [-o FILE]

Reports the number of mailboxes a Zimbra source will count against a migration
license, reproducing the migration Software's own enumeration (LDAP-only, fast):

  zmprov -l gaa  ->  drop system accounts  ->  subtract external-virtual
                 ->  LICENSABLE count = surviving accounts

Options:
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

# ---------- step 2: drop system accounts ----------

grep -vE "$SYSTEM_ACCOUNT_RE" "$TMP_GAA" > "$TMP_CAND" || true
AFTER_SYSTEM=$(grep -c . "$TMP_CAND" || true)
SYSTEM_EXCLUDED=$(( TOTAL - AFTER_SYSTEM ))

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
  printf '  %-42s %8d   %s\n' "  - System accounts excluded:" "$SYSTEM_EXCLUDED" "(galsync / ham. / spam. / virus-quarantine)"
  printf '  %-42s %8d   %s\n' "  - External virtual accounts excluded:" "$EXTERNAL_EXCLUDED" "(zimbraIsExternalVirtualAccount=TRUE)"
  echo "  ============================================================"
  printf '  %-42s %8d\n' "  LICENSABLE MAILBOXES:" "$LICENSABLE"
  echo ""
  echo "  This is the count to license for migrating the ENTIRE deployment."
  echo "  To migrate only a subset of accounts, license that subset instead."
}

{
  write_report
  echo ""
  echo "  Licensable account list: $ACCOUNTS_FILE"
  echo "  This report:             $OUTPUT_FILE"
} | tee "$OUTPUT_FILE"

exit 0
