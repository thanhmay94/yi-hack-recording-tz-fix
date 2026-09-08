# yi-hack recording folder timezone fix

On Yi cameras running [yi-hack-MStar](https://github.com/roleoroleo/yi-hack-MStar),
recordings are stored as `/tmp/sd/record/<YYYY>Y<MM>M<DD>D<HH>H/<MM>M<SS>S.mp4`.
The **folder names come out in UTC** while the timestamp burned into the video
is in local time. Anything that derives the recording time from the folder name
is therefore off by your UTC offset.

This repo explains why, and fixes it without touching the on-screen timestamp.

Also documented here: a second failure mode that produces **truncated .mp4
files which look exactly like failing camera hardware** but are not.

*[Tiếng Việt](README.vi.md)*

## Two clocks

This is the key to the whole thing. Two different times are derived from two
different sources that happen to share one offset:

```
On-screen timestamp (OSD) = system timezone (/etc/localtime) + tz_offset_osd
Recording folder name     = mp4record's own TZ env var       + tz_offset_osd
```

`tz_offset_osd` is an integer (seconds) written into the shared memory file
`/tmp/mmap.info`, at address `0x4F4` for model `y203c` (see
[`set_tz_offset.c`](https://github.com/roleoroleo/yi-hack-MStar/blob/master/src/set_tz_offset/set_tz_offset/set_tz_offset.c)
for the per-model address table). `system.sh` sets it to your UTC offset on
every boot. It lives in `/tmp` (tmpfs), so it does not survive a reboot.

## The bug

`system.sh` launches `mp4record` like this:

```sh
export TZP=`TZ=$TZ_TMP date +%z`      # "+0700"
export TZP=${TZP:0:3}:${TZP:3:2}      # "+07:00"
export TZ=GMT$TZP                     # "GMT+07:00"
./mp4record
```

In POSIX, `GMT+07:00` means 7 hours **west** of Greenwich — that is `UTC-7`,
the opposite sign from what was intended. Plugging that into the formulas
(example: a UTC+7 zone, so `tz_offset_osd = 25200`):

```
folder = (-7) + (+7) = 0    ->  folder names in UTC          (wrong)
OSD    =   0  + (+7) = +7   ->  on-screen time is local      (correct by luck)
```

The two errors cancel out for the OSD but not for the folder name.

## The fix

Restart `mp4record` with `TZ=UTC0` and **leave `tz_offset_osd` alone**:

```
folder = 0 + (+7) = +7   ->  local time  ✓
OSD    = 0 + (+7) = +7   ->  unchanged   ✓
```

`sua_mp4record.sh` does this: it waits for `system.sh` to finish starting its
own (broken) copy, kills every `mp4record`, and starts exactly one with
`TZ=UTC0`. It is called from `/tmp/sd/yi-hack/startup.sh`, which `system.sh`
runs automatically at the end of boot. Everything lives on the SD card, so it
survives reboots and firmware upgrades.

> **Do not** fix this by setting `tz_offset_osd` to `0` and using `TZ=ICT-7`
> (or your equivalent). That also gives correct folder names, but it drags the
> OSD along with it and your burned-in timestamps end up in UTC — which is far
> worse, because unlike a folder name you cannot correct it afterwards.

## Pitfall 1: duplicate `mp4record` processes corrupt recordings

The CGI `service.sh?name=mp4record&action=start` runs `./mp4record &` with **no
check of any kind** — no "is one already running", no kill first. Upstream
yi-hack-MStar 0.5.7, lines 466-474, unchanged in master. Call it n times and you
get n recorders. `system.sh` has already started one at boot, so the very first
call gives you two.

Callers cannot avoid it by asking first. `action=status` is `ps_program()`:

```sh
ps | grep $1 | grep -v grep | grep -c ^
```

The command line of the CGI process asking the question contains `$1`, so it
matches itself. Ask for the status of a program that does not exist and it still
answers `started`. The only reliable sequence is `stop` (which is `killall`, so
it is idempotent) and then `start`.

Anything that switches recording back on goes through this: the Yi phone app, an
on/off schedule, your own tooling.

**Why one matters.** Every `mp4record` writes through the *same staging file*,
`/tmp/sd/record/tmp.mp4.tmp`, and only renames it into the hour folder when the
clip is finished. That path is identical no matter what `TZ` each process has or
which folder it is aiming at. Two recorders are two H.264 streams interleaved
into one file: full size, opens without error, decodes **20-60% of the frames it
claims to have**. It looks exactly like a failing encoder chip. It is not.

Check with:

```sh
ps | grep '[m]p4record'
```

Anything other than exactly one line is a problem.

Because of this, `sua_mp4record.sh` is also registered as a cron job with
`--canh` ("watch"): if exactly one process with the right `TZ` is running it
exits immediately and does not disturb recording; it only cleans up when
something is actually wrong. It costs about 0.4 s per run, so once a minute is
reasonable on a camera that is switched on and off during the day.

Two suspects that turned out to be innocent, in case you go looking for them:
Yi's `watch_process` is not running on these cameras at all, and
`camera_settings.sh?switch_on=yes` only calls `ipc_cmd -t on` — it does not
launch a recorder itself.

## Pitfall 2: `/etc/localtime` lives on the camera body, not the SD card

If `/etc/TZ` and `/etc/localtime` exist, the system timezone is local rather
than UTC, and the first formula becomes `OSD = (+7) + (+7) = +14`.

These files are on the internal flash (jffs2), so they **stay with the camera
body** when you move SD cards between cameras. If you have ever swapped
hardware around, one camera can end up with them and another without, and the
same configuration then behaves differently on each.

Check before applying the fix:

```sh
date
```

If it prints `UTC`, you are fine. If it prints a local zone, remove
`/etc/TZ` and `/etc/localtime` (back them up first) or your OSD will be off
by one extra offset. The installer asks you about this.

## Pitfall 3: the Google Drive uploader now runs 7 hours late

Only relevant if you use roleoroleo's Google Drive add-on
(`/tmp/sd/yi-hack/gdrive/`).

`GDriveUploader` converts folder names back into timestamps with `date -d`,
which uses the system clock — and the system clock is UTC. Once folder names
carry local time, every folder looks like it is in the future, so the uploader
waits one full UTC offset before rolling over to the next hour. Uploads end up
running permanently that far behind. Nothing is lost; it just lags.

Give the uploader the same clock the folder names use, in
`/tmp/sd/yi-hack/startup.sh`:

```sh
GDRIVE_TZ=$(cat /home/yi-hack/etc/TZ 2>/dev/null)
TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveUploader
TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveAutoremover
```

`restart_gdrive.sh` applies this to a running camera without a reboot.

Three things to know before you do:

- **`start_time` / `finish_time`** near the top of `GDriveUploader` are read in
  whatever clock the process has. If you set an upload window it now means
  local time rather than UTC — a `01:00`–`07:00` window that was really running
  08:00–14:00 local moves to 01:00–07:00 local. Check it is still what you want.
- **`get_next_dir()` only moves forward** (`[ "$current_dir" \< "$n" ]`). If the
  pointer in `gdrive_folder.index` ever gets ahead of your real folders — a
  clock experiment, a renamed directory — every hour in between is skipped
  permanently. `restart_gdrive.sh <FOLDER> <DRIVE_DIR_ID>` rewinds it.
- **Launch it with the right environment.** `system.sh` (lines 53-54) puts the
  bundled `curl` on `PATH` and its libraries on `LD_LIBRARY_PATH` before it
  calls `startup.sh`. Start the uploader from a bare SSH session without them
  and every upload fails with `libssl.so.1.1: cannot open shared object file`,
  logged quietly to `log/GDriveUploader.log` while the process keeps looping.

## Pitfall 4: your cron job never runs

`sua_mp4record.sh --canh` is registered as a cron job. On a stock camera that
job never executes, and nothing tells you.

`busybox crond` reads the crontabs **once, when it starts**, and never rescans
them. `system.sh` starts crond on line 385 and only calls
`/tmp/sd/yi-hack/startup.sh` on line 395 - after. So any cron line written from
`startup.sh` is registered into a file crond has already finished reading.

Measured on a y203c: add a line to `/var/spool/cron/crontabs/root`, wait 80
seconds, nothing runs. Restart crond and it fires on the very next minute.

This bites anything you schedule from `startup.sh`, not just this fix.
`/var/spool` is tmpfs as well, so the crontab itself is gone after a reboot and
gets rewritten by `startup.sh` - into a crond that will not read it again.

So `startup.sh` must restart crond after writing the crontab:

```sh
for p in $(ps | grep '[c]rond' | awk '{print $1}'); do kill "$p" 2>/dev/null; done
sleep 2
/usr/sbin/crond -c /var/spool/cron/crontabs/
```

`deploy.py` writes this for you. To check an existing camera:

```sh
echo '* * * * * date >> /tmp/moc.txt' >> /var/spool/cron/crontabs/root
sleep 80; cat /tmp/moc.txt      # empty means crond is not reading your crontab
```

## Install

Requires Python 3 and `paramiko` on your PC (`pip install paramiko`), and SSH
enabled on the camera (yi-hack default: user `root`, empty password).

```bash
python deploy.py 192.168.1.99
```

On Windows you can double-click `run_deploy.bat`, which just asks for the IP.

Then reboot the camera:

```
http://<camera-ip>/cgi-bin/reboot.sh
```

## Verify

About two minutes after the reboot:

```sh
date                       # should print UTC
date -u                    # actual UTC
ls /tmp/sd/record | tail    # newest folder should match your LOCAL hour
ps | grep '[m]p4record'    # exactly one process
```

Then pull the newest `.mp4` off the card and check that the burned-in timestamp
matches the folder name plus the file name. All three must agree.

## Uninstall

Remove the line calling `sua_mp4record.sh` from `/tmp/sd/yi-hack/startup.sh`,
remove the cron entry from `/var/spool/cron/crontabs/root`, and reboot.

## Scope

Tested on model `y203c`, app firmware `4.5.0.0C_201910080934`,
yi-hack-MStar `0.5.7`, in a UTC+7 zone. The formulas are not zone-specific;
`TZ=UTC0` is the correct value regardless of your offset, because the fix
relies on `tz_offset_osd` (which `system.sh` already sets correctly for your
zone) rather than on hard-coding an offset.

Cameras running **yi-hack-v5** are a different codebase and do not have this
bug — check `date` before assuming otherwise.

## License

MIT
