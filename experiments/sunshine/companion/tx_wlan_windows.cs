// Read-only notification listener for the test socket's existing Wi-Fi
// interface. Never requests a scan or reads any notification payload.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class TxWlanEvents : IDisposable
{
    private const uint Acm = 0x00000008;
    private const int Limit = 64;
    [StructLayout(LayoutKind.Sequential)]
    private struct Notification
    {
        public uint source, code;
        public Guid adapter;
        public uint size;
        public IntPtr data;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void Notify(ref Notification notification, IntPtr context);
    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")]
    private static extern uint WlanRegisterNotification(IntPtr handle, uint source, bool ignoreDuplicate, Notify callback,
        IntPtr context, IntPtr reserved, IntPtr previousSource);
    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
    [DllImport("wlanapi.dll")]
    private static extern uint WlanQueryInterface(IntPtr handle, ref Guid adapter, uint opcode,
        IntPtr reserved, out uint bytes, out IntPtr data, IntPtr valueType);
    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr data);

    // SDK wlanapi.h: three u64s, two sets of 12 MAC u64s, PHY count,
    // 8-byte alignment, then 18 u64s per PHY. No MAC addresses are read.
    private const int CountOffset=(3+12*2)*8, PhyOffset=224, PhyBytes=18*8;
    private static readonly int[] counters={0,2,3,5,9,10,17};
    public string ReadPhy()
    {
        long start=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Guid id=adapter;
        uint length=0, error=6;
        IntPtr p=IntPtr.Zero;
        ulong[] totals=new ulong[counters.Length];
        try {
            if(handle!=IntPtr.Zero)
                error=WlanQueryInterface(handle,ref id,0x10000101,IntPtr.Zero,out length,out p,IntPtr.Zero);
            if(error==0) {
                int count=p!=IntPtr.Zero && length>=PhyOffset ? Marshal.ReadInt32(p,CountOffset) : 0;
                if(count<1 || count>64 || length<PhyOffset+count*PhyBytes) error=13;
                else for(int phy=0;phy<count;phy++) for(int j=0;j<counters.Length;j++)
                    totals[j]=checked(totals[j]+unchecked((ulong)Marshal.ReadInt64(p,PhyOffset+phy*PhyBytes+8*counters[j])));
            }
        } catch(OverflowException) { error=534; }
        finally { if(p!=IntPtr.Zero) WlanFreeMemory(p); }
        return "wlan_phy "+start+" "+DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()+" "+error+" "+String.Join(" ",totals);
    }

    public string ReadQuality()
    {
        long start=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Guid id=adapter;
        uint length=0,error=6;
        IntPtr p=IntPtr.Zero;
        int quality=0,rx=0,tx=0;
        try {
            if(handle!=IntPtr.Zero)
                error=WlanQueryInterface(handle,ref id,19,IntPtr.Zero,out length,out p,IntPtr.Zero);
            // Only the fixed fields of WLAN_REALTIME_CONNECTION_QUALITY.
            // No BSS list, AP addresses, SSID, active scan or guessed RSSI.
            if(error==0) {
                if(p==IntPtr.Zero || length<24) error=13;
                else {
                    quality=Marshal.ReadInt32(p,4); rx=Marshal.ReadInt32(p,8); tx=Marshal.ReadInt32(p,12);
                    if(quality<0 || quality>100 || rx<0 || tx<0) { error=13; quality=rx=tx=0; }
                }
            }
        } finally { if(p!=IntPtr.Zero) WlanFreeMemory(p); }
        return "wlan_quality "+start+" "+DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()+" "+error+" "+quality+" "+rx+" "+tx;
    }

    private uint ReadInt(uint opcode,out int value)
    {
        Guid id=adapter;
        uint length;
        IntPtr data=IntPtr.Zero;
        value=0;
        try {
            uint error=WlanQueryInterface(handle,ref id,opcode,IntPtr.Zero,out length,out data,IntPtr.Zero);
            if(error!=0) return error;
            if(data==IntPtr.Zero || length!=4) return 13;
            value=Marshal.ReadInt32(data);
            return 0;
        } finally { if(data!=IntPtr.Zero) WlanFreeMemory(data); }
    }

    public string ReadRadio()
    {
        long start=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        int rssi=0, state=0;
        uint re=handle!=IntPtr.Zero ? ReadInt(0x10000102,out rssi) : 6;
        uint se=handle!=IntPtr.Zero ? ReadInt(6,out state) : 6;
        if(re==0 && (rssi>=0 || rssi < -127)) { re=13; rssi=0; }
        if(se==0 && (state<0 || state>7)) { se=13; state=0; }
        return "wlan_radio "+start+" "+DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()+" "+re+" "+rssi+" "+se+" "+state;
    }

    private readonly Guid adapter;
    private readonly Queue<string> events = new Queue<string>();
    private readonly Notify callback;
    private IntPtr handle;
    public uint Status { get; private set; }
    public TxWlanEvents(Guid current)
    {
        adapter = current;
        callback = OnNotice;
        uint negotiated;
        Status = WlanOpenHandle(2,IntPtr.Zero,out negotiated,out handle);
        if (Status == 0)
            Status = WlanRegisterNotification(handle,Acm,false,callback,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
    }

    private void OnNotice(ref Notification n, IntPtr context)
    {
        if (n.source != Acm || n.adapter != adapter) return;
        // Scan completion/failure/refresh and association or link changes.
        switch (n.code) {
            case 7: case 8: case 9: case 10: case 11:
            case 20: case 21: case 26: case 27: break;
            default: return;
        }
        lock (events)
        {
            if (events.Count >= Limit) events.Dequeue();
            events.Enqueue("wlan_event " + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + " " + n.code);
        }
    }

    public string[] Drain()
    {
        lock (events)
        {
            var rows = events.ToArray();
            events.Clear();
            return rows;
        }
    }

    public void Dispose()
    {
        if (handle != IntPtr.Zero)
        {
            WlanRegisterNotification(handle,0,false,null,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            WlanCloseHandle(handle,IntPtr.Zero);
            handle=IntPtr.Zero;
        }
        GC.KeepAlive(callback);
    }
}
