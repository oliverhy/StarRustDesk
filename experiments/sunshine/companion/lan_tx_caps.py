"""Read-only Windows LAN preflight. A capability is never a packet timestamp."""
import ctypes as c


# Windows SDK iphlpapi.h (the Active/Supported API, not the older Current API).
class Hardware(c.Structure):
    _fields_=[('ptp',c.c_uint8*8),('rx',c.c_uint8),('all_tx',c.c_uint8),('tagged_tx',c.c_uint8)]


class Software(c.Structure):
    _fields_=[('rx',c.c_uint8),('all_tx',c.c_uint8),('tagged_tx',c.c_uint8)]


class Caps(c.Structure):
    _fields_=[('hz',c.c_uint64),('cross',c.c_uint8),('hw',Hardware),('sw',Software)]


def result(code,buf):
    if code:return dict(status='not_supported' if code==50 else 'query_failed',win32=code)
    return dict(status='read',hardware_udp_tx=bool(buf.hw.all_tx or buf.hw.tagged_tx),
                software_udp_tx=bool(buf.sw.all_tx or buf.sw.tagged_tx))


def query(index):
    if type(index)!=int or not 0<index<2**32:return dict(status='no_bound_interface')
    try:
        dll=c.WinDLL('iphlpapi.dll',winmode=0x800) # LOAD_LIBRARY_SEARCH_SYSTEM32
        cv=dll.ConvertInterfaceIndexToLuid
        cv.argtypes=(c.c_uint32,c.POINTER(c.c_uint64));cv.restype=c.c_uint32
        luid=c.c_uint64()
        e=cv(index,c.byref(luid))
        if e:return dict(status='interface_unavailable',win32=e)
        out=dict(status='queried',packet_time_observed=False)
        for label,name in [('active','GetInterfaceActiveTimestampCapabilities'),('supported','GetInterfaceSupportedTimestampCapabilities')]:
            fn=getattr(dll,name,None)
            if fn is None:
                out[label]=dict(status='api_unavailable');continue
            fn.argtypes=(c.POINTER(c.c_uint64),c.POINTER(Caps));fn.restype=c.c_uint32
            buf=Caps();out[label]=result(fn(c.byref(luid),c.byref(buf)),buf)
        return out
    except (AttributeError,OSError):return dict(status='api_unavailable')
