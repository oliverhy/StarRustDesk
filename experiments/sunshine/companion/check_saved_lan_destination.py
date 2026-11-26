"""Is the saved debug client's TCP destination our selected LAN interface? No pairing or media."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import re
import socket
import subprocess
import sys

import check_device as ui
import windows_companion as wc
from wifi_uplink import windows_lan_medium


def main(device):
    f=wc.load_fixture();p=f.d.CoverageApp()
    wc.require(p.hdc[-2:]==['-t',device],'device_mismatch')
    before=p.debug_targets();p.idle_preflight();ui.no_usb_forward(p)
    local,mobile=f.lan.wifi_pair(p)
    state=wc.runtime_dir()/'windows-companion-state'
    wc.require((state/'protected-companion.dat').is_file(),'saved_host_identity_missing')
    s=wc.Companion(local,47837,state,None,allowed_phone=mobile)
    try:
        wc.require(not s.invitation() and not s.allow_input and not s.wan,'unexpected_enrollment')
        s.start();ui.open_page(p,f.d)
        wc.require(ui.marker(p,'companion_saved_host_loaded=1'),'no_saved_debug_pair')
        uid=re.search(r'(?m)^Uid:\s+(\d+)\s',p.shell('cat /proc/'+p.pid+'/status'))
        wc.require(uid is not None,'uid_unknown')
        dest=socket.inet_aton(local)[::-1].hex().upper()+':'+format(s.port,'04X')
        # Filter on device: never collect other apps' socket tables or destination addresses.
        filt=("awk -v u="+uid[1]+" -v d="+dest+" '$8==u && toupper($3) ~ /:"+
              format(s.port,'04X')+"$/ {if(toupper($3)==d)print 1;else print 2}' /proc/net/tcp")
        cmd='i=0; while [ "$i" -lt 52 ]; do '+filt+'; i=$((i+1)); sleep .10; done'
        x,y=p.button_spot()
        with ThreadPoolExecutor(max_workers=1) as pool:
            job=pool.submit(subprocess.run,p.hdc+['shell',cmd],capture_output=True,timeout=14)
            p.tap_start(x,y)
            raw=job.result().stdout.splitlines()
        wc.event('saved_lan_destination medium='+windows_lan_medium(local,mobile)+' matched='+str(int(b'1' in raw))+
                 ' other='+str(int(b'2' in raw))+' listener_reached='+str(int('companion_control_rejected=1' in s.events)))
    finally:
        s.close();p.shell('aa force-stop '+f.d.APP);p.shell('aa start -a EntryAbility -b '+f.d.APP)
        wc.require(before==p.debug_targets(),'other_apps_changed')


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--device',required=True)
    try:main(ap.parse_args().device)
    except Exception as e:
        wc.event('destination_check_failed='+ (str(e) if isinstance(e,RuntimeError) and re.fullmatch('[a-z0-9_]{3,80}',str(e)) else type(e).__name__));sys.exit(1)
