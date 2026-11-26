"""Install the exact separately obtained Sunshine portable archive; never run an installer or import identities."""
import argparse
import ctypes
import hashlib
import ipaddress
import os
from pathlib import Path,PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

from display_targets import geometry
from portable_host import ROOT,EXE_HASH
from windows_companion import Identity,runtime_dir,require,WAN_PEER
from udp_broker import tickets

ARCHIVE_HASH="233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b"

def digest(p):
    with p.open("rb") as f: return hashlib.file_digest(f,"sha256").hexdigest()

def prepare(archive):
    require(archive.is_file() and archive.stat().st_size<250_000_000 and digest(archive)==ARCHIVE_HASH,
            "sunshine_archive_not_verified")
    ROOT.mkdir(exist_ok=True,parents=True)
    dest=ROOT/"portable"
    if dest.exists():
        old=list(dest.rglob("sunshine.exe"))
        require(len(old)==1 and digest(old[0])==EXE_HASH,"existing_capture_not_replaced")
        return
    with tempfile.TemporaryDirectory(dir=ROOT,prefix="unpack-") as temp:
        stage=Path(temp)/"portable"; stage.mkdir()
        with zipfile.ZipFile(archive) as z:
            require(sum(f.file_size for f in z.infolist())<600_000_000,"archive_size_invalid")
            for f in z.infolist():
                key=PurePosixPath(f.filename)
                require(not key.is_absolute() and not any(x in ("..",".") or ":" in x or "\\" in x for x in key.parts)
                        and not stat.S_ISLNK(f.external_attr>>16),"archive_path_invalid")
                out=stage.joinpath(*key.parts)
                if f.is_dir(): out.mkdir(parents=True,exist_ok=True); continue
                out.parent.mkdir(parents=True,exist_ok=True)
                with z.open(f) as src,out.open("xb") as dst: shutil.copyfileobj(src,dst)
        exe=list(stage.rglob("sunshine.exe"))
        require(len(exe)==1 and digest(exe[0])==EXE_HASH,"portable_sunshine_not_verified")
        stage.rename(dest)

def provision(login,state,replace=False):
    m=re.fullmatch(r"([a-z_][a-z0-9_-]{0,30})@([0-9.]+)",login)
    require(m is not None,"expected_operator_at_ipv4")
    ip=ipaddress.IPv4Address(m[2])
    require(ip.is_global and not ip.is_multicast and str(ip)==m[2],"expected_public_ipv4")
    require((state/"protected-companion.dat").is_file(),"pair_first")
    identity=Identity(state); require(any(identity.device_hash),"pair_first")
    ssh=Path(os.environ["SystemRoot"])/"System32/OpenSSH/ssh.exe"
    cmd='python3 -I "$HOME/.local/share/sesame-stream-relay/relay_service.py" provision'+(' --replace' if replace else '')
    # No shell on Windows, no secrets in argv/output, no password automation,
    # no implicit host key trust and no use of the development VPS credential.
    result=subprocess.run([str(ssh),"-T","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes",
                           "-o","ClearAllForwardings=yes","-o","ForwardAgent=no","-o","ConnectTimeout=8",
                           "-l",m[1],str(ip),cmd],input=b"".join(tickets(identity.device_hash)),
                          stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20)
    require(result.returncode==0 and result.stdout.strip()==b"relay_tickets_installed","relay_ticket_install_failed")

def self_check():
    exe=list((ROOT/"portable").rglob("sunshine.exe"))
    print(f"windows_displays={len(geometry())} peer_ready={int(WAN_PEER.is_file())} capture_ready={int(len(exe)==1 and digest(exe[0])==EXE_HASH)}",flush=True)
