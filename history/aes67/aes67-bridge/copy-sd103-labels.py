#!/usr/bin/env python3
# Copy the four label lines of the target48-trace-txoff950-rxtrim-age50-sd103 block (DESCRIPTION, STATUS, COVER,
# MEASURED) from the shipped conf into the live conf. Labels only, atomic
# replace, no other line touched. Run without --apply for a dry run.
import os, re, sys, tempfile
shipped = os.path.expanduser("~bdimaio/usb-16x16-work/aes67-sd103-install/aes67.conf")
live = "/etc/usb16x16/aes67.conf"
prefix = "PROFILE_SERVO_ALIGNED_BOTH_240_RX120_SD144_TX192_TARGET48_TRACE_TXOFF950_RXTRIM_AGE50_SD103_"
keys = ("DESCRIPTION", "STATUS", "COVER", "MEASURED")
want = {}
for line in open(shipped):
    for k in keys:
        if line.startswith(prefix + k + "="):
            want[k] = line
assert len(want) == 4, want.keys()
src = open(live).read().split("\n")
out, changed = [], []
for line in src:
    hit = next((k for k in keys if line.startswith(prefix + k + "=")), None)
    if hit and line + "\n" != want[hit]:
        changed.append((line, want[hit].rstrip("\n")))
        line = want[hit].rstrip("\n")
    out.append(line)
for old, new in changed:
    print("- " + old); print("+ " + new)
print("%d line(s) would change" % len(changed) if "--apply" not in sys.argv else "%d line(s) changed" % len(changed))
if "--apply" in sys.argv and changed:
    st = os.stat(live)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(live), prefix=".aes67.conf.")
    with os.fdopen(fd, "w") as fh: fh.write("\n".join(out))
    os.chmod(tmp, st.st_mode & 0o7777); os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, live)
