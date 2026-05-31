#!/bin/bash
# =========================================
# patch_script.sh (FIXED VERSION)
# =========================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin:/usr/local/sbin

PATCH_TYPE=$1
MAILTO="${MAILTO:-nico.zanjani@fujitsu.com}"
AUTO_REBOOT="${AUTO_REBOOT:-true}"

LOGDIR="/var/log/auto_patching"
LOGFILE="${LOGDIR}/auto_patching$(date +%F).log"

HOST=$(hostname -f)
ENVIRONMENT="${ENVIRONMENT:-unknown}"
PATCH_FAILED=false
REBOOT_REQUIRED="No"

# ===== INPUT VALIDATION =====
if [ $# -ne 1 ]; then
    echo "ERROR: You must specify one argument: security | full"
    exit 1
fi

if [[ "$PATCH_TYPE" != "security" && "$PATCH_TYPE" != "full" ]]; then
    echo "ERROR: Invalid argument: $PATCH_TYPE"
    exit 1
fi

mkdir -p "$LOGDIR"

echo "=== Patch run started on $HOST for $PATCH_TYPE at $(date) ===" > "$LOGFILE"

# ----- HELPER FUNCTION -----
run_and_log() {
    echo "Running: $*" >> "$LOGFILE"
    "$@" >> "$LOGFILE" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "FAILED: $* (exit $rc)" >> "$LOGFILE"
        PATCH_FAILED=true
    fi
}

# ----- OS DETECTION -----
OS_ID=$(awk -F= '/^ID=/ {print $2}' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]')

case "$OS_ID" in
    rhel|centos|ol|oraclelinux)
        OS_FAMILY="rhel"
        ;;
    debian|ubuntu)
        OS_FAMILY="debian"
        ;;
    sles|suse)
        OS_FAMILY="suse"
        ;;
    *)
        OS_FAMILY="unsupported"
        ;;
esac

echo "OS detected: $OS_FAMILY" >> "$LOGFILE"

# ----- PATCHING -----
if [ "$PATCH_TYPE" == "security" ]; then
    echo "Security patching..." >> "$LOGFILE"

    case "$OS_FAMILY" in
        rhel)
            run_and_log dnf -y update --security
            ;;
        debian)
            run_and_log apt update -y
            run_and_log unattended-upgrade -d
            run_and_log apt -y autoremove
            ;;
        suse)
            run_and_log zypper patch --category security -y
            ;;
        *)
            echo "Unsupported OS" >> "$LOGFILE"
            PATCH_FAILED=true
            ;;
    esac

else
    echo "Full patching..." >> "$LOGFILE"

    case "$OS_FAMILY" in
        rhel)
            run_and_log dnf -y upgrade
            ;;
        debian)
            run_and_log apt update -y
            run_and_log apt -y upgrade
            run_and_log apt -y autoremove
            ;;
        suse)
            run_and_log zypper patch -y
            ;;
        *)
            echo "Unsupported OS" >> "$LOGFILE"
            PATCH_FAILED=true
            ;;
    esac
fi

echo "=== Patch completed at $(date) ===" >> "$LOGFILE"

# ----- SAFE REBOOT CHECK (RHEL ONLY) -----
if [ "$OS_FAMILY" == "rhel" ]; then
    if command -v needs-restarting >/dev/null 2>&1; then

        needs-restarting -r >/dev/null 2>&1
        rc=$?

        echo "DEBUG needs-restarting exit=$rc" >> "$LOGFILE"

        if [ "$rc" -eq 1 ]; then
            REBOOT_REQUIRED="Yes"
        else
            REBOOT_REQUIRED="No"
        fi

    else
        echo "WARNING: needs-restarting not installed" >> "$LOGFILE"
    fi
fi

# ----- WARNINGS -----
PATCH_WARNINGS=$(grep -i "warning\|held\|conflict" "$LOGFILE" || echo "None")

# ----- REPORT -----
MAILBODY=$(mktemp)

{
echo "Patching Report"
echo "==============="
echo "Host: $HOST"
echo "Environment: $ENVIRONMENT"
echo "Patch Type: $PATCH_TYPE"
echo "Date: $(date)"
echo
echo "Result: $( [ "$PATCH_FAILED" = true ] && echo FAILED || echo SUCCESS )"
echo
echo "Reboot Required: $REBOOT_REQUIRED"
echo
echo "Warnings:"
echo "$PATCH_WARNINGS"
echo
echo "Log: $LOGFILE"
} > "$MAILBODY"

sendmail -t <<EOF
Subject: [PATCH REPORT] $HOST - $PATCH_TYPE
To: $MAILTO
From: root@$HOST

$(cat "$MAILBODY")
EOF

rm -f "$MAILBODY"

# ----- REBOOT -----
if [ "$AUTO_REBOOT" = "true" ] && [ "$REBOOT_REQUIRED" = "Yes" ]; then
    echo "Scheduling reboot..." >> "$LOGFILE"
    shutdown -r +5 "Reboot after patching ($PATCH_TYPE)" | tee -a "$LOGFILE"
else
    echo "No reboot required." >> "$LOGFILE"
fi

# ----- CLEANUP -----
find /var/log/auto_patching/ -type f -mtime +50 -name "*.log" -delete
