import unittest
from datetime import datetime,timezone
from unittest.mock import MagicMock, patch

from lan_recovery_witness import known_missing,next_wire,single,stamp_interval,wall_bounds
from wifi_uplink import windows_lan_medium


class Checks(unittest.TestCase):
    def setUp(self):
        self.span=dict(begin_ms=2200,end_ms=3000,busy_ms=800,errno=10035,phone_ok_during_pc_failure=True)
        self.src=[2000,2100,2200,2500,2700,2999,3040,3120,3200,3300]
        self.sam=[(2000,2006,1),(2450,2462,2),(3090,3100,4),(3350,3360,7)]
        self.res={(3000,10035):(95,800004)}
    def result(self,events=None,missed=None,idrs=()):
        return single(self.span,[(3090,3100,3,1100)] if events is None else events,
                      self.sam,1,self.src,4,missed or [],self.res,idrs)
    def test_intersecting_gap_proven_but_not_assumed_fresh(self):
        r=self.result()
        self.assertEqual((r['status'],r['render_after_send_interval_ms'],r['order_proven']),
                         ('crossing_render',[90,100],True))
        self.assertEqual((r['new_source_surface_upper_ms'],r['observed_writable_to_send_us']),(360,95))
    def test_uncertain_order_is_signed_never_claimed_proven(self):
        r=self.result(events=[(2880,3060,3,1050)])
        self.assertFalse(r['order_proven']);self.assertEqual(r['render_after_send_interval_ms'],[-120,60])
    def test_no_duplicate_or_unbracketed_render_match(self):
        self.assertEqual(self.result(events=[(3090,3100,3,1100)]*2)['status'],'ambiguous')
        self.assertEqual(self.result(events=[(3090,3100,8,1100)])['status'],'no_confirmed_crossing_render')
        self.assertEqual(self.result(events=[])['status'],'no_confirmed_crossing_render')
    def test_only_post_resume_idr_uses_causal_lower_bound(self):
        r=self.result(idrs=[(6,3010,3230),(7,2970,3140)])
        self.assertEqual(r['new_idr_callback_interval_ms'],[36,140])
        self.assertNotIn('new_idr_callback_interval_ms',self.result(idrs=[(7,2970,3010)]))
    def test_only_confirmed_missing_frames_pruned(self):
        ep=dict(gap_events=[[100,2,5,2],[150,5,7,1]],samples=[[0,0,0,0,0,3]])
        self.assertEqual(known_missing(ep,1,10),[(3,4),(6,6)])
        self.assertEqual(self.result(missed=[(3,5)])['new_source_surface_upper_ms'],100)
        ep['gap_events'].reverse()
        self.assertEqual(known_missing(ep,1,10),[])
    def test_no_cross_session_clock_or_invented_missing_id(self):
        self.assertIsNone(wall_bounds([None,None]))
        def clk(host,off,tz=480):return dict(host_ms=host,offset_ms=off,radius_ms=20,tz_min=tz)
        self.assertIsNone(wall_bounds([clk(10,100),clk(30,400)]))
        self.assertIsNone(wall_bounds([clk(10,100),clk(30,100,60)]))
        self.assertIsNone(wall_bounds([clk(30,100),clk(10,100)]))
        self.assertEqual(known_missing(dict(gap_events=[[1,4,7,2]],samples=[[0]*6]),1,10),[])
    def test_host_video_must_follow_a_wire_silence_and_have_source(self):
        rows=[(1,1,1000,0,0),(0,2,1650,0,0),(1,2,1670,0,0),(1,3,1681,0,0)]
        self.assertEqual(next_wire(rows,[1671],1,[980,1650,1680]),
                         {1671:{'source_frame':2,'age_ms':20,'relative_ms':-1}})
        self.assertFalse(next_wire(rows,[1681],1,[980,1650,1680]))
        self.assertFalse(next_wire(rows,[1671],1,[980]))
    def test_midnight_clock_and_untrusted_wall_text(self):
        mid=int(datetime(2026,11,24,16,tzinfo=timezone.utc).timestamp()*1000)
        c=(480,mid,-2100,-2000)
        left=stamp_interval('23:59:59.900',c);right=stamp_interval('00:00:00.100',c)
        self.assertEqual(right[0]-left[0],200)
        self.assertLess(left[0],mid+2000);self.assertGreater(left[1],mid+1900)
        self.assertIsNone(stamp_interval('25:00:00.000',c))
    def test_physical_route_not_just_any_wifi_card(self):
        sock=MagicMock();sock.__enter__.return_value=sock;sock.getsockname.return_value=('192.168.1.12',49001)
        with patch('socket.socket',return_value=sock),patch('portable_host.pwsh',return_value='6:17') as pw:
            self.assertEqual(windows_lan_medium('192.168.1.12','192.168.1.25'),'ethernet')
            pw.return_value='71:6';self.assertEqual(windows_lan_medium('192.168.1.12','192.168.1.25'),'wifi')
            pw.return_value='53';self.assertEqual(windows_lan_medium('192.168.1.12','192.168.1.25'),'unknown')
            self.assertEqual(windows_lan_medium('192.168.1.20','192.168.1.25'),'changed')

    def test_udp_timestamp_abi_and_unavailable(self):
        from lan_tx_caps import Caps,result,query
        import ctypes
        b=Caps()
        self.assertEqual((ctypes.sizeof(b),Caps.hw.offset,Caps.sw.offset),(24,9,20))
        b.hw.ptp[2]=1
        self.assertFalse(result(0,b)['hardware_udp_tx'])
        b.sw.tagged_tx=1;self.assertTrue(result(0,b)['software_udp_tx'])
        self.assertEqual(result(50,b),dict(status='not_supported',win32=50))
        self.assertEqual(result(5,b)['status'],'query_failed')
        self.assertEqual(query(None),dict(status='no_bound_interface'))


if __name__=='__main__':unittest.main()
