"""Numeric-only recovery evidence rejects mismatched sessions, frames and clocks."""
from datetime import datetime
from pathlib import Path
import tempfile
import unittest
import json
from types import SimpleNamespace
import lan_key_path as k
from long_metrics import META,RECORD

class TestKeys(unittest.TestCase):
    def test_slot_returns(self):
        a='lan_slot_return f=10 us=7001 seen=1';b='lan_slot_return f=11 us=0 seen=0'
        seal='lan_slot_return_end kept=2 overflow=0'
        rej=[(10,1,103,0),(11,1,104,0),(12,2,105,0)]
        run=lambda *lines:k.slot_returns([('s',x) for x in lines],rej)
        for s in (a,b,seal):
            self.assertTrue(META.fullmatch(s));self.assertFalse(META.fullmatch(s+' text'))
        self.assertEqual(run()['status'],'not_in_archive')
        self.assertEqual(run(a,b,seal)['events'],[dict(frame=10,reject_to_available_us=7001),
                                                   dict(frame=11,reject_to_available_us=None)])
        for lines in ((a,b),(a,a,seal),(a,b,seal,seal),(a,seal),(a,b,seal[:-1]+'1'),
                      (a,b.replace('us=0','us=1'),seal),(a,b.replace('f=11','f=99'),seal)):
            self.assertEqual(run(*lines)['status'],'incomplete')
    def test_no_secrets(self):
        h=k.HostKeys();h.armed=True
        stamp='2026-11-25 13:00:00.123'
        t=round(datetime.strptime(stamp,'%Y-%m-%d %H:%M:%S.%f').timestamp()*1000)
        def send(s,lag=5):h.observe('['+stamp+']: '+s,t+lag)
        send('Debug: type [IDX_REQUEST_IDR_FRAME]');self.assertEqual(h.rows,[])
        send('Info: CLIENT CONNECTED');send('Debug: type [IDX_REQUEST_IDR_FRAME]')
        send('Debug: type [IDX_INVALIDATE_REF_FRAMES]');send('Debug: NvEnc: idr frame 24')
        send('Debug: type [IDX_REQUEST_IDR_FRAME] extra');send('Debug: NvEnc: idr frame 27',2200)
        send('Info: CLIENT DISCONNECTED');send('Debug: NvEnc: idr frame 90')
        self.assertEqual((h.sessions,h.bad,len(h.rows)),(1,1,3))
        e,c=k.host_evidence(h.rows);self.assertEqual(e,{24:(t,None)});self.assertEqual(c,[(t,0),(t,2)])
        with self.assertRaises(ValueError):k.host_evidence(h.rows+[h.rows[-1]])
    def test_wire_join(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'ledger'
            def put(rows):p.write_bytes(b''.join(RECORD.pack(*r) for r in rows))
            rows=[(0,1,4,0,0),(1,1,5,0,0),(0,2,7,0,0),(0,2,8,0,0),(1,2,9,0,0)]
            put(rows+[(255,0,0,5,0)]);self.assertEqual(k.wire(p,{2})[2],[7,9,2,1])
            put(rows+[(255,0,0,6,0)])
            with self.assertRaises(ValueError):k.wire(p,{2})
    def test_allowlists_and_ambiguous(self):
        a='lan_key_phase f=12 first=135 loss=0 wait=135 kind=1 queue=136 sent=138 last=138 nq=1 ns=1'
        b='lan_key_out f=12 first=135 unit=152 surface=157 exact=1 idr=1 backup=0 tries=0'
        for s in (a,b,'lan_key_policy=1','lan_key_reject f=11 why=1 at=130 idr=0','lan_key_slot_policy=1',
                  'lan_key_slot f=33 wait_us=1040 pushed=1 idr=0','lan_key_slot_end tries=4 pushed=3'):
            self.assertTrue(META.fullmatch(s));self.assertFalse(META.fullmatch(s+' unexpected'))
        self.assertEqual(k.slots([('s',a),('t',a)],k.PHASE),{})
        self.assertIsNone(k.interval(-5,-1));self.assertEqual(k.interval(-4,3.2),[0,4])
        self.assertEqual(k.causal_floor(8000,500,[(15,7900,490)])['min_ms'],82)
        self.assertIsNone(k.causal_floor(8000,500,[(14,5100,300),(18,8001,490)]))

    def test_epoch_clock_and_frame_join(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);t=round(datetime(2026,11,25,14).timestamp()*1000)
            # Make phone stamps in UTC in this fixture, independently of the host timezone.
            from datetime import timezone
            def stamp(delta):return datetime.fromtimestamp((t+delta)/1000,timezone.utc).strftime('%H:%M:%S.%f')[:12]
            def put(n,obj):(p/n).write_text(json.dumps(obj),'ascii')
            result=dict(route='lan',encrypted_video_audio=True,usb_forward=False,primary_capture_confirmed=True,
                        host_refuses_input=True,windows_medium_at_boundaries=['ethernet']*2,ethernet_phone_wifi={'phone_source_bound':True},
                        host_setups=[[1920,1080,60,20000]],attribution={'host_trace_complete':1,'host_stream_epochs':1})
            put('result.json',result)
            put('encoder-size-numeric.json',{'clocks':[dict(host_ms=t+x,offset_ms=0,radius_ms=5,tz_min=0) for x in (0,1000)]})
            (p/'host-path-numeric.txt').write_text(f'lan_tx_clock phase=1 elapsed_us=0 utc_ms={t} bracket_us=10\nlan_tx_clock phase=2 elapsed_us=1000000 utc_ms={t+1000} bracket_us=10','ascii')
            rows=[(k,f,m+k,0,f) for f,m in [(1,0),(2,30),(3,50),(4,103)] for k in (0,1)]
            (p/'host-numeric.ssmeta').write_bytes(b''.join(RECORD.pack(*v) for v in rows+[(255,0,0,len(rows),0)]))
            phase='lan_key_phase f=4 first=5030 loss=5030 wait=5040 kind=1 queue=5041 sent=5043 last=5043 nq=1 ns=1'
            out='lan_key_out f=4 first=5030 unit=5120 surface=5127 exact=1 idr=1 backup=0 tries=0'
            put('phone-numeric.json',{'events':[[stamp(127),phase],[stamp(127),out]],'epochs':[{'gap_events':[[5120,1,4,2,122,2,0,1,0]],'gap_stamps':[stamp(120)]}]})
            def make(controls):
                h=SimpleNamespace(sessions=1,bad=0,rows=[[t,1,1]]+controls+[[t+100,1,4]])
                side=p/'lan-key-host.json'
                if side.exists():side.unlink()
                k.seal(p,h)
            make([[t+60,0,0]])
            e=k.join(p)['episodes'][0]
            self.assertTrue(e['encoder_idr_frame_match']);self.assertEqual(e['host_candidate_to_encoded_ms'],40)
            self.assertEqual(e['intent_to_control_handoff_ms'],2);self.assertEqual(e['submit_to_surface_ms'],7)
            make([[t+59,0,0],[t+60,0,0]])
            e=k.join(p)['episodes'][0];self.assertNotIn('host_candidate_to_encoded_ms',e)
            make([[t+59,1,3],[t+60,0,0]])
            e=k.join(p)['episodes'][0];self.assertEqual(e['earlier_candidate_encoded_idrs'],[3]);self.assertNotIn('host_candidate_to_encoded_ms',e)
            (p/'phone-numeric.json').write_text('{}','ascii')
            with self.assertRaises(ValueError):k.join(p)

if __name__=='__main__':unittest.main()
