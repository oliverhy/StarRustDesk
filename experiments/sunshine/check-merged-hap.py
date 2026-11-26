"""Inspect the actual package, without extracting credentials, user data or media."""
import argparse
import json
import re
from pathlib import Path
import zipfile

def require(ok, reason):
    if not ok:
        raise ValueError(reason)

def check(path, preview, expected_broker=None, rx_trial=None, core_rx=None, expected_fec=None,expected_reader=None,expected_phase=None,expected_margin=None):
    entry = Path(__file__).resolve().parents[2] / "entry"
    base = json.loads((entry / "src/main/resources/base/profile/main_pages.json").read_text("utf-8"))["src"]
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        m = json.loads(z.read("module.json"))
        require(m["app"]["bundleName"] == "com.yinhe.starrustdesk", "Unexpected app identity")
        require(not preview or m["app"].get("debug") is True, "Preview is not a debug package")
        page_file = m["module"]["pages"].removeprefix("$profile:")
        pages = json.loads(z.read("resources/base/profile/" + page_file + ".json"))["src"]
        require(pages == base + (["pages/SunshineStreamPage"] if preview else []), "Unexpected page list")
        libs = {p for p in names if p.endswith("/libsunshine_stream_exp.so")}
        assets = {p.split("/")[-1] for p in names if p.startswith("resources/rawfile/sunshine/") and not p.endswith("/")}
        require(libs == ({"libs/" + abi + "/libsunshine_stream_exp.so" for abi in ("arm64-v8a", "x86_64")} if preview else set()), "Unexpected streaming native libraries")
        if expected_broker is not None:
            require(preview, "Broker verification is preview-only")
            expected={expected_broker.encode("ascii")} if expected_broker else set()
            for lib in libs:
                embedded=set(re.findall(rb"(?<![.0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}:23388(?=\x00)",z.read(lib)))
                require(embedded==expected, "Packaged native broker does not match the selected route")
            print("both_packaged_routes_verified=1")
        if rx_trial is not None:
            require(preview and (not rx_trial or expected_broker==""), "Phone receive trial must be LAN-only")
            for lib in libs:
                image=z.read(lib)
                for mark in (b"rx_ledger_ahead packets=",b"rx_ledger_gap_pair ms=",b"rx_ledger_gap_pair_end gaps=",
                             b"lan_loss_idr_retry=1",b"lan_loss_recovered unit_ms="):
                    require((mark in image)==rx_trial,"Packaged native receiver does not match build scope")
            print("both_packaged_receive_modes_verified=1")
        if core_rx is not None:
            require(not core_rx or (preview and rx_trial and expected_broker==""),"Core counters must be LAN-trial only")
            for lib in libs:
                image=z.read(lib)
                for mark in (b"lan_core_end reads=",b"lan_core_head f="):
                    require((mark in image)==core_rx,"Packaged core counters do not match scope")
            print("both_packaged_core_witness_modes_verified=1")
        if expected_fec is not None:
            require(preview and (expected_fec=='debug' or (core_rx and rx_trial and expected_broker=="")),"Unsupported FEC build scope")
            for lib in libs:
                image=z.read(lib)
                # Both audio and video use the first error format. Only the video
                # self-test also checks trailing zero padding; audio must not change.
                require((b"Recovery error at %d: expected 0x00, actual 0x%02x" in image)==(expected_fec=='debug'),
                        "Unexpected video FEC self-test mode")
                require(b"Recovery error at %d: expected 0x%02x, actual 0x%02x" in image,
                        "Audio FEC diagnostic changed in video-only trial")
                require(b"Failed to decrypt video packet!" in image and b"FEC recovery returned corrupt packet" in image,
                        "Missing ordinary encrypted video or FEC checks")
            print("both_packaged_fec_modes_verified="+expected_fec)
        if expected_reader is not None:
            active=expected_reader=='initiated'
            require(expected_reader in ('unchanged','initiated') and preview and (not active or (core_rx and rx_trial and expected_broker=='' and expected_fec=='debug')),"Invalid reader trial combination")
            for lib in libs:
                binary=z.read(lib)
                for marker in (b' reader_qos=',b'OH_QoS_SetThreadQoS',b'OH_QoS_GetThreadQoS',b'OH_QoS_ResetThreadQoS'):
                    require((marker in binary)==active,'Wrong reader QoS in native image')
            print('both_packaged_reader_modes_verified='+expected_reader)
        if expected_phase is not None:
            active=expected_phase=='v1'
            require(preview and (not active or (expected_broker=='' and rx_trial)), "Reader phase must be LAN-trial only")
            for lib in libs:
                require((b" phase_v=1 ph=" in z.read(lib))==active,"Wrong reader phase witness")
            print("both_packaged_reader_phase_verified="+expected_phase)
        if expected_margin is not None:
            active=expected_margin in ('paired','bounded')
            require(preview and (not active or (expected_phase=='v1' and expected_reader=='unchanged' and core_rx and expected_fec=='debug' and expected_broker=='')), "Buffer margin must be an isolated stock-reader LAN trial")
            for lib in libs:
                binary=z.read(lib)
                require((b"rx_ledger_margin state=" in binary)==active,"Wrong burst margin policy")
                require((b"rx_ledger_margin_comparison=1" in binary)==(expected_margin=='paired'),"Wrong controlled comparison arm")
            print("both_packaged_burst_margin_verified="+expected_margin)
        require(assets == ({"sesame-sunshine.html", "ENET-LICENSE.txt", "LUCIDE-LICENSE.txt", "MOONLIGHT-LICENSE.txt"} if preview else set()), "Unexpected streaming assets")
        require(all("libs/" + abi + "/libentry.so" in names for abi in ("arm64-v8a", "x86_64")), "Missing RustDesk library")
    print("verified_artifact=" + ("merged_debug_with_streaming" if preview else "ordinary_without_streaming"))

if __name__ == "__main__":
    p=argparse.ArgumentParser()
    p.add_argument("hap",type=Path)
    p.add_argument("--preview",action="store_true")
    p.add_argument("--expected-broker")
    p.add_argument("--expected-rx",choices=["inline","ahead"])
    p.add_argument("--expected-core-rx",choices=["on","off"])
    p.add_argument("--expected-fec",choices=["debug","runtime"])
    p.add_argument("--expected-reader",choices=["unchanged","initiated"])
    p.add_argument("--expected-phase",choices=["none","v1"])
    p.add_argument("--expected-margin",choices=["off","bounded","paired"])
    args=p.parse_args()
    check(args.hap,args.preview,args.expected_broker,None if args.expected_rx is None else args.expected_rx=="ahead",
          None if args.expected_core_rx is None else args.expected_core_rx=="on",args.expected_fec,args.expected_reader,args.expected_phase,args.expected_margin)
