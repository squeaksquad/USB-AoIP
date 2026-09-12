#!/usr/bin/env python3
# Copy the four label lines (DESCRIPTION, STATUS, COVER, MEASURED) of the three
# accepted DSP blocks (dsp-direct, dsp-transparent, dsp-loaded) from the shipped
# repo conf into the live conf. Labels only, atomic replace, no other line
# touched; the transport fields and PROFILE= are not read. Run without --apply
# for a dry run. Form of copy-sd103-labels.py (2026-09-07).
import os, sys, tempfile
# 2026-09-11 23:58: the shipped conf may be given as the first argument (the
# meters set lives under meters-20260911/aes67/); the default is the DSP set.
shipped = os.path.expanduser("~bdimaio/usb-16x16-work/aes67-dsp-accept-install/aes67.conf")
if len(sys.argv) > 1 and not sys.argv[1].startswith("--"):
    shipped = sys.argv[1]
live = "/etc/usb16x16/aes67.conf"
prefixes = ("PROFILE_DSP_DIRECT_", "PROFILE_DSP_TRANSPARENT_", "PROFILE_DSP_LOADED_")
keys = ("DESCRIPTION", "STATUS", "COVER", "MEASURED")
want = {}
for line in open(shipped):
    for p in prefixes:
        for k in keys:
            if line.startswith(p + k + "="):
                want[p + k] = line
assert len(want) == 12, sorted(want)
src = open(live).read().split("\n")
out, changed = [], []
for line in src:
    hit = next((key for key in want if line.startswith(key + "=")), None)
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
