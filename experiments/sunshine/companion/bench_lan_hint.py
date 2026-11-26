"""One-use LAN address only. Never export pairing data; the pinned peer stays unchanged."""
from ipaddress import IPv4Address, IPv4Network
import subprocess

from windows_companion import require

PATH='./data/storage/el2/base/files/.sesame-bench-lan-v1'
RFC1918=tuple(map(IPv4Network,('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')))

def validate(pc, mobile):
    a,b=IPv4Address(pc),IPv4Address(mobile)
    require(a!=b and a in IPv4Network((b,24),strict=False) and any(a in n and b in n for n in RFC1918),
            'candidate_not_private_local')
    return str(a)

def stage(scope,phone,app,pc,mobile):
    ip=validate(pc,mobile)
    require(app=='com.yinhe.starrustdesk','not_the_debug_app')
    def cmd(s):
        out=subprocess.run(phone.hdc+['shell','-b',app,s],capture_output=True,text=True,timeout=8)
        return out.stdout.strip() if out.returncode==0 else ''
    require(cmd(f'test ! -e {PATH} && test ! -L {PATH} && echo free')=='free','candidate_slot_not_empty')
    def clear():
        require(cmd(f'if test ! -e {PATH}; then echo clean; elif test ! -L {PATH} && test "$(cat {PATH})" = {ip}; then rm -- {PATH} && echo clean; fi')=='clean',
                'candidate_cleanup_not_verified')
    # The scoped HDC mount maps owner/group to the bundle; chmod is not supported.
    require(cmd(f"(set -C; umask 077; printf %s {ip} > {PATH}) && echo staged")=='staged',
            'candidate_handoff_failed')
    scope.callback(clear)
    require(cmd(f'test "$(cat {PATH})" = {ip} && echo exact')=='exact','candidate_handoff_readback_failed')
    return lambda: cmd(f'test ! -e {PATH} && echo consumed')=='consumed'
