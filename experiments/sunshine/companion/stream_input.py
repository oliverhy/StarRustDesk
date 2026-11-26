"""Opt-in Windows input on the existing pinned TLS session route."""
from collections import deque
import ctypes as c
from ctypes import wintypes as w
import secrets
import select
import ssl
import struct
import time
from display_targets import geometry, native_relative_inside, physical_pixels, source_point, virtual_point


HEADER = struct.Struct("!IBBHHH")
TICK = struct.Struct("!I")
MAX_TEXT = 256
PERIOD = .12
LEASE = .78
KEYS = frozenset((*range(0x30,0x3a), *range(0x41,0x5b), *range(0x70,0x7c),
                  8,9,13,16,17,18,20,27,32,33,34,35,36,37,38,39,40,45,46,91,92,
                  0xa0,0xa1,0xa2,0xa3,0xa4,0xa5))


def signed(value):
    return value if value < 32768 else value - 65536


def decode(kind, switch, a, b, data):
    if kind == 6:
        if switch or a or b or not 0 < len(data) <= MAX_TEXT:
            raise ValueError("text_frame")
        value = data.decode("utf-8", "strict")
        if any(ord(ch) < 32 or 127 <= ord(ch) < 160 for ch in value):
            raise ValueError("text_controls")
        return kind, 0, 0, 0, value
    if data or switch not in (0,1): raise ValueError("frame_flags")
    if kind in (0,7) and not (switch or a or b): return kind,0,0,0,""
    if kind == 1 and not switch: return kind,0,a,b,""
    if kind == 2 and not switch and max(abs(signed(a)),abs(signed(b))) <= 4096:
        return kind,0,signed(a),signed(b),""
    if kind == 3 and not b and a in (1,2,3): return kind,switch,a,0,""
    if kind == 4 and not (switch or b) and 0 < abs(signed(a)) <= 8:
        return kind,0,signed(a),0,""
    if kind == 5 and not b and a in KEYS: return kind,switch,a,0,""
    raise ValueError("input_frame")


class Mouse(c.Structure):
    _fields_=[("x",w.LONG),("y",w.LONG),("data",w.DWORD),("flags",w.DWORD),
              ("time",w.DWORD),("extra",c.c_size_t)]


class Key(c.Structure):
    _fields_=[("vk",w.WORD),("scan",w.WORD),("flags",w.DWORD),
              ("time",w.DWORD),("extra",c.c_size_t)]


class Event(c.Union):
    _fields_=[("mouse",Mouse),("key",Key)]


class Input(c.Structure):
    _fields_=[("kind",w.DWORD),("event",Event)]


class WindowsInput:
    def __init__(self, fixture=0, target=None, video=None):
        self.user=c.WinDLL("user32",use_last_error=True)
        self.user.SendInput.argtypes=(w.UINT,c.POINTER(Input),c.c_int)
        self.user.SendInput.restype=w.UINT
        self.user.GetForegroundWindow.restype=w.HWND
        self.user.GetAncestor.argtypes=(w.HWND,w.UINT)
        self.user.GetAncestor.restype=w.HWND
        self.user.WindowFromPoint.argtypes=(w.POINT,)
        self.user.WindowFromPoint.restype=w.HWND
        self.user.GetCursorPos.argtypes=(c.POINTER(w.POINT),)
        self.user.GetAsyncKeyState.argtypes=(c.c_int,)
        self.user.GetAsyncKeyState.restype=c.c_short
        self.fixture=fixture
        self.target,self.video=target,video
        self.point_valid=True
        self.keys=set()
        self.buttons=set()

    def permitted(self):
        return not self.fixture or self.user.GetForegroundWindow()==self.fixture

    def inside(self,x=None,y=None):
        if not self.fixture: return True
        point=w.POINT()
        if x is None:
            if not self.user.GetCursorPos(c.byref(point)): return False
        else:
            point.x=x
            point.y=y
        return self.user.GetAncestor(self.user.WindowFromPoint(point),2)==self.fixture

    def send(self,*events):
        rows=(Input*len(events))(*events)
        return self.user.SendInput(len(events),rows,c.sizeof(Input)) == len(events)

    @staticmethod
    def key(a,down,unicode=False):
        extended=a in (33,34,35,36,37,38,39,40,45,46,91,92,0xa3,0xa5)
        flags=(4 if unicode else int(extended)) | (0 if down else 2)
        return Input(1,Event(key=Key(0 if unicode else a,a if unicode else 0,flags,0,0)))

    @staticmethod
    def mouse(flags,x=0,y=0,data=0):
        return Input(0,Event(mouse=Mouse(x,y,data & 0xffffffff,flags,0,0)))

    @staticmethod
    def button_flag(a,down):
        return {1:(2,4),2:(8,16),3:(32,64)}[a][0 if down else 1]

    def handle(self,kind,down,a,b,text):
        if self.target and kind!=7:
            with physical_pixels(self.user):
                screens=geometry()
                if not any((s.name,s.rect)==(self.target.name,self.target.rect) for s in screens):
                    raise PermissionError("selected_monitor_changed")
                l,t,r,bottom=self.target.rect
                area=(min(s.rect[0] for s in screens),min(s.rect[1] for s in screens),
                      max(s.rect[2] for s in screens),max(s.rect[3] for s in screens))
                if kind in (1,2,3,4):
                    if not self.permitted(): raise PermissionError("test_target_not_foreground")
                    point=w.POINT()
                    if not self.user.GetCursorPos(c.byref(point)): return 0
                    if kind==1:
                        pos=source_point(self.target.rect,self.video,a,b)
                        self.point_valid=pos is not None
                        if pos is None: return 0
                    elif kind==2:
                        if not self.fixture and native_relative_inside(self.target.rect,point.x,point.y,a,b):
                            result=self._handle(kind,down,a,b,text)
                            self.point_valid=bool(result)
                            return result
                        pos=(min(r-1,max(l,point.x+a)),min(bottom-1,max(t,point.y+b)))
                    else:
                        if (down or kind==4) and (not self.point_valid or not (l<=point.x<r and t<=point.y<bottom)): return 0
                        return self._handle(kind,down,a,b,text)
                    if not self.inside(*pos): return 0
                    if not self.send(self.mouse(0xC001,*virtual_point(area,*pos))): raise OSError("windows_input_rejected")
                    self.point_valid=True
                    return 1
                return self._handle(kind,down,a,b,text)
        return self._handle(kind,down,a,b,text)

    def _handle(self,kind,down,a,b,text):
        if kind==7: return self.release()
        if not self.permitted(): raise PermissionError("test_target_not_foreground")
        success=True
        if kind==1:
            px=a*max(1,self.user.GetSystemMetrics(0)-1)//65535
            py=b*max(1,self.user.GetSystemMetrics(1)-1)//65535
            if not self.inside(px,py): return 0
            success=self.send(self.mouse(0x8001,a,b))
        elif kind==2:
            if self.fixture:
                point=w.POINT()
                if not self.user.GetCursorPos(c.byref(point)) or not self.inside(point.x+a,point.y+b):
                    return 0
                width,height=self.user.GetSystemMetrics(0),self.user.GetSystemMetrics(1)
                # Test relative actions stay inside the test window even if the
                # PC's mouse acceleration is enabled.
                x=max(0,min(65535,round((point.x+a)*65535/max(1,width-1))))
                y=max(0,min(65535,round((point.y+b)*65535/max(1,height-1))))
                success=self.send(self.mouse(0x8001,x,y))
            else:
                success=self.send(self.mouse(1,a,b))
        elif kind in (3,5):
            held=self.buttons if kind==3 else self.keys
            if bool(down)==(a in held): return 0
            if kind==3 and down and not self.inside(): return 0
            local_key={1:1,2:2,3:4}[a] if kind==3 else a
            if down and self.user.GetAsyncKeyState(local_key)&0x8000: return 0
            ev=self.mouse(self.button_flag(a,down)) if kind==3 else self.key(a,down)
            success=self.send(ev)
            if success:
                if down: held.add(a)
                else: held.discard(a)
        elif kind==4:
            if not self.inside(): return 0
            success=self.send(self.mouse(0x800,data=120*a))
        elif kind==6:
            # One IME commit, without clipboard access or an implicit Return.
            nodes=tuple(e for (unit,) in struct.iter_unpack("<H",text.encode("utf-16-le"))
                        for e in (self.key(unit,True,True),self.key(unit,False,True)))
            success=self.send(*nodes)
        if not success: raise OSError("windows_input_rejected")
        return 1

    def release(self):
        released=0
        for a in tuple(self.buttons):
            if self.send(self.mouse(self.button_flag(a,False))):
                self.buttons.remove(a)
                released+=1
        for a in tuple(self.keys):
            if self.send(self.key(a,False)):
                self.keys.remove(a)
                released+=1
        return released


def serve(tls, live, sink, note, muted=lambda:False):
    """A new challenge must be echoed before any action; old buffered data dies."""
    stamps=deque(maxlen=10)
    serial=secrets.randbelow(0xffffffff-8192)+1
    data=bytearray()
    started=time.monotonic()
    deadline=started+LEASE
    next_tick=0.
    ack_serial=0
    last_issued=0.
    counts=[0]*8
    max_heartbeat=0
    last_ack=last_rx=prev_turn=started
    peak_loop=ticks=read_waits=0
    stage="grant"
    injected=False
    status="closed"
    try:
        tls.settimeout(.18)
        tls.sendall(b"OKI1")
        note("companion_input_granted=1")
        while live():
            now=time.monotonic()
            peak_loop=max(peak_loop,round((now-prev_turn)*1000))
            prev_turn=now
            if now>=deadline:
                status="watchdog"
                break
            if not sink.permitted():
                status="focus"
                break
            # Only the programmatically bound self-test window can select
            # this. It emulates an input-lane blackhole, not a system change.
            if muted():
                injected=True
                stage="test_blackhole"
                time.sleep(min(.025,deadline-now))
                continue
            if now>=next_tick:
                serial=(serial+1)&0xffffffff or 1
                stamps.append((serial,now))
                stage="write_tick"
                # Never extend a lease on a write or retry a possibly partial write.
                tls.settimeout(min(.18,deadline-now))
                tls.sendall(TICK.pack(serial))
                next_tick=now+PERIOD
                ticks+=1
            stage="wait_reply"
            budget=min(.035,next_tick-time.monotonic(),deadline-time.monotonic())
            if budget<=0: continue
            if not tls.pending() and not select.select([tls],[],[],budget)[0]:
                continue
            remaining=min(.035,next_tick-time.monotonic(),deadline-time.monotonic())
            if remaining<=0: continue
            stage="read_reply"
            tls.settimeout(remaining)
            try:
                part=tls.recv(4096)
            except (TimeoutError,ssl.SSLWantReadError):
                # TCP readable need not mean a complete TLS record. Keep the
                # partial record in OpenSSL, but allow the next tick/deadline.
                read_waits+=1
                continue
            if not part: break
            last_rx=time.monotonic()
            data.extend(part)
            if len(data)>8192: raise ValueError("input_backlog")
            while len(data)>=HEADER.size:
                if not live(): return
                echo,kind,switch,a,b,sz=HEADER.unpack_from(data)
                if sz>MAX_TEXT: raise ValueError("input_length")
                size=HEADER.size+sz
                if len(data)<size: break
                payload=bytes(data[HEADER.size:size])
                del data[:size]
                action=decode(kind,switch,a,b,payload)
                now=time.monotonic()
                if now>=deadline:
                    status="watchdog"
                    return
                if not kind:
                    match=next((t for token,t in stamps if echo==token),0.)
                    if not match or now-match>=LEASE or match<=last_issued:
                        status="stale"
                        return
                    ack_serial=echo
                    last_issued=match
                    last_ack=now
                    deadline=match+LEASE
                    counts[0]+=1
                    max_heartbeat=max(max_heartbeat,round((now-match)*1000))
                    continue
                if not ack_serial or echo!=ack_serial:
                    status="stale"
                    return
                counts[kind]+=sink.handle(*action)
    except PermissionError:
        status="focus"
    except ValueError:
        status="protocol"
    except OSError:
        status="transport"
    finally:
        released=sink.release()
        # Retry a partial OS release; report a residual rather than claiming
        # success if Windows rejected a release (e.g. a secure desktop switch).
        if sink.keys or sink.buttons: released+=sink.release()
        now=time.monotonic()
        note(f"companion_input_closed reason={status} move={counts[1]+counts[2]} "
             f"button={counts[3]} wheel={counts[4]} key={counts[5]} text={counts[6]} "
             f"released={released+counts[7]} residual={len(sink.keys)+len(sink.buttons)} "
             f"heartbeats={counts[0]} max_heartbeat_ms={max_heartbeat} phase={stage} "
             f"ack_silence_ms={round((now-last_ack)*1000)} rx_silence_ms={round((now-last_rx)*1000)} "
             f"unanswered={ticks-counts[0]} partial={int(bool(data))} read_waits={read_waits} "
             f"host_loop_peak_ms={peak_loop} injected={int(injected)}")
