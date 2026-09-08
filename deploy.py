"""
Deploy sua_mp4record.sh to a yi-hack-MStar camera over SSH/SFTP.

Fixes recording folder names that come out in UTC instead of local time.
See README.md for the root cause.

Usage:
    python deploy.py 192.168.1.99

Requires: pip install paramiko
The camera must have SSH enabled (yi-hack default: user "root", no password).
"""
import sys
import os
import paramiko

PASSWORD = ""  # yi-hack-MStar default: no password
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT_LOCAL = os.path.join(HERE, "sua_mp4record.sh")
SCRIPT_REMOTE = "/tmp/sd/yi-hack/scripts/sua_mp4record.sh"
STARTUP_REMOTE = "/tmp/sd/yi-hack/startup.sh"
CALL_LINE = "/bin/sh /tmp/sd/yi-hack/scripts/sua_mp4record.sh >/dev/null 2>&1 &\n"
CRON_LINE = "*/5 * * * * /bin/sh /tmp/sd/yi-hack/scripts/sua_mp4record.sh --canh >/dev/null 2>&1"

# Deliberately one long line: a "|| \" continuation here is easy to mangle when
# this block is written out through another tool, and a literal "\n" in the
# middle silently breaks the registration - the cron job then quietly stops
# coming back after a reboot, because /var/spool is tmpfs.
CRON_BLOCK = (
    "\n# Keep exactly one mp4record with the right TZ - see README.\n"
    "mkdir -p /var/spool/cron/crontabs\n"
    f"grep -q 'sua_mp4record.sh --canh' /var/spool/cron/crontabs/root 2>/dev/null"
    f" || echo '{CRON_LINE}' >> /var/spool/cron/crontabs/root\n"
    "\n"
    "# busybox crond reads the crontabs ONCE when it starts and never rescans,\n"
    "# and system.sh starts it (line 385) BEFORE it calls this file (line 395).\n"
    "# Without this restart the cron line above is never loaded: it silently does\n"
    "# nothing, every boot, forever. Measured: add a cron line and wait 80s -\n"
    "# nothing runs; restart crond and it fires on the very next minute.\n"
    "for p in $(ps | grep '[c]rond' | awk '{print $1}'); do kill \"$p\" 2>/dev/null; done\n"
    "sleep 2\n"
    "/usr/sbin/crond -c /var/spool/cron/crontabs/\n"
)

# See "Pitfall 3" in the README. Only applied if the gdrive add-on is present.
GDRIVE_TZ_LINE = "GDRIVE_TZ=$(cat /home/yi-hack/etc/TZ 2>/dev/null)\n"


def patch_gdrive_lines(text):
    """Give GDriveUploader/Autoremover the same clock the folder names use."""
    if "gdrive/GDriveUploader" not in text or "GDRIVE_TZ" in text:
        return text, False
    for name in ("GDriveUploader", "GDriveAutoremover"):
        old = f"sh /tmp/sd/yi-hack/gdrive/{name}"
        new = f'TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/{name}'
        if old in text and new not in text:
            text = text.replace(old, new, 1)
    anchor = 'TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveUploader'
    return text.replace(anchor, GDRIVE_TZ_LINE + anchor, 1), True


def deploy(ip):
    print(f"=== connecting to {ip} ===")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip, port=22, username="root", password=PASSWORD, timeout=10,
              allow_agent=False, look_for_keys=False)

    def sh(cmd):
        _, out, _ = c.exec_command(cmd)
        out.channel.recv_exit_status()
        return out.read().decode(errors="replace").strip()

    # 1. Make sure this is yi-hack-MStar, not v5
    if "No such" not in sh("ls -d /home/yi-hack-v5 2>&1"):
        print("  STOP: this is yi-hack-v5, not MStar. It does not have this bug.")
        print("  Check 'date' on the camera - folder names are usually already correct.")
        c.close()
        return

    # 2. Pitfall 2: /etc/localtime makes the system clock local, which shifts
    #    the on-screen timestamp by an extra offset. See README.
    system_date = sh("date")
    print(f"  camera system time: {system_date}")
    if "UTC" not in system_date:
        print("  !! This camera has /etc/localtime (system clock is on local time).")
        print("     Leave it in place and your on-screen timestamp will be off by")
        print("     one extra offset after this fix.")
        answer = input("     Remove /etc/TZ and /etc/localtime (backed up first)? (y/N): ")
        if answer.strip().lower() == "y":
            sh("mkdir -p /tmp/sd/yi-hack/backup_etc_tz")
            sh("cp -f /etc/TZ /tmp/sd/yi-hack/backup_etc_tz/TZ 2>/dev/null")
            sh("cp -f /etc/localtime /tmp/sd/yi-hack/backup_etc_tz/localtime 2>/dev/null")
            sh("rm -f /etc/TZ /etc/localtime")
            print("     removed (backup in /tmp/sd/yi-hack/backup_etc_tz/).")
        else:
            print("     skipped - expect the on-screen time to be off.")

    # 3. Upload the script and hook it into startup.sh
    sh("mkdir -p /tmp/sd/yi-hack/scripts")
    sftp = c.open_sftp()
    sftp.put(SCRIPT_LOCAL, SCRIPT_REMOTE)
    sftp.chmod(SCRIPT_REMOTE, 0o755)

    try:
        with sftp.open(STARTUP_REMOTE, "r") as f:
            existing = f.read().decode("utf-8", errors="replace")
    except IOError:
        existing = ""

    new = existing
    if "sua_mp4record.sh" not in new:
        new += ("\n" if new and not new.endswith("\n") else "") + CALL_LINE
        print("  added the startup.sh hook.")
    else:
        print("  startup.sh already calls sua_mp4record.sh.")

    if "--canh" not in new:
        new += CRON_BLOCK
        print("  added the cron registration to startup.sh.")

    new, gdrive_patched = patch_gdrive_lines(new)
    if gdrive_patched:
        print("  gdrive add-on found: gave the uploader your local timezone.")
        print("     !! start_time/finish_time in GDriveUploader now mean LOCAL")
        print("        time, not UTC. Check your upload window - see README.")

    if new != existing:
        with sftp.open(STARTUP_REMOTE, "w") as f:
            f.write(new.encode())
        sftp.chmod(STARTUP_REMOTE, 0o755)
    sftp.close()

    # 4. Register the cron job now, without waiting for the next boot
    sh("mkdir -p /var/spool/cron/crontabs")
    sh(f"grep -q 'sua_mp4record.sh --canh' /var/spool/cron/crontabs/root 2>/dev/null "
       f"|| echo '{CRON_LINE}' >> /var/spool/cron/crontabs/root")

    # The same crond restart, applied now instead of waiting for a reboot.
    sh("for p in $(ps | grep '[c]rond' | awk '{print $1}'); do kill \"$p\" 2>/dev/null; done")
    sh("sleep 2; /usr/sbin/crond -c /var/spool/cron/crontabs/")
    print("  crond restarted, so the cron entry is actually loaded.")

    # 5. Warn about an older style of fix that fights this one
    if "set_tz_offset" in existing and "-v 0" in existing:
        print("  !! startup.sh still contains 'set_tz_offset ... -v 0'.")
        print("     That forces the on-screen timestamp to UTC. Remove it - see README.")

    print("  done. Reboot the camera to apply:")
    print(f"     http://{ip}/cgi-bin/reboot.sh")
    print("  Then check that the newest folder in /tmp/sd/record/ and the burned-in")
    print("  timestamp both match your local time.")

    c.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python deploy.py <CAMERA_IP>")
        sys.exit(1)
    deploy(sys.argv[1])
