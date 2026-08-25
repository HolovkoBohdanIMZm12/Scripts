#!/bin/bash
#
# export_ise_collection_profile.sh
#
# Purpose:
#   Automates exporting a CSPC collection profile via
#   export_collectionProfile.sh (which interactively prompts for
#   CSPC username/password), then copies the resulting zip archive
#   from the CSPC export directory to the ISE export directory.
#
# Target OS: AlmaLinux 9.3
#
# Requirements:
#   - Must be run as a user with permission to execute the CSPC CLI
#     tools and to read/write the directories referenced below
#     (typically root or the adminshell/collectorlogin service account).
#   - The "expect", "unzip", and "awk" packages must already be installed.
#     This host has no internet access, so the script only checks for
#     their presence and fails with a clear message if any are missing -
#     it does not attempt to install anything.
#
# Security note:
#   This script stores the CSPC password in plain text below, as
#   requested. Restrict access to this file (e.g. `chmod 600`) and
#   store it in a location only trusted operators/service accounts
#   can read.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# User-configurable variables
# ----------------------------------------------------------------------------

# CSPC credentials used to answer the interactive prompts.
CSPC_USERNAME="CHANGE_ME_USERNAME"
CSPC_PASSWORD="CHANGE_ME_PASSWORD"

# Identifier passed to export_collectionProfile.sh via the "_identifier" flag.
PROFILE_IDENTIFIER="_LCS_Full_Clone_IseVmK9_"

# Directories used by the CSPC application and the ISE export destination.
CSPC_BIN_DIR="/opt/cisco/ss/adminshell/applications/CSPC/cli/bin"
CSPC_EXPORT_DIR="/opt/cisco/ss/adminshell/applications/CSPC/exportdata"
DEST_DIR="/home/collectorlogin/ISE_export"

# Owner to apply to everything under DEST_DIR after each run, so the
# exported zip and CSV are retrievable over SSH/SCP/SFTP by this account
# (the script itself typically runs as root, e.g. via cron).
DEST_OWNER="collectorlogin"

# Where to keep a copy of the export command's output, so we can parse
# the generated FileName out of it.
LOG_FILE="/tmp/export_collectionProfile_$(date +%Y%m%d%H%M%S).log"

# How many days to retain old per-run log files in /tmp before they're
# automatically deleted (a new one is created on every run, e.g. via cron).
LOG_RETENTION_DAYS=7

# ----------------------------------------------------------------------------
# Script logic - normally no need to edit below this line
# ----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

# 0. Clean up old per-run log files from previous executions so /tmp
#    doesn't accumulate them indefinitely (e.g. when run daily via cron).
find /tmp -maxdepth 1 -name 'export_collectionProfile_*.log' -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

# 1. Make sure required tools are available (this host has no internet
#    access, so we just verify presence rather than attempting to install).
command -v expect >/dev/null 2>&1 || fail "'expect' is not installed. Please install it manually (e.g. from a local repo/rpm) and re-run."
command -v unzip >/dev/null 2>&1 || fail "'unzip' is not installed. Please install it manually (e.g. from a local repo/rpm) and re-run."
command -v awk >/dev/null 2>&1 || fail "'awk' is not installed. Please install it manually (e.g. from a local repo/rpm) and re-run."

# 2. Move into the CSPC CLI bin directory.
[ -d "$CSPC_BIN_DIR" ] || fail "Directory not found: $CSPC_BIN_DIR"
cd "$CSPC_BIN_DIR" || fail "Unable to cd into $CSPC_BIN_DIR"
[ -x "./export_collectionProfile.sh" ] || fail "export_collectionProfile.sh not found or not executable in $CSPC_BIN_DIR"

# 3. Export credentials/identifier/log path via environment so the expect
#    script (heredoc below) never has these values textually substituted
#    into the Tcl source - this avoids issues with special characters.
export CSPC_USERNAME CSPC_PASSWORD PROFILE_IDENTIFIER LOG_FILE

log "Running export_collectionProfile.sh with identifier '${PROFILE_IDENTIFIER}'..."

set +e
expect <<'EOF'
set timeout 180
log_file -a $::env(LOG_FILE)

spawn ./export_collectionProfile.sh _identifier $::env(PROFILE_IDENTIFIER)

expect {
    -re "Please Enter CSPC Username:\\s*$" {
        send -- "$::env(CSPC_USERNAME)\r"
        exp_continue
    }
    -re "Please Enter CSPC Password:\\s*$" {
        send -- "$::env(CSPC_PASSWORD)\r"
        exp_continue
    }
    -re "FileName\\s+\\S+\\.zip" {
        # The export finished and printed the result table. The underlying
        # tool does not reliably close its pty afterwards (it can return to
        # a shell prompt instead of exiting), so don't wait for eof here -
        # just fall through and end the session ourselves below.
    }
    timeout {
        puts "ERROR: Timed out waiting for a prompt or command completion."
        exit 1
    }
    eof
}

# Give the spawned process a brief grace period in case it does exit on its
# own, then force-close the session regardless so we don't hang waiting on
# a shell prompt that will never send eof.
set timeout 5
expect {
    eof
    timeout
}
catch {close}
catch {wait}
exit 0
EOF
EXPECT_RC=$?
set -e

[ "$EXPECT_RC" -eq 0 ] || fail "export_collectionProfile.sh interaction failed or timed out (see $LOG_FILE)."

# 4. Sanity-check that authentication actually succeeded.
if ! grep -qi "Verfied Username and Password\|Verified Username and Password" "$LOG_FILE"; then
    fail "Did not see a successful authentication message in output. Check credentials. Log: $LOG_FILE"
fi

# 5. Parse the generated FileName out of the command output, e.g.:
#    " FileName             _LCS_Full_Clone_IseVmK9__CSP0009017120_1787057191737.zip"
EXPORTED_FILENAME=$(grep -E "^\s*FileName\s+\S+\.zip" "$LOG_FILE" | awk '{print $2}' | tail -1 || true)

if [ -z "$EXPORTED_FILENAME" ]; then
    log "Could not parse FileName from command output; falling back to newest matching file in $CSPC_EXPORT_DIR"
    EXPORTED_FILENAME=$(ls -1t "$CSPC_EXPORT_DIR" 2>/dev/null | grep -F "${PROFILE_IDENTIFIER}" | head -1 || true)
fi

[ -n "$EXPORTED_FILENAME" ] || fail "Unable to determine the exported zip filename. Check log: $LOG_FILE"

log "Generated file: $EXPORTED_FILENAME"

SOURCE_PATH="${CSPC_EXPORT_DIR}/${EXPORTED_FILENAME}"
[ -f "$SOURCE_PATH" ] || fail "Expected exported file not found: $SOURCE_PATH"

# 6. Copy the file to the ISE export destination, ensuring that directory
#    ends up containing ONLY this freshly exported file. The new file is
#    copied in under a temp name first, so if anything fails mid-copy the
#    previous export is left untouched rather than the directory being
#    wiped with nothing successfully placed back into it.
mkdir -p "$DEST_DIR" || fail "Unable to create destination directory: $DEST_DIR"

TMP_DEST_FILE="${DEST_DIR}/.incoming_${EXPORTED_FILENAME}"
cp -p "$SOURCE_PATH" "$TMP_DEST_FILE" || fail "Failed to copy $SOURCE_PATH to $DEST_DIR"

log "Removing existing files from $DEST_DIR"
find "$DEST_DIR" -mindepth 1 -maxdepth 1 ! -name "$(basename "$TMP_DEST_FILE")" -exec rm -rf -- {} + \
    || fail "Failed to clear old files from $DEST_DIR"

mv -f "$TMP_DEST_FILE" "${DEST_DIR}/${EXPORTED_FILENAME}" \
    || fail "Failed to finalize copy of ${EXPORTED_FILENAME} into $DEST_DIR"

if [ -f "${DEST_DIR}/${EXPORTED_FILENAME}" ]; then
    log "Successfully copied ${EXPORTED_FILENAME} to ${DEST_DIR}/"
else
    fail "Copy verification failed: ${DEST_DIR}/${EXPORTED_FILENAME} does not exist"
fi

# 7. Parse the export archive for device inventory (hostname, IP, ISE
#    version, latest applied patch number) and write it to ise_devices.csv
#    in the ISE export directory. The CSV is overwritten on every run so
#    it always reflects only the most recent export.
CSV_FILE="${DEST_DIR}/ise_devices.csv"
EXTRACT_DIR=$(mktemp -d /tmp/ise_export_extract.XXXXXX) || fail "Unable to create temp extraction directory"

cleanup_extract_dir() {
    rm -rf "$EXTRACT_DIR"
}
trap cleanup_extract_dir EXIT

log "Extracting ${EXPORTED_FILENAME} to parse device inventory..."
unzip -q -o "${DEST_DIR}/${EXPORTED_FILENAME}" -d "$EXTRACT_DIR" || fail "Failed to extract ${EXPORTED_FILENAME}"

echo "Hostname,IPAddress,ISEVersion,PatchNumber" > "$CSV_FILE"

# Only "Network_*" directories (managed/collected devices) are considered;
# "ExcludedNetwork_*" directories hold do-not-manage devices with no
# collected CLI/version details.
shopt -s nullglob
for NETDIR in "$EXTRACT_DIR"/Network_*/; do
    for DEVICE_FILE in "${NETDIR}"DeviceList_*.xml; do
        [ -f "$DEVICE_FILE" ] || continue

        FIELDS=$(awk '
            /^<Id>$/        { getline; gsub(/<!\[CDATA\[|\]\]><\/Id>/, "");        id = $0 }
            /^<IPAddress>$/ { getline; gsub(/<!\[CDATA\[|\]\]><\/IPAddress>/, ""); ip = $0 }
            /^<HostName>$/  { getline; gsub(/<!\[CDATA\[|\]\]><\/HostName>/, "");  host = $0 }
            /^<OSType>$/    { getline; gsub(/<!\[CDATA\[|\]\]><\/OSType>/, "");    ostype = $0 }
            END { printf "%s\037%s\037%s\037%s", id, host, ip, ostype }
        ' "$DEVICE_FILE")

        DEV_ID="${FIELDS%%$'\037'*}"; REST="${FIELDS#*$'\037'}"
        DEV_HOST="${REST%%$'\037'*}"; REST="${REST#*$'\037'}"
        DEV_IP="${REST%%$'\037'*}"; DEV_OSTYPE="${REST#*$'\037'}"

        # Only include actual ISE nodes (skips any non-ISE device that
        # might appear in the same network group).
        case "$DEV_OSTYPE" in
            *[Ii][Ss][Ee]*) ;;
            *) continue ;;
        esac

        ISE_VERSION=""
        PATCH_NUMBER=""
        CLI_VERSION_FILE="${NETDIR}NetworkDevice_${DEV_ID}/CLI/_show version"
        if [ -f "$CLI_VERSION_FILE" ]; then
            VERSION_FIELDS=$(awk '
                BEGIN { maxpatch = -1 }
                /^Cisco Identity Services Engine Patch/ { mode = "patch"; next }
                /^Cisco Identity Services Engine[[:space:]]*$/ { mode = "ise"; next }
                /^Version[[:space:]]*:/ {
                    val = $0
                    sub(/^Version[[:space:]]*:[[:space:]]*/, "", val)
                    gsub(/[[:space:]]+$/, "", val)
                    if (mode == "ise" && iseversion == "") { iseversion = val }
                    else if (mode == "patch") {
                        n = val + 0
                        if (n > maxpatch) { maxpatch = n }
                    }
                    mode = ""
                }
                END {
                    patchout = (maxpatch == -1) ? "" : maxpatch
                    printf "%s\037%s", iseversion, patchout
                }
            ' "$CLI_VERSION_FILE")
            ISE_VERSION="${VERSION_FIELDS%%$'\037'*}"
            PATCH_NUMBER="${VERSION_FIELDS#*$'\037'}"
        fi

        echo "\"${DEV_HOST}\",\"${DEV_IP}\",\"${ISE_VERSION}\",\"${PATCH_NUMBER}\"" >> "$CSV_FILE"
    done
done
shopt -u nullglob

DEVICE_COUNT=$(( $(wc -l < "$CSV_FILE") - 1 ))
log "Wrote ${DEVICE_COUNT} device record(s) to ${CSV_FILE}"

# 8. Ensure the exported zip and CSV (and the directory itself) are owned
#    by DEST_OWNER, so they can be retrieved over SSH/SCP/SFTP by that
#    account even though this script runs as root.
if id "$DEST_OWNER" >/dev/null 2>&1; then
    DEST_GROUP=$(id -gn "$DEST_OWNER")
    chown -R "${DEST_OWNER}:${DEST_GROUP}" "$DEST_DIR" \
        || fail "Failed to chown ${DEST_DIR} to ${DEST_OWNER}:${DEST_GROUP}"
    log "Set ownership of ${DEST_DIR} (and its contents) to ${DEST_OWNER}:${DEST_GROUP}"
else
    fail "User '${DEST_OWNER}' does not exist on this system; cannot set ownership of ${DEST_DIR}"
fi

log "Done. Log file retained at: $LOG_FILE"
