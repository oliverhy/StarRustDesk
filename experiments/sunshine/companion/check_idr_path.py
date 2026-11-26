import base64
from contextlib import chdir
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zlib

import idr_path as trace


def log(text, level='Debug'):
    return '[2026-11-24 12:34:56.123]: '+level+': '+text+'\r\n'


def write(folder, name, value):
    (folder/name).write_text(json.dumps(value),encoding='ascii')


def make_archive(p):
    result=dict(verified_physical_nvenc_and_encrypted_playback=True,view_only=True,playback=dict(route='relay'),
                attribution=dict(host_trace_complete=1,relay_trace_complete=1,host_stream_epochs=1,stream_epochs=1))
    write(p,'result.json',result)
    phone=dict(epochs=[dict(gap_events=[[1100,10,19,8,100,15,0,1,0]])],events=[
        ['irrelevant','freshness_request at=1000 frame=10 gap_ms=2550 extra_ms=2400 request=1'],
        ['irrelevant','freshness_submit at=1100 frame=19 skipped=1 extra_ms=20 wait_ms=100 requests=1'],
        ['irrelevant','freshness_render at=1118 wait_ms=118 pts_ms=5100']])
    write(p,'phone-numeric.json',phone)
    # IDR 13 is *smaller* than a normal frame yet is the one not fully sent.
    frames=[(0,10,5,600,0),(0,11,8,900,0),(0,11,8,900,0),(0,11,8,900,0),
            (0,13,11,700,0),(0,13,12,650,0),(1,13,15,7,0),
            (0,19,35,700,0),(0,19,36,700,0),(1,19,37,7,1),(1,19,45,7,2)]
    (p/'host-numeric.ssmeta').write_bytes(b''.join(trace.RECORD.pack(*r) for r in frames+[(255,0,0,len(frames),0)]))
    write(p,'relay-packet-status.json',{'7':base64.b64encode(zlib.compress(bytes([1,1,1]))).decode()})
    block=bytearray(256);block[24:26]=b'\1\1';block[36:38]=b'\2\2'
    write(p,'phone-packet-counts.json',dict(status=[128,0,0],valid=True,blocks={'1':block.hex()}))
    return phone,result


class MarkerContract(unittest.TestCase):
    def test_only_allowlisted_debug_events_after_arm_and_connect(self):
        m=trace.HostMarkers(); m.observe(log('NvEnc: idr frame 40'));m.arm()
        m.observe(log('NvEnc: idr frame 41'));m.observe(log('CLIENT CONNECTED','Info'))
        for msg in (log('type [IDX_REQUEST_IDR_FRAME]'),log('type [IDX_INVALIDATE_REF_FRAMES]'),'firstFrame [1234]','lastFrame [5678]',
                    log('NvEnc: idr frame 42'),log('NvEnc: idr frame 43 secret'),
                    log('type [IDX_INPUT_DATA]'),log('NvEnc: idr frame 120','Info'),log('NvEnc: idr frame 44\nextra'),
                    'NvEnc: idr frame 45',log('NvEnc: idr frame 0'),log('x'*700)):
            m.observe(msg)
        m.observe(log('CLIENT DISCONNECTED','Info'));m.observe(log('NvEnc: idr frame 46'))
        self.assertEqual([r[1:] for r in trace.accepted_markers(m.snapshot())],[[0,0],[2,0],[1,42]])
        self.assertNotIn('secret',json.dumps(m.snapshot()))

    def test_reference_invalidation_is_not_an_explicit_request_or_encoded_idr(self):
        m=trace.encoder_observations([[1,2,0],[10,1,13],[11,0,0],[12,2,0],[20,1,17],[21,0,0],[23,1,19]])
        self.assertEqual(list(m),[13,17,19])
        self.assertEqual((m[13]['preceding_request_count'],m[13]['preceding_reference_invalidations']),(0,1))
        self.assertIsNone(m[13]['single_request_to_idr_observed_ms'])
        self.assertIsNone(m[17]['single_request_to_idr_observed_ms'])
        self.assertEqual(m[19]['single_request_to_idr_observed_ms'],2)
        for kind,frame in [(2,99),(3,0)]:
            self.assertIsNone(trace.accepted_markers(dict(version=1,sessions=1,invalid=False,rows=[[0,kind,frame]])))

    def test_repeat_connect_reset_duplicate_or_overflow_invalidates(self):
        for wrong in ('reconnect','arm','order','overflow'):
            m=trace.HostMarkers();m.arm();m.observe(log('CLIENT CONNECTED','Info'));m.observe(log('NvEnc: idr frame 9'))
            if wrong=='reconnect':m.observe(log('CLIENT CONNECTED','Info'))
            elif wrong=='arm':m.arm()
            elif wrong=='order':m.observe(log('NvEnc: idr frame 9'))
            else:
                with patch.object(trace,'LIMIT',1):m.observe(log('NvEnc: idr frame 10'))
            self.assertIsNone(trace.accepted_markers(m.snapshot()),wrong)

    def test_unknown_debug_and_continuations_do_not_enter_host_log(self):
        class Base:
            output_id='selected'
            def line(self,row): self.lines.append(row)
        h=trace.HostMarkers().host_type(Base)();h.lines=[]
        for v in [log('secret'), 'wrapped secret', log('NvEnc: created encoder v13 H.264 + user text','Info')]:h.line(v)
        self.assertEqual(h.lines,['NvEnc: created encoder'])

    def test_storm_fits_past_old_capacity_without_changing_the_capture_allowlist(self):
        m=trace.HostMarkers();m.arm();m.observe(log('CLIENT CONNECTED','Info'))
        for f in range(1,1501):
            m.observe(log('type [IDX_REQUEST_IDR_FRAME]'));m.observe(log('NvEnc: idr frame '+str(f)))
            m.observe(log('arbitrary upstream text'))
        rows,counts=trace.marker_evidence(m.snapshot())
        self.assertEqual((len(rows),counts,len(m.rows)),(3000,[1500,1500,0],3000*trace.MARK.size))
        self.assertNotIn('arbitrary',json.dumps(m.snapshot()))

    def test_overflow_counts_entire_single_epoch_but_never_joins_partial_frames(self):
        with patch.object(trace,'LIMIT',2):
            m=trace.HostMarkers();m.arm();m.observe(log('CLIENT CONNECTED','Info'))
            for f in (1,2,3):
                m.observe(log('type [IDX_REQUEST_IDR_FRAME]'));m.observe(log('NvEnc: idr frame '+str(f)))
            doc=m.snapshot()
            self.assertEqual((len(m.rows),doc['truncated'],trace.marker_evidence(doc)),
                             (2*trace.MARK.size,True,(None,[3,3,0])))
            for bad in (dict(totals=[1,0,0]),dict(totals=[True,3,0]),dict(truncated=False),dict(sessions=2)):
                self.assertEqual(trace.marker_evidence(dict(doc,**bad)),(None,None))
            m.observe(log('NvEnc: idr frame 2'))
            self.assertEqual(trace.marker_evidence(m.snapshot()),(None,None))

    @unittest.skipUnless(os.name=='nt','Windows device semantics')
    def test_debug_sink_is_a_character_device_and_security_config_is_unchanged(self):
        with tempfile.TemporaryDirectory(prefix='session-') as path:
            p=Path(path); cfg='lan_encryption_mode = 2\nwan_encryption_mode = 2\nkeyboard = disabled\nmin_log_level = info\nlog_path = '+(p/'sunshine.log').as_posix()+'\n'
            for active in (False,True):
                safe=trace.private_debug_config(cfg,p,active=active)
                self.assertIn('min_log_level = '+('debug' if active else 'info'),safe)
                self.assertIn('log_path = '+(p/'NUL').as_posix(),safe); self.assertTrue(safe.startswith(cfg[:cfg.index('min_log_level')]))
                with (p/'NUL').open('wb') as out:out.write(b'numeric-fixture')
                self.assertEqual(list(p.iterdir()),[])
            for bad in (cfg.replace('sunshine.log','other.log'),cfg+'min_log_level = info\n'):
                with self.assertRaises(ValueError):trace.private_debug_config(bad,p)


class HopContract(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.p=Path(tmp.name)
        self.phone,self.result=make_archive(self.p)

    def ep(self):return trace.report(self.p)['episodes'][0]

    def marks(self,rows):
        write(self.p,'idr-host-numeric.json',dict(version=1,sessions=1,invalid=False,rows=rows,artifacts=trace.fingerprints(self.p)))

    def test_archive_without_markers_is_unknown_not_no_idr(self):
        e=self.ep();self.assertIsNone(e['earlier_observed_idrs']);self.assertEqual(e['encoder_evidence'],'not_recorded')
        self.assertEqual(e['final_frame']['status'],'all_traced_fragments_delivered')
        self.assertEqual((e['final_frame']['host_first_to_last_send_ms'],e['phone_request_to_submit_ms'],e['phone_submit_to_output_ms']),(10,100,18))

    def test_short_gap_reports_shared_idr_without_claiming_request_or_render(self):
        self.phone['events']=[];write(self.p,'phone-numeric.json',self.phone);self.marks([[4,1,13],[5,1,19]])
        r=trace.report(self.p);self.assertEqual(r['status'],'no_confirmed_phone_recovery');self.assertEqual(r['episodes'],[])
        self.assertEqual((r['host_encoded_idrs_in_session'],r['phone_gap_idr_units'],r['matched_gap_idr_units']),(2,1,1))
        top,=r['longest_gap_idr_units'];self.assertEqual((top['phone_decoder_input_gap_ms'],top['frame_path']['frame']),(100,19))
        self.assertEqual(top['frame_path']['phone_local'],2);self.assertNotIn('phone_submit_to_output_ms',top)

    def test_overflow_totals_bound_to_all_artifacts_and_not_promoted_to_frame_evidence(self):
        with patch.object(trace,'LIMIT',1):
            doc=dict(version=2,sessions=1,invalid=False,truncated=True,rows=[[7,1,19]],totals=[5,4,0],
                     artifacts=trace.fingerprints(self.p))
            write(self.p,'idr-host-numeric.json',doc);r=trace.report(self.p)
            self.assertEqual((r['host_marker_coverage'],r['host_request_markers_in_session'],r['host_encoded_idrs_in_session']),
                             ('totals_only',5,4))
            self.assertIsNone(r['matched_gap_idr_units']);self.assertIsNone(r['episodes'][0]['earlier_observed_idrs'])
            self.phone['events'].append(['ignored','core_wait_idr at=4123']);write(self.p,'phone-numeric.json',self.phone)
            r=trace.report(self.p);self.assertEqual(r['host_marker_coverage'],'unavailable');self.assertIsNone(r['host_encoded_idrs_in_session'])

    def test_largest_gap_uses_hashed_hop_records_not_invalid_legacy_marker_prefix(self):
        doc=dict(version=1,sessions=1,invalid=True,rows=[],artifacts=trace.fingerprints(self.p))
        write(self.p,'idr-host-numeric.json',doc)
        r=trace.report(self.p);g=r['largest_phone_gap_fragment_path']
        self.assertIsNone(r['matched_gap_idr_units'])
        self.assertEqual((g['previous_input_frame'],g['recovery_input_frame'],g['missing_sequences'],g['source_seen_frames']),
                         (10,19,8,2))
        self.assertEqual((g['windows_incomplete_frames'],g['host_ingress_fragments'],g['windows_udp_fragments'],
                          g['relay_forwarded_fragments'],g['phone_authenticated_fragments']),(2,5,1,1,1))
        (self.p/'phone-packet-counts.json').unlink()
        self.assertIsNone(trace.report(self.p)['largest_phone_gap_fragment_path'])
        doc['artifacts']=trace.fingerprints(self.p);write(self.p,'idr-host-numeric.json',doc)
        self.assertIsNone(trace.report(self.p)['largest_phone_gap_fragment_path']['phone_authenticated_fragments'])
        self.assertIsNone(trace.largest_gap_hops(self.p,{100000:(38000,50001)},True))

    def test_gap_idr_requires_unique_plausible_input_and_bound_host(self):
        g=self.phone['epochs'][0]['gap_events'][0]
        self.assertFalse(trace.gap_idr_units(dict(gap_events=[g,g,g,[*g[:2],0,*g[3:]],g[:7]])))
        self.phone['events']=[];write(self.p,'phone-numeric.json',self.phone)
        r=trace.report(self.p);self.assertIsNone(r['host_encoded_idrs_in_session']);self.assertIsNone(r['matched_gap_idr_units'])

    def test_core_wait_counts_only_inside_confirmed_phone_window(self):
        for t in [995,1002,1002,1098,1102]: self.phone['events'].insert(1,['ignored','core_wait_idr at='+str(t)])
        self.phone['events'][-2][1]=self.phone['events'][-2][1].replace('requests=1','requests=2')
        write(self.p,'phone-numeric.json',self.phone); e=self.ep()
        self.assertEqual((e['phone_freshness_requests'],e['core_wait_observations'],
            e['first_core_wait_after_request_ms'],e['last_core_wait_after_request_ms']),(2,2,2,98))

    def test_explicit_encoder_marker_identifies_failed_earlier_idr_not_large_interframe(self):
        self.marks([[300,0,0],[310,1,13],[380,0,0],[390,0,0],[405,1,19]])
        e=self.ep();self.assertEqual(e['encoder_evidence'],'matched');prev,=e['earlier_observed_idrs']
        self.assertEqual((prev['frame'],prev['status'],prev['single_request_to_idr_observed_ms']),(13,'windows_send_incomplete',10))
        self.assertIsNone(prev['phone_decoder_input_gap_ms'])
        self.assertIsNone(e['final_encoder_observation']['single_request_to_idr_observed_ms'])

    def test_missing_anchor_or_mismatched_file_pair_does_not_join(self):
        self.marks([[4,1,13]]);self.assertEqual(self.ep()['encoder_evidence'],'no_shared_frame_anchor')
        self.marks([[4,1,19]]);self.phone['events'].append(['ignored','core_wait_idr at=1170']);write(self.p,'phone-numeric.json',self.phone)
        self.assertEqual(self.ep()['encoder_evidence'],'invalid_or_unbound_markers');self.assertIsNone(self.ep()['earlier_observed_idrs'])

    def test_repeated_or_unknown_frame_identity_and_invalid_clocks_rejected(self):
        self.result['attribution']['host_stream_epochs']=2;write(self.p,'result.json',self.result)
        self.assertIn('unverified',trace.report(self.p)['status']);self.result['attribution']['host_stream_epochs']=1
        write(self.p,'result.json',self.result)
        self.phone['events'][-1][1]=self.phone['events'][-1][1].replace('wait_ms=118','wait_ms=119')
        self.assertFalse(trace.phone_episodes(self.phone));self.phone['epochs'][0]['gap_events'][0][7]=0
        self.phone['events'][-1][1]=self.phone['events'][-1][1].replace('119','118');self.assertFalse(trace.phone_episodes(self.phone))

    def test_unknown_phone_is_not_counted_as_loss_and_relay_limit_is_separate(self):
        write(self.p,'relay-packet-status.json',{'7':base64.b64encode(zlib.compress(bytes([1,1,2]))).decode()})
        self.assertEqual(self.ep()['final_frame']['status'],'relay_limited')
        (self.p/'phone-packet-counts.json').unlink();self.assertIsNone(self.ep()['final_frame']['phone_authenticated'])
        write(self.p,'relay-packet-status.json',{'7':base64.b64encode(zlib.compress(bytes([1,1,1]))).decode()})
        self.assertEqual(self.ep()['final_frame']['status'],'phone_unobserved')

    def test_relay_send_error_is_distinct_from_no_observation_and_expired_pair(self):
        self.marks([[4,1,19]])
        for state,reason in [(3,'relay_send_failure'),(0,'relay_forward_unconfirmed')]:
            write(self.p,'relay-packet-status.json',{'7':base64.b64encode(zlib.compress(bytes([1,1,state]))).decode()})
            e=self.ep();f=e['final_frame'];self.assertEqual(e['encoder_evidence'],'invalid_or_unbound_markers')
            self.assertEqual((f['status'],f['relay_send_errors'],f['relay_not_observed']),(reason,int(state==3),int(state==0)))

    def test_direct_route_and_missing_or_stale_phone_block(self):
        self.result['playback']['route']='direct';write(self.p,'result.json',self.result)
        (self.p/'relay-packet-status.json').unlink()
        self.assertIsNone(self.ep()['final_frame']['relay_forwarded'])
        self.assertEqual(self.ep()['final_frame']['status'],'all_traced_fragments_delivered')
        for status,blocks in [([128,0,0],{}),([4,0,0],{'1':'00'*256}),([128,1,0],{'1':'00'*256})]:
            write(self.p,'phone-packet-counts.json',dict(valid=True,status=status,blocks=blocks))
            self.assertEqual(self.ep()['final_frame']['status'],'phone_unobserved')

    def test_incomplete_fragments_do_not_contradict_a_rendered_fec_picture(self):
        block=bytearray(256);block[36:38]=b'\1\1'
        write(self.p,'phone-packet-counts.json',dict(valid=True,status=[128,0,0],blocks={'1':block.hex()}))
        e=self.ep();self.assertEqual(e['final_frame']['status'],'phone_ingress_incomplete');self.assertEqual(e['phone_submit_to_output_ms'],18)

    def test_restart_or_trailing_zlib_payload_is_never_full_evidence(self):
        self.phone['events'].insert(1,['ignored','quality_restart from_kbps=850 to_kbps=500']);self.assertFalse(trace.phone_episodes(self.phone))
        write(self.p,'relay-packet-status.json',{'7':base64.b64encode(zlib.compress(b'\1\1\1')+b'bad').decode()})
        self.assertEqual(trace.report(self.p)['status'],'incomplete_hop_trace')

    def test_truncated_or_duplicate_send_trace_cannot_report_a_valid_path(self):
        path=self.p/'host-numeric.ssmeta';raw=path.read_bytes();path.write_bytes(raw[:-1]);self.assertEqual(trace.report(self.p)['status'],'incomplete_hop_trace')
        rows=list(trace.RECORD.iter_unpack(raw));rows[-2]=rows[-3];path.write_bytes(b''.join(trace.RECORD.pack(*v) for v in rows))
        self.assertEqual(trace.report(self.p)['status'],'incomplete_hop_trace')

    def test_sidecar_is_exclusive_and_contains_no_raw_message(self):
        m=trace.HostMarkers();m.arm();m.observe(log('CLIENT CONNECTED','Info'));m.observe(log('NvEnc: idr frame 19'));m.observe(log('discard-me'))
        trace.save_markers(self.p,m);self.assertEqual(self.ep()['encoder_evidence'],'matched')
        self.assertNotIn('discard-me',(self.p/'idr-host-numeric.json').read_text())
        with self.assertRaises(FileExistsError):trace.save_markers(self.p,m)

    def test_relative_cli_run_directory_opens_same_sidecar_as_absolute(self):
        self.marks([[4,1,19]])
        with chdir(self.p.parent):
            r=trace.report(Path(self.p.name))
        self.assertEqual(r,trace.report(self.p))
        self.assertEqual(r['episodes'][0]['encoder_evidence'],'matched')


if __name__=='__main__':unittest.main()
