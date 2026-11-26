"""One opt-in 26 s, view-only, encrypted real-primary cellular relay trial.

No change to the saved broker profile. A deliberately silent direct-test peer
exercises the App's ordinary direct-first, then authenticated relay path.
"""
import argparse
from contextlib import ExitStack
from datetime import datetime
import json
from pathlib import Path
import re
import secrets

import check_device as ui
from check_public import TemporaryBroker
from long_metrics import Recorder
import windows_companion as wc

def run(device):
    win=wc.load_fixture()
    import native_wan as deps
    phone=win.d.CoverageApp()
    wc.require(re.fullmatch(r'[A-Za-z0-9_-]{7,64}',device) and phone.hdc[-2:]==['-t',device],'wrong_usb_device')
    before=phone.debug_targets(); phone.idle_preflight(); ui.no_usb_forward(phone)
    interfaces=phone.shell('ifconfig')
    wc.require(re.search(r'^wlan\d+\b',interfaces,re.M) and not re.search(
        r'^(?:tun|tap|wg|vpn|ppp|ipsec|xfrm)[\w.-]*\b',interfaces,re.M|re.I),'active_vpn_or_unknown_radio')
    pc,_=win.lan.wifi_pair(phone); state=wc.runtime_dir()/'windows-companion-state'
    wc.require((state/'protected-companion.dat').is_file(),'saved_pairing_missing')
    wc.WAN_PEER=wc.HERE.parent/'.generated/delivery-rust-target/release/sesame_wan_peer.exe'
    wc.require(wc.WAN_PEER.is_file(),'updated_peer_missing')
    folder=wc.HERE.parent/'.generated/public-compare'/(datetime.now().strftime('%Y%m%d-%H%M%S')+'-single-20m-'+secrets.token_hex(2))
    folder.mkdir(parents=True); wc.event('cellular_standard_run='+folder.name)
    rec=Recorder('single-cellular-real-primary-20m',folder,60)
    facts=dict(requested_kbps=20000,wire_cap_kbps=30000,lease_seconds=26,
               direct_response_suppressed_in_fixture=True,video_confirmed=False)
    server=host=relay=radio=None
    try:
        with ExitStack() as scope:
            host=wc.PhysicalBackend(scope,public_profile='1080p60')
            wc.require(host.desktop_size[0]>=1920 and host.desktop_size[1]>=1080,'physical_primary_below_full_hd')
            relay=TemporaryBroker(scope,deps)
            radio=deps.prepare_radio(scope)
            ui.open_page(phone,win.d)
            wc.require(ui.marker(phone,'companion_saved_host_loaded=1') and ui.has(phone,
                lambda r:r.get('type','').lower() in ('web','webview'),25),'saved_pairing_missing')
            x,y=phone.button_spot()
            salt=secrets.token_bytes(16)
            relay.start(scope,wc.Identity(state).device_hash,salt,smooth=True,standard30=True)
            server=wc.Companion(pc,47837,state,host,seconds=26,broker=relay.endpoint,silent_direct=True,
                trace_file=folder/'host-numeric.ssmeta',trace_salt=salt,standard_wan=True,
                fresh_recovery=True,relay_spacing=True)
            scope.callback(server.close)
            wc.require(not server.allow_input and not server.sustained,'not_a_short_view_only_session')
            server.start(); phone.tap_start(x,y)  # exactly once; never retry on metered data
            route=ui.watch_stream(phone,win,server,26,'relay',recorder=rec)
            relay.check_flow(route)
            wc.require(host.profile_replies==[(1920,1080,60,20000)] and
                any((1920,1080) in e.get('presented_pictures',[]) for e in rec.epochs),'standard_picture_unconfirmed')
            facts.update(video_confirmed=True,playback=rec.summary(route,26))
    except Exception as exc:
        why=str(exc); facts['stopped']=why if re.fullmatch(r'[a-z_0-9]{3,90}',why) else type(exc).__name__
        raise
    finally:
        try:
            if server:
                facts['connection_evidence']=[e for e in server.events if re.fullmatch(
                    r'companion_(?:host_(?:direct|relay)_authenticated=1|host_bandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+|relay_capacity_plan wire_kbps=\d+ video_cap_kbps=\d+|standard_video_budget_insufficient=1|setup_served=1)',e)]
            if phone.pid:
                raw=phone.shell('hilog -P '+phone.pid+' -T SesameSecureClient,SesameWanProbe -z 220')
                rec.observe(raw)
                facts['phone_evidence']=sorted(set(m[0] for line in raw.splitlines() if (m:=re.search(
                    r'\b(?:companion_wan_(?:direct_attempt|direct_no_reply|relay_authenticated|tls_and_pair_verified)=1|companion_cellular_binding_verified=1|bandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+|secure_result=[a-z_]+|companion_route_result=[a-z_]+)$',line))))
            if relay:
                facts['broker_wire_bytes_both_directions']=relay.trial_bytes
                facts['listener_gone_services_unchanged']=getattr(relay,'cleanup_verified',False)
                if relay.shape is not None: facts['broker_packet_counts']=relay.shape
                if facts['video_confirmed'] and relay.trace:
                    facts['missing_frame_attribution']=rec.attribute('relay',folder/'host-numeric.ssmeta',
                        relay.trace,relay.trace_truncated)
            facts['wifi_original_restored']=bool(radio and radio.is_set())
            facts['host_setups']=host.profile_replies if host else []
            rec.save_phone()
            ui.no_usb_forward(phone); facts['other_apps_unchanged']=phone.debug_targets()==before
            (folder/'result.json').write_text(json.dumps(facts,indent=2),'utf-8')
            wc.event('cellular_standard_result='+json.dumps(facts,separators=(',',':')))
        finally:
            phone.shell('aa force-stop '+win.d.APP); phone.shell('aa start -a EntryAbility -b '+win.d.APP)
    wc.require(facts.get('listener_gone_services_unchanged') and facts['wifi_original_restored'] and
        facts['other_apps_unchanged'] and isinstance(relay.trial_bytes,int) and relay.trial_bytes<=115_000_000,
        'trial_cleanup_or_budget_unverified')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--device',required=True)
    p.add_argument('--one-short-relay-trial',action='store_true',required=True)
    try: run(p.parse_args().device)
    except Exception as exc:
        msg=str(exc); wc.event('short_trial_failed='+(msg if re.fullmatch('[a-z_0-9]{3,90}',msg) else type(exc).__name__))
        raise SystemExit(2) from None
