"""Assemble explicitly selected, locally verified artifacts without rebuilding or including local identities."""
from pathlib import Path
import argparse,hashlib,re,zipfile

HERE=Path(__file__).resolve().parent
NAMES=("SesameStream-Windows-x64-test.zip","SesameStream-Linux-UDP-test.zip","SesameStream-Harmony-debug.hap")

def digest(p):
    with p.open("rb") as f: return hashlib.file_digest(f,"sha256").hexdigest()

def bundle(folder,include_live=False):
    root=(HERE.parent/".generated/delivery").resolve()
    if folder.parent!=root or not folder.is_dir(): raise ValueError("expected_local_delivery_folder")
    files={n:folder/n for n in NAMES}
    if any(not p.is_file() or p.resolve().parent!=folder for p in files.values()): raise ValueError("missing_or_external_artifact")
    for n in ("SETUP.md","Test-LocalNetwork.ps1","ACCEPTANCE-20261124.md"):
        files[n]=HERE/"deploy"/n
    if include_live:
        report=HERE/"deploy"/"ACCEPTANCE-20261124-LIVE.md"
        pins=re.findall(r"HAP SHA-256：`([A-Fa-f\d]{64})`",report.read_text(encoding="utf-8"))
        if len(pins)!=1 or pins[0].lower()!=digest(files[NAMES[2]]):
            raise ValueError("acceptance_does_not_describe_selected_phone_build")
        files[report.name]=report
    out=folder/"SesameStream-test-kit.zip"; part=out.with_suffix(".part")
    if out.exists() or part.exists(): raise FileExistsError("existing_delivery_not_overwritten")
    sums={name:digest(p) for name,p in files.items()}
    try:
        with zipfile.ZipFile(part,"x",zipfile.ZIP_STORED) as z:
            for name,p in files.items(): z.write(p,name)
            z.writestr("SHA256SUMS.txt","".join(f"{h}  {n}\n" for n,h in sums.items()))
        with zipfile.ZipFile(part) as z:
            if z.testzip() is not None: raise ValueError("delivery_crc_failed")
            for n,h in sums.items():
                with z.open(n) as f:
                    if hashlib.file_digest(f,"sha256").hexdigest()!=h: raise ValueError("delivery_digest_failed")
        part.rename(out)
    finally: part.unlink(missing_ok=True)
    print(f"delivery_bundle={out.name} verified_entries={len(files)} sha256={digest(out)}")

if __name__=="__main__":
    p=argparse.ArgumentParser(); p.add_argument("folder",type=Path)
    p.add_argument("--include-live-acceptance",action="store_true")
    a=p.parse_args();bundle(a.folder.resolve(),a.include_live_acceptance)
