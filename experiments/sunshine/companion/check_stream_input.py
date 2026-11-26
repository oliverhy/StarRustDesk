import socket
import threading
import time
import unittest

from stream_input import HEADER, TICK, decode, serve


class FakeSocket:
    def __init__(self, sock): self.sock=sock
    def __getattr__(self, name): return getattr(self.sock,name)
    def pending(self): return 0


class FakeSink:
    def __init__(self):
        self.keys=set()
        self.buttons=set()
        self.received=threading.Event()

    def permitted(self): return True

    def handle(self,kind,down,a,b,text):
        if kind==3:
            (self.buttons.add if down else self.buttons.discard)(a)
        elif kind==5:
            (self.keys.add if down else self.keys.discard)(a)
        if self.keys and self.buttons: self.received.set()
        return 1

    def release(self):
        n=len(self.keys)+len(self.buttons)
        self.keys.clear()
        self.buttons.clear()
        return n


class InputContract(unittest.TestCase):
    def test_frame_bounds(self):
        self.assertEqual(decode(1,0,0,65535,b""),(1,0,0,65535,""))
        self.assertEqual(decode(2,0,65532,3,b""),(2,0,-4,3,""))
        self.assertEqual(decode(6,0,0,0,"测试".encode()),(6,0,0,0,"测试"))
        for value in ((3,1,6,0,b""), (5,2,16,0,b""), (5,1,255,0,b""),
                      (7,0,0,1,b""), (6,0,0,0,b"x\n"), (6,0,1,0,b"x"),
                      (6,0,0,0,b"x"*257)):
            with self.subTest(kind=value[0]), self.assertRaises(ValueError):
                decode(*value)

    def session(self,wrapper=FakeSocket):
        host,phone=socket.socketpair()
        sink,events=FakeSink(),[]
        worker=threading.Thread(target=serve,args=(wrapper(host),lambda:True,sink,events.append),daemon=True)
        phone.settimeout(2)
        worker.start()
        self.addCleanup(host.close)
        self.addCleanup(phone.close)
        def read(n):
            b=bytes()
            while len(b)<n:
                part=phone.recv(n-len(b))
                self.assertTrue(part)
                b+=part
            return b
        self.assertEqual(read(4),b"OKI1")
        token=TICK.unpack(read(4))[0]
        return phone,sink,events,worker,token

    def test_watchdog_releases_reliable_button_and_key_on_silence(self):
        phone,sink,events,worker,token=self.session()
        phone.sendall(HEADER.pack(token,0,0,0,0,0) + HEADER.pack(token,5,1,16,0,0) +
                      HEADER.pack(token,3,1,1,0,0))
        self.assertTrue(sink.received.wait(.5))
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertFalse(sink.keys or sink.buttons)
        self.assertIn("reason=watchdog",events[-1])
        self.assertIn("released=2 residual=0",events[-1])
        self.assertIn("injected=0",events[-1])
        self.assertGreaterEqual(int(events[-1].split("ack_silence_ms=")[1].split()[0]),650)

    def test_incomplete_tls_record_read_can_resume_without_replaying_input(self):
        class DelayedRecord(FakeSocket):
            waits=2
            def recv(self,n):
                if self.waits:
                    self.waits-=1
                    raise TimeoutError
                return self.sock.recv(min(n,7))
        phone,sink,events,worker,token=self.session(DelayedRecord)
        phone.sendall(HEADER.pack(token,0,0,0,0,0)+HEADER.pack(token,3,1,1,0,0)+HEADER.pack(token,5,1,16,0,0))
        self.assertTrue(sink.received.wait(.5))
        phone.shutdown(socket.SHUT_RDWR)
        worker.join(1.2)
        self.assertIn("released=2 residual=0",events[-1])
        self.assertIn("read_waits=2",events[-1])
        self.assertIn("button=1 wheel=0 key=1",events[-1])

    def test_partial_traffic_cannot_keep_pressed_keys_alive(self):
        phone,sink,events,worker,token=self.session()
        phone.sendall(HEADER.pack(token,0,0,0,0,0)+HEADER.pack(token,5,1,16,0,0)+
                      HEADER.pack(token,3,1,1,0,0)+HEADER.pack(token,0,0,0,0,0)[:3])
        self.assertTrue(sink.received.wait(.5))
        worker.join(1.2)
        self.assertFalse(worker.is_alive())
        self.assertIn("reason=watchdog",events[-1])
        self.assertIn("partial=1",events[-1])
        self.assertIn("released=2 residual=0",events[-1])

    def test_unacknowledged_stale_commands_not_delivered(self):
        phone,sink,events,worker,token=self.session()
        phone.sendall(HEADER.pack(token,5,1,16,0,0))
        worker.join(1.3)
        self.assertFalse(worker.is_alive())
        self.assertFalse(sink.keys)
        self.assertIn("reason=stale",events[-1])
        self.assertIn("key=0",events[-1])

    def test_fin_releases_only_owned_keys_and_buttons(self):
        phone,sink,events,worker,token=self.session()
        phone.sendall(HEADER.pack(token,0,0,0,0,0) + HEADER.pack(token,5,1,16,0,0) +
                      HEADER.pack(token,3,1,1,0,0))
        self.assertTrue(sink.received.wait(.5))
        phone.shutdown(socket.SHUT_RDWR)
        worker.join(1.0)
        self.assertFalse(worker.is_alive())
        self.assertFalse(sink.keys or sink.buttons)
        self.assertIn("released=2 residual=0",events[-1])


if __name__=="__main__":
    unittest.main()
