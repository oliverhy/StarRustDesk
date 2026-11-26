"""One-pair, expiring UDP rendezvous for the explicitly authorized test VPS.

Accepts two independently scoped broker tickets, not the pairing secret or
WireGuard keys. Only reachability-proven endpoints can receive offers or
encrypted relay traffic. No payload, candidate address or ticket is logged.
"""
import hashlib
import hmac
import base64
from collections import deque
import ipaddress
import secrets
import select
import socket
import struct
import sys
import threading
import time
import zlib

PORT = 23388
SIZE = 96
HELLO, PROOF, CHALLENGE, OFFER = range(1, 5)
DIRECT, RELAY = 1, 2
WIRE_BYTES_PER_SECOND = 1800 * 125
BURST = 4096
SHAPE_MAX_DELAY = .012
SHAPE_MAX_BYTES = 4096
SHAPE_MAX_PACKETS = 8
# One byte per opaque counter per key epoch, diagnostic runs only. A full
# 10-minute high-bandwidth trial can exceed 240k packets in one epoch.
TRACE_LIMIT = 800_000
TRACE_EPOCHS = 10
BURST_ROW = struct.Struct("<QQHIi")  # run-specific id, counter, wire bytes, dequeue us, kernel us (-1 unknown)


def timestamp_mode(channel):
    # Only for the ephemeral diagnostic socket. Never timestamp or shape a
    # session based on a wall clock. Unsupported ABI/provider -> observation off.
    if sys.platform!="linux" or struct.calcsize("@l")!=8 or not hasattr(channel,"recvmsg"): return 0
    import os
    opt=getattr(socket,"SO_TIMESTAMPNS",None)
    if opt is None and os.uname().machine in ("aarch64","x86_64"): opt=64  # Linux SO_TIMESTAMPNS_NEW
    if not opt: return 0
    try: channel.setsockopt(socket.SOL_SOCKET,opt,1)
    except OSError: return 0
    return opt


def kernel_stamp(ancillary,flags,opt):
    if flags & getattr(socket,"MSG_CTRUNC",8): return None
    for level,kind,value in ancillary:
        if level==socket.SOL_SOCKET and kind==opt and len(value)==16:
            sec,ns=struct.unpack("=qq",value)
            if sec>0 and 0<=ns<1_000_000_000: return sec*1_000_000_000+ns
    return None


class PacketTrace:
    """Opaque, one-run packet counters. No payload or address is stored."""
    def __init__(self, salt):
        self.salt=salt
        self.epochs={}
        self.truncated=0
        self.last=None

    def identity(self,packet):
        index=packet[4:8]
        counter=int.from_bytes(packet[8:16],"little")
        if not self.last or self.last[0]!=index:
            tag=int.from_bytes(hashlib.sha256(self.salt+index).digest()[:8],"little")
            self.last=(index,tag)
        else:
            tag=self.last[1]
        return tag,counter

    def mark(self, packet, state):
        if len(packet)<52 or packet[0]!=4: return
        tag,counter=self.identity(packet)
        if counter>=TRACE_LIMIT or (tag not in self.epochs and len(self.epochs)>=TRACE_EPOCHS):
            self.truncated+=1
            return
        if tag not in self.epochs: self.epochs[tag]=[bytearray(TRACE_LIMIT),0]
        buf,end=self.epochs[tag]
        # If an identical datagram was sent more than once, retain success.
        if buf[counter]!=1: buf[counter]=state
        self.epochs[tag][1]=max(end,counter+1)

    def dump(self):
        for tag,(buf,end) in self.epochs.items():
            value=base64.b64encode(zlib.compress(buf[:end],4)).decode("ascii")
            print(f"companion_broker_trace tag={tag} data={value}",flush=True)
        print(f"companion_broker_trace_done epochs={len(self.epochs)} truncated={self.truncated}",flush=True)


def sign(key, data):
    return hmac.digest(key, data, hashlib.sha256)


def tickets(root):
    return tuple(sign(root, b"sesame-companion/broker/v1" + bytes([role])) for role in (0, 1))


class Broker:
    def __init__(self, keys, cookie_key=None, trace=None, smooth_downlink=False, wire_kbps=1800):
        if len(keys) != 2 or not all(len(k) == 32 and any(k) for k in keys) or keys[0] == keys[1]:
            raise ValueError("broker_ticket_invalid")
        self.keys = keys
        self.cookie_key = cookie_key or secrets.token_bytes(32)
        self.trace=trace
        if wire_kbps not in (1800,8000,30000) or (wire_kbps!=1800 and not smooth_downlink):
            raise ValueError("broker_rate_profile_invalid")
        self.smooth_downlink=smooth_downlink
        self.bytes_per_second=wire_kbps*125
        # Pending bytes are not send credit. Reserve no more than 10 ms of
        # high-rate work (2 ms margin for scheduler wake), still expire at
        # 12 ms, keep the original 4 KiB emission burst and legacy budget.
        self.pending_bytes=max(SHAPE_MAX_BYTES,self.bytes_per_second//100)
        self.pending_count=40 if wire_kbps==30000 else 16 if wire_kbps==8000 else SHAPE_MAX_PACKETS
        self.proved = {}
        self.lease = None
        self.rx = self.tx = self.dropped = 0
        self.requests=[0,0]
        self.valid=[0,0]
        self.proofs=[0,0]
        self.offers=[0,0]
        self.queued=self.queued_sent=self.queue_expired=self.queue_cancelled=0
        self.queue_peak_bytes=self.queue_peak_us=0
        self.downlink_limited=self.shadow_limited=0
        self.limit_bytes=self.limit_count=self.limit_deadline=0
        self.ingress_window=deque()
        self.ingress_wire=self.limit_ingress_peak_bytes=0
        self.burst_trace=bool(trace and smooth_downlink and wire_kbps==8000)
        self.peak_windows={}

    def shape_stats(self):
        return (f"companion_broker_shape queued={self.queued} sent={self.queued_sent} "
                f"expired={self.queue_expired} cancelled={self.queue_cancelled} "
                f"peak_bytes={self.queue_peak_bytes} max_wait_us={self.queue_peak_us} "
                f"downlink_limited={self.downlink_limited} immediate_limited={self.shadow_limited} "
                f"limit_bytes={self.limit_bytes} limit_count={self.limit_count} "
                f"limit_deadline={self.limit_deadline} limit_ingress_peak_bytes={self.limit_ingress_peak_bytes}")

    def _observe_ingress(self, now, cost, packet, kernel_ns):
        # Diagnostic only. A burst observed here may belong to the network
        # or to the VPS socket wake; it does not grant extra sending credit.
        while self.ingress_window and (len(self.ingress_window)>=64 or
                                      now-self.ingress_window[0][0]>=SHAPE_MAX_DELAY):
            self.ingress_wire-=self.ingress_window.popleft()[1]
        identity=self.trace.identity(packet) if self.burst_trace else None
        self.ingress_window.append((now,cost,identity,kernel_ns))
        self.ingress_wire+=cost

    @staticmethod
    def burst_evidence(rows):
        origin=rows[0][0]
        stamps=[r[3] for r in rows]
        # Reject missing timestamps, clock steps and impossible ordering;
        # a missing kernel clock is NOT a zero-duration ingress burst.
        valid=all(s is not None for s in stamps) and all(
            0<=b-a<=2_000_000_000 for a,b in zip(stamps,stamps[1:])) and stamps[-1]-stamps[0]<=2_000_000_000
        return b"".join(BURST_ROW.pack(*identity,cost,round((now-origin)*1e6),
                            (stamp-stamps[0])//1000 if valid else -1)
                        for now,cost,identity,stamp in rows)

    def cookie(self, source, request, bucket):
        address = socket.inet_aton(source[0]) + struct.pack("!H", source[1])
        return sign(self.cookie_key, request[4:6] + request[8:24] + address + struct.pack("!Q", bucket))[:16]

    def reply(self, request, op, data, address=b"\0" * 6):
        message = request[:6] + bytes([op, 0]) + request[8:24] + data + address + bytes(18)
        return message + sign(self.keys[request[4]], message)

    def expire(self, now):
        if self.lease and (self.lease["until"] <= now or now-self.lease["last"] >= 14):
            self.discard_pending()
            self.lease = None
            for role in (0,1): self.proved.pop((RELAY,role),None)

    def request(self, request, source, now):
        if len(request) != SIZE or request[:4] != b"SCB1":
            return None
        role, phase, op, reserved = request[4:8]
        if role in (0,1): self.requests[role]+=1
        if (role not in (0, 1) or phase not in (DIRECT, RELAY) or op not in (HELLO, PROOF) or reserved
                or not any(request[8:24]) or any(request[40:64])
                or not hmac.compare_digest(request[64:], sign(self.keys[role], request[:64]))):
            return None
        self.valid[role]+=1
        address = ipaddress.IPv4Address(source[0])
        if not address.is_global or address.is_multicast or source[1] < 1024:
            return None
        bucket = int(now) // 3
        if op == HELLO:
            if any(request[24:40]):
                return None
            return self.reply(request, CHALLENGE, self.cookie(source, request, bucket))
        if not any(hmac.compare_digest(request[24:40], self.cookie(source, request, b)) for b in (bucket, max(0, bucket - 1))):
            return None
        self.proofs[role]+=1
        nonce = request[8:24]
        self.expire(now)
        if phase == RELAY and self.lease:
            mine = self.lease["roles"][role]
            if (source, nonce) != mine:
                return None
            # A datagram alone never renews the absolute lease. Require a
            # fresh MAC/cookie proof from BOTH original endpoint identities.
            lease=self.lease
            lease["proved_at"][role]=now
            lease["until"]=min(lease["hard_stop"],max(lease["until"],min(lease["proved_at"])+75))
        self.proved[(phase, role)] = (source, nonce, now + 5)
        other = self.proved.get((phase, 1 - role))
        if other is None or other[2] < now or other[0] == source:
            return None
        if phase == RELAY and self.lease is None:
            order = [(source, nonce), (other[0], other[1])]
            if role:
                order.reverse()
            self.lease = dict(until=now + (700 if self.trace else 130), last=now, roles=order,
                              hard_stop=now+4*3600+120, proved_at=[now,now],
                              credit=[BURST, BURST], updated=[now, now],
                              pending=deque(), pending_wire=0, shadow_at=now, shadow_credit=BURST)
        peer, peer_nonce, _ = other
        self.offers[role]+=1
        return self.reply(request, OFFER, peer_nonce, socket.inet_aton(peer[0]) + struct.pack("!H", peer[1]))

    def _refill(self, lease, role, now):
        # Refill only against elapsed monotonic time, never against
        # predicted departure time or a repeated scheduler wake.
        elapsed = max(0, now - lease["updated"][role])
        lease["credit"][role] = min(BURST, lease["credit"][role] + elapsed * self.bytes_per_second)
        lease["updated"][role] = max(now, lease["updated"][role])
        return lease["credit"][role]

    def _limit(self, role, packet):
        self.dropped += 1
        if role==0:
            self.downlink_limited+=1
            if self.trace: self.trace.mark(packet,2)

    def _count_without_queue(self, lease, now, cost):
        # Counterfactual for this exact authenticated arrival sequence;
        # this meter never makes send decisions or emits extra traffic.
        credit=min(BURST,lease["shadow_credit"]+
                   max(0,now-lease["shadow_at"])*self.bytes_per_second)
        lease["shadow_at"]=max(now,lease["shadow_at"])
        if credit<cost: self.shadow_limited+=1
        else: credit-=cost
        lease["shadow_credit"]=credit

    def _send(self, lease, role, packet, now, send):
        lease["credit"][role] -= len(packet)+28
        lease["last"] = now
        dest=lease["roles"][1-role][0]
        if send is not None:
            try:
                if send(packet,dest)!=len(packet): raise OSError
            except OSError:
                if role==0 and self.trace: self.trace.mark(packet,3)
                return None
        if role==0 and self.trace: self.trace.mark(packet,1)
        self.tx += 1
        return dest

    def discard_pending(self):
        lease=self.lease
        if not lease: return
        while lease["pending"]:
            _,packet=lease["pending"].popleft()
            self.queue_cancelled+=1
            self._limit(0,packet)
        lease["pending_wire"]=0

    def flush_downlink(self, now, send):
        """Send due packets under the same bucket; return seconds to next due."""
        self.expire(now)
        lease=self.lease
        if not lease or not lease["pending"]: return None
        while lease["pending"]:
            received,packet=lease["pending"][0]
            age=now-received
            cost=len(packet)+28
            if age >= SHAPE_MAX_DELAY:
                lease["pending"].popleft()
                lease["pending_wire"]-=cost
                self.queue_expired+=1
                self._limit(0,packet)
                continue
            credit=self._refill(lease,0,now)
            if credit < cost:
                return min(SHAPE_MAX_DELAY-age,(cost-credit)/self.bytes_per_second)
            lease["pending"].popleft()
            lease["pending_wire"]-=cost
            if self._send(lease,0,packet,now,send) is not None:
                self.queued_sent+=1
                self.queue_peak_us=max(self.queue_peak_us,int(age*1_000_000))
        return None

    def forward(self, packet, source, now, send=None, kernel_ns=None):
        self.expire(now)
        lease = self.lease
        if lease is None or now >= lease["until"] or not 32 <= len(packet) <= 1328 or packet[1:4] != b"\0\0\0":
            return None
        # BoringTun can emit a valid unpadded transport datagram. Its outer
        # header, maximum size and proven source still have to match; the
        # destination independently authenticates the ciphertext.
        if not ((packet[0] == 1 and len(packet) == 148) or (packet[0] == 2 and len(packet) == 92)
                or (packet[0] == 3 and len(packet) == 64)
                or (packet[0] == 4 and (len(packet) == 32 or len(packet) >= 52))):
            return None
        role = next((i for i, r in enumerate(lease["roles"]) if r[0] == source), None)
        if role is None:
            return None
        self.rx += 1
        # Only the authorized host's encrypted stream data may wait. Never
        # defer handshakes, keepalives or the phone's upstream input/control.
        paced = self.smooth_downlink and role==0 and packet[0]==4 and len(packet)>=52
        if paced and lease["pending"]:
            self.flush_downlink(now,send)
        cost = len(packet) + 28
        if paced and self.trace:
            self._observe_ingress(now,cost,packet,kernel_ns)
        if self.smooth_downlink and role==0:
            self._count_without_queue(lease,now,cost)
        credit = self._refill(lease,role,now)
        if credit >= cost and not (paced and lease["pending"]):
            return self._send(lease,role,packet,now,send)
        if paced:
            wire=lease["pending_wire"]+cost
            predicted=max(0,wire-credit)/self.bytes_per_second
            if (len(lease["pending"])<self.pending_count and wire<=self.pending_bytes
                    and predicted<SHAPE_MAX_DELAY and now+predicted<lease["until"]):
                lease["pending"].append((now,packet))
                lease["pending_wire"]=wire
                self.queued+=1
                self.queue_peak_bytes=max(self.queue_peak_bytes,wire)
                return None
            if len(lease["pending"])>=self.pending_count:
                self.limit_count+=1
            elif wire>self.pending_bytes:
                self.limit_bytes+=1
            else:
                self.limit_deadline+=1
            if self.trace:
                self.limit_ingress_peak_bytes=max(self.limit_ingress_peak_bytes,self.ingress_wire)
                # A bandwidth probe may make the largest encrypted burst. Save
                # one bounded peak per 12 s; only Windows can identify VIDEO.
                if self.burst_trace:
                    slot=int(now//12)
                    previous=self.peak_windows.get(slot)
                    if ((previous is None and len(self.peak_windows)<68) or
                        (previous and self.ingress_wire>previous[0])):
                        self.peak_windows[slot]=(self.ingress_wire,tuple(self.ingress_window))
        self._limit(role,packet)
        return None


def receive_one(channel, broker, expires, clock=time.monotonic, stamp_opt=0):
    kernel_ns=None
    if stamp_opt:
        packet,anc,flags,source=channel.recvmsg(1329,socket.CMSG_SPACE(16))
        kernel_ns=kernel_stamp(anc,flags,stamp_opt)
    else:
        packet,source=channel.recvfrom(1329)
    # The read can block. Charge against the monotonic clock at receipt,
    # including time spent waiting, with the same per-direction rate/burst.
    now = clock()
    if now >= expires: return
    if not packet.startswith(b"SCB1"):
        broker.forward(packet,source,now,channel.sendto,kernel_ns)
        return
    response = broker.request(packet, source, now)
    if response is not None:
        try:
            channel.sendto(response, source)
        except OSError:
            pass


class ShortTrialSocket:
    """All directions combined; an independent byte and time bound for one opt-in trial."""
    MAX_BYTES=115_000_000
    def __init__(self,channel,clock=time.monotonic):
        self.channel,self.clock=channel,clock
        self.at=clock(); self.credit=8192; self.charged=0; self.exhausted=False
    def __getattr__(self,key): return getattr(self.channel,key)
    def sendto(self,data,dest):
        cost=len(data)+28  # listener is IPv4/UDP, includes its outer headers
        now=self.clock()
        self.credit=min(8192,self.credit+max(0,now-self.at)*3_750_000)
        self.at=max(now,self.at)
        if self.charged+cost>self.MAX_BYTES:
            self.exhausted=True
            raise BlockingIOError
        if self.credit<cost: raise BlockingIOError
        n=self.channel.sendto(data,dest)
        self.credit-=cost; self.charged+=cost
        return n


def main():
    args=sys.argv[1:]
    high=args in (["soak-shape","high8"],["shape","high8"])
    standard=args in (["soak-shape","short30"],["shape","short30"])
    if high or standard: args=args[:1]
    smooth=args in (["soak-shape"],["shape"])
    soak=args in (["soak-shape"],["soak"])
    if args and not (soak or smooth): raise ValueError
    keys = sys.stdin.buffer.read(64)
    salt=sys.stdin.buffer.read(16) if soak else None
    if soak and len(salt)!=16: raise ValueError
    broker = Broker((keys[:32], keys[32:]),trace=PacketTrace(salt) if soak else None,
                    smooth_downlink=smooth,wire_kbps=30000 if standard else 8000 if high else 1800)
    if high: print("companion_broker_wire_cap_kbps=8000",flush=True)
    if standard: print("companion_broker_wire_cap_kbps=30000",flush=True)
    del keys
    stop = threading.Event()
    def wait_for_close():
        # The owning, pinned SSH channel is the lifetime of this process.
        sys.stdin.buffer.read(1)
        stop.set()
    threading.Thread(target=wait_for_close,daemon=True).start()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
        # No reuse options: existing listeners cause this process to fail.
        channel.bind(("0.0.0.0", PORT))
        stamp_opt=timestamp_mode(channel) if broker.burst_trace else 0
        if smooth:
            channel.setblocking(False)
            print("companion_broker_shape_active=1",flush=True)
        else:
            channel.settimeout(.25)
        print("companion_broker_listening=1", flush=True)
        if standard: channel=ShortTrialSocket(channel)
        expires = time.monotonic() + (110 if standard else 785 if soak else 580)
        sample = time.monotonic() + 2
        while not stop.is_set() and time.monotonic() < expires and not (standard and channel.exhausted):
            now = time.monotonic()
            if now >= sample:
                print(f"companion_broker_forward rx={broker.rx} tx={broker.tx} limited={broker.dropped}", flush=True)
                groups=(broker.requests,broker.valid,broker.proofs,broker.offers)
                print("companion_broker_register "+" ".join(f"{k}_h={v[0]} {k}_p={v[1]}"
                    for k,v in zip(("seen","valid","proof","offer"),groups)),flush=True)
                sample = now + 3
            try:
                if smooth:
                    wait=broker.flush_downlink(time.monotonic(),channel.sendto)
                    if not select.select([channel],[],[],.25 if wait is None else max(.00005,wait))[0]:
                        continue
                receive_one(channel, broker, expires, stamp_opt=stamp_opt)
            except (socket.timeout,BlockingIOError):
                continue
    if standard: print(f"companion_broker_trial_wire_bytes={channel.charged}",flush=True)
    if smooth:
        broker.discard_pending()
        print(broker.shape_stats(),flush=True)
    if broker.trace:
        for _,rows in broker.peak_windows.values():
            print("companion_broker_peak data="+base64.b64encode(broker.burst_evidence(rows)).decode("ascii"),flush=True)
        broker.trace.dump()
    print("companion_broker_stopped=1",flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError):
        print("companion_broker_unavailable=1", flush=True)
        raise SystemExit(4) from None
