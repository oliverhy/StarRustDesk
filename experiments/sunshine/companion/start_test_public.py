"""Explicitly start the local helper and a temporary, pre-authorized test broker.

This launcher never enumerates, opens, configures, or communicates with a USB
device. A phone must have previously paired with this Windows user.
"""
import argparse
from contextlib import ExitStack
import re
import time

import windows_companion as wc
from check_public import TemporaryBroker


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--listen-ip")
    p.add_argument("--allow-input",action="store_true")
    wc.add_output_options(p)
    args=p.parse_args()
    state=wc.runtime_dir()/"windows-companion-state"
    wc.require((state/"protected-companion.dat").is_file(),"companion_saved_pairing_missing")
    root=wc.Identity(state).device_hash
    wc.require(any(root),"companion_saved_pairing_missing")
    address=wc.choose_local(args.listen_ip)
    wc.require(wc.private(address),"companion_requires_private_ipv4")
    wc.load_fixture()
    import native_wan as authorized
    with ExitStack() as scope:
        backend=wc.PhysicalBackend(scope,output_profile=args.output_profile)
        relay=TemporaryBroker(scope,authorized)
        high=relay.allowed_cap==8000
        relay.start(scope,root,smooth=True,high=high)
        del root
        server=wc.Companion(address,47837,state,backend,broker=relay.endpoint,allow_input=args.allow_input,
                            fresh_recovery=True,relay_spacing=True,high_relay=high,
                            frame_spread=high and args.output_profile=="1080p60")
        scope.callback(server.close)
        server.start()
        wc.event("公网测试助手已就绪。请在已配对手机上打开游戏串流，无需 USB。")
        wc.event("仅此授权设备可用，预计九分钟后关闭，也可随时用 Ctrl+C 结束。")
        expire=time.monotonic()+540
        try:
            while time.monotonic()<expire and not relay.channel.exit_status_ready():
                time.sleep(.35)
        except KeyboardInterrupt:
            pass


if __name__=="__main__":
    try: main()
    except Exception as exc:
        reason=str(exc)
        wc.event(reason if re.fullmatch(r"companion_[a-z_]{4,75}",reason) else "companion_public_launcher_failed")
        raise SystemExit(4) from None
