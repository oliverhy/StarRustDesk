"""Build local Windows/Linux test kits from a narrow allowlist (no HAP, tickets, config, keys or Sunshine binary)."""
import hashlib
import importlib.metadata as meta
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import zipfile

HERE=Path(__file__).resolve().parent
PEER=HERE.parent/"peer"
SOURCE=("windows_companion.py","stream_input.py","display_targets.py","lan_startup_evidence.py","delivery.py","portable_host.py","local_pair.py","udp_broker.py")

def digest(p):
    with p.open("rb") as f: return hashlib.file_digest(f,"sha256").hexdigest()

def archive(folder,path):
    part=path.with_suffix(".part")
    try:
        with zipfile.ZipFile(part,"x",zipfile.ZIP_DEFLATED,compresslevel=4,strict_timestamps=False) as z:
            for p in sorted(folder.rglob("*")):
                if p.is_file(): z.write(p,p.relative_to(folder).as_posix())
        with zipfile.ZipFile(part) as z:
            if z.testzip() is not None: raise ValueError("archive_integrity_failed")
        part.rename(path)
    finally: part.unlink(missing_ok=True)

def build():
    import datetime
    out=HERE.parent/".generated"/"delivery"/datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True,exist_ok=False)
    cargo=Path.home()/".cargo/bin/cargo.exe"
    # A kit build must not replace the executable of a running acceptance stream.
    target=HERE.parent/".generated"/"delivery-rust-target"
    subprocess.run([str(cargo),"build","--target-dir",str(target),"--manifest-path",str(PEER/"Cargo.toml"),"--release","--locked",
                    "--offline","--bin","sesame_wan_peer","--features","companion-soak"],check=True)
    with tempfile.TemporaryDirectory(prefix="sesame-kit-") as temp:
        root=Path(temp); win=root/"Windows"; relay=root/"Linux"; win.mkdir(); relay.mkdir()
        subprocess.run([sys.executable,"-m","PyInstaller","--noconfirm","--log-level","WARN","--onefile","--console",
                        "--exclude-module","tkinter","--add-data",str(HERE/"deploy/Test-LocalNetwork.ps1")+";.",
                        "--name","SesameStreamCompanion","--distpath",str(win),
                        "--workpath",str(root/"work"),"--specpath",str(root),"--paths",str(HERE),
                        str(HERE/"windows_companion.py")],check=True,cwd=root)
        shutil.copy2(target/"release/sesame_wan_peer.exe",win)
        shutil.copy2(HERE/"deploy/Install-CurrentUser.ps1",win)
        shutil.copy2(HERE/"deploy/Test-LocalNetwork.ps1",win)
        for target in (win,relay): shutil.copy2(HERE/"deploy/SETUP.md",target)
        for name in ("udp_broker.py","relay_service.py"): shutil.copy2(HERE/name,relay)
        for name in ("install-relay.sh","sesame-stream-relay.service.in"): shutil.copy2(HERE/"deploy"/name,relay)
        src=win/"source"; src.mkdir()
        for name in SOURCE: shutil.copy2(HERE/name,src)
        shutil.copytree(PEER/"src",src/"peer"/"src")
        for name in ("Cargo.toml","Cargo.lock"): shutil.copy2(PEER/name,src/"peer")
        notices=win/"licenses"; notices.mkdir()
        shutil.copy2(Path(sys.base_prefix)/"LICENSE.txt",notices/"PYTHON-LICENSE.txt")
        for dep in ("cryptography","cffi","pycparser","pyinstaller","pyinstaller-hooks-contrib"):
            dist=meta.distribution(dep)
            for f in dist.files or ():
                if any(s in f.name.lower() for s in ("license","copying","notice")) and not f.name.endswith(".py"):
                    origin=Path(dist.locate_file(f))
                    if origin.is_file(): shutil.copy2(origin,notices/(dep+"-"+f.name))
        crates=list((Path.home()/".cargo/registry/src").iterdir())
        for spec in tomllib.loads((PEER/"Cargo.lock").read_text())["package"]:
            if "source" not in spec: continue
            name=spec["name"]+"-"+spec["version"]
            for cache in crates:
                found=cache/name
                if found.is_dir():
                    for f in found.iterdir():
                        if f.is_file() and f.name.upper().startswith(("LICENSE","COPYING","NOTICE")):
                            shutil.copy2(f,notices/(name+"-"+f.name))
                    break
        manifest={p.name:digest(p) for p in [*win.glob("*.exe"),win/"Test-LocalNetwork.ps1"]}
        (win/"SHA256.json").write_text(json.dumps(manifest,indent=2),"ascii")
        for folder,label in ((win,"Windows-x64"),(relay,"Linux-UDP")):
            path=out/("SesameStream-"+label+"-test.zip"); archive(folder,path)
            print(path.name+" sha256="+digest(path),flush=True)
        print("delivery_directory="+str(out),flush=True)

if __name__=="__main__": build()
