// Read the selected gateway's cached IPv4 neighbor state only. This does not
// ask Windows to resolve the neighbor, or expose the address or MAC in logs.
using System;
using System.Net;
using System.Runtime.InteropServices;

public sealed class TxGatewayCache
{
    // Windows SDK MIB_IPNET_ROW2 with an IPv4 SOCKADDR_INET at offset 0.
    [StructLayout(LayoutKind.Explicit, Size=88)]
    private struct NeighborRow
    {
        [FieldOffset(0)] public ushort family;
        [FieldOffset(4)] public uint ipv4;
        [FieldOffset(28)] public uint ifIndex;
        [FieldOffset(76)] public uint state;
        [FieldOffset(80)] public byte flags;
    }

    [DllImport("iphlpapi.dll")]
    private static extern uint GetIpNetEntry2(ref NeighborRow row);

    private readonly NeighborRow key;

    public TxGatewayCache(uint index, IPAddress gateway)
    {
        var bytes = gateway.GetAddressBytes();
        if (index == 0 || bytes.Length != 4) throw new ArgumentException();
        key = new NeighborRow {family=2, ipv4=BitConverter.ToUInt32(bytes,0), ifIndex=index};
    }

    public uint[] Read()
    {
        var row = key;
        uint error = GetIpNetEntry2(ref row);
        return new uint[] {error, error==0 ? row.state : 0, error==0 ? (uint)((row.flags>>1)&1) : 0};
    }
}
