"""Exercise the shipped ZIP on the authorized Linux test host, as nobody in a temporary HOME.
Never install a unit in a real user's account, start systemd, or open a public UDP socket."""
from contextlib import ExitStack
import base64,shlex,sys,zipfile
from pathlib import Path
import windows_companion as wc
from check_public import TemporaryBroker

SMOKE=r'''
import os,io,sys,zipfile,tempfile,pathlib,subprocess,threading,socket,pwd,stat
from pathlib import Path
archive=sys.stdin.buffer.read(160000)
assert len(archive)<160000
acct=pwd.getpwnam("nobody")
def unprivileged():
    os.setgroups([]); os.setgid(acct.pw_gid); os.setuid(acct.pw_uid)
check=r"""
import os,sys,pathlib,secrets,subprocess,socket,threading,queue
from pathlib import Path
home=Path.home()
code=home/'.local/share/sesame-stream-relay'
sys.path.insert(0,str(code))
import relay_service as relay
import udp_broker as broker
cmd=[sys.executable,'-I',str(code/'relay_service.py'),'provision']
raw=secrets.token_bytes(64)
assert subprocess.run(cmd,input=raw,capture_output=True).returncode==0
assert subprocess.run(cmd,input=secrets.token_bytes(64),capture_output=True).returncode!=0
file=home/'.local/state/sesame-stream-relay/roles.bin'
assert b''.join(relay.load(file))==raw and file.stat().st_mode&0o777==0o600
# In-memory protocol test, no packet is sent to these illustrative endpoints.
# Exercise the exact imported modules from the installed ZIP, without relaxing
# the production requirement for a public, reachability-proven source.
keys=relay.load(file); nonce=[secrets.token_bytes(16) for _ in keys]
endpoints=[('8.8.4.4',41818),('1.1.1.1',41919)]
payload=b'\x04\0\0\0'+secrets.token_bytes(68)
def envelope(role,op,cookie=bytes(16)):
    body=b'SCB1'+bytes([role,broker.RELAY,op,0])+nonce[role]+cookie+bytes(24)
    return body+broker.sign(keys[role],body)
for cap in (1800,8000):
    core=broker.Broker(keys,smooth_downlink=True,wire_kbps=cap)
    for role in (0,1):
        challenge=core.request(envelope(role,broker.HELLO),endpoints[role],30)
        assert challenge[6]==broker.CHALLENGE and challenge[64:]==broker.sign(keys[role],challenge[:64])
        offer=core.request(envelope(role,broker.PROOF,challenge[24:40]),endpoints[role],30)
        if role==1: assert offer[6]==broker.OFFER and offer[64:]==broker.sign(keys[role],offer[:64])
    for role in (0,1): assert core.forward(payload,endpoints[role],31)==endpoints[1-role]
    assert core.bytes_per_second==cap*125 and core.forward(payload,('8.8.4.4',41819),31) is None
    # Exercise the shipped, installed module beyond its original 130s lease.
    end=core.lease['until']; hard=core.lease['hard_stop']
    for t in range(35,146,5): assert core.forward(payload,endpoints[0],t)==endpoints[1]
    assert core.lease['until']==end
    for role in (0,1):
        now=146+role
        challenge=core.request(envelope(role,broker.HELLO),endpoints[role],now)
        assert challenge[6]==broker.CHALLENGE
        core.request(envelope(role,broker.PROOF,challenge[24:40]),endpoints[role],now)
        if not role: assert core.lease['until']==end
    assert core.lease['until']>end and core.lease['hard_stop']==hard
    for t in (151,156,161,166): assert core.forward(payload,endpoints[0],t)==endpoints[1]
q=queue.Queue(); stopped=threading.Event()
t=threading.Thread(target=relay.serve,args=(relay.load(file),1800,'127.0.0.1',0,q.put,stopped)); t.start()
try:
    addr=q.get(timeout=3)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.settimeout(.2); s.sendto(b'not an authenticated peer',addr)
        try: s.recv(128); raise RuntimeError('unexpected reply')
        except socket.timeout: pass
finally: stopped.set(); t.join(3)
assert not t.is_alive() and os.getuid()!=0
assert ' --wire-kbps 1800' in (home/'.config/systemd/user/sesame-stream-relay.service').read_text()
print('packaged_linux_unprivileged_install_ticket_refusal_loopback_cleanup=1')
"""
with tempfile.TemporaryDirectory(prefix='sesame-delivery-smoke-') as d:
    root=Path(d); os.chown(d,acct.pw_uid,acct.pw_gid)
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        assert set(z.namelist())=={'SETUP.md','udp_broker.py','relay_service.py','install-relay.sh','sesame-stream-relay.service.in'}
        for name in z.namelist():
            file=root/name; file.write_bytes(z.read(name)); os.chown(file,acct.pw_uid,acct.pw_gid)
    kw=dict(cwd=d,env={'HOME':d,'PATH':'/usr/bin:/bin'},preexec_fn=unprivileged,timeout=12,capture_output=True)
    assert subprocess.run(['sh','install-relay.sh'],**kw).returncode==0
    res=subprocess.run([sys.executable,'-I','-c',check],**kw)
    if res.returncode: sys.exit(3)
    sys.stdout.buffer.write(res.stdout)
'''

def main(archive):
    data=archive.read_bytes()
    wc.require(len(data)<160000,"unexpected_linux_package_size")
    wc.load_fixture()
    import native_wan as deps
    with ExitStack() as scope:
        b=TemporaryBroker(scope,deps)
        clin,cout,cerr=b.client.exec_command("python3 -I -c "+shlex.quote(SMOKE),timeout=22)
        try:
            clin.write(data); clin.flush(); clin.channel.shutdown_write()
            ok=cout.read(130).strip()==b"packaged_linux_unprivileged_install_ticket_refusal_loopback_cleanup=1"
            wc.require(cout.channel.recv_exit_status()==0 and ok,"linux_archive_smoke_failed")
        finally:
            clin.close(); cout.close(); cerr.close()
        wc.require(b.port_free() and b.services()==b.baseline,"existing_services_changed")
    print("linux_archive_nonroot_temp_install_credential_checks_loopback_stop=verified")

if __name__=="__main__": main(Path(sys.argv[1]))
