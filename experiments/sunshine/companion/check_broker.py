"""Checks the broker contract in memory. No network traffic."""
import unittest
import udp_broker as b


class Contract(unittest.TestCase):
    def test_short30_shares_both_directions_and_enforces_byte_budget(self):
        class Sink:
            def sendto(self,packet,addr): return len(packet)
        tick=[0.0]
        meter=b.ShortTrialSocket(Sink(),lambda:tick[0])
        for i in range(7): meter.sendto(b'x'*1024,self.addrs[i%2])
        with self.assertRaises(BlockingIOError): meter.sendto(b'x'*1024,self.addrs[1])
        tick[0]+=.002
        meter.sendto(b'x'*1024,self.addrs[1])
        self.assertEqual(meter.charged,8*1052)
        meter.charged=meter.MAX_BYTES-10
        with self.assertRaises(BlockingIOError): meter.sendto(b'x',self.addrs[0])
        self.assertTrue(meter.exhausted)
        self.assertEqual(b.Broker(self.keys).bytes_per_second,1800*125)
        self.assertEqual(b.Broker(self.keys,smooth_downlink=True,wire_kbps=8000).bytes_per_second,8000*125)
        with self.assertRaises(ValueError): b.Broker(self.keys,wire_kbps=30000)

    def setUp(self):
        self.keys=b.tickets(b"r"*32)
        self.b=b.Broker(self.keys,b"c"*32)
        self.addrs=(("8.8.4.4",48888),("1.1.1.1",49999))
        self.nonces=(b"h"*16,b"p"*16)

    def msg(self, role, phase, op, cookie=bytes(16)):
        p=b"SCB1"+bytes([role,phase,op,0])+self.nonces[role]+cookie+bytes(24)
        return p+b.sign(self.keys[role],p)

    def challenge(self, role, phase, stamp=33):
        reply=self.b.request(self.msg(role,phase,b.HELLO),self.addrs[role],stamp)
        self.assertEqual(reply[6],b.CHALLENGE)
        return self.msg(role,phase,b.PROOF,reply[24:40])

    def test_overlapping_proved_pair_is_required(self):
        p=self.challenge(0,b.DIRECT)
        self.assertIsNone(self.b.request(p,(self.addrs[0][0],50000),33))
        self.assertIsNone(self.b.request(p,self.addrs[0],60))
        self.assertIsNone(self.b.request(p,self.addrs[0],33))
        p=self.challenge(1,b.DIRECT)
        self.assertEqual(self.b.request(p,self.addrs[1],33)[6],b.OFFER)
        self.assertIsNone(self.b.forward(bytes([4])+bytes(59),self.addrs[1],33))

    def test_relay_requires_reserved_pair_bounds_and_expiry(self):
        p=self.challenge(0,b.RELAY)
        self.assertIsNone(self.b.request(p,self.addrs[0],33))
        p=self.challenge(1,b.RELAY)
        self.assertEqual(self.b.request(p,self.addrs[1],33)[6],b.OFFER)
        self.assertIsNone(self.b.forward(bytes([4])+bytes(60),("1.1.1.2",49999),34))
        packet=bytes([4])+bytes(1226)   # Valid unpadded envelope.
        self.assertEqual(self.b.forward(packet,self.addrs[1],34),self.addrs[0])
        for _ in range(15): self.b.forward(packet,self.addrs[1],34)
        self.assertGreater(self.b.dropped,0)
        self.assertIsNone(self.b.forward(packet,self.addrs[1],164))

    def test_altered_ticket_and_cross_role_fail_closed(self):
        m=self.msg(1,b.DIRECT,b.HELLO)
        self.assertIsNone(self.b.request(m[:4]+bytes([0])+m[5:],self.addrs[1],33))
        self.assertIsNone(self.b.request(m[:-1]+bytes([m[-1]^1]),self.addrs[1],33))

    def test_lease_extension_requires_two_fresh_bound_proofs_and_never_moves_hard_limit(self):
        self.enable_shape(); lease=self.b.lease; initial=lease["until"]; hard=lease["hard_stop"]
        packet=b"\x04"+bytes(180)
        for t in range(34,146,5): self.b.forward(packet,self.addrs[0],t)
        self.assertEqual(lease["until"],initial)
        p=self.challenge(0,b.RELAY,145)
        self.b.request(p,self.addrs[0],145)
        self.assertEqual(lease["until"],initial)
        q=self.challenge(1,b.RELAY,146)
        self.b.request(q,(self.addrs[1][0],50005),146)
        self.assertEqual(lease["until"],initial)
        self.b.request(q,self.addrs[1],146)
        self.assertEqual((lease["until"],lease["hard_stop"]),(220,hard))
        self.b.expire(160);self.assertIsNone(self.b.lease)

    def test_high_budget_requires_shaping_and_does_not_expand_the_burst(self):
        for rate in (8001,9000,0):
            with self.assertRaises(ValueError): b.Broker(self.keys,smooth_downlink=True,wire_kbps=rate)
        with self.assertRaises(ValueError): b.Broker(self.keys,wire_kbps=8000)
        packet=b"\x04"+bytes(1023)
        for cap in (1800,8000):
            self.b=b.Broker(self.keys,b"c"*32,smooth_downlink=True,wire_kbps=cap)
            self.enable_shape()
            sent=[]
            def emit(p,d):
                sent.append(len(p)+28)
                return len(p)
            for _ in range(20): self.b.forward(packet,self.addrs[0],34,emit)
            self.assertLessEqual(sum(sent),b.BURST)
            for t in (34.001,34.003,34.006,34.010,34.013):
                self.b.flush_downlink(t,emit)
                self.assertLessEqual(sum(sent),b.BURST+(t-34)*cap*125+.01)
            self.assertLessEqual(self.b.queue_peak_bytes,self.b.pending_bytes)
            self.assertEqual(self.b.pending_bytes,10000 if cap==8000 else 4096)
            if cap==8000:
                self.assertGreater(self.b.queue_peak_bytes,4096)
                self.assertLess(self.b.queue_peak_us,12000)
            self.assertEqual(self.b.bytes_per_second,cap*125)

    def test_refill_uses_receipt_time_and_does_not_increase_the_burst(self):
        self.b.trace=b.PacketTrace(b"b"*16)
        for role in (0,1):
            self.b.request(self.challenge(role,b.RELAY),self.addrs[role],33)
        self.b.lease["credit"][0]=0
        self.b.lease["updated"][0]=33
        owner=self
        class Channel:
            now=33
            delay=.050
            sent=0
            def recvfrom(self, maximum):
                self.now+=self.delay
                self.delay=0
                return b"\x04"+bytes(1226),owner.addrs[0]
            def sendto(self, packet, dest):
                owner.assertEqual(dest,owner.addrs[1])
                self.sent+=1
                return len(packet)
        sock=Channel()
        for _ in range(4): b.receive_one(sock,self.b,100,lambda: sock.now)
        self.assertEqual(sock.sent,b.BURST//(1227+28))
        self.assertEqual(self.b.dropped,1)
        sock.delay=10
        b.receive_one(sock,self.b,40,lambda: sock.now)
        self.assertEqual(sock.sent,3,"deadline must also be checked after the read")

    def enable_shape(self):
        self.b.smooth_downlink=True
        for role in (0,1):
            self.b.request(self.challenge(role,b.RELAY),self.addrs[role],33)

    def test_shape_preserves_fifo_rate_and_reverse_direction(self):
        self.enable_shape()
        sent=[]
        def emit(p,d):
            sent.append((p[-1],d))
            return len(p)
        packets=[b"\x04"+bytes(846)+bytes([i]) for i in range(8)]
        for p in packets: self.b.forward(p,self.addrs[0],34,emit)
        self.assertEqual(sent,[(i,self.addrs[1]) for i in range(4)])
        self.assertEqual((self.b.queued,self.b.dropped,self.b.shadow_limited),(3,1,4))
        self.assertLessEqual(self.b.lease["pending_wire"],b.SHAPE_MAX_BYTES)
        self.assertIsNone(self.b.forward(packets[-1],("1.1.1.2",49999),34,emit))
        self.assertEqual(self.b.forward(packets[-1],self.addrs[1],34,emit),self.addrs[0])
        self.assertEqual(sent[-1],(7,self.addrs[0]))
        # Repeated ticks at the same timestamp do not release a second burst.
        for _ in range(10): self.b.flush_downlink(34,emit)
        self.assertEqual(len(sent),5)
        for t in (34.0015,34.0055,34.0105):
            self.b.flush_downlink(t,emit)
            sent_down=sum(d==self.addrs[1] for _,d in sent)
            self.assertLessEqual(sent_down*(len(packets[0])+28),
                b.BURST+(t-34)*b.WIRE_BYTES_PER_SECOND)
        self.assertEqual([i for i,d in sent if d==self.addrs[1]],list(range(7)))
        self.assertEqual(self.b.queued_sent,3)
        self.assertLess(self.b.queue_peak_us,12_000)

    def test_slow_wake_and_expired_lease_never_replay_packets(self):
        self.enable_shape()
        packet=b"\x04"+bytes(847)
        for _ in range(5): self.b.forward(packet,self.addrs[0],34)
        sent=[]
        self.b.flush_downlink(34.013,lambda p,d: sent.append(p) or len(p))
        self.assertEqual(sent,[])
        self.assertEqual(self.b.queue_expired,1)
        for _ in range(5): self.b.forward(packet,self.addrs[0],35)
        self.b.lease["until"]=35.001
        self.b.flush_downlink(35.002,lambda p,d: sent.append(p) or len(p))
        self.assertEqual(sent,[])
        self.assertIsNone(self.b.lease)
        self.assertEqual(self.b.queue_cancelled,1)

    def test_high_trace_records_only_verified_downlink_without_changing_shaping(self):
        def run(trace):
            self.b=b.Broker(self.keys,b"c"*32,trace=b.PacketTrace(b"t"*16) if trace else None,
                            smooth_downlink=True,wire_kbps=8000)
            for role in (0,1): self.b.request(self.challenge(role,b.RELAY),self.addrs[role],33)
            sent=[]
            def emit(p,dst):
                sent.append((p[8:16],dst));return len(p)
            def packet(i):
                return b"\x04"+bytes(7)+i.to_bytes(8,"little")+bytes(1040)
            self.b.forward(packet(1),("192.0.2.1",41234),34,emit,1)
            self.b.forward(packet(2),self.addrs[1],34,emit,1)
            self.assertFalse(self.b.ingress_window)
            for begin in (35,47):
                for i in range(56):
                    self.b.forward(packet(i+begin*100),self.addrs[0],begin+i*.00001,emit,2_000_000_000+i*3000)
                self.b.flush_downlink(begin+.011,emit)
            if trace:
                self.assertEqual(len(self.b.peak_windows),2)
                for _,rows in self.b.peak_windows.values():
                    evidence=list(b.BURST_ROW.iter_unpack(self.b.burst_evidence(rows)))
                    self.assertTrue(4<len(evidence)<=64)
                    self.assertNotIn(2,[r[1] for r in evidence])
                    self.assertGreater(evidence[-1][4],0)
            else: self.assertFalse(self.b.peak_windows)
            return sent,self.b.dropped,self.b.limit_bytes,self.b.queued_sent
        self.assertEqual(run(True),run(False))


if __name__=="__main__":
    unittest.main()
