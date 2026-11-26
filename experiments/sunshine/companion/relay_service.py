"""Single-pair, non-root Linux broker. Provision binary role tickets only over authenticated SSH stdin."""
import argparse
from pathlib import Path
import os
import select
import signal
import socket
import stat
import sys
import tempfile
import time

sys.path.insert(0,str(Path(__file__).resolve().parent))  # also under python -I
from udp_broker import Broker,PORT,receive_one

def validate(data):
    if len(data)!=64 or not any(data[:32]) or not any(data[32:]) or data[:32]==data[32:]:
        raise ValueError("invalid_tickets")
    return data[:32],data[32:]

def store(folder,data,replace=False):
    validate(data); folder.mkdir(mode=0o700,parents=True,exist_ok=True)
    meta=folder.lstat()
    if not stat.S_ISDIR(meta.st_mode) or meta.st_uid!=os.getuid() or meta.st_mode&0o077: raise ValueError("private_directory_required")
    dest=folder/"roles.bin"
    with tempfile.NamedTemporaryFile(dir=folder,delete=False) as tmp:
        path=Path(tmp.name)
        try:
            tmp.write(data); tmp.flush(); os.fsync(tmp.fileno())
            if replace: os.replace(path,dest)
            else: os.link(path,dest)  # atomic, never replace an existing authorization
        finally: path.unlink(missing_ok=True)

def load(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,"rb") as fp:
        meta=os.fstat(fd)
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid!=os.getuid() or meta.st_mode&0o077: raise ValueError("private_tickets_required")
        return validate(fp.read(65))

def serve(keys,cap,address="0.0.0.0",port=PORT,ready=None,stop=None):
    b=Broker(keys,smooth_downlink=True,wire_kbps=cap)
    running=True
    def end(*_):
        nonlocal running
        running=False
    if stop is None:
        signal.signal(signal.SIGTERM,end); signal.signal(signal.SIGINT,end)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.bind((address,port)); s.setblocking(False)
        if ready: ready(s.getsockname())
        while running and not (stop and stop.is_set()):
            wait=b.flush_downlink(time.monotonic(),s.sendto)
            if select.select([s],[],[],.25 if wait is None else max(.00005,wait))[0]:
                try: receive_one(s,b,float("inf"))
                except (socket.timeout,BlockingIOError): pass
        b.discard_pending()

def main():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="action",required=True)
    sub.add_parser("provision").add_argument("--replace",action="store_true")
    sub.add_parser("serve").add_argument("--wire-kbps",type=int,choices=(1800,8000),default=1800)
    a=p.parse_args(); directory=Path.home()/".local/state/sesame-stream-relay"
    if a.action=="provision":
        store(directory,sys.stdin.buffer.read(65),a.replace); print("relay_tickets_installed",flush=True)
    else: serve(load(directory/"roles.bin"),a.wire_kbps)

if __name__=="__main__":
    try: main()
    except (OSError,ValueError): sys.exit("relay_unavailable_check_port_or_private_ticket")
