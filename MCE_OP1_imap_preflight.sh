#!/bin/bash

###############################################################################################################
#                                                                                                             #
# Description     : IMAP pre-flight check for Zimbra migration                                                #
# Usage           : MCE_OP1_imap_preflight.sh [-o /tmp/output.zmp] [--output-dir DIR] [-h]                    #
# Last Updated    : 14 Jun 2026 (v14.1.9 - exclude external-account CoSes from IMAP remediation)              #
# Copyright 2026  : Mission Critical Email LLC. All rights reserved.                                          #
#                                                                                                             #
# What it does    :                                                                                           #
#   Scans the local Zimbra system for Classes of Service and accounts where                                   #
#   zimbraImapEnabled is FALSE, and emits a single Zimbra bulk-provisioning                                   #
#   file containing the zmprov commands needed to turn IMAP ON.                                               #
#                                                                                                             #
#   The output file is NOT applied automatically.  The operator reviews it                                    #
#   and applies it manually with:                                                                             #
#       zmprov -f /tmp/MCE_OP1_imap_preflight_<timestamp>.zmp                                                 #
#                                                                                                             #
#   Run on source BEFORE the migration backup so IMAPSYNC has IMAP-enabled                                    #
#   accounts to log into.  Optionally run on destination after restore so                                     #
#   the migrated accounts have IMAP available to end users.                                                   #
#                                                                                                             #
# Why this matters:                                                                                           #
#   If a source account has zimbraImapEnabled=FALSE, IMAPSYNC cannot log                                      #
#   in to copy its mail and the account's data is silently skipped during                                     #
#   migration.  Disabled IMAP is common on admin accounts, service accounts,                                  #
#   and anywhere a hardening policy turned IMAP off.                                                          #
#                                                                                                             #
# Correctness — CoS inheritance:                                                                              #
#   zimbraImapEnabled inherits from the account's CoS unless explicitly set                                   #
#   on the account.  This script distinguishes the two cases by querying                                      #
#   LDAP directly: an LDAP search for `zimbraImapEnabled=FALSE` returns                                       #
#   exactly the accounts that have an EXPLICIT account-level override                                         #
#   (inherited values are not stored on the account's LDAP entry).                                            #
#                                                                                                             #
#   Accounts whose IMAP is FALSE only because of CoS inheritance are fixed                                    #
#   automatically when the CoS-level `mc` line is applied — no per-account                                    #
#   `ma` line is emitted for them, so we avoid creating spurious account-                                     #
#   level overrides that would shadow future CoS changes.                                                     #
#                                                                                                             #
# Efficiency:                                                                                                 #
#   Uses ldapsearch (a tiny C client) against Zimbra's local LDAP — one                                       #
#   query for all CoSes, one query for all accounts.  Avoids the per-record                                   #
#   JVM-startup cost that per-account `zmprov ga` calls would incur.                                          #
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

# ---------- argument parsing ----------

VERSION="14.1.9"

# External-account Classes of Service to EXCLUDE from the IMAP-enable
# remediation (one name per line).  These CoSes are applied ONLY to external
# virtual accounts (zimbraIsExternalVirtualAccount=TRUE) -- the stub accounts
# Zimbra auto-creates when an internal user shares a folder to an outside email
# address (e.g. share-ee@gmail.com).  Such accounts are NOT real mailboxes:
# they carry no mail for IMAPSYNC to copy, and they must NOT have IMAP enabled
# (an external share-target should never accept an IMAP login).  Flagging them
# was a false positive (found on a real migration, 2026-06-14).  Zimbra's
# built-in external CoS is "defaultExternal"; add any custom external CoS names
# below if your deployment uses them.
EXTERNAL_COS_SKIP="defaultExternal"

OUTPUT_FILE=""
OUTPUT_DIR=""
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
Usage: $(basename "$0") [-o /path/to/output.zmp] [--output-dir DIR]

Scans the local Zimbra system for IMAP-disabled CoSes and accounts and
emits a bulk-provisioning file to enable IMAP on each.

Options:
  -o <path>          Full output file path.  Default:
                     <output-dir>/MCE_OP1_imap_preflight_<timestamp>.zmp
  --output-dir <DIR> Directory for the auto-named output file.  Default: /tmp
                     Ignored if -o is also given.
  -h, --help         Show this help.

Apply the generated file with:
  zmprov -f <output_file>

Exit codes:
  0  No fixes needed (every CoS and account already has IMAP enabled)
  1  Fixes were generated (operator should review the output file and apply it)
  2  Setup / environment error
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

# OUTPUT_FILE wins if both are set; otherwise auto-name into OUTPUT_DIR (or /tmp)
if [[ -z "$OUTPUT_FILE" ]]; then
  if [[ -n "$OUTPUT_DIR" ]]; then
    if [[ ! -d "$OUTPUT_DIR" ]]; then
      echo "ERROR: --output-dir does not exist: $OUTPUT_DIR" >&2
      exit 2
    fi
    if [[ ! -w "$OUTPUT_DIR" ]]; then
      echo "ERROR: --output-dir not writable: $OUTPUT_DIR" >&2
      exit 2
    fi
    OUTPUT_FILE="${OUTPUT_DIR}/MCE_OP1_imap_preflight_$(date +%Y%m%d-%H%M%S).zmp"
  else
    OUTPUT_FILE="/tmp/MCE_OP1_imap_preflight_$(date +%Y%m%d-%H%M%S).zmp"
  fi
fi

# ---------- preconditions ----------

if ! command -v zmlocalconfig >/dev/null 2>&1; then
  echo "ERROR: zmlocalconfig not found in PATH. Run this script as the zimbra user on a Zimbra mailstore." >&2
  exit 2
fi

if ! command -v ldapsearch >/dev/null 2>&1; then
  echo "ERROR: ldapsearch not found in PATH. Install openldap-clients (or equivalent)." >&2
  exit 2
fi

# ---------- LDAP credentials from zmlocalconfig ----------

# zmlocalconfig -s outputs "key = value"; strip the "key = " prefix.
# ldap_url may list multiple URLs space-separated; take the first.
LDAP_URL=$(zmlocalconfig -s ldap_url 2>/dev/null | sed -E 's/^[^=]*= ?//' | awk '{print $1}')
LDAP_USERDN=$(zmlocalconfig -s zimbra_ldap_userdn 2>/dev/null | sed -E 's/^[^=]*= ?//')
LDAP_PASSWORD=$(zmlocalconfig -s zimbra_ldap_password 2>/dev/null | sed -E 's/^[^=]*= ?//')

if [[ -z "$LDAP_URL" || -z "$LDAP_USERDN" || -z "$LDAP_PASSWORD" ]]; then
  echo "ERROR: Could not retrieve LDAP credentials from zmlocalconfig." >&2
  echo "  ldap_url:            ${LDAP_URL:-<missing>}" >&2
  echo "  zimbra_ldap_userdn:  ${LDAP_USERDN:-<missing>}" >&2
  echo "  zimbra_ldap_password: ${LDAP_PASSWORD:+<set>}${LDAP_PASSWORD:-<missing>}" >&2
  exit 2
fi

# ---------- helper: LDAP search ----------

ldap_search() {
  # $1 = base DN, $2 = filter, $3 = attribute to return
  ldapsearch -LLL -o ldif-wrap=no -x \
    -H "$LDAP_URL" \
    -D "$LDAP_USERDN" \
    -w "$LDAP_PASSWORD" \
    -b "$1" \
    "$2" "$3" 2>/dev/null \
    | awk -v attr="$3" 'BEGIN{IGNORECASE=1} $1 == attr":" { sub(/^[^:]*: /, ""); print }'
}

# ---------- scan CoSes ----------

# Zimbra CoS entries live at cn=cos,cn=zimbra and have objectClass=zimbraCOS.
# An LDAP search for zimbraImapEnabled=FALSE returns only CoSes with an explicit FALSE
# (the default-unset case is treated as TRUE by Zimbra).
COS_NAMES_RAW=$(ldap_search "cn=cos,cn=zimbra" "(&(objectClass=zimbraCOS)(zimbraImapEnabled=FALSE))" "cn")

# v14.1.9: drop external-account CoSes (see EXTERNAL_COS_SKIP).  IMAP is
# CORRECTLY disabled on these; enabling it would be wrong, so they are excluded
# from the remediation instead of flagged.
if [[ -n "${EXTERNAL_COS_SKIP//[[:space:]]/}" ]]; then
  COS_NAMES=$(printf '%s\n' "$COS_NAMES_RAW" | grep -vxF -f <(printf '%s\n' "$EXTERNAL_COS_SKIP") || true)
else
  COS_NAMES="$COS_NAMES_RAW"
fi
COS_COUNT=$(printf '%s\n' "$COS_NAMES" | grep -c . || true)
COS_EXCLUDED_COUNT=$(( $(printf '%s\n' "$COS_NAMES_RAW" | grep -c . || true) - COS_COUNT ))

# ---------- scan accounts ----------

# Account entries live under ou=people,<domain-dn>.  An empty base DN ("") in
# ldapsearch performs a subtree-wide search; combined with the account
# objectClass and the FALSE filter, this returns exactly the accounts that
# have an explicit account-level zimbraImapEnabled=FALSE.  Inherited values
# from CoS are not stored on the account entry and therefore do not match.
ACCOUNT_EMAILS=$(ldap_search "" "(&(objectClass=zimbraAccount)(zimbraImapEnabled=FALSE))" "zimbraMailDeliveryAddress")
ACCOUNT_COUNT=$(printf '%s\n' "$ACCOUNT_EMAILS" | grep -c .)

# ---------- write output ----------

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
TOTAL=$((COS_COUNT + ACCOUNT_COUNT))

{
  echo "# Zimbra IMAP pre-flight provisioning script"
  echo "# Generated by MCE_OP1_imap_preflight.sh (v${VERSION})"
  echo "# Generated at: $TIMESTAMP"
  echo "# Source LDAP:  $LDAP_URL"
  echo "#"
  echo "# Apply with:  zmprov -f $OUTPUT_FILE"
  echo "#"
  echo "# Run on the SOURCE Zimbra system before the migration backup so that"
  echo "# IMAPSYNC has IMAP-enabled accounts to authenticate against.  Optionally"
  echo "# apply on the DESTINATION after restore if end users will need IMAP."
  echo "#"

  if [[ $TOTAL -eq 0 ]]; then
    echo "# No work required — every Class of Service and every account already has"
    echo "# zimbraImapEnabled=TRUE (or no explicit FALSE override).  IMAPSYNC will be"
    echo "# able to authenticate to all accounts on this Zimbra system as-is."
  else
    if [[ $COS_EXCLUDED_COUNT -gt 0 ]]; then
      echo ""
      echo "# Excluded $COS_EXCLUDED_COUNT external-account Class(es) of Service from the"
      echo "# IMAP remediation (EXTERNAL_COS_SKIP): $EXTERNAL_COS_SKIP"
      echo "# These apply only to external virtual share-target accounts, which must"
      echo "# NOT have IMAP enabled.  No 'mc' line is emitted for them by design."
    fi

    if [[ $COS_COUNT -gt 0 ]]; then
      echo ""
      echo "# Classes of Service with zimbraImapEnabled=FALSE ($COS_COUNT)"
      echo "# Fixing at the CoS level cascades to every account inheriting from that CoS."
      while IFS= read -r cos; do
        [[ -z "$cos" ]] && continue
        printf 'mc "%s" zimbraImapEnabled TRUE\n' "$cos"
      done <<< "$COS_NAMES"
    fi

    if [[ $ACCOUNT_COUNT -gt 0 ]]; then
      echo ""
      echo "# Accounts with EXPLICIT account-level zimbraImapEnabled=FALSE ($ACCOUNT_COUNT)"
      echo "# These accounts have an account-level override and won't be reached by"
      echo "# the CoS-level fix above; they need their explicit override flipped."
      while IFS= read -r email; do
        [[ -z "$email" ]] && continue
        printf 'ma %s zimbraImapEnabled TRUE\n' "$email"
      done <<< "$ACCOUNT_EMAILS"
    fi
  fi
} > "$OUTPUT_FILE"

# ---------- summary to stdout ----------

echo ""
echo "Zimbra IMAP Pre-flight Check"
echo "============================"
echo "Classes of Service with IMAP disabled: $COS_COUNT"
if [[ $COS_EXCLUDED_COUNT -gt 0 ]]; then
  echo "  (excluded $COS_EXCLUDED_COUNT external-account CoS: $EXTERNAL_COS_SKIP -- must stay IMAP-disabled)"
fi
echo "Accounts with explicit IMAP disabled:  $ACCOUNT_COUNT"
echo ""
echo "Output file: $OUTPUT_FILE"
echo ""
if [[ $TOTAL -eq 0 ]]; then
  echo "No action required — IMAP is enabled everywhere it matters."
  exit 0
else
  echo "To apply on this Zimbra system (turn IMAP ON for the affected CoSes and accounts):"
  echo "    zmprov -f $OUTPUT_FILE"
  echo ""
  echo "Review the file first; the operator decides when and where to apply it."
  exit 1
fi
