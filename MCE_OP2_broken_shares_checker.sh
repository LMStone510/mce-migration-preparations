#!/bin/bash

###############################################################################################################
#                                                                                                             #
# Description     : Operator preflight that scans a Zimbra source system for THREE categories of broken       #
#                   shares.  Produces CSV reports plus reviewable removal scripts.  Read-only by itself;      #
#                   cleanup only happens when the operator chooses to execute the generated removal scripts.  #
#                                                                                                             #
# Usage           : MCE_OP2_broken_shares_checker.sh [--jobs N] [--delay SEC]                                 #
#                                                   [--timeout SEC] [--output-dir DIR] [-h]                   #
# Last Updated    : 30 May 2026 (script version 2.1.0)                                                        #
#                                                                                                             #
# Why this exists :                                                                                           #
#   Broken shares accumulate over time on any long-running Zimbra system as users are added/removed,          #
#   shares are revoked, mailbox-move workflows leave residue, etc.  At migration time these surface as        #
#   noisy log entries and partial failures on the destination -- the migration script cannot tell which       #
#   failures are real and which trace back to source-side data corruption.  Cleaning them up BEFORE the       #
#   migration moves the noise from migration time (irrecoverable, mid-cutover) to a quiet preflight pass      #
#   where the operator can review and act with confidence.  Useful outside migration cycles too -- many       #
#   operators run this periodically to keep zimbraSharedItem state tidy.                                      #
#                                                                                                             #
# What it detects :                                                                                           #
#   1. INBOUND broken shares (broken mount points).  Folders in user mailboxes that are mount points to       #
#      shares whose source folder no longer exists or is inaccessible.  Detected via zmsoap                   #
#      GetFolderRequest looking for the broken="1" XML attribute.                                             #
#   2. OUTBOUND broken shares (invalid recipients).  Shares granted by users TO recipients that no longer     #
#      exist on the system.  Detected by reading each user's zimbraSharedItem LDAP attribute and attempting   #
#      to resolve each grantee back to a live account.                                                        #
#   3. STALE ACL entries (zimbraSharedItem outliving its grant).  Entries listed in a user's                  #
#      zimbraSharedItem cache that no longer have a matching grant on the actual folder ACL -- typically      #
#      because the share was revoked through the web UI but the LDAP cache was never synchronously cleaned    #
#      up.  At migration restore time these cause service.PERM_DENIED when the destination tries to           #
#      recreate the mount point, because no underlying grant exists on the destination folder.  Detected      #
#      by reading each user's zimbraSharedItem and cross-referencing every entry against the live folder      #
#      ACL via `zmmailbox gfg <folder>` on the owner's mailbox.  A zimbraSharedItem entry whose grantee is    #
#      not present in the matching folder's actual ACL is flagged stale.                                      #
#                                                                                                             #
# Output          :                                                                                           #
#   - 3 CSV reports (INBOUND mount points, OUTBOUND grants, STALE ACL entries)                                #
#   - 3 removal scripts (review and execute manually if appropriate)                                          #
#   - 1 unified log file                                                                                      #
#   - 1 skipped-accounts file (accounts excluded by the reachability probe)                                   #
#   All output files go to the --output-dir (default /var/tmp/) with a timestamp suffix.                      #
#                                                                                                             #
# Version history : See the companion MCE_OP2_broken_shares_checker_CHANGELOG.txt file                        #
#                   for per-release behavior changes.                                                         #
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

set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Script version
VERSION="2.1.0"

# ---------------------------------------------------------------------------
# Defaults (overridable via CLI flags parsed in parse_args)
# ---------------------------------------------------------------------------
DELAY_BETWEEN_USERS_DEFAULT="0.2"   # Seconds between per-user checks
ZMSOAP_TIMEOUT_DEFAULT=300          # Per-user zmsoap timeout (sec)
OUTPUT_DIR_DEFAULT="/var/tmp"       # Directory for reports / logs
PROBE_JOBS_DEFAULT=4                # Parallel jobs for reachability probe

# Filled in by parse_args
DELAY_BETWEEN_USERS=""
ZMSOAP_TIMEOUT=""
OUTPUT_DIR=""
PROBE_JOBS=""

# Behavior settings (not currently exposed as CLI flags)
SKIP_ON_TIMEOUT=true   # On second-try timeout, skip user (false = abort)
NICE_PRIORITY=19
IONICE_CLASS=3

# Output paths -- set after parse_args
TIMESTAMP=""
LOG_FILE=""
INBOUND_CSV=""
OUTBOUND_CSV=""
INBOUND_SCRIPT=""
OUTBOUND_SCRIPT=""
SKIPPED_ACCOUNTS_FILE=""
# v2.0.0: stale-ACL detection (Bug C)
STALE_ACL_CSV=""
STALE_ACL_SCRIPT=""

# Color codes (only enabled when stdout is a TTY)
if [[ -t 1 ]]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[1;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
fi

# LDAP connection parameters (populated by get_ldap_settings)
LDAP_MASTER_URL=""
LDAP_BIND_DN=""
ZIMBRA_LDAP_PASSWORD=""
ZIMBRA_LDAP_BASE=""

# LDAP base DN override (empty = auto-detect)
LDAP_BASE_DN_OVERRIDE=""

# Temp files used during the run
LDAP_FALLBACK_WARNED_FILE=""
USERS_TEMP_FILE=""

################################################################################
# Function: log_message
# Description:
#   Emits a timestamped message to console (with color for the level prefix
#   when stdout is a TTY) and appends a plain-text version (no ANSI codes) to
#   the log file.
# Signature:
#   log_message LEVEL "message"
#     LEVEL: INFO | WARNING | ERROR | SUCCESS
################################################################################
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +"%H:%M:%S")

    local color="" prefix=""
    case "$level" in
        ERROR)   color="$RED";    prefix="[ERROR]" ;;
        WARNING) color="$YELLOW"; prefix="[WARNING]" ;;
        SUCCESS) color="$GREEN";  prefix="[SUCCESS]" ;;
        INFO)    color="";        prefix="" ;;
        *)       color="";        prefix="[$level]" ;;
    esac

    # Console (stderr): colored when a TTY, plain when piped
    local console_text
    if [[ -n "$prefix" ]]; then
        console_text="[${timestamp}] ${color}${prefix}${NC} ${message}"
    else
        console_text="[${timestamp}] ${message}"
    fi
    echo -e "$console_text" >&2

    # Log file: always plain text, no ANSI escapes
    if [[ -n "${LOG_FILE:-}" ]]; then
        local plain_text
        if [[ -n "$prefix" ]]; then
            plain_text="[${timestamp}] ${prefix} ${message}"
        else
            plain_text="[${timestamp}] ${message}"
        fi
        # Strip any ANSI escapes the caller may have embedded
        plain_text=$(printf '%s' "$plain_text" | sed 's/\x1b\[[0-9;]*m//g')
        echo "$plain_text" >> "$LOG_FILE"
    fi
}

################################################################################
# Function: usage
# Description: Print --help text and exit.
################################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Scans the local Zimbra source for broken inbound mountpoints and broken
outbound share grants.  Run as the zimbra user on a mailbox server BEFORE
running MissionCriticalEmail_Backup-Restore in pre/full mode.

Options:
  --jobs N              Parallel jobs for the reachability probe phase
                        (default: ${PROBE_JOBS_DEFAULT}; requires GNU Parallel; pass 1 for sequential)
  --delay SECONDS       Delay between user checks in the inbound scan
                        (default: ${DELAY_BETWEEN_USERS_DEFAULT})
  --timeout SECONDS     zmsoap timeout per user (default: ${ZMSOAP_TIMEOUT_DEFAULT})
  --output-dir DIR      Directory for CSV / log / removal-script output
                        (default: ${OUTPUT_DIR_DEFAULT})
  -h, --help            Show this help

Exit codes:
  0 = no broken shares found
  1 = broken shares found (operator action recommended)
  2 = setup / environment error
  3 = no reachable users found on this server
EOF
}

################################################################################
# Function: parse_args
# Description: Parse command-line flags into globals; compute output paths.
################################################################################
parse_args() {
    DELAY_BETWEEN_USERS="$DELAY_BETWEEN_USERS_DEFAULT"
    ZMSOAP_TIMEOUT="$ZMSOAP_TIMEOUT_DEFAULT"
    OUTPUT_DIR="$OUTPUT_DIR_DEFAULT"
    PROBE_JOBS="$PROBE_JOBS_DEFAULT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --jobs)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --jobs requires a value" >&2
                    exit 2
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
                    echo "ERROR: --jobs must be a positive integer (got: $2)" >&2
                    exit 2
                fi
                PROBE_JOBS="$2"
                shift 2
                ;;
            --delay)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --delay requires a value" >&2
                    exit 2
                fi
                DELAY_BETWEEN_USERS="$2"
                shift 2
                ;;
            --timeout)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --timeout requires a value" >&2
                    exit 2
                fi
                ZMSOAP_TIMEOUT="$2"
                shift 2
                ;;
            --output-dir)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --output-dir requires a value" >&2
                    exit 2
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                echo "" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "ERROR: output directory does not exist: $OUTPUT_DIR" >&2
        exit 2
    fi
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        echo "ERROR: output directory not writable by current user: $OUTPUT_DIR" >&2
        exit 2
    fi

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    LOG_FILE="${OUTPUT_DIR}/broken-shares-unified-${TIMESTAMP}.log"
    INBOUND_CSV="${OUTPUT_DIR}/broken-inbound-shares-${TIMESTAMP}.csv"
    OUTBOUND_CSV="${OUTPUT_DIR}/broken-outbound-shares-${TIMESTAMP}.csv"
    INBOUND_SCRIPT="${OUTPUT_DIR}/remove-broken-inbound-shares-${TIMESTAMP}.sh"
    OUTBOUND_SCRIPT="${OUTPUT_DIR}/remove-broken-outbound-shares-${TIMESTAMP}.sh"
    SKIPPED_ACCOUNTS_FILE="${OUTPUT_DIR}/broken-shares-skipped-accounts-${TIMESTAMP}.txt"
    # v2.0.0: stale-ACL detection (Bug C)
    STALE_ACL_CSV="${OUTPUT_DIR}/stale-acl-shares-${TIMESTAMP}.csv"
    STALE_ACL_SCRIPT="${OUTPUT_DIR}/remove-stale-acl-shares-${TIMESTAMP}.sh"
}

################################################################################
# Function: get_ldap_settings
# Description: Retrieves LDAP connection parameters from Zimbra configuration.
################################################################################
get_ldap_settings() {
    log_message INFO "Retrieving LDAP connection parameters..."

    if [[ ! -f /opt/zimbra/bin/zmshutil ]]; then
        log_message ERROR "Cannot find /opt/zimbra/bin/zmshutil"
        log_message ERROR "This script must be run as the zimbra user on a Zimbra mailbox server"
        exit 2
    fi

    # zmshutil references unset variables; temporarily disable -u for it
    set +u
    source /opt/zimbra/bin/zmshutil
    zmsetvars zimbra_ldap_password ldap_master_url zimbra_ldap_userdn
    set -u

    LDAP_MASTER_URL="$ldap_master_url"
    LDAP_BIND_DN="$zimbra_ldap_userdn"
    ZIMBRA_LDAP_PASSWORD="$zimbra_ldap_password"

    if [[ -z "$LDAP_MASTER_URL" ]] || [[ -z "$LDAP_BIND_DN" ]] || [[ -z "$ZIMBRA_LDAP_PASSWORD" ]]; then
        log_message ERROR "Failed to retrieve LDAP connection parameters"
        exit 2
    fi

    # Determine LDAP base DN -- key names and output formats vary across
    # Zimbra versions and OS environments.  Each attempt is evaluated
    # independently so an empty result from one does not block the next.
    ZIMBRA_LDAP_BASE=""
    local _val

    # Attempt 1: ldap_root (explicit override key; often unset)
    _val=$(zmlocalconfig -s -m nokey ldap_root 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n "$_val" ]] && ZIMBRA_LDAP_BASE="$_val"

    # Attempt 2: zimbra_ldap_suffix with -m nokey
    if [[ -z "$ZIMBRA_LDAP_BASE" ]]; then
        _val=$(zmlocalconfig -s -m nokey zimbra_ldap_suffix 2>/dev/null | tr -d '[:space:]' || true)
        [[ -n "$_val" ]] && ZIMBRA_LDAP_BASE="$_val"
    fi

    # Attempt 3: zimbra_ldap_suffix without -m nokey
    if [[ -z "$ZIMBRA_LDAP_BASE" ]]; then
        _val=$(zmlocalconfig -s zimbra_ldap_suffix 2>/dev/null | awk -F' = ' 'NF>1{print $2}' | tr -d '[:space:]' || true)
        [[ -n "$_val" ]] && ZIMBRA_LDAP_BASE="$_val"
    fi

    # Attempt 4: query LDAP root DSE namingContexts directly
    if [[ -z "$ZIMBRA_LDAP_BASE" ]] && [[ -n "${LDAP_MASTER_URL:-}" ]]; then
        _val=$(ldapsearch -x -H "$LDAP_MASTER_URL" \
            -D "$LDAP_BIND_DN" -w "$ZIMBRA_LDAP_PASSWORD" \
            -s base -b "" namingContexts 2>/dev/null | \
            grep "^namingContexts:" | grep -v "cn=" | \
            head -1 | awk '{print $2}' | tr -d '[:space:]' || true)
        [[ -n "$_val" ]] && ZIMBRA_LDAP_BASE="$_val"
    fi

    # Attempt 5: derive from primary domain.  In standard Zimbra multi-tenant
    # deployments all user accounts live under ou=people,dc=<primary-domain>
    # regardless of how many hosted domains the server carries.
    if [[ -z "$ZIMBRA_LDAP_BASE" ]]; then
        _val=$(zmprov gcf zimbraDefaultDomainName 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' || true)
        if [[ -n "$_val" ]]; then
            ZIMBRA_LDAP_BASE="dc=$(echo "$_val" | sed 's/\./,dc=/g')"
        fi
    fi
    unset _val

    if [[ -n "$ZIMBRA_LDAP_BASE" ]]; then
        log_message INFO "  LDAP base: $ZIMBRA_LDAP_BASE"
    else
        log_message WARNING "Could not determine LDAP base DN from localconfig or root DSE"
        log_message WARNING "Outbound check will use per-domain fallback DNs; set LDAP_BASE_DN_OVERRIDE if incorrect"
    fi

    log_message SUCCESS "LDAP connection parameters retrieved"

    LDAP_FALLBACK_WARNED_FILE=$(mktemp)
}

################################################################################
# Function: get_ldap_base_dn
# Description: Get LDAP base DN for a domain, with fallback logic.
################################################################################
get_ldap_base_dn() {
    local domain="$1"

    if [[ -n "$LDAP_BASE_DN_OVERRIDE" ]]; then
        echo "$LDAP_BASE_DN_OVERRIDE"
        return 0
    fi

    if [[ -n "$ZIMBRA_LDAP_BASE" ]]; then
        echo "$ZIMBRA_LDAP_BASE"
        return 0
    fi

    local fallback_dn="ou=people,dc=$(echo "$domain" | sed 's/\./,dc=/g')"

    # One warning per domain.  Use a temp file rather than an associative array
    # so the state survives command-substitution subshells.
    if [[ -n "$LDAP_FALLBACK_WARNED_FILE" ]] && \
       ! grep -qxF "$domain" "$LDAP_FALLBACK_WARNED_FILE" 2>/dev/null; then
        echo "$domain" >> "$LDAP_FALLBACK_WARNED_FILE"
        log_message WARNING "LDAP base DN not found via zmlocalconfig; using fallback for $domain: $fallback_dn"
        log_message WARNING "If users are missing from results, set LDAP_BASE_DN_OVERRIDE at top of script."
    fi
    echo "$fallback_dn"
}

################################################################################
# Function: check_prerequisites
# Description: Verify required commands are available.
################################################################################
check_prerequisites() {
    local required_commands=("zmprov" "zmmailbox" "ldapsearch" "zmsoap")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_message ERROR "Required command not found: $cmd"
            exit 2
        fi
    done
}

################################################################################
# Function: probe_one_account
# Description:
#   v1.3.1: Worker function for the reachability probe.  Takes one email,
#   runs `zmmailbox -z -m <user> gms`, and emits a single tab-separated
#   result line on stdout:
#       KEEP\t<email>                 (reachable)
#       SKIP\t<email>\t<reason>       (unreachable, with classified reason)
#   Designed to be invoked via GNU Parallel; the parent collects all stdout
#   into one file and partitions into users/skipped via awk.
################################################################################
probe_one_account() {
    local email="$1"
    local probe_out probe_rc
    probe_out=$(zmmailbox -z -m "$email" gms 2>&1)
    probe_rc=$?

    if [[ $probe_rc -eq 0 ]]; then
        printf 'KEEP\t%s\n' "$email"
        return 0
    fi

    local reason="reachability_probe_failed"
    if echo "$probe_out" | grep -q -i "no such account"; then
        reason="no_such_account"
    elif echo "$probe_out" | grep -q -i "wrong host\|account is not"; then
        reason="wrong_mailstore_or_disabled"
    elif echo "$probe_out" | grep -q -i "maintenance"; then
        reason="account_in_maintenance"
    fi
    printf 'SKIP\t%s\t%s\n' "$email" "$reason"
}
export -f probe_one_account

################################################################################
# Function: get_all_active_users
# Description:
#   Returns the path to a temp file listing all reachable user accounts.
#   Candidates from `zmprov -l gaa` are filtered via a reachability probe
#   (`zmmailbox -z -m <user> gms`) that succeeds only when the LDAP entry
#   AND a live, reachable mailbox both exist on this mailstore.  Skipped
#   accounts (with reason) are written to $SKIPPED_ACCOUNTS_FILE for
#   operator audit.  Same probe pattern used by the v14.1.7+ main script.
#
#   v1.3.1: probe parallelized via GNU Parallel (--jobs N).  Falls back to
#   sequential when Parallel is not installed or --jobs=1 is passed.
################################################################################
get_all_active_users() {
    log_message INFO "Querying for all candidate user accounts (zmprov -l gaa)..."

    local candidates_file users_file probe_results
    candidates_file=$(mktemp)
    users_file=$(mktemp)
    probe_results=$(mktemp)
    USERS_TEMP_FILE="$users_file"

    if ! zmprov -l gaa > "$candidates_file"; then
        log_message ERROR "Failed to retrieve user list"
        rm -f "$candidates_file" "$users_file" "$probe_results"
        exit 2
    fi

    local candidate_count
    candidate_count=$(wc -l < "$candidates_file" | tr -d ' ')

    if [[ "$candidate_count" -eq 0 ]]; then
        log_message ERROR "No accounts found on this server"
        rm -f "$candidates_file" "$users_file" "$probe_results"
        exit 3
    fi

    # Initialize the skipped-accounts audit file
    echo "# Accounts skipped by MCE_OP2 reachability probe (tab-separated: email <TAB> reason)" > "$SKIPPED_ACCOUNTS_FILE"

    # Choose execution mode: parallel if available + requested, else sequential
    if [[ "$PROBE_JOBS" -gt 1 ]] && command -v parallel >/dev/null 2>&1; then
        log_message INFO "Probing $candidate_count candidate(s) via reachability probe (GNU Parallel, $PROBE_JOBS jobs)..."
        parallel --no-notice -j "$PROBE_JOBS" probe_one_account :::: "$candidates_file" > "$probe_results"
    else
        if [[ "$PROBE_JOBS" -gt 1 ]]; then
            log_message WARNING "  GNU Parallel not installed; falling back to sequential probe"
        fi
        log_message INFO "Probing $candidate_count candidate(s) via reachability probe (sequential)..."
        while IFS= read -r email; do
            [[ -z "$email" ]] && continue
            probe_one_account "$email" >> "$probe_results"
        done < "$candidates_file"
    fi

    # Partition results: KEEP lines to users_file, SKIP lines (email+reason) to skipped file
    awk -F'\t' '$1 == "KEEP" { print $2 }' "$probe_results" > "$users_file"
    awk -F'\t' '$1 == "SKIP" { printf "%s\t%s\n", $2, $3 }' "$probe_results" >> "$SKIPPED_ACCOUNTS_FILE"

    local kept_count skipped_count
    kept_count=$(wc -l < "$users_file" | tr -d ' ')
    skipped_count=$(awk -F'\t' '$1 == "SKIP"' "$probe_results" | wc -l | tr -d ' ')

    rm -f "$candidates_file" "$probe_results"

    if [[ $kept_count -eq 0 ]]; then
        log_message ERROR "Reachability probe filtered out all $candidate_count candidates"
        log_message INFO "  See $SKIPPED_ACCOUNTS_FILE for per-account reasons"
        exit 3
    fi

    log_message SUCCESS "Reachability probe complete: $kept_count reachable, $skipped_count skipped"
    if [[ $skipped_count -gt 0 ]]; then
        log_message INFO "  Skipped accounts logged to: $SKIPPED_ACCOUNTS_FILE"
    fi

    echo "$users_file"
}

################################################################################
# PART 1: INBOUND BROKEN SHARES (MOUNT POINTS)
################################################################################

################################################################################
# Function: check_one_account_inbound
# Description:
#   v1.3.2: Worker function for the inbound check.  Takes one email, runs
#   `zmsoap GetFolderRequest` (with one retry-at-doubled-timeout if the first
#   attempt times out), parses the response for broken="1" folders, and
#   emits a structured TSV result on stdout:
#       BROKEN<TAB>email<TAB>folder_id<TAB>abs_path<TAB>folder_name
#         (one line per broken folder; user may have many)
#       TIMEOUT<TAB>email
#         (zmsoap timed out twice)
#       ERROR<TAB>email
#         (non-timeout zmsoap failure)
#   No output = user has no broken mountpoints (clean).
#
#   Reads ZMSOAP_TIMEOUT from the environment (parent must export it).
################################################################################
check_one_account_inbound() {
    local user_email="$1"
    local folder_data="" exit_code=0 attempt

    for attempt in 1 2; do
        local effective_timeout=$ZMSOAP_TIMEOUT
        [[ $attempt -eq 2 ]] && effective_timeout=$((ZMSOAP_TIMEOUT * 2))

        folder_data=$(timeout "$effective_timeout" zmsoap -z -m "$user_email" GetFolderRequest @tr=1 2>&1)
        exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            break
        fi

        if [[ $exit_code -eq 124 ]]; then
            # Timeout.  Retry once at doubled timeout; otherwise emit TIMEOUT.
            if [[ $attempt -eq 1 ]]; then
                continue
            fi
            printf 'TIMEOUT\t%s\n' "$user_email"
            return 0
        fi

        # Non-timeout failure; no retry, just emit ERROR
        printf 'ERROR\t%s\n' "$user_email"
        return 0
    done

    # Parse broken folders from the XML response
    if echo "$folder_data" | grep -q 'broken="1"'; then
        local line folder_id abs_path folder_name
        while read -r line; do
            folder_id=$(echo "$line" | sed -n 's/.*id="\([^"]*\)".*/\1/p')
            abs_path=$(echo "$line" | sed -n 's/.*absFolderPath="\([^"]*\)".*/\1/p')
            folder_name=$(echo "$line" | sed -n 's/.*name="\([^"]*\)".*/\1/p')

            # Fallback extraction methods if the sed pass missed any field
            if [[ -z "$folder_id" ]]; then
                folder_id=$(echo "$line" | grep -oP 'id="\K[^"]+' || true)
            fi
            if [[ -z "$abs_path" ]]; then
                abs_path=$(echo "$line" | grep -oP 'absFolderPath="\K[^"]+' || true)
            fi
            if [[ -z "$folder_name" ]]; then
                folder_name=$(echo "$line" | grep -oP 'name="\K[^"]+' || true)
            fi

            if [[ -n "$folder_id" ]] && [[ -n "$abs_path" ]]; then
                printf 'BROKEN\t%s\t%s\t%s\t%s\n' "$user_email" "$folder_id" "$abs_path" "$folder_name"
            fi
        done < <(echo "$folder_data" | grep 'broken="1"')
    fi

    return 0
}
export -f check_one_account_inbound

check_inbound_broken_shares() {
    log_message INFO ""
    log_message INFO "========================================"
    log_message INFO "PART 1: INBOUND BROKEN SHARES"
    log_message INFO "========================================"
    log_message INFO "Checking for broken mount points in user mailboxes..."
    log_message INFO ""

    echo "UserEmail,FolderId,AbsolutePath,FolderName" > "$INBOUND_CSV"

    cat > "$INBOUND_SCRIPT" << 'SCRIPT_HEADER'
#!/bin/bash
################################################################################
# Generated script to remove broken inbound shares (mount points)
#
# IMPORTANT: Review this script carefully before executing!
# This script will DELETE folder mount points from user mailboxes.
#
# USAGE: Run as zimbra user
#   su - zimbra -c 'bash /path/to/this/script.sh'
#
# NOTE on `set -uo pipefail` (no -e):
#   `-e` is intentionally OMITTED.  Each removal command stands alone, and
#   one failure (e.g. a folder already gone from a previous partial run)
#   should NOT abort the cleanup of the remaining items.  Errors are logged
#   inline via `|| echo "[WARNING] ..."` so nothing is silenced.
################################################################################

set -uo pipefail

SCRIPT_HEADER
    chmod +x "$INBOUND_SCRIPT"

    local users_file="$1"
    local total_users
    total_users=$(wc -l < "$users_file" | tr -d ' ')

    local inbound_results
    inbound_results=$(mktemp)

    # Worker reads ZMSOAP_TIMEOUT from environment; export so parallel sees it
    export ZMSOAP_TIMEOUT

    if [[ "$PROBE_JOBS" -gt 1 ]] && command -v parallel >/dev/null 2>&1; then
        log_message INFO "Inbound scan: $total_users users via GNU Parallel ($PROBE_JOBS jobs)..."
        # `|| true` because parallel returns non-zero if any worker did, and we
        # handle worker failures via the TIMEOUT/ERROR rows in the output stream
        parallel --no-notice --bar -j "$PROBE_JOBS" check_one_account_inbound :::: "$users_file" > "$inbound_results" 2>&1 || true
    else
        if [[ "$PROBE_JOBS" -gt 1 ]]; then
            log_message WARNING "  GNU Parallel not installed; falling back to sequential inbound scan"
        fi
        log_message INFO "Inbound scan: $total_users users (sequential)..."
        local current_user=0
        while IFS= read -r user_email || [[ -n "$user_email" ]]; do
            [[ -z "$user_email" ]] && continue
            current_user=$((current_user + 1))
            if [[ $((current_user % 10)) -eq 0 ]]; then
                local percent=$((current_user * 100 / total_users))
                printf "\r${CYAN}Progress:${NC} %3d%% (%d/%d users)" \
                    "$percent" "$current_user" "$total_users" >&2
            fi
            check_one_account_inbound "$user_email" >> "$inbound_results"
            sleep "$DELAY_BETWEEN_USERS"
        done < "$users_file"
        printf "\r%80s\r" "" >&2
    fi

    # Partition results into counters, CSV rows, and removal-script blocks.
    # Sort BROKEN rows by email so users-with-broken counting works correctly.
    local timeout_count error_count
    timeout_count=$(awk -F'\t' '$1 == "TIMEOUT"' "$inbound_results" | wc -l | tr -d ' ')
    error_count=$(awk -F'\t' '$1 == "ERROR"' "$inbound_results" | wc -l | tr -d ' ')

    # Log per-user timeouts and errors
    if [[ $timeout_count -gt 0 ]]; then
        local t_email
        while IFS=$'\t' read -r _ t_email; do
            log_message WARNING "$t_email - timeout (after retry); skipped"
        done < <(awk -F'\t' '$1 == "TIMEOUT"' "$inbound_results")
    fi
    if [[ $error_count -gt 0 ]]; then
        local e_email
        while IFS=$'\t' read -r _ e_email; do
            log_message WARNING "$e_email - zmsoap failed (non-timeout); skipped"
        done < <(awk -F'\t' '$1 == "ERROR"' "$inbound_results")
    fi

    local sorted_broken
    sorted_broken=$(mktemp)
    awk -F'\t' '$1 == "BROKEN"' "$inbound_results" | sort -t$'\t' -k2,2 > "$sorted_broken"

    local total_broken=0
    local users_with_broken=0
    local last_email=""
    local tag user_email folder_id abs_path folder_name

    while IFS=$'\t' read -r tag user_email folder_id abs_path folder_name; do
        [[ -z "$user_email" ]] && continue

        if [[ "$user_email" != "$last_email" ]]; then
            users_with_broken=$((users_with_broken + 1))
            last_email="$user_email"
        fi

        local escaped_path="${abs_path//\"/\"\"}"
        local escaped_name="${folder_name//\"/\"\"}"

        printf '"%s","%s","%s","%s"\n' "$user_email" "$folder_id" "$escaped_path" "$escaped_name" >> "$INBOUND_CSV"

        {
            echo ""
            echo "# User: $user_email - Remove broken mount point: $abs_path"
            printf 'echo "[%s] Removing broken mount point ID %s: %s"\n' \
                "$(printf '%q' "$user_email")" \
                "$(printf '%q' "$folder_id")" \
                "$(printf '%q' "$abs_path")"
            printf 'zmmailbox -z -m %s df %s 2>&1 || echo "  [WARNING] Error removing folder %s"\n' \
                "$(printf '%q' "$user_email")" \
                "$(printf '%q' "$folder_id")" \
                "$(printf '%q' "$folder_id")"
        } >> "$INBOUND_SCRIPT"

        total_broken=$((total_broken + 1))
    done < "$sorted_broken"

    rm -f "$inbound_results" "$sorted_broken"

    log_message INFO ""
    log_message SUCCESS "Inbound shares check finished"
    log_message INFO "  Users checked: $total_users"
    log_message INFO "  Users with broken mount points: $users_with_broken"
    log_message INFO "  Total broken mount points: $total_broken"
    if [[ $timeout_count -gt 0 ]]; then
        log_message WARNING "  Timeouts (after retry): $timeout_count"
    fi
    if [[ $error_count -gt 0 ]]; then
        log_message WARNING "  zmsoap failures (non-timeout): $error_count"
    fi

    echo "$total_broken|$users_with_broken|$timeout_count"
}

################################################################################
# PART 2: OUTBOUND BROKEN SHARES (INVALID RECIPIENTS)
################################################################################

# Function: resolve_grantee_id_to_email
# v1.3.4: Returns the resolved email if the grantee exists in LDAP, else
#   returns the sentinel string "UNRESOLVED".  Sentinel propagates out
#   of the subshell created by command substitution (`var=$(resolve...)`);
#   the prior cache-based UNRESOLVED signaling did not, which caused
#   every OP2 version through v1.3.3 to silently no-op on broken-share
#   detection.  See the v1.3.4 entry in MCE_OP2_broken_shares_checker_CHANGELOG.txt.
#
# v1.3.3 (still in effect):
#   - Always does the LDAP lookup (no email short-circuit) -- email-form
#     grantees are exactly what we need to VERIFY.
#   - Correct LDAP filter form (|(X)(Y)) -- not v1.3.2's malformed
#     (|((X)(Y))) which libldap rejected as "Bad search filter (-7)".
resolve_grantee_id_to_email() {
    local grantee_id="$1"

    local resolved_email
    resolved_email=$(ldapsearch -x -H "$LDAP_MASTER_URL" \
        -D "$LDAP_BIND_DN" \
        -w "$ZIMBRA_LDAP_PASSWORD" \
        -LLL \
        -o ldif-wrap=no \
        "(|(&(objectClass=zimbraAccount)(|(zimbraId=$grantee_id)(uid=$grantee_id)(mail=$grantee_id)))(&(objectClass=zimbraDistributionList)(zimbraId=$grantee_id)))" \
        mail 2>/dev/null | \
        grep "^mail: " | \
        head -n 1 | \
        awk '{print $2}' | \
        tr -d '\n' || true)

    if [[ -n "$resolved_email" ]] && [[ "$resolved_email" =~ @ ]]; then
        echo "$resolved_email"
    else
        echo "UNRESOLVED"
    fi
    return 0
}

# Function: get_user_shares
# Retrieves zimbraSharedItem LDAP attribute values for a user.
# Uses -b "" to search explicitly from the LDAP root DN so that all user
# accounts are reachable regardless of the server's naming context layout.
# In standard Zimbra multi-tenant deployments, accounts for all hosted domains
# live under a single ou=people,dc=<primary-domain> tree, so a root-level
# search correctly spans every hosted domain without needing per-domain base DNs.
# Explicit -b "" is preferred over omitting -b to avoid inheriting an incorrect
# BASE directive from the client's /etc/ldap/ldap.conf or /etc/openldap/ldap.conf.
get_user_shares() {
    local user_email="$1"

    local ldap_raw
    ldap_raw=$(ldapsearch -x -H "$LDAP_MASTER_URL" \
        -D "$LDAP_BIND_DN" \
        -w "$ZIMBRA_LDAP_PASSWORD" \
        -b "" \
        -LLL \
        -o ldif-wrap=no \
        "(mail=$user_email)" \
        zimbraSharedItem 2>/dev/null || true)

    # Handle both plain and base64-encoded zimbraSharedItem values
    # Plain values:  zimbraSharedItem: value
    # Base64 values: zimbraSharedItem:: base64encodedvalue
    while IFS= read -r line; do
        if [[ "$line" == "zimbraSharedItem:: "* ]]; then
            local b64_value="${line#zimbraSharedItem:: }"
            local decoded
            decoded=$(echo "$b64_value" | base64 -d 2>/dev/null || true)
            if [[ -n "$decoded" ]]; then
                echo "$decoded"
            fi
        elif [[ "$line" == "zimbraSharedItem: "* ]]; then
            echo "${line#zimbraSharedItem: }"
        fi
    done <<< "$ldap_raw"
}

# Function: parse_shared_item
parse_shared_item() {
    local shared_item="$1"
    local owner_email="$2"
    local -n broken_array="$3"

    local grantee_id="" grantee_name="" grantee_type="" folder_path="" permissions=""

    IFS=';' read -ra pairs <<< "$shared_item"
    for pair in "${pairs[@]}"; do
        local key="${pair%%:*}"
        local value="${pair#*:}"

        case "$key" in
            granteeId) grantee_id="$value" ;;
            granteeName) grantee_name="$value" ;;
            granteeType) grantee_type="$value" ;;
            folderPath) folder_path="$value" ;;
            rights) permissions="$value" ;;
        esac
    done

    if [[ -z "$grantee_id" ]] || [[ -z "$grantee_type" ]]; then
        return 0
    fi

    # Skip non-user/group shares (dom, all, pub, gst don't need resolution).
    # Handle both short forms (usr, grp) and long forms (account, group).
    if [[ "$grantee_type" != "usr" ]] && [[ "$grantee_type" != "grp" ]] && \
       [[ "$grantee_type" != "account" ]] && [[ "$grantee_type" != "group" ]]; then
        return 0
    fi

    # v1.3.5: check ONLY the field the migration restore script uses.
    # When granteeName is an email-form value, that's what `mfg` / `cm`
    # will reference at restore time -- so that's what we check.  No
    # fallback to granteeId, because granteeId may resolve to a
    # different live account (alias-residue pattern; see CHANGELOG).
    # If granteeName is empty/null/non-email, fall back to granteeId.
    local resolved_email=""

    if [[ -n "$grantee_name" ]] && [[ "$grantee_name" != "null" ]] && [[ "$grantee_name" =~ @ ]]; then
        resolved_email=$(resolve_grantee_id_to_email "$grantee_name")
    else
        resolved_email=$(resolve_grantee_id_to_email "$grantee_id")
    fi

    local is_broken=0
    if [[ "$resolved_email" == "UNRESOLVED" ]]; then
        is_broken=1
    fi

    if [[ $is_broken -eq 1 ]]; then
        local share_type_label
        if [[ "$grantee_type" == "grp" ]] || [[ "$grantee_type" == "group" ]]; then
            share_type_label="Distribution List"
        else
            share_type_label="User"
        fi

        # Store: owner|folder|type|granteeId|perms|label|ORIGINAL_SHARED_ITEM
        broken_array+=("$owner_email|$folder_path|$grantee_type|$grantee_id|$permissions|$share_type_label|$shared_item")
    fi
}

check_outbound_broken_shares() {
    log_message INFO ""
    log_message INFO "========================================"
    log_message INFO "PART 2: OUTBOUND BROKEN SHARES"
    log_message INFO "========================================"
    log_message INFO "Checking for shares granted to non-existent accounts..."
    log_message INFO ""

    echo "OwnerEmail,FolderPath,ShareType,GranteeId,Permissions,ShareTypeLabel" > "$OUTBOUND_CSV"

    cat > "$OUTBOUND_SCRIPT" << 'SCRIPT_HEADER'
#!/bin/bash
################################################################################
# Generated script to remove broken outbound shares (invalid recipients)
#
# IMPORTANT: Review this script carefully before executing!
# This script will MODIFY zimbraSharedItem attributes by removing shares
# where the grantee (recipient) no longer exists.
#
# USAGE: Run as zimbra user
#   su - zimbra -c 'bash /path/to/this/script.sh'
#
# NOTE on `set -uo pipefail` (no -e):
#   `-e` is intentionally OMITTED.  Each removal stands alone, and one
#   failure (e.g. value already gone) should NOT abort the cleanup of the
#   remaining items.  Errors are logged inline via `|| echo "[WARNING] ..."`.
################################################################################

set -uo pipefail

SCRIPT_HEADER
    chmod +x "$OUTBOUND_SCRIPT"

    local users_file="$1"
    local total_users
    total_users=$(wc -l < "$users_file" | tr -d ' ')

    local current_user=0
    local total_broken=0
    local users_with_broken=0

    declare -a broken_shares=()

    while IFS= read -r user_email || [[ -n "$user_email" ]]; do
        current_user=$((current_user + 1))

        if [[ $((current_user % 10)) -eq 0 ]]; then
            local percent=$((current_user * 100 / total_users))
            printf "\r${CYAN}Progress:${NC} %3d%% (%d/%d users) - %d broken shares found" \
                "$percent" "$current_user" "$total_users" "$total_broken" >&2
        fi

        local share_data
        share_data=$(get_user_shares "$user_email")

        if [[ -z "$share_data" ]]; then
            continue
        fi

        local user_broken_count=0

        while IFS= read -r shared_item || [[ -n "$shared_item" ]]; do
            if [[ -z "$shared_item" ]]; then
                continue
            fi

            local before_count=${#broken_shares[@]}
            parse_shared_item "$shared_item" "$user_email" broken_shares
            local after_count=${#broken_shares[@]}

            if [[ $after_count -gt $before_count ]]; then
                user_broken_count=$((user_broken_count + 1))
            fi
        done <<< "$share_data"

        if [[ $user_broken_count -gt 0 ]]; then
            users_with_broken=$((users_with_broken + 1))
            total_broken=$((total_broken + user_broken_count))
        fi

    done < "$users_file"

    printf "\r%80s\r" "" >&2

    log_message INFO ""
    log_message SUCCESS "Outbound shares check finished"
    log_message INFO "  Users checked: $total_users"
    log_message INFO "  Users with broken outbound shares: $users_with_broken"
    log_message INFO "  Total broken outbound shares: $total_broken"

    if [[ $total_broken -gt 0 ]]; then
        local array_size=${#broken_shares[@]}

        if [[ $array_size -gt 0 ]]; then
            log_message INFO ""
            log_message INFO "Writing broken outbound shares to CSV and removal script..."

            local entry
            for entry in "${broken_shares[@]}"; do
                local owner_email folder_path share_type grantee_id permissions share_type_label original_shared_item
                IFS='|' read -r owner_email folder_path share_type grantee_id permissions share_type_label original_shared_item <<< "$entry"

                local owner_email_escaped="${owner_email//\"/\"\"}"
                local folder_path_escaped="${folder_path//\"/\"\"}"
                local grantee_id_escaped="${grantee_id//\"/\"\"}"
                local permissions_escaped="${permissions//\"/\"\"}"
                local share_type_label_escaped="${share_type_label//\"/\"\"}"

                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "$owner_email_escaped" \
                    "$folder_path_escaped" \
                    "$share_type" \
                    "$grantee_id_escaped" \
                    "$permissions_escaped" \
                    "$share_type_label_escaped" >> "$OUTBOUND_CSV"

                {
                    echo ""
                    echo "# Owner: $owner_email"
                    echo "# Folder: $folder_path"
                    echo "# Broken grantee: $grantee_id ($share_type_label)"
                    printf 'echo "Removing broken share: %s - %s -> %s"\n' \
                        "$(printf '%q' "$owner_email")" \
                        "$(printf '%q' "$folder_path")" \
                        "$(printf '%q' "$grantee_id")"
                    printf 'zmprov ma %s -zimbraSharedItem %s 2>&1 || echo "  [WARNING] Failed to remove share"\n' \
                        "$(printf '%q' "$owner_email")" \
                        "$(printf '%q' "$original_shared_item")"
                } >> "$OUTBOUND_SCRIPT"
            done
        fi
    fi

    echo "$total_broken|$users_with_broken"
}

################################################################################
# Function: check_outbound_stale_acl_shares  (v2.0.0 -- Bug C)
# Description:
#   For each user, cross-references zimbraSharedItem entries against the actual
#   folder ACLs.  A "stale ACL" is a zimbraSharedItem that names a grantee
#   whose grant has been removed from the folder's real ACL -- the owner
#   revoked the share via the UI but the cached info was not cleaned up.
#
#   Stale entries cause service.PERM_DENIED at restore time when the
#   migration script tries to recreate the mountpoint on the destination,
#   because the destination folder has no matching grant.  Detecting and
#   removing them PRE-migration avoids that class of restore failure.
#
#   Implementation: per user, runs a SINGLE zmmailbox -m <user> session
#   (one JVM spawn) with a piped sequence of `gfg <folder>` commands for
#   every distinct folder referenced in their shares.  Parses the gfg
#   output for ACL grants.  Each shared_item is then checked against the
#   parsed ACL map; missing matches are emitted to STALE_ACL_CSV and
#   STALE_ACL_SCRIPT.
#
#   Skips shared_items whose grantee is already known broken (Bug A/D/E)
#   since the OUTBOUND_CSV removal script will handle those.
################################################################################
check_outbound_stale_acl_shares() {
    log_message INFO ""
    log_message INFO "========================================"
    log_message INFO "PART 3: STALE ACL ENTRIES (Bug C)"
    log_message INFO "========================================"
    log_message INFO "Checking for zimbraSharedItem entries whose grants are no longer in the folder ACL..."
    log_message INFO ""

    echo "OwnerEmail,FolderPath,GranteeName,GranteeId,GranteeType,Permissions" > "$STALE_ACL_CSV"

    cat > "$STALE_ACL_SCRIPT" << 'SCRIPT_HEADER'
#!/bin/bash
################################################################################
# Generated script to remove stale-ACL zimbraSharedItem entries (Bug C)
#
# These entries name grantees whose grant has been removed from the
# folder's actual ACL.  The cached share info on the owner's account
# was never cleaned up, so the migration restore would fail with
# service.PERM_DENIED trying to recreate the mountpoint.
#
# IMPORTANT: Review carefully before executing.  Run as zimbra user:
#   su - zimbra -c 'bash /path/to/this/script.sh'
################################################################################

set -uo pipefail

SCRIPT_HEADER
    chmod +x "$STALE_ACL_SCRIPT"

    local users_file="$1"
    local total_users
    total_users=$(wc -l < "$users_file" | tr -d ' ')

    local current_user=0
    local total_stale=0
    local users_with_stale=0

    while IFS= read -r user_email || [[ -n "$user_email" ]]; do
        current_user=$((current_user + 1))

        if [[ $((current_user % 10)) -eq 0 ]]; then
            local percent=$((current_user * 100 / total_users))
            printf "\r${CYAN}Progress:${NC} %3d%% (%d/%d users) - %d stale ACL entries found" \
                "$percent" "$current_user" "$total_users" "$total_stale" >&2
        fi

        local share_data
        share_data=$(get_user_shares "$user_email")
        [[ -z "$share_data" ]] && continue

        # Build (folder, grantee_name, rights) expected set + unique folder list.
        # Skip non-account/group shares and unresolved grantees (Bug A/D/E
        # are handled by Part 2's OUTBOUND script).
        declare -A expected_keys=()
        declare -A folder_set=()
        declare -A item_by_key=()
        while IFS= read -r shared_item; do
            [[ -z "$shared_item" ]] && continue
            local fp gn gi gt rights
            fp=""; gn=""; gi=""; gt=""; rights=""
            IFS=';' read -ra pairs <<< "$shared_item"
            for pair in "${pairs[@]}"; do
                local k="${pair%%:*}"
                local v="${pair#*:}"
                case "$k" in
                    folderPath)  fp="$v" ;;
                    granteeName) gn="$v" ;;
                    granteeId)   gi="$v" ;;
                    granteeType) gt="$v" ;;
                    rights)      rights="$v" ;;
                esac
            done
            [[ -z "$fp" ]] && continue
            # Only user/group types -- pub/all/dom/gst don't appear in gfg ACL same way
            if [[ "$gt" != "usr" && "$gt" != "grp" && "$gt" != "account" && "$gt" != "group" ]]; then
                continue
            fi
            # Skip if grantee fails resolution (Bug A/D/E owns these)
            local resolved=""
            if [[ -n "$gn" ]] && [[ "$gn" != "null" ]] && [[ "$gn" =~ @ ]]; then
                resolved=$(resolve_grantee_id_to_email "$gn")
            else
                resolved=$(resolve_grantee_id_to_email "$gi")
            fi
            [[ "$resolved" == "UNRESOLVED" ]] && continue
            # Key matches what gfg reports: <folder>|<grantee email>|<rights>
            local key="${fp}|${resolved}"
            expected_keys["$key"]="$rights"
            folder_set["$fp"]=1
            item_by_key["$key"]="$shared_item"
        done <<< "$share_data"

        [[ ${#expected_keys[@]} -eq 0 ]] && continue

        # v2.0.2: Per-folder gfg calls.  v2.0.1 batched all of a user's
        # gfg commands into one zmmailbox session and aligned each output
        # block to the folder array by counting "Permissions Type Display"
        # header occurrences.  Field testing on a multi-hundred-account
        # source showed systematic false positives -- some users had every
        # grantee flagged stale while gfg manually re-run showed them
        # present.  The only explanation is that ONE folder's gfg in the
        # batch produced no header output (path with special chars,
        # transient error, etc.) and the index slipped, mapping subsequent
        # folders to the wrong block.
        #
        # v2.0.2 calls gfg once per folder with its own zmmailbox process.
        # Eliminates the alignment dependency at the cost of one JVM cold-
        # start per folder.  For ~5 folders/user typical of stale-ACL
        # workloads, total runtime stays in the tens-of-minutes range and
        # is acceptable for a once-per-cycle preflight.
        declare -A actual_keys=()
        local fp
        for fp in "${!folder_set[@]}"; do
            local gfg_output
            # v2.0.3: belt-and-suspenders -- LC_ALL=en_US.UTF-8 is also set
            # via top-of-script export.  Repeating it inline here makes the
            # locale requirement obvious to anyone grepping for LC_ALL at
            # this exact call site (which is the only zmmailbox invocation
            # in OP2 that touches user-controlled folder paths).
            gfg_output=$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 zmmailbox -z -m "$user_email" gfg "$fp" 2>/dev/null || true)
            [[ -z "$gfg_output" ]] && continue
            while IFS= read -r line; do
                [[ "$line" =~ ^Permissions[[:space:]]+Type[[:space:]]+Display ]] && continue
                [[ "$line" =~ ^---- ]] && continue
                [[ -z "${line// }" ]] && continue
                local g_rights g_type g_display _rest
                read -r g_rights g_type g_display _rest <<< "$line"
                if [[ -n "$g_display" && -n "$g_rights" ]]; then
                    case "$g_type" in
                        account|group|grp|usr|dl)
                            actual_keys["${fp}|${g_display}"]="$g_rights"
                            ;;
                    esac
                fi
            done <<< "$gfg_output"
        done

        # Cross-reference: for each expected key, check actuals.
        local user_stale_count=0
        local key
        for key in "${!expected_keys[@]}"; do
            if [[ -z "${actual_keys[$key]:-}" ]]; then
                local shared_item="${item_by_key[$key]}"
                local fp_part="${key%|*}"
                local g_part="${key##*|}"
                local rights="${expected_keys[$key]}"

                # Pull original granteeId for the removal record.
                local orig_id=""
                IFS=';' read -ra pairs <<< "$shared_item"
                for pair in "${pairs[@]}"; do
                    if [[ "${pair%%:*}" == "granteeId" ]]; then
                        orig_id="${pair#*:}"
                        break
                    fi
                done

                local owner_q="${user_email//\"/\"\"}"
                local fp_q="${fp_part//\"/\"\"}"
                local g_q="${g_part//\"/\"\"}"
                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "$owner_q" "$fp_q" "$g_q" "$orig_id" "usr" "$rights" >> "$STALE_ACL_CSV"

                {
                    echo ""
                    echo "# Owner: $user_email"
                    echo "# Folder: $fp_part"
                    echo "# Stale grantee in cache (no matching ACL grant): $g_part"
                    printf 'echo "Removing stale ACL share: %s - %s -> %s"\n' \
                        "$(printf '%q' "$user_email")" \
                        "$(printf '%q' "$fp_part")" \
                        "$(printf '%q' "$g_part")"
                    printf 'zmprov ma %s -zimbraSharedItem %s 2>&1 || echo "  [WARNING] Failed to remove share"\n' \
                        "$(printf '%q' "$user_email")" \
                        "$(printf '%q' "$shared_item")"
                } >> "$STALE_ACL_SCRIPT"

                user_stale_count=$((user_stale_count + 1))
            fi
        done

        if [[ $user_stale_count -gt 0 ]]; then
            users_with_stale=$((users_with_stale + 1))
            total_stale=$((total_stale + user_stale_count))
        fi

    done < "$users_file"

    printf "\r%80s\r" "" >&2

    log_message INFO ""
    log_message SUCCESS "Stale ACL check finished"
    log_message INFO "  Users checked: $total_users"
    log_message INFO "  Users with stale ACL entries: $users_with_stale"
    log_message INFO "  Total stale ACL entries: $total_stale"

    echo "$total_stale|$users_with_stale"
}

################################################################################
# Function: cleanup
# Description: Clean up internal temp files on exit (output files are kept).
################################################################################
cleanup() {
    if [[ -n "$USERS_TEMP_FILE" ]] && [[ -f "$USERS_TEMP_FILE" ]]; then
        rm -f "$USERS_TEMP_FILE"
    fi
    [[ -n "$LDAP_FALLBACK_WARNED_FILE" ]] && rm -f "$LDAP_FALLBACK_WARNED_FILE"
}

trap cleanup EXIT INT TERM

################################################################################
# Main execution
################################################################################

parse_args "$@"

cat << EOF

================================================================================
  MCE_OP2 Broken Shares Checker
  Version ${VERSION}
================================================================================

  This script checks for THREE classes of broken shares:
    1. INBOUND:    Broken mount points in user mailboxes
    2. OUTBOUND:   Shares granted to non-existent accounts (Bugs A/D/E)
    3. STALE ACL:  zimbraSharedItem entries with no matching folder ACL (Bug C)

  Output directory    : ${OUTPUT_DIR}
  Reachability jobs   : ${PROBE_JOBS}
  Delay between users : ${DELAY_BETWEEN_USERS}s
  zmsoap timeout      : ${ZMSOAP_TIMEOUT}s

================================================================================

EOF

log_message INFO "Started at $(date)"
log_message INFO ""

# Lower process priority so we don't impact production load
if command -v renice >/dev/null 2>&1; then
    renice -n "$NICE_PRIORITY" $$ >/dev/null 2>&1 || true
fi
if command -v ionice >/dev/null 2>&1; then
    ionice -c "$IONICE_CLASS" -p $$ >/dev/null 2>&1 || true
fi

check_prerequisites
get_ldap_settings
users_file=$(get_all_active_users)

log_message INFO ""
log_message INFO "========================================"
log_message INFO "Starting comprehensive broken shares scan..."
log_message INFO "========================================"

# Part 1: Inbound broken shares
inbound_results=$(check_inbound_broken_shares "$users_file")
IFS='|' read -r inbound_total inbound_users inbound_timeouts <<< "$inbound_results"

# Part 2: Outbound broken shares
outbound_results=$(check_outbound_broken_shares "$users_file")
IFS='|' read -r outbound_total outbound_users <<< "$outbound_results"

# v2.0.0 Part 3: Stale-ACL detection (Bug C)
stale_results=$(check_outbound_stale_acl_shares "$users_file")
IFS='|' read -r stale_total stale_users <<< "$stale_results"

rm -f "$users_file"
USERS_TEMP_FILE=""

# Final summary
log_message INFO ""
log_message INFO "========================================"
log_message INFO "FINAL SUMMARY"
log_message INFO "========================================"
log_message INFO ""
log_message INFO "INBOUND BROKEN SHARES (Mount Points):"
log_message INFO "  Total broken mount points: $inbound_total"
log_message INFO "  Users affected: $inbound_users"
if [[ $inbound_timeouts -gt 0 ]]; then
    log_message WARNING "  Timeouts (after retry): $inbound_timeouts"
fi
log_message INFO ""
log_message INFO "OUTBOUND BROKEN SHARES (Invalid Recipients):"
log_message INFO "  Total broken shares: $outbound_total"
log_message INFO "  Users affected: $outbound_users"
log_message INFO ""
log_message INFO "STALE ACL ENTRIES (Bug C):"
log_message INFO "  Total stale entries: $stale_total"
log_message INFO "  Users affected: $stale_users"
log_message INFO ""
log_message INFO "========================================"
log_message INFO "OUTPUT FILES:"
log_message INFO "========================================"
log_message INFO "  Log file:          $LOG_FILE"
log_message INFO "  Skipped accounts:  $SKIPPED_ACCOUNTS_FILE"
log_message INFO ""
log_message INFO "  Inbound (Mount Points):"
log_message INFO "    CSV report:     $INBOUND_CSV"
log_message INFO "    Removal script: $INBOUND_SCRIPT"
log_message INFO ""
log_message INFO "  Outbound (Invalid Recipients):"
log_message INFO "    CSV report:     $OUTBOUND_CSV"
log_message INFO "    Removal script: $OUTBOUND_SCRIPT"
log_message INFO ""
log_message INFO "  Stale ACL Entries (Bug C):"
log_message INFO "    CSV report:     $STALE_ACL_CSV"
log_message INFO "    Removal script: $STALE_ACL_SCRIPT"
log_message INFO ""

total_all_broken=$((inbound_total + outbound_total + stale_total))

if [[ $total_all_broken -gt 0 ]]; then
    log_message INFO "========================================"
    log_message WARNING "ACTION REQUIRED"
    log_message INFO "========================================"
    log_message INFO ""
    log_message INFO "Broken shares were found.  Review the CSV reports and removal scripts."
    log_message INFO ""
    log_message ERROR "IMPORTANT: Review scripts carefully before executing!"
    log_message INFO "           Test in non-production environment first."
    log_message INFO ""
    log_message INFO "To remove broken mount points (inbound):"
    log_message INFO "  bash $INBOUND_SCRIPT"
    log_message INFO ""
    log_message INFO "To remove broken share grants (outbound):"
    log_message INFO "  bash $OUTBOUND_SCRIPT"
    log_message INFO ""
    log_message INFO "To remove stale ACL entries (Bug C):"
    log_message INFO "  bash $STALE_ACL_SCRIPT"
    log_message INFO ""
    log_message INFO "========================================"
    log_message INFO "Completed at $(date)"
    log_message INFO "========================================"
    exit 1
else
    log_message SUCCESS "No broken shares found!"
    log_message INFO "Your Zimbra shared folders are healthy."
    log_message INFO ""
    log_message INFO "========================================"
    log_message INFO "Completed at $(date)"
    log_message INFO "========================================"
    exit 0
fi
