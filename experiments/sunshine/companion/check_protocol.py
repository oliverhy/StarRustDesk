"""Local security/retention regressions; no video and no network writes."""
import hashlib
import io
import os
from pathlib import Path
import secrets
import struct
import tempfile
import threading
from types import SimpleNamespace
import unittest

from cryptography.hazmat.primitives import hashes
from windows_companion import Companion, Identity, Lease, PhysicalBackend, remove_test_runtime, same_lan, smooth_host_config
from unittest.mock import MagicMock, Mock, patch


class Request:
    def __init__(self, data):
        self.data=io.BytesIO(data)
        self.reply=bytearray()
    def recv(self,n):
        return self.data.read(n)
    def sendall(self,data):
        self.reply.extend(data)


class CompanionContract(unittest.TestCase):
    def test_capabilities_preserve_legacy_versions_keys_and_screen_catalog(self):
        from windows_companion import session_capabilities
        packet=struct.pack("!4s6I16s16s32s32s",b"SCH2",960,540,30,1400,50,1024,b"a"*16,b"b"*16,b"7.1",b"3.0")
        for live,audio in ((True,False),(False,True),(True,True)):
            new=session_capabilities(packet,live,audio)
            self.assertEqual((new[:84],new[91:]),(packet[:84],packet[91:]))
            self.assertEqual(new[84:91],b"SSC1"+bytes([int(live)|int(audio)<<1,0,0]))
        self.assertEqual(session_capabilities(packet,False,False),packet)
        new=session_capabilities(packet,False,False,exact_video=True)
        self.assertEqual(new[84:91],b"SSC1"+bytes([0,20,1]))
        self.assertEqual((new[:84],new[91:]),(packet[:84],packet[91:]))
        with self.assertRaises(RuntimeError):session_capabilities(packet[:60]+b"A"*32+packet[92:],True,True)
    def test_network_hint_is_interface_scoped_and_requires_both_programs(self):
        from windows_companion import network_summary
        s="interface=6 profile=Public\r\nprogram=SesameStreamCompanion.exe matching_inbound_block=2 matching_inbound_allow=1\r\nprogram=sesame_wan_peer.exe matching_inbound_block=0 matching_inbound_allow=0\r\n"
        self.assertEqual(network_summary(s),("Public",("助手",)))
        self.assertEqual(network_summary(s.replace("Public","Private").replace("block=2","block=0")),("Private",()))
        self.assertEqual(network_summary(s+"interface=7 profile=Private\n"),("unknown",()))
        self.assertEqual(network_summary(s.partition("program=sesame_wan_peer")[0]),("unknown",()))

    def test_distributed_high_cap_is_opt_in_and_does_not_silence_direct(self):
        from contextlib import redirect_stdout
        import windows_companion as wc
        for extra,high in (([],False),(["--broker","1.1.1.1:23388"],False),
                 (["--broker","1.1.1.1:23388","--relay-wire-kbps","8000"],True)):
            with patch("sys.argv",["helper","--listen-ip","192.168.1.2",*extra]), \
                 patch.object(wc,"PhysicalBackend"),patch.object(wc,"Companion") as factory,redirect_stdout(io.StringIO()):
                svc=factory.return_value; svc.invitation.return_value=None; svc.stop_requested.wait.return_value=True
                wc.main()
                cfg=factory.call_args.kwargs
                self.assertEqual(cfg["high_relay"],high); self.assertEqual(cfg["frame_spread"],high)
                self.assertFalse(cfg.get("silent_direct",False)); self.assertFalse(cfg["allow_input"])

    def test_lan_uses_this_build_lease_pipe_and_only_explicit_diagnostics(self):
        backend=object.__new__(PhysicalBackend)
        fixture=SimpleNamespace(PEER='unrelated-fixture-peer',keypair=lambda:('11'*32,'22'*32))
        backend.win=SimpleNamespace(lan=fixture)
        own=Path(__file__).resolve()
        with patch('windows_companion.WAN_PEER',own),patch('windows_companion.socket.socket') as make_socket, \
             patch('windows_companion.subprocess.Popen') as spawn,patch.dict(os.environ,{
                 'SESAME_COMPANION_SOAK_TRACE':'unrelated','SESAME_COMPANION_TX_GUARD':'1','SESAME_COMPANION_LAN_READY_TRIAL':'1',
                 'SESAME_PHYSICAL_QUALITY_TRIAL':'1','SESAME_COMPANION_LAN_SOURCE_RX':'stock'}):
            s=MagicMock(); s.getsockname.return_value=('127.0.0.1',55000)
            make_socket.return_value.__enter__.return_value=s
            for trace in (None,own.with_suffix('.ssmeta')):
                spawn.return_value.stdin=io.BytesIO()
                proc,port,pub=backend.open_peer('127.0.0.1','127.0.0.1:56000',bytes([3])*32,11200,
                                                trace,b'0'*16 if trace else None)
                argv,kw=spawn.call_args
                self.assertEqual(argv[0],[str(own),'--lan','--physical','--managed'])
                self.assertNotIn('SESAME_COMPANION_TX_GUARD',kw['env'])
                self.assertNotIn('SESAME_COMPANION_LAN_READY_TRIAL',kw['env'])
                self.assertNotIn('SESAME_COMPANION_LAN_SOURCE_RX',kw['env'])
                self.assertNotIn('SESAME_PHYSICAL_QUALITY_TRIAL',kw['env'])
                self.assertEqual(kw['env'].get('SESAME_COMPANION_SOAK_TRACE'),str(trace) if trace else None)
                self.assertEqual(kw['env']['SESAME_COMPANION_MANAGED_LAN'],'1')
                self.assertFalse(proc.stdin.closed)
                self.assertEqual(len(proc.stdin.getvalue().splitlines()),5)
                self.assertEqual((port,pub),(55000,bytes([0x22])*32))
            with self.assertRaises(RuntimeError):
                backend.open_peer('127.0.0.1','127.0.0.1:56000',bytes([3])*32,11200,Path('invalid'),None)
            self.assertEqual(spawn.call_count,2)
            backend.lan_ready_trial=True
            for rate,file in ((34000,None),(11200,own.with_suffix('.ssmeta'))):
                with self.assertRaises(RuntimeError):backend.open_peer('127.0.0.1','127.0.0.1:56000',bytes([3])*32,rate,file,b'0'*16)
            spawn.return_value.stdin=io.BytesIO()
            backend.open_peer('127.0.0.1','127.0.0.1:56000',bytes([3])*32,34000,own.with_suffix('.ssmeta'),b'0'*16)
            self.assertEqual(spawn.call_args.kwargs['env']['SESAME_COMPANION_LAN_READY_TRIAL'],'1')
            for mode in ('stock','bounded','auto'):
                backend.lan_source_rx=mode
                with self.assertRaisesRegex(RuntimeError,'source_rx_requires_verified_lan'):
                    backend.open_peer('127.0.0.1','127.0.0.1:56000',bytes([3])*32,34100,own.with_suffix('.ssmeta'),b'0'*16)
                backend.open_peer('127.0.0.1','127.0.0.1:56000',bytes([3])*32,34000,own.with_suffix('.ssmeta'),b'0'*16)
                self.assertEqual(spawn.call_args.kwargs['env']['SESAME_COMPANION_LAN_SOURCE_RX'],mode)

    def test_only_retry_sharing_errors_on_this_owned_runtime(self):
        runtime=Mock()
        runtime.cleanup.side_effect=[PermissionError(),None]
        with patch("windows_companion.time.sleep"): remove_test_runtime(runtime)
        self.assertEqual(runtime.cleanup.call_count,2)
        runtime.cleanup.side_effect=PermissionError()
        with patch("windows_companion.time.sleep"),self.assertRaises(PermissionError): remove_test_runtime(runtime)
        self.assertEqual(runtime.cleanup.call_count,10)

    def test_smooth_360_keeps_limits_pinning_capture_and_forced_encryption(self):
        conf=smooth_host_config("capture = ddx\nlan_encryption_mode = 2\nwan_encryption_mode = 2\n"
                                "bind_address = 127.0.0.1\nkeyboard = disabled\n", "wgc")
        for field in ("capture = wgc", "max_bitrate = 650", "minimum_fps_target = 1",
                      "lan_encryption_mode = 2", "wan_encryption_mode = 2", "bind_address = 127.0.0.1",
                      "keyboard = disabled"):
            self.assertIn(field+"\n",conf)
        backend=object.__new__(PhysicalBackend)
        backend.public_profile,backend.smooth_capture="360p60","wgc"
        backend.peak_shave=False
        backend.host=SimpleNamespace(mark_start=lambda: None)
        backend.pair=None
        backend.profile_replies,backend.packet_sizes=[],[]
        def media_args(pair, args, rate):
            return struct.pack("!4s6I",b"SCH1",args.width,args.height,args.fps,args.kbps,args.seconds,1024)+bytes(96)
        backend.win=SimpleNamespace(f=SimpleNamespace(media_args=media_args))
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(1400,180)),
                         (b"SCH2",640,360,60,650,180,768))
        with self.assertRaises(RuntimeError): backend.configuration(1400,1400,180)
        backend.peak_shave=True
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(1400,180)),
                         (b"SPK2",640,360,60,500,180,768))
        with self.assertRaises(RuntimeError): backend.rebuild(1400,650,180)
        backend.peak_shave=False
        backend.public_profile,backend.smooth_capture="540p30",None
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(1400,180)),
                         (b"SCH2",960,540,30,1400,180,1024))
        with self.assertRaises(RuntimeError): backend.configuration(3000,3000,180)
        backend.high_relay=True
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(4200,180)),
                         (b"SCH2",960,540,30,4200,180,1024))
        with self.assertRaises(RuntimeError): backend.configuration(6401,6401,180)
        backend.public_profile="1080p30"
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(5800,120,True))[1:5],(1920,1080,30,1850))
        self.assertEqual(struct.unpack_from("!4s6I",backend.configuration(5800,1800,120,True))[1:5],(1920,1080,30,1800))
        backend.high_relay=False
        with self.assertRaises(RuntimeError): backend.launch(5800,120,True)
        backend.public_profile=None
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(5900,120,True))[1:5],(960,540,30,5900))
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(8000,120,False))[1:5],(1920,1080,60,8000))
        backend.output_profile="1080p30"
        for wan,rate in ((True,1400),(False,8000)):
            self.assertEqual(struct.unpack_from("!4s6I",backend.launch(rate,120,wan))[1:5],(1920,1080,30,800 if wan else rate))
        for benchmark in (False,True):
            backend.public_profile,backend.output_profile=("1080p60",None) if benchmark else (None,"1080p60")
            backend.high_relay=True
            for grant,expected,size in ((1400,500,640),(1450,500,768),(2850,950,768),(5650,1800,1024),(5800,1850,1024)):
                self.assertEqual(struct.unpack_from("!4s6I",backend.launch(grant,120,True)),
                    (b"SCH2",1920,1080,60,expected,120,size))
                self.assertEqual(struct.unpack_from("!4s6I",backend.rebuild(grant,500,120,True)),
                    (b"SCH2",1920,1080,60,500,120,size))
        backend.public_profile=None
        self.assertEqual(struct.unpack_from("!4s6I",backend.launch(8000,120,False)),(b"SCH2",1920,1080,60,8000,120,1024))

    def test_private_same_subnet_only(self):
        self.assertTrue(same_lan("192.168.1.3","192.168.1.4"))
        self.assertFalse(same_lan("192.168.1.3","192.168.2.4"))
        self.assertFalse(same_lan("127.0.0.1","127.0.0.2"))
        self.assertFalse(same_lan("203.0.113.3","203.0.113.4"))
        self.assertFalse(same_lan("10.10.10.1","10.10.10.255"))

    def test_windows_identity_and_invite_replay(self):
        with tempfile.TemporaryDirectory(prefix="companion-contract-") as directory:
            root=Path(directory)
            server=object.__new__(Companion)
            server.identity=Identity(root)
            server.mutex=threading.Lock()
            server.wan=None
            server.invite=secrets.token_bytes(32)
            server.invite_until=float("inf")
            server.lease=None
            server.note=lambda _: None
            correct=server.invite
            wrong=Request(secrets.token_bytes(32))
            server.enroll(wrong)
            self.assertEqual(wrong.reply,b"NOPE")
            self.assertEqual(server.identity.device_hash,bytes(32))
            response=Request(correct)
            server.enroll(response)
            self.assertEqual(response.reply[:4],b"OKP1")
            token=bytes(response.reply[4:])
            self.assertEqual(len(token),32)
            self.assertNotIn(token,server.identity.file.read_bytes())
            self.assertNotIn(hashlib.sha256(token).digest(),server.identity.file.read_bytes())
            saved=Identity(root)
            self.assertEqual(saved.cert.fingerprint(hashes.SHA256()),
                             server.identity.cert.fingerprint(hashes.SHA256()))
            self.assertEqual(saved.device_hash,hashlib.sha256(token).digest())
            replay=Request(correct)
            server.enroll(replay)
            self.assertEqual(replay.reply,b"NOPE")
            saved.context()

    def test_first_pair_then_reconnect_over_pinned_tls_without_changing_saved_identity(self):
        import socket,ssl,time
        from cryptography.hazmat.primitives.serialization import Encoding
        from windows_companion import read_exact
        with tempfile.TemporaryDirectory(prefix="sesame-ephemeral-pair-") as tmp:
            s=object.__new__(Companion)
            s.identity=Identity(Path(tmp));s.invite=secrets.token_bytes(32);s.invite_until=time.monotonic()+5
            s.lease=s.wan=None;s.mutex=threading.Lock();s.note=lambda _:None
            s.menu_fixture=False;s.trace_file=s.trace_salt=None;s.ip="192.168.1.1";s.backend=Mock()
            peer=Mock();peer.stdout=io.BytesIO(b"stage=host_media_lan_authenticated\n");peer.stdin=io.BytesIO()
            s.backend.open_peer.return_value=(peer,12345,b"p"*32)
            pem=s.identity.cert.public_bytes(Encoding.PEM).decode()
            pin=s.identity.cert.fingerprint(hashes.SHA256())
            def request(tag,body,size):
                service=s.identity.context()
                client=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);client.check_hostname=False
                client.minimum_version=ssl.TLSVersion.TLSv1_2;client.load_verify_locations(cadata=pem)
                l,r=socket.socketpair();l.settimeout(4);r.settimeout(4)
                errors=[]
                def serve():
                    try:
                        with service.wrap_socket(l,server_side=True) as channel:
                            op=read_exact(channel,4)
                            if op==b"PAI1":s.enroll(channel)
                            elif op==b"CTL1":s.control(channel,"192.168.1.9")
                    except (EOFError,ssl.SSLEOFError):pass # client stops before desktop capture
                    except Exception as exc:errors.append(type(exc).__name__)
                worker=threading.Thread(target=serve);worker.start()
                try:
                    with client.wrap_socket(r) as sock:
                        self.assertEqual(hashlib.sha256(sock.getpeercert(True)).digest(),pin)
                        sock.sendall(tag+body)
                        answer=read_exact(sock,size)
                finally:
                    r.close();worker.join(5);l.close()
                self.assertFalse(worker.is_alive());self.assertEqual(errors,[])
                return answer
            invitation=s.invite
            paired=request(b"PAI1",invitation,36);self.assertEqual(paired[:4],b"OKP1")
            self.assertEqual(request(b"PAI1",invitation,4),b"NOPE")
            s.identity=Identity(Path(tmp))
            rest=b"q"*32+struct.pack("!HI",20000,2000)
            self.assertEqual(request(b"CTL1",bytes(32)+rest,4),b"NOPE")
            self.assertEqual(request(b"CTL1",paired[4:]+rest,70)[:4],b"OKC1")
            s.backend.launch.assert_not_called()

    def test_rtsp_not_a_generic_proxy(self):
        server=object.__new__(Companion)
        server.mutex=threading.Lock()
        lease=Lease("192.168.1.4")
        server.lease=lease
        before=Request(lease.grant)
        server.rtsp(before,"192.168.1.4")
        self.assertEqual(before.reply,b"NOPE")
        lease.launched=True
        other=Request(lease.grant)
        server.rtsp(other,"192.168.1.5")
        self.assertEqual(other.reply,b"NOPE")
        bad=Request(secrets.token_bytes(32))
        server.rtsp(bad,"192.168.1.4")
        self.assertEqual(bad.reply,b"NOPE")
        self.assertEqual(lease.proxy_count,0)


    def test_paired_custom_rate_validation_and_lan_only_headroom(self):
        from windows_companion import lan_wire_budget,paired_video_rate
        for rate in (2000,9000,20000,37000,50000):self.assertTrue(paired_video_rate(rate))
        for rate in (False,0,1999,19001,51000,None):self.assertFalse(paired_video_rate(rate))
        self.assertEqual([lan_wire_budget(x) for x in (8000,20000,50000)],[11200,34000,72000])


if __name__=="__main__":
    unittest.main()

