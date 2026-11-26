"""Local Windows outputs only. Network peers select an index, never an OS identifier."""
import contextlib
import ctypes as c
from ctypes import wintypes as w
from dataclasses import dataclass
import json
import re


@dataclass(frozen=True)
class Monitor:
    name: str
    rect: tuple
    primary: bool
    guid: str = ""


@contextlib.contextmanager
def physical_pixels(user):
    f=user.SetThreadDpiAwarenessContext
    f.argtypes=[c.c_void_p]; f.restype=c.c_void_p
    old=f(c.c_void_p(-4))
    if not old: raise OSError("monitor_pixel_context_unavailable")
    try: yield
    finally: f(old)


def geometry():
    user=c.WinDLL("user32",use_last_error=True)
    class Info(c.Structure):
        _fields_=[("size",w.DWORD),("area",w.RECT),("work",w.RECT),("flags",w.DWORD),("name",w.WCHAR*32)]
    cb=c.WINFUNCTYPE(w.BOOL,w.HANDLE,w.HDC,c.POINTER(w.RECT),w.LPARAM)
    user.GetMonitorInfoW.argtypes=[w.HANDLE,c.POINTER(Info)]
    user.EnumDisplayMonitors.argtypes=[w.HDC,c.POINTER(w.RECT),cb,w.LPARAM]
    result=[]
    @cb
    def visit(handle,dc,area,unused):
        info=Info(); info.size=c.sizeof(info)
        if not user.GetMonitorInfoW(handle,c.byref(info)): return False
        r=info.area
        result.append(Monitor(info.name,(r.left,r.top,r.right,r.bottom),bool(info.flags&1)))
        return True
    with physical_pixels(user):
        if not user.EnumDisplayMonitors(None,None,visit,0): raise OSError("monitor_enumeration_failed")
    return result


def capture_catalog(host_log, screens):
    candidates=list(re.finditer(r"Currently available display devices\s*:\s*(\[)",host_log,re.I))
    for start in reversed(candidates):
        try: rows,_=json.JSONDecoder().raw_decode(host_log[start.start(1):])
        except ValueError: continue
        if not isinstance(rows,list): continue
        found=[]
        for s in screens:
            matches=[r for r in rows if isinstance(r,dict) and r.get("display_name")==s.name and
                     isinstance(r.get("info"),dict) and r["info"].get("primary") is s.primary and
                     re.fullmatch(r"\{[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}\}",str(r.get("device_id","")))]
            if len(matches)==1:
                found.append(Monitor(s.name,s.rect,s.primary,matches[0]["device_id"]))
        if (sum(s.primary for s in found)==1 and len(found)<=16 and
                len({s.guid.lower() for s in found})==len(found)):
            return sorted(found,key=lambda s:(not s.primary,s.name))
    return []


def encode_catalog(packet,screens,active):
    # SCH2 has two zero-padded C version strings. Old clients stop at the
    # first NUL; never shorten/overwrite either version, or the credentials.
    if len(packet)!=124 or not 0<=active<len(screens)<=16: return packet
    if b"\0" not in packet[92:116] or any(packet[116:]): return packet
    return packet[:116]+b"MON1"+bytes((len(screens),active,0,0))


def source_point(rect,video,a,b):
    # map the encoded frame's active content, excluding Sunshine letterboxing
    l,t,r,d=rect; sw,sh=r-l,d-t; vw,vh=video
    if min(sw,sh,vw,vh)<2: return None
    scale=min(vw/sw,vh/sh); aw,ah=sw*scale,sh*scale
    x=a*(vw-1)/65535-(vw-aw)/2; y=b*(vh-1)/65535-(vh-ah)/2
    if x<-.5 or y<-.5 or x>aw-.5 or y>ah-.5: return None
    return (l+max(0,min(sw-1,round(x*(sw-1)/max(1,aw-1)))),
            t+max(0,min(sh-1,round(y*(sh-1)/max(1,ah-1)))))


def virtual_point(rect,x,y):
    l,t,r,b=rect
    if not l<=x<r or not t<=y<b: raise ValueError("monitor_point_outside")
    # SendInput selects pixel bins; hit the centre of the bin, including the
    # last pixel of a screen and monitors with a negative desktop origin.
    return (min(65535,((x-l)*2+1)*32768//(r-l)),min(65535,((y-t)*2+1)*32768//(b-t)))


def native_relative_inside(rect,x,y,dx,dy):
    # Preserve native relative mouse semantics away from edges, allowing room
    # for pointer acceleration. Buttons independently recheck the actual output.
    l,t,r,b=rect
    return l<=x<r and t<=y<b and l<=x+4*dx<r and t<=y+4*dy<b
