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
#   ONE thing starts extra recorders: the CGI
#   service.sh?name=mp4record&action=start. It runs `./mp4record &` with no
#   check at all (upstream yi-hack-MStar 0.5.7 lines 466-474, unchanged in
#   master), so calling it n times gives you n recorders - and system.sh has
#   already started one at boot. Anything that switches recording back on hits
#   this: the Yi phone app, an on/off schedule, your own tooling.
#
#   Callers cannot avoid it by asking first. service.sh?action=status is
#   ps_program(), which is `ps | grep $1 | grep -v grep | grep -c ^` - and the
#   command line of the CGI process asking the question contains "$1". Query
#   the status of a program that does not exist and it still answers "started".
#   The only reliable sequence is stop (killall, idempotent) then start.
#
#   Note camera_settings.sh?switch_on=yes does NOT start a recorder; it only
#   runs `ipc_cmd -t on`. And Yi's watch_process is not running on these
#   cameras at all - both were plausible suspects, neither is the cause.
#
#   Why one matters: every mp4record writes through the SAME staging file,
#   /tmp/sd/record/tmp.mp4.tmp, and only then renames it into the hour folder.
#   That path is identical no matter what TZ or target folder each process has.
#   Two recorders are two H.264 streams interleaved into one file: full size,
#   opens without error, decodes 20-60% of the frames it claims. It looks
#   exactly like a failing encoder chip. It is not.
#
# USAGE
#   sua_mp4record.sh          wait 60s (for system.sh to finish), then clean up.
#                             This is what you call from startup.sh at boot.
#   sua_mp4record.sh --ngay   clean up immediately.
#   sua_mp4record.sh --canh   only clean up IF NEEDED. Safe to run from cron:
#                             it does not interrupt recording when all is well.
#
# THE STUCK LOCK (found 2026-11-18)
#
#   mp4record reads frames from a shared buffer guarded by the POSIX named
#   semaphore /dev/sem.fshare_read_lock (16-byte file on tmpfs; byte 0 is the
#   value: 1 = free, 0 = held). Killing a recorder at the instant it holds that
#   semaphore leaves it at 0 forever. Every recorder started afterwards blocks
#   in sem_wait (wchan futex_wait_queue_me) right after logging
#   "fshare_open ok": the process exists, SWITCH_ON is yes, RTSP still works,
#   but not a single file is written - until the camera reboots. One camera
#   lost 3.5 days of footage this way.
#
#   Two defences here:
#   - dung_an_toan: freeze the recorder (SIGSTOP), and only send SIGTERM if the
#     semaphore is free at that moment - a frozen process cannot be holding it.
#     SIGTERM (not SIGKILL) so mp4record still saves its partial minute.
#   - khoa_ket / mo_khoa: the lock is held for microseconds (300 reads over
#     10 s on a recording camera: never 0). Six reads of 0 over 2.5 s means
#     nobody will ever release it, so write 1 back and restart the recorder.
# ---------------------------------------------------------------------------

CHO_BAN_DAU=60          # wait for system.sh to start its own copy first
LOG=$(dirname "$0")/sua_mp4record.log
TZ_DUNG="UTC0"          # the TZ mp4record must run with

TZ="$TZ_DUNG"
export TZ

# Print "<pid> <TZ>" for every running mp4record.
#
# Shortlist with one `ps` first. Walking all of /proc instead forks `tr` once
# per process - about 60 forks on an idle camera, which measured 2 seconds per
# call. That is fine every 5 minutes and wasteful every minute.
#
# `ps | grep` alone is NOT enough to decide: a `wget` fetching
# service.sh?name=mp4record&action=start has "mp4record" in its own command
# line and would be counted as a recorder. So each candidate is still confirmed
# against /proc/<pid>/cmdline - just for the two or three that ps shortlisted.
liet_ke() {
    for pid in $(ps 2>/dev/null | grep '[m]p4record' | awk '{print $1}'); do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        # The redirect must be inside the braces: when a process exits between
        # the listing and the read, it is the SHELL that reports "can't open
        # /proc/N/cmdline", so 2>/dev/null on tr alone does not silence it.
        c=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null )
        case "$c" in
            "./mp4record"*)
                tz=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | grep '^TZ=' | cut -d= -f2- )
                echo "$pid ${tz:-NO_TZ}"
                ;;
        esac
    done
}

KHOA=/dev/sem.fshare_read_lock

# Byte 0 of the semaphore: 1 = free, 0 = held.
gia_tri_khoa() {
    dd if="$KHOA" bs=1 count=1 2>/dev/null | hexdump -e '1/1 "%u"'
}

# True only if the lock reads 0 six times over ~2.5 s. Returns after ONE read
# when the lock is free, which is the normal case - cheap enough for cron.
khoa_ket() {
    [ -e "$KHOA" ] || return 1
    i=0
    while [ $i -lt 6 ]; do
        [ "$(gia_tri_khoa)" = "0" ] || return 1
        i=$((i + 1))
        usleep 500000
    done
    return 0
}

# Put the semaphore back to "free". Waiters already asleep are not woken by
# this, which is why the callers restart the recorder afterwards.
mo_khoa() {
    echo -ne '\001' | dd of="$KHOA" bs=1 count=1 conv=notrunc 2>/dev/null
}

# Stop one recorder at a moment it is not holding the lock (see above).
dung_an_toan() {
    lan=0
    while [ $lan -lt 20 ]; do
        kill -STOP "$1" 2>/dev/null || return 0     # already gone
        if [ "$(gia_tri_khoa)" != "0" ]; then
            kill -TERM "$1" 2>/dev/null
            kill -CONT "$1" 2>/dev/null
            return 0
        fi
        kill -CONT "$1" 2>/dev/null
        usleep 100000
        lan=$((lan + 1))
    done
    # Lock busy for 2 s straight: stop anyway, the check after restart repairs it.
    echo "  lock busy for 2s, stopping $1 anyway"
    kill -TERM "$1" 2>/dev/null
}

case "$1" in
    --ngay) ;;
    --canh)
        if khoa_ket; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') read lock stuck at 0 -> reset to 1" >> "$LOG"
            mo_khoa
            # A recorder already asleep on the lock stays asleep: restart it
            # (falls through to the cleanup below). No recorder = recording is
            # off on purpose, leave it off.
            [ -n "$(liet_ke)" ] || exit 0
        else
        ds=$(liet_ke)
        so=$(echo "$ds" | grep -c .)

        # No recorder at all: the camera was switched OFF on purpose - the yi
        # app, a schedule, or your own tooling called
        # service.sh?name=mp4record&action=stop. Starting one here would undo
        # that and leave the camera recording all night. The periodic guard
        # keeps ONE recorder correct; it does not decide whether to record.
        if [ "$so" = "0" ]; then
            exit 0
        fi

        # Exactly one process with the right TZ: leave recording alone.
        if [ "$so" = "1" ] && [ "${ds#* }" = "$TZ_DUNG" ]; then
            exit 0
        fi
        fi
        ;;
    *) sleep "$CHO_BAN_DAU" ;;
esac

khoi_dong_lai() {
    liet_ke | while read pid tz; do
        echo "  kill $pid (TZ=$tz)"
        dung_an_toan "$pid"
    done

    sleep 3

    cd /home/app || exit 1
    LD_LIBRARY_PATH="/lib:/home/lib:/home/ms:/home/app/locallib:/home/lib:/home/yi-hack/lib:/tmp/sd/yi-hack/lib" \
        ./mp4record >/dev/null 2>&1 &

    sleep 4
    liet_ke | while read pid tz; do
        echo "  running $pid (TZ=$tz)"
    done
}

{
    echo "$(date '+%Y-%m-%d %H:%M:%S') === cleaning up mp4record ($1) ==="
    khoi_dong_lai
    # The kill above may still have hit the lock (SIGTERM handler, or the
    # 2 s fallback). Check once and repair right away instead of a minute later.
    if khoa_ket; then
        echo "  read lock stuck at 0 after restart -> reset to 1, restart again"
        mo_khoa
        khoi_dong_lai
    fi
} >> "$LOG" 2>&1

# Trim the log
if [ -f "$LOG" ]; then
    dong=$(grep -c . "$LOG")
    if [ "$dong" -gt 500 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
fi
