"""The local operator's one authorized test destination, never supplied by the phone."""
import ipaddress
import json
from pathlib import Path

PROFILE = Path(__file__).resolve().parent.parent / ".generated" / "public-test-target.json"
PORT = 23388


def _no_duplicates(pairs):
    cfg=dict(pairs)
    if len(cfg)!=len(pairs):
        raise ValueError
    return cfg


def read_profile(path=PROFILE):
    try:
        if not 0 < path.stat().st_size <= 256:
            raise ValueError
        cfg = json.loads(path.read_text(encoding="utf-8-sig"),object_pairs_hook=_no_duplicates)
        if (type(cfg) is not dict or set(cfg) not in ({"endpoint"},{"endpoint","maxRelayKbps"}) or
                not isinstance(cfg["endpoint"],str)):
            raise ValueError
        cap=cfg.get("maxRelayKbps",1800)
        if type(cap) is not int or cap not in (1800,8000): raise ValueError
        host, sep, port = cfg["endpoint"].partition(":")
        address = ipaddress.IPv4Address(host)
        if (not sep or port != str(PORT) or str(address) != host or not address.is_global or
                address.is_multicast or address.is_reserved):
            raise ValueError
        return str(address), PORT, cap
    except (OSError, ValueError, UnicodeError):
        raise RuntimeError("companion_local_test_target_missing_or_invalid") from None


def endpoint(path=PROFILE):
    return read_profile(path)[:2]


if __name__ == "__main__":
    import sys
    if sys.argv[1:]==["--max-relay"]: print(read_profile()[2])
    elif len(sys.argv)==1: print("{}:{}".format(*endpoint()))
    else: raise SystemExit("invalid_operator_profile_option")
