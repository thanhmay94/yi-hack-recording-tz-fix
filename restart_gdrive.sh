#!/bin/sh
#
# restart_gdrive.sh - Restart the yi-hack Google Drive uploader with the local
#                     timezone, and optionally rewind its pointer.
#
# WHY THIS EXISTS
#
#   GDriveUploader turns recording folder names into timestamps with `date -d`,
#   using the system clock. The camera's system clock is UTC. Once this repo's
#   fix makes folder names local time, the uploader reads every folder as if it
#   were in the future and waits one UTC-offset (7 hours here) before rolling
#   over to the next hour. Uploads then run permanently that far behind.
#
#   Giving the uploader TZ from /home/yi-hack/etc/TZ puts both sides on the same
#   clock. Add it to /tmp/sd/yi-hack/startup.sh so it survives a reboot:
#
#       GDRIVE_TZ=$(cat /home/yi-hack/etc/TZ 2>/dev/null)
#       TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveUploader
#       TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveAutoremover
#
#   HEADS UP: start_time/finish_time near the top of GDriveUploader are read in
#   whatever clock the process has. If you had set an upload window, it now
#   means local time instead of UTC - check that the window is still what you
#   want before leaving this in place.
#
# REWINDING THE POINTER
#
#   get_next_dir() only ever moves forward (`[ "$current_dir" \< "$n" ]`), so if
#   the pointer in gdrive_folder.index ever lands ahead of your real folders,
#   every hour in between is skipped for good. Pass a folder name and the id of
#   a matching Google Drive folder to rewind it.
#
#   The Drive folder must already exist - create it by hand and copy its id out
#   of the URL. You cannot simply name an already-uploaded hour and mark it
#   finished: read_conf_files() compares against `cut -c 15-24` of the saved
#   name, which truncates ".mp4" off a 12-character filename, never matches, and
#   re-uploads the whole folder.
#
# USAGE
#   restart_gdrive.sh                          restart in place, keep pointer
#   restart_gdrive.sh <FOLDER> <DRIVE_DIR_ID>  restart and rewind to FOLDER
#
# Example:
#   ./restart_gdrive.sh 2026Y09M07D13H 1RuEBeaf_m0SRW_t1FAmg6o9HMsiBkxUf

G=/tmp/sd/yi-hack/gdrive

for p in $(ps | grep '[g]drive/GDrive' | awk '{print $1}'); do kill -9 "$p" 2>/dev/null; done
for p in $(ps | grep '[c]url' | awk '{print $1}'); do kill -9 "$p" 2>/dev/null; done
sleep 2

if [ -n "$1" ] && [ -n "$2" ]; then
    cp -f "$G/gdrive_folder.index" "$G/gdrive_folder.index.bak" 2>/dev/null
    cp -f "$G/gdrive_file.index"   "$G/gdrive_file.index.bak"   2>/dev/null
    echo "current_dir='$1'"    > "$G/gdrive_folder.index"
    echo "google_dir_id='$2'" >> "$G/gdrive_folder.index"
    echo "current_dir_file=''" > "$G/gdrive_file.index"
fi

# system.sh (lines 53-54) sets these before it calls startup.sh. Without them
# the bundled curl is not on PATH and fails with
# "libssl.so.1.1: cannot open shared object file" - silently, into the log.
PATH=$PATH:/home/base/tools:/home/yi-hack/bin:/home/yi-hack/sbin:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin
LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/lib:/home/yi-hack/lib:/tmp/sd/yi-hack/lib
export PATH LD_LIBRARY_PATH

TZ=$(cat /home/yi-hack/etc/TZ 2>/dev/null)
export TZ

nohup sh "$G/GDriveUploader"    >/dev/null 2>&1 &
nohup sh "$G/GDriveAutoremover" >/dev/null 2>&1 &
sleep 4

echo "--- processes ---"
ps | grep '[g]drive/GDrive'
echo "--- pointer ---"
cat "$G/gdrive_folder.index" "$G/gdrive_file.index"
echo "--- upload window (in the clock above) ---"
grep -n '^start_time=\|^finish_time=' "$G/GDriveUploader" | sed -n 1,2p
echo "--- camera clock ---"
date
