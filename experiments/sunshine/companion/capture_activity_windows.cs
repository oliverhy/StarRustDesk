// Private comparison of desktop presents against the stream's first
// encoded packet. Never maps a texture, reads pixels or changes focus.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class CaptureActivityWindows
{
    private const int Timeout = unchecked((int)0x887a0027);
    private const int NotFound = unchecked((int)0x887a0002);
    private static readonly Guid Factory1 = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    private static readonly Guid Output1 = new Guid("00cddea8-939b-4b83-a340-a685226666cc");

    // dwmapi.h uses pack(1). Windows 8.1+ requires HWND=NULL: these are
    // compositor-wide counters, NOT proof that the video player submitted.
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    private struct DwmTiming {
        public uint cbSize, refreshNumerator, refreshDenominator;
        public long refreshPeriod;
        public uint composeNumerator, composeDenominator;
        public long vblank;
        public ulong refresh;
        public uint dxRefresh;
        public long compose;
        public ulong frame;
        public uint dxPresent;
        public ulong refreshFrame, submitted;
        public uint dxSubmitted;
        public ulong confirmed;
        public uint dxConfirmed;
        public ulong refreshConfirmed;
        public uint dxRefreshConfirmed;
        public ulong late;
        public uint outstanding;
        public ulong displayed;
        public long qpcDisplayed;
        public ulong refreshDisplayed, complete;
        public long qpcComplete;
        public ulong pending;
        public long qpcPending;
        public ulong framesDisplayed, framesComplete, framesPending, available, dropped, missed,
                     refreshNextDisplayed, refreshNextPresented, refreshesDisplayed, refreshesPresented,
                     refreshStarted, pixelsReceived, pixelsDrawn, buffersEmpty;
    }
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, ref DwmTiming timing);

    private static bool ReadComposition(out DwmTiming data) {
        data = new DwmTiming();
        data.cbSize = (uint)Marshal.SizeOf(typeof(DwmTiming));
        return DwmGetCompositionTimingInfo(IntPtr.Zero, ref data)==0;
    }
    private static bool CompositionSuitable() {
        // Some modern drivers provide per-query sequence numbers, not screen
        // counters: four immediate reads advance even on an unchanged desktop.
        DwmTiming a,b;
        if (!ReadComposition(out a) || a.refreshPeriod<=0) return false;
        for(int tries=0;tries<3;tries++) {
            long begin=Stopwatch.GetTimestamp();
            if (!ReadComposition(out a)) return false;
            for(int j=0;j<5;j++) if (!ReadComposition(out b)) return false;
            if (!ReadComposition(out b)) return false;
            if (Stopwatch.GetTimestamp()-begin>=a.refreshPeriod/2) continue;
            // One refresh could straddle the reads; two cannot.
            if (b.refresh<a.refresh || b.refresh-a.refresh>1 || b.frame<a.frame || b.frame-a.frame>1) return false;
            Thread.Sleep(90);
            return ReadComposition(out b) && b.refresh>a.refresh+1;
        }
        return false;
    }
    private static void SampleComposition() {
        long at = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), qpc = Stopwatch.GetTimestamp();
        DwmTiming data;
        bool ok = ReadComposition(out data);
        long us = (Stopwatch.GetTimestamp()-qpc)*1000000/Stopwatch.Frequency;
        if (ok)
            Console.WriteLine("capture_dwm {0} {1} {2} {3} {4} {5}", at, us, data.refresh,
                              data.frame, data.submitted, data.confirmed);
    }

    // Only inspect the loopback Sunshine child PID passed by the controller.
    // Names and IDs are used for filtering in memory; output is role codes.
    [DllImport("kernel32.dll")] private static extern IntPtr OpenThread(uint access, bool inherit, int threadId);
    [DllImport("kernel32.dll")] private static extern uint GetProcessIdOfThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern int GetThreadDescription(IntPtr thread, out IntPtr description);
    [DllImport("kernel32.dll")] private static extern bool GetThreadTimes(IntPtr thread,
        out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll")] private static extern bool QueryThreadCycleTime(IntPtr thread, out ulong cycles);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr ptr);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr LoadLibrary(string file);
    [DllImport("kernel32.dll")] private static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);

    [StructLayout(LayoutKind.Sequential)]
    private struct EncoderSession
    {
        public uint id, pid, vgpu, codec, width, height, fps, latencyUs;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int NvCall();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int NvCount(out uint count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int NvDevice(uint i, out IntPtr device);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int NvSessions(IntPtr device,
        ref uint count, [Out] EncoderSession[] sessions);

    private sealed class HostProbe : IDisposable
    {
        private Process process;
        private readonly int owner;
        private readonly Dictionary<int,int> roles = new Dictionary<int,int>();
        private IntPtr nvml;
        private NvCall shutdown;
        private NvSessions sessions;
        private readonly List<IntPtr> devices = new List<IntPtr>();
        private readonly EncoderSession[] buffer = new EncoderSession[32];
        private readonly int[] roleCounts = new int[5], states = new int[5], waits = new int[5];
        private readonly long[] cpuUs = new long[5];
        private readonly bool lan;
        private readonly long[] origins = new long[5], generations = new long[5];
        private readonly ulong[] seenCycles = new ulong[5];
        private readonly bool[] hasCycles = new bool[5];

        public HostProbe(int pid, bool fullHd)
        {
            owner = pid; lan = fullHd;
            if (pid == 0) return;
            try
            {
                var target = Process.GetProcessById(pid);
                if (target.ProcessName.Equals("sunshine", StringComparison.OrdinalIgnoreCase)) process = target;
                else target.Dispose();
            }
            catch (ArgumentException) { }
            catch (System.ComponentModel.Win32Exception) { }
            if (process == null) return;
            // Load only the installed system driver library, never a DLL from
            // the test directory or PATH. The GPU query is optional.
            nvml = LoadLibrary(Path.Combine(Environment.SystemDirectory, "nvml.dll"));
            if (nvml == IntPtr.Zero) return;
            var init = Export<NvCall>("nvmlInit_v2");
            var stop = Export<NvCall>("nvmlShutdown");
            var count = Export<NvCount>("nvmlDeviceGetCount_v2");
            var device = Export<NvDevice>("nvmlDeviceGetHandleByIndex_v2");
            var query = Export<NvSessions>("nvmlDeviceGetEncoderSessions");
            if (init == null || stop == null || count == null || device == null || query == null || init() != 0) return;
            shutdown = stop;
            uint n;
            if (count(out n) != 0) return;
            sessions = query;
            for (uint i=0; i<Math.Min(8u,n); i++)
            {
                IntPtr handle;
                if (device(i,out handle) == 0) devices.Add(handle);
            }
        }

        private T Export<T>(string name) where T : class
        {
            IntPtr fn=GetProcAddress(nvml,name);
            return fn==IntPtr.Zero ? null : (Marshal.GetDelegateForFunctionPointer(fn,typeof(T)) as T);
        }

        private static int Role(IntPtr thread)
        {
            IntPtr ptr;
            // Windows can return nonzero success HRESULTs from this API.
            if (GetThreadDescription(thread,out ptr)<0 || ptr==IntPtr.Zero) return 0;
            try
            {
                switch(Marshal.PtrToStringUni(ptr))
                {
                    case "video::capture": return 1;
                    case "session::video": return 2;
                    case "stream::videoBroadcast": return 3;
                    case "video::capture_sync": return 4;
                    default: return 0;
                }
            }
            finally { LocalFree(ptr); }
        }

        public void Sample(int index)
        {
            if (process == null) return;
            try
            {
                if (process.HasExited) return;
                long at=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), begin=Stopwatch.GetTimestamp();
                if (index%(lan ? 25 : 10)==1) roles.Clear();
                Array.Clear(roleCounts,0,roleCounts.Length);
                process.Refresh();
                foreach (ProcessThread thread in process.Threads)
                {
                    int role;
                    bool known=roles.TryGetValue(thread.Id,out role);
                    if (known && role==0) continue;
                    IntPtr handle=OpenThread(0x0800,false,thread.Id); // QUERY_LIMITED_INFORMATION only
                    if (handle==IntPtr.Zero) continue;
                    try
                    {
                        if (GetProcessIdOfThread(handle)!=owner) continue;
                        if (!known) roles[thread.Id]=role=Role(handle);
                        if (role==0) continue;
                        long created,exited,kernel,user;
                        if (!GetThreadTimes(handle,out created,out exited,out kernel,out user)) continue;
                        roleCounts[role]++;
                        var state=thread.ThreadState;
                        states[role]=(int)state;
                        waits[role]=state==System.Diagnostics.ThreadState.Wait ? 1+(int)thread.WaitReason : 0;
                        cpuUs[role]=(kernel+user)/10;
                        if (lan)
                        {
                            if (origins[role]!=created) {origins[role]=created; generations[role]++;}
                            hasCycles[role]=QueryThreadCycleTime(handle,out seenCycles[role]);
                        }
                    }
                    finally { CloseHandle(handle); }
                }
                long duration=(Stopwatch.GetTimestamp()-begin)*1000000/Stopwatch.Frequency;
                for (int role=1;role<roleCounts.Length;role++)
                    if (roleCounts[role]==1)
                    {
                        Console.WriteLine("capture_thread {0} {1} {2} {3} {4} {5}",
                            at,duration,role,states[role],waits[role],cpuUs[role]);
                        if (lan && hasCycles[role])
                            Console.WriteLine("capture_worker {0} {1} {2} {3} {4} {5}",
                                at,duration,role,states[role],generations[role],seenCycles[role]);
                    }
                if (index%(lan ? 2 : 5)==1 && sessions!=null)
                {
                    int matches=0; EncoderSession found=new EncoderSession();
                    at=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    begin=Stopwatch.GetTimestamp();
                    foreach (var device in devices)
                    {
                        uint n=(uint)buffer.Length;
                        if (sessions(device,ref n,buffer)!=0 || n>buffer.Length) continue;
                        for (int i=0;i<n;i++)
                            if (buffer[i].pid==owner && buffer[i].width==(lan ? 1920 : 640) &&
                                buffer[i].height==(lan ? 1080 : 360) && (!lan || buffer[i].codec==0))
                            { matches++; found=buffer[i]; }
                    }
                    duration=(Stopwatch.GetTimestamp()-begin)*1000000/Stopwatch.Frequency;
                    if (matches==1)
                        Console.WriteLine("capture_encoder {0} {1} {2} {3}",at,duration,found.fps,found.latencyUs);
                }
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }

        public void Dispose()
        {
            if (process!=null) process.Dispose();
            if (shutdown!=null) shutdown();
            if (nvml!=IntPtr.Zero) FreeLibrary(nvml);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int x, y; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct OutputDesc
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name;
        public int left, top, right, bottom, attached;
        public uint rotation;
        public IntPtr monitor;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct FrameInfo
    {
        public long lastPresent, lastMouse;
        public uint accumulated;
        public int coalesced, masked, pointerX, pointerY, visible;
        public uint metadataBytes, shapeBytes;
    }
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("dxgi.dll")] private static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr result);
    [DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(IntPtr adapter, uint driver, IntPtr soft,
        uint flags, IntPtr levels, uint levelCount, uint sdk, out IntPtr device, out uint level, out IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int EnumItem(IntPtr self, uint i, out IntPtr item);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int Describe(IntPtr self, out OutputDesc desc);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int Duplicate(IntPtr self, IntPtr device, out IntPtr duplication);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int Acquire(IntPtr self, uint milliseconds,
        out FrameInfo frame, out IntPtr resource);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ReleaseFrame(IntPtr self);

    private static T Slot<T>(IntPtr pointer, int index) where T: class
    {
        IntPtr table = Marshal.ReadIntPtr(pointer);
        return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(table, index * IntPtr.Size), typeof(T)) as T;
    }
    private static void Drop(IntPtr value)
    {
        if (value != IntPtr.Zero) Marshal.Release(value);
    }
    private static void Check(int result) { if (result < 0) Marshal.ThrowExceptionForHR(result); }

    public static void Run(int maxSamples, int sunshinePid, bool lan)
    {
        Run(maxSamples, sunshinePid, lan, false);
    }

    public static void Run(int maxSamples, int sunshinePid, bool lan, bool identifyOnly)
    {
        IntPtr monitor = MonitorFromPoint(new Point(), 1); // physical primary at the origin
        if (monitor == IntPtr.Zero) throw new InvalidOperationException();
        IntPtr factory = IntPtr.Zero;
        Guid factoryId = Factory1;
        Check(CreateDXGIFactory1(ref factoryId, out factory));
        try
        {
            var enumAdapters = Slot<EnumItem>(factory, 12); // IDXGIFactory1::EnumAdapters1
            for (uint i = 0; i < 16; ++i)
            {
                IntPtr adapter;
                int hr = enumAdapters(factory, i, out adapter);
                if (hr == NotFound) break;
                Check(hr);
                try
                {
                    var enumOutputs = Slot<EnumItem>(adapter, 7);
                    for (uint j = 0; j < 16; ++j)
                    {
                        IntPtr output;
                        hr = enumOutputs(adapter, j, out output);
                        if (hr == NotFound) break;
                        Check(hr);
                        try
                        {
                            OutputDesc desc;
                            Check(Slot<Describe>(output, 7)(output, out desc));
                            if (desc.attached == 0 || desc.monitor != monitor) continue;
                            if (identifyOnly)
                            {
                                Console.WriteLine("capture_primary {0} {1} {2} {3}", i, j,
                                                  desc.right - desc.left, desc.bottom - desc.top);
                                return;
                            }
                            PollOutput(adapter, output, desc.right - desc.left, desc.bottom - desc.top, maxSamples, sunshinePid,lan);
                            return;
                        }
                        finally { Drop(output); }
                    }
                }
                finally { Drop(adapter); }
            }
        }
        finally { Drop(factory); }
        throw new InvalidOperationException();
    }

    private static void PollOutput(IntPtr adapter, IntPtr output, int width, int height, int maxSamples, int sunshinePid, bool lan)
    {
        IntPtr output1 = IntPtr.Zero, device = IntPtr.Zero, context = IntPtr.Zero, duplex = IntPtr.Zero;
        try
        {
            Guid iid = Output1;
            Check(Marshal.QueryInterface(output, ref iid, out output1));
            uint level;
            Check(D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, IntPtr.Zero, 0, 7,
                out device, out level, out context));
            Check(Slot<Duplicate>(output1, 22)(output1, device, out duplex));
            var acquire = Slot<Acquire>(duplex, 8);
            var release = Slot<ReleaseFrame>(duplex, 14);
            Console.WriteLine("capture_setup 1 {0} {1}", width, height);
            bool dwm = lan && CompositionSuitable();
            if (lan) Console.WriteLine("capture_dwm_capability {0}", dwm ? 1 : 0);
            var life = Stopwatch.StartNew();
            long next = 0;
            long wallStart=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            using (var host = new HostProbe(sunshinePid,lan))
            for (int i = 0; i < maxSamples && life.ElapsedMilliseconds < 720000; ++i)
            {
                long slack = next - life.ElapsedMilliseconds;
                if (slack > 0) Thread.Sleep((int)slack);
                long at = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), qpc = Stopwatch.GetTimestamp();
                if(lan && Math.Abs((at-wallStart)-life.ElapsedMilliseconds)>15) {
                    Console.WriteLine("capture_clock_invalid 1"); break;
                }
                FrameInfo frame;
                IntPtr resource;
                int hr = acquire(duplex, 0, out frame, out resource);
                if (hr >= 0)
                {
                    Drop(resource);
                    Check(release(duplex));
                }
                else if (hr != Timeout) Check(hr);
                long us = (Stopwatch.GetTimestamp() - qpc) * 1000000 / Stopwatch.Frequency;
                bool present = hr >= 0 && frame.lastPresent > 0;
                long last = present
                    ? Math.Max(0, at + (frame.lastPresent - qpc) * 1000 / Stopwatch.Frequency) : 0;
                if (i > 0)
                {
                    Console.WriteLine("capture_sample {0} {1} {2} {3} {4}", at, us,
                        present ? Math.Max(1U, frame.accumulated) : 0, last,
                        hr == Timeout || frame.masked == 0 ? 1 : 0);
                    host.Sample(i);
                    if (dwm) SampleComposition();
                }
                next = Math.Max(next + (lan ? 40 : 100), life.ElapsedMilliseconds + (lan ? 10 : 25));
            }
        }
        finally
        {
            Drop(duplex);
            Drop(context);
            Drop(device);
            Drop(output1);
        }
    }
}
