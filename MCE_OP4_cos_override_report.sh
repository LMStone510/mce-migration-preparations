#!/bin/bash
#
# MCE_OP4_cos_override_report.sh
#
# Copyright (c) 2026 Mission Critical Email LLC.  MIT License (see LICENSE).
#
# Reports every ACCOUNT-LEVEL override of a CoS-manageable POLICY attribute
# on this Zimbra system.  Read-only: it changes nothing.
#
# WHY: Zimbra policy attributes (zimbraFeature*, quotas, protocol toggles)
# are meant to be managed at the Class of Service level.  Setting them on
# individual accounts "breaks" CoS > Account inheritance -- the account
# stops following its COS for that attribute, silently and forever.  Over
# years of administration these overrides accumulate, and most are either
# redundant or long-forgotten workarounds.
#
# The MCE migration binary (v15.7.0+) handles this class in tiers:
#
#   MIGRATED automatically (and so NOT reported here): overrides that
#   TIGHTEN security or encode per-account operational policy -- password
#   locks, forwarding-permission policy, per-seat feature grants (EWS,
#   S/MIME), POP3 toggles, quotas, session lifetimes, and the tightening
#   direction of 2FA policy (Required/Available=TRUE) and
#   PasswordMustChange=TRUE.  The restore records every one it applies in
#   applied_policy_overrides.txt, with quota overrides called out
#   separately (they interact with COS-keyed billing).
#
#   NOT migrated (REPORTED here): overrides that LOOSEN policy -- e.g. a
#   2FA exemption on an application account -- plus provisioning cruft and
#   UX toggles.  Migration is the opportunity to restore CoS discipline:
#   anything here that an account genuinely depended on will surface
#   during the dry-run "kick the tires" phase, where it can be fixed
#   properly (that web-form account under a 2FA-required COS belongs on an
#   app-specific password -- which the migration DOES carry -- not on a
#   2FA exemption).
#
#   (zimbraImapEnabled is excluded entirely: IMAP readiness is
#   MCE_OP1_imap_preflight.sh's job; this report stays unique.)
#
# This script tells you, BEFORE the migration, exactly which accounts carry
# such overrides so nothing surfaces as a surprise.  It writes:
#
#   1. A CSV report:  account, attribute, value        (review this)
#   2. A reapply file: zmprov -f batch that would re-create every override
#      on the destination.  APPLYING IT RE-BREAKS INHERITANCE DELIBERATELY.
#      Review it line by line; apply only what you conclude is genuinely
#      load-bearing, after the migration completes.
#
# User preferences (zimbraPref*) are NOT reported: users set those through
# the web client by design, and the migration carries them as user data.
#
# Usage (as the zimbra user, on the SOURCE):
#   bash MCE_OP4_cos_override_report.sh [--output-dir /var/tmp]
#
# Requires: ldapsearch, zmlocalconfig.

set -u

OUTPUT_DIR="/tmp"
while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="${2:?--output-dir needs a path}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument '$1' (only --output-dir is accepted)" >&2; exit 1 ;;
  esac
done

command -v ldapsearch >/dev/null || { echo "ERROR: ldapsearch not found" >&2; exit 1; }
command -v zmlocalconfig >/dev/null || { echo "ERROR: zmlocalconfig not found (run as the zimbra user)" >&2; exit 1; }

LDAP_URL="$(zmlocalconfig -s -m nokey ldap_url | awk '{print $1}')"
LDAP_DN="$(zmlocalconfig -s -m nokey zimbra_ldap_userdn)"
LDAP_PW="$(zmlocalconfig -s -m nokey zimbra_ldap_password)"
[ -n "$LDAP_URL" ] && [ -n "$LDAP_DN" ] && [ -n "$LDAP_PW" ] || { echo "ERROR: LDAP credentials unavailable" >&2; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUTPUT_DIR/MCE_OP4_cos_overrides_${TS}.csv"
REAPPLY="$OUTPUT_DIR/MCE_OP4_reapply_overrides_${TS}.zmp"

# The policy families reported.  zimbraFeature* is matched as a prefix; the
# rest are exact attribute names.  Deliberately excluded: zimbraPref* (user
# data), identity attributes, and per-account state the migration carries.
EXACT_ATTRS="zimbraAttachmentsBlocked zimbraAttachmentsViewInHtmlOnly zimbraMaxMailItemsPerFolder zimbraPasswordMustChange"

# Attributes the migration binary carries automatically (v15.7.0+ Tier 1):
# excluded so this report lists ONLY what will not migrate.  The tighten-only
# trio is excluded at its migrated value; the loosening (FALSE) forms ARE
# reported.  zimbraImapEnabled is OP1's domain (excluded entirely).
SKIP_ALWAYS="zimbraImapEnabled zimbraPasswordLocked zimbraFeatureMailForwardingEnabled zimbraFeatureEwsEnabled zimbraFeatureSMIMEEnabled zimbraPop3Enabled zimbraMailQuota zimbraAuthTokenLifetime zimbraAdminAuthTokenLifetime zimbraMailIdleSessionTimeout"
SKIP_WHEN_TRUE="zimbraFeatureTwoFactorAuthRequired zimbraFeatureTwoFactorAuthAvailable zimbraPasswordMustChange"

# Raw-entry search: LDAP knows nothing about CoS inheritance, so every
# attribute returned here is an EXPLICIT account-level value -- exactly the
# override set.  System accounts and external-virtual share stubs (which
# carry a deliberate hard-off zimbraFeature* posture) are excluded.
FILTER='(&(objectClass=zimbraAccount)(!(zimbraIsExternalVirtualAccount=TRUE))(!(zimbraIsSystemResource=TRUE))(!(zimbraIsSystemAccount=TRUE)))'

ldapsearch -LLL -o ldif-wrap=no -x -H "$LDAP_URL" -D "$LDAP_DN" -w "$LDAP_PW" \
  -b '' "$FILTER" '*' 2>/dev/null |
awk -v exact="$EXACT_ATTRS" -v skipalways="$SKIP_ALWAYS" -v skiptrue="$SKIP_WHEN_TRUE" '
BEGIN {
  n = split(exact, a, " ");     for (i = 1; i <= n; i++) want[a[i]] = 1
  n = split(skipalways, b, " "); for (i = 1; i <= n; i++) skipA[b[i]] = 1
  n = split(skiptrue, d, " ");   for (i = 1; i <= n; i++) skipT[d[i]] = 1
}
/^zimbraMailDeliveryAddress: / { acct = substr($0, 28); next }
/^dn: / { acct = "" ; next }
{
  # attribute name = text before the first ":" (":: " = base64 values pass
  # through verbatim; the policy attrs are booleans/numbers, so in practice
  # they are always inline)
  i = index($0, ":"); if (i == 0) next
  attr = substr($0, 1, i - 1)
  val = substr($0, i + 1); sub(/^:? /, "", val)
  if (attr in skipA) next
  if ((attr in skipT) && toupper(val) == "TRUE") next
  if (attr ~ /^zimbraFeature/ || (attr in want)) {
    if (acct != "") print acct "\t" attr "\t" val
  }
}' | sort > "$REPORT.tmp"

# Skip Zimbra service accounts by name prefix (same set the migration and
# OP3 exclude).
grep -vE '^(galsync|ham\.|spam\.|virus-quarantine)' "$REPORT.tmp" > "$REPORT.tsv" || true
rm -f "$REPORT.tmp"

TOTAL=$(wc -l < "$REPORT.tsv")
ACCOUNTS=$(cut -f1 "$REPORT.tsv" | sort -u | wc -l)

{
  echo "account,attribute,value"
  awk -F'\t' '{ printf "\"%s\",\"%s\",\"%s\"\n", $1, $2, $3 }' "$REPORT.tsv"
} > "$REPORT"

{
  echo "# MCE_OP4 reapply batch -- generated $TS"
  echo "# EVERY line below re-creates an account-level override of a CoS-managed"
  echo "# policy attribute on the destination, DELIBERATELY re-breaking CoS >"
  echo "# Account inheritance.  The MCE migration does not apply these by design."
  echo "# Review line by line; delete what should stay clean; apply the remainder"
  echo "# AFTER the migration completes:  zmprov -f $REAPPLY"
  awk -F'\t' '{ gsub(/"/, "\\\"", $3); printf "ma \"%s\" %s \"%s\"\n", $1, $2, $3 }' "$REPORT.tsv"
} > "$REAPPLY"
rm -f "$REPORT.tsv"

echo ""
echo "================================================================"
echo "CoS > Account policy-override report"
echo "  Overrides found : $TOTAL (across $ACCOUNTS account(s))"
echo "  Report (CSV)    : $REPORT"
echo "  Reapply batch   : $REAPPLY"
echo ""
echo "Everything listed above will NOT migrate (security-tightening and"
echo "operational-policy overrides migrate automatically and are recorded"
echo "by the restore in applied_policy_overrides.txt).  What remains is"
echo "mostly policy EXEMPTIONS and provisioning leftovers: review before"
echo "your dry run.  A load-bearing exemption is usually better fixed"
echo "properly (app-specific password, dedicated COS) than re-applied;"
echo "for the rest, the reapply batch re-creates them AFTER migration."
echo "================================================================"
