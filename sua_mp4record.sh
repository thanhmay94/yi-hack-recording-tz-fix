#!/bin/sh
#
# sua_mp4record.sh - Make recording folder names use local time, and make sure
#                    exactly ONE mp4record process is running.
#
# ("sua" is Vietnamese for "fix". The filename is kept as-is so existing
#  deployments that reference it from startup.sh keep working.)
#
# ---------------------------------------------------------------------------
# TWO CLOCKS
#
#   On-screen timestamp (OSD) = system timezone (/etc/localtime) + tz_offset_osd
#   Recording folder name     = mp4record's own TZ              + tz_offset_osd
#
#   tz_offset_osd is an integer (seconds) in the shared memory file
#   /tmp/mmap.info at address 0x4F4 for model y203c. system.sh sets it to
#   your UTC offset (e.g. 25200 for UTC+7) on every boot. It lives in /tmp
#   (tmpfs) so it does NOT survive a reboot.
#
# THE BUG
#
#   system.sh starts mp4record like this:
#
#       export TZP=`TZ=$TZ_TMP date +%z`      # "+0700"
#       export TZP=${TZP:0:3}:${TZP:3:2}      # "+07:00"
#       export TZ=GMT$TZP                     # "GMT+07:00"
#       ./mp4record
#
#   In POSIX, "GMT+07:00" means 7 hours WEST of Greenwich, i.e. UTC-7 - the
#   sign is inverted compared to what the author intended. So:
#
#       folder = (-7) + (+7) = 0   -> folder names come out in UTC
#       OSD    =   0  + (+7) = +7  -> on-screen time is correct (by luck)
#
#   The two cancel out. That is why the folders are off by exactly your UTC
#   offset while the burned-in timestamp looks fine.
#
# THE FIX
#
#   Restart mp4record with TZ=UTC0 (offset 0) and leave tz_offset_osd alone:
#
#       folder = 0 + (+7) = +7  -> local time
#       OSD    = 0 + (+7) = +7  -> unchanged
#
#   Do NOT "fix" this by setting tz_offset_osd to 0 and using TZ=ICT-7. That
#   also produces correct folder names, but it drags the OSD along with it and
#   your burned-in timestamps end up in UTC.
#
# WHY THIS RUNS PERIODICALLY
#
#   Several things start additional mp4record processes:
#     - Yi's own watch_process (inherits TZ=GMT+07:00 from system.sh)
#     - the CGI camera_settings.sh?switch_on=yes, used whenever recording is
#       switched back on - by the app, by a schedule, or by your own scripts.
#       It inherits TZ from httpd, i.e. the contents of /home/yi-hack/etc/TZ.
#
#   Two processes whose TZ resolves to the same offset write into the SAME
#   folder and overwrite each other's files. The result is truncated .mp4
#   files that open fine but only decode 20-60% of their frames - which looks
#   exactly like failing hardware. Keep exactly one process and it goes away.
#
# USAGE
#   sua_mp4record.sh          wait 60s (for system.sh to finish), then clean up.
#                             This is what you call from startup.sh at boot.
#   sua_mp4record.sh --ngay   clean up immediately.
#   sua_mp4record.sh --canh   only clean up IF NEEDED. Safe to run from cron:
#                             it does not interrupt recording when all is well.
# ---------------------------------------------------------------------------

CHO_BAN_DAU=60          # wait for system.sh to start its own copy first
LOG=$(dirname "$0")/sua_mp4record.log
TZ_DUNG="UTC0"          # the TZ mp4record must run with

TZ="$TZ_DUNG"
export TZ

# Print "<pid> <TZ>" for every running mp4record
liet_ke() {
    for p in /proc/[0-9]*; do
        # The redirect must be inside the braces: when a process exits between
        # the glob and the read, it is the SHELL that reports "can't open
        # /proc/N/cmdline", so 2>/dev/null on tr alone does not silence it.
        c=$( { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null )
        case "$c" in
            "./mp4record"*)
                tz=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep '^TZ=' | cut -d= -f2- )
                echo "${p#/proc/} ${tz:-NO_TZ}"
                ;;
        esac
    done
}

case "$1" in
    --ngay) ;;
    --canh)
        # Exactly one process with the right TZ: leave recording alone.
        ds=$(liet_ke)
        so=$(echo "$ds" | grep -c .)
        if [ "$so" = "1" ] && [ "${ds#* }" = "$TZ_DUNG" ]; then
            exit 0
        fi
        ;;
    *) sleep "$CHO_BAN_DAU" ;;
esac

{
    echo "$(date '+%Y-%m-%d %H:%M:%S') === cleaning up mp4record ($1) ==="
    liet_ke | while read pid tz; do
        echo "  kill $pid (TZ=$tz)"
        kill "$pid" 2>/dev/null
    done

    sleep 3

    cd /home/app || exit 1
    LD_LIBRARY_PATH="/lib:/home/lib:/home/ms:/home/app/locallib:/home/lib:/home/yi-hack/lib:/tmp/sd/yi-hack/lib" \
        ./mp4record >/dev/null 2>&1 &

    sleep 4
    liet_ke | while read pid tz; do
        echo "  running $pid (TZ=$tz)"
    done
} >> "$LOG" 2>&1

# Trim the log
if [ -f "$LOG" ]; then
    dong=$(grep -c . "$LOG")
    if [ "$dong" -gt 500 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
fi
