"""One dedicated local test window, and LAN before either cellular route."""
import argparse
from contextlib import ExitStack
import re
import subprocess
import sys

import check_device
import check_public
import input_ui_checks
import windows_companion as wc


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--lan-only",action="store_true")
    p.add_argument("--public-only",action="store_true")
    p.add_argument("--relay-only",action="store_true")
    p.add_argument("--relay-release-only",action="store_true",
                   help="Verify the held-key interruption first in a real relay session")
    p.add_argument("--relay-observe",action="store_true",
                   help="After touch/IME keep an idle input lane active for 45s before the release test")
    a=p.parse_args()
    wc.require(sum((a.lan_only,a.public_only,a.relay_only,a.relay_release_only,a.relay_observe))<=1,"input_test_bad_route_scope")
    with ExitStack() as scope:
        fixture=input_ui_checks.Fixture(scope)
        fixture.release_only=a.relay_release_only
        fixture.idle_seconds=45 if a.relay_observe else 0
        input_ui_checks.use_shared_fixture(fixture)
        scope.callback(input_ui_checks.use_shared_fixture,None)
        if not (a.public_only or a.relay_only or a.relay_release_only or a.relay_observe):
            sys.argv=["check_device","--use-saved","--check-input"]
            check_device.main()
            wc.event("companion_input_route_verified=lan")
        if not a.lan_only:
            for route in (("forced-relay",) if a.relay_only or a.relay_release_only or a.relay_observe else ("natural","forced-relay")):
                sys.argv=["check_public","--case",route,"--seconds","120" if a.relay_observe else "50","--check-input"]
                if a.relay_observe: sys.argv+=["--profile","540p30"]
                check_public.main()
                wc.event(("companion_modifier_release_route_verified=" if a.relay_release_only else
                          "companion_input_route_verified=")+route)


if __name__=="__main__":
    try: main()
    except (RuntimeError,OSError,ValueError,subprocess.SubprocessError) as exc:
        reason=str(exc)
        wc.event("companion_input_route_failed="+(reason if re.fullmatch(r"[a-z_]{4,110}",reason) else type(exc).__name__))
        raise SystemExit(4)
