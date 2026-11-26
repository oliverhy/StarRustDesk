"""Read-only USB observation of the test app's one connected IPv4 relay socket.

Filter by app UID, connected state and exact approved relay ON the phone. Do
not export socket tables, other apps' endpoints, kernel pointers or payloads.
"""
import argparse
from bisect import bisect_left,bisect_right
import ipaddress
import json
from pathlib import Path
import re
import subprocess
from public_target import read_profile

SHELL=r'''p=$(pidof com.yinhe.starrustdesk)
case "$p" in ""|*" "*) echo unavailable; exit;; esac
uid=$(stat -c %u /proc/$p 2>/dev/null)
case "$uid" in ""|*[!0-9]*) echo unavailable; exit;; esac
file=/proc/$p/net/udp
read -r header < "$file" || { echo unavailable; exit; }
case "$header" in *" rem_address "*" drops"*) ;; *) echo unavailable; exit;; esac
last=; epoch=0; idx=0; absent=0
echo "zone $(date +%z)"
start=$(date +%s%3N); end=$((start+DURATION))
while [ "$idx" -lt SAMPLES ]; do
  count=0; inode=; rx=; drops=
  while read -r slot local remote state queue timer retr owner timeout ino ref ptr loss extra; do
    if [ "$owner" = "$uid" ] && [ "$state" = 01 ] && [ "$remote" = TARGET ] && [ -z "$extra" ]; then
      count=$((count+1)); inode=$ino; rx=${queue#*:}; drops=$loss
    fi
  done < "$file" || { echo unavailable; break; }
  stamp=$(date +%s%3N)
  if [ "$count" = 1 ]; then
    if [ "$inode" != "$last" ]; then epoch=$((epoch+1)); fi
    last=$inode; absent=0; echo "sock $stamp $epoch $rx $drops"
  else
    last=; absent=$((absent+1)); echo "none $stamp $count"
  fi
  [ "$stamp" -ge "$end" ] && break
  [ "$absent" -gt 36 ] && break
  idx=$((idx+1)); sleep 0.5
done'''


def summarize(rows):
    valid=[r for r in rows if r[1]>0]
    contiguous=[(a,b) for a,b in zip(rows,rows[1:]) if a[1]>0 and a[1]==b[1] and 0<b[0]-a[0]<=1500]
    diffs=[b[3]-a[3] for a,b in contiguous if b[3]>=a[3]]
    return dict(samples=len(rows),matched=len(valid),covered_ms=sum(b[0]-a[0] for a,b in contiguous if b[3]>=a[3]),
                counter_increase=sum(diffs) if diffs else None,peak_receive_queue_bytes=max((r[2] for r in valid),default=None),
                counter_resets=sum(b[3]<a[3] for a,b in contiguous))


def gap_windows(rows,epochs,zone):
    """A zero delta in a bracketing window rules out this socket's counted
    drops there, not radio loss. Positive deltas need not be video packets."""
    if not rows or zone is None: return []
    times=[r[0] for r in rows]
    if any(b<=a for a,b in zip(times,times[1:])): return []
    windows=[];day=86_400_000
    for epoch in epochs:
        for gap,stamp in zip(epoch["gap_events"],epoch.get("gap_stamps",[])):
            if not (m:=re.fullmatch(r"(\d\d):(\d\d):(\d\d)\.(\d{3,6})",stamp)): continue
            h,minute,sec=map(int,m.groups()[:3])
            offset=((h*60+minute)*60+sec)*1000+int(m[4][:3])-zone*60_000
            end=(times[0]//day)*day+offset
            end=min((end-day,end,end+day),key=lambda n:abs(n-times[0]))
            begin=end-gap[4]
            lo=bisect_right(times,begin)-1; hi=bisect_left(times,end)
            if lo<0 or hi>=len(rows) or times[hi]-end>1500 or begin-times[lo]>1500: continue
            group=rows[lo:hi+1]
            if any(a[1]==0 or a[1]!=b[1] or b[0]-a[0]>1500 or b[3]<a[3] for a,b in zip(group,group[1:])):
                continue
            if not group[0][1] or not gap[4]: continue
            windows.append(dict(gap_ms=gap[4],missing_frames=gap[3],socket_drops=group[-1][3]-group[0][3],
                peak_queue_bytes=max(r[2] for r in group),before_ms=begin-times[lo],after_ms=times[hi]-end))
    return sorted(windows,key=lambda r:-r["gap_ms"])[:8]


def observe(device,folder,seconds):
    root=Path(__file__).resolve().parent.parent/".generated"/"public-compare"
    if (folder.resolve().parent!=root.resolve() or not folder.is_dir() or not re.fullmatch(r"[A-Za-z0-9]+",device)
            or not 5<=seconds<=240): raise ValueError("unexpected_test_scope")
    ip,port,_=read_profile()
    target=ipaddress.IPv4Address(ip).packed[::-1].hex().upper()+":"+format(port,"04X")
    script=SHELL.replace("TARGET",target).replace("SAMPLES",str(seconds*2+2)).replace("DURATION",str(seconds*1000))
    # Noninteractive HDC command. Only validated hex endpoint and bounded
    # decimal sample count are substituted in the fixed filtering program.
    proc=subprocess.run(["hdc","-t",device,"shell",script],stdin=subprocess.DEVNULL,
                        capture_output=True,timeout=seconds*2+15)
    rows=[];zone=None
    for line in proc.stdout.decode("ascii","ignore").splitlines():
        if m:=re.fullmatch(r"zone ([+-])(\d\d)(\d\d)",line.strip()):
            if int(m[2])<=14 and int(m[3])<60: zone=(int(m[2])*60+int(m[3]))*(1 if m[1]=="+" else -1)
        elif m:=re.fullmatch(r"sock (\d{13}) ([1-9]\d{0,3}) ([0-9A-Fa-f]{8}) (\d{1,10})",line.strip()):
            rows.append([int(m[1]),int(m[2]),int(m[3],16),int(m[4])])
        elif m:=re.fullmatch(r"none (\d{13}) \d{1,4}",line.strip()): rows.append([int(m[1]),0,0,0])
    out=summarize(rows)
    with (folder/"phone-socket-numeric.json").open("x",encoding="utf-8") as f:
        json.dump(dict(summary=out,utc_offset_minutes=zone,samples=rows),f)
    print("phone_socket_observation "+json.dumps(out,separators=(",",":")))
    return out


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("device");p.add_argument("folder",type=Path);p.add_argument("--seconds",type=int,default=120)
    a=p.parse_args();observe(a.device,a.folder,a.seconds)
