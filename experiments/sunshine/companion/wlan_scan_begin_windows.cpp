// Bounded ETW observer for the test Wi-Fi interface. No ETL, radio operations,
// logging of event payloads, or persisted changes to Event Viewer channels.
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <objbase.h>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <fcntl.h>
#include <io.h>

namespace {
constexpr GUID wlan_provider={0x9580d7dd,0x0379,0x4658,{0x98,0x70,0xd5,0xbe,0x7d,0x52,0xd6,0xde}};
constexpr USHORT begin_id=20022, complete_id=20023;
constexpr ULONGLONG filetime_unix=116444736000000000ULL;
constexpr unsigned max_rows=512;
std::FILE* output=stdout;
struct Session {
    EVENT_TRACE_PROPERTIES props{};
    wchar_t name[128]{};
};
struct alignas(8) IdFilter {
    BOOLEAN filter_in=TRUE;
    UCHAR reserved=0;
    USHORT count=2;
    USHORT events[2]={begin_id,complete_id};
};
static_assert(offsetof(IdFilter,events)==offsetof(EVENT_FILTER_EVENT_ID,Events));
struct Observer {
    GUID interface_guid{};
    unsigned rows=0;
    unsigned skipped=0;
    TRACEHANDLE consumer=INVALID_PROCESSTRACE_HANDLE;
};
struct Capture {
    HANDLE signal=nullptr;
    HANDLE owner=nullptr;
    ~Capture() {
        if (signal) CloseHandle(signal);
        if (owner) CloseHandle(owner);
        if (output!=stdout) std::fclose(output);
    }
};

ULONG open_output(Capture& capture,const wchar_t* nonce,DWORD pid) {
    if (std::wcslen(nonce)!=32 || std::wcsspn(nonce,L"0123456789abcdef")!=32)
        return ERROR_INVALID_PARAMETER;
    // Use a new file beside this fixed executable, not an elevated-write path
    // supplied by the caller. Even a pre-existing link cannot be overwritten.
    wchar_t path[MAX_PATH]{};
    const auto len=GetModuleFileNameW(nullptr,path,_countof(path));
    if (!len || len>=_countof(path)) return ERROR_BAD_PATHNAME;
    auto slash=std::wcsrchr(path,L'\\');
    if (!slash) return ERROR_BAD_PATHNAME;
    ++slash;
    if (swprintf_s(slash,_countof(path)-(slash-path),L"wlan-scan-%ls.txt",nonce)<0)
        return ERROR_BAD_PATHNAME;
    const auto file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if (file==INVALID_HANDLE_VALUE) return GetLastError();
    const int fd=_open_osfhandle(reinterpret_cast<intptr_t>(file),_O_WRONLY | _O_TEXT);
    if (fd<0) { CloseHandle(file); return ERROR_WRITE_FAULT; }
    auto f=_fdopen(fd,"w");
    if (!f) { _close(fd); return ERROR_WRITE_FAULT; }
    output=f;
    wchar_t name[96]{};
    swprintf_s(name,L"Local\\SesameStream_WlanBegin_Stop_%ls",nonce);
    capture.signal=OpenEventW(SYNCHRONIZE,FALSE,name);
    if (!capture.signal) return GetLastError();
    capture.owner=OpenProcess(SYNCHRONIZE,FALSE,pid);
    if (!capture.owner) return GetLastError();
    return ERROR_SUCCESS;
}

void WINAPI event_record(EVENT_RECORD* event) {
    const auto id=event->EventHeader.EventDescriptor.Id;
    if (id!=begin_id && id!=complete_id) return;
    if (!IsEqualGUID(event->EventHeader.ProviderId,wlan_provider) ||
        event->EventHeader.EventDescriptor.Version!=0 ||
        event->EventHeader.Flags & EVENT_HEADER_FLAG_STRING_ONLY ||
        event->UserDataLength<(id==begin_id ? sizeof(GUID) : sizeof(GUID)+sizeof(ULONG)) ||
        !event->UserData) return;
    auto& observer=*static_cast<Observer*>(event->UserContext);
    GUID adapter{};
    std::memcpy(&adapter,event->UserData,sizeof adapter);
    if (!IsEqualGUID(adapter,observer.interface_guid)) return;
    if (observer.rows>=max_rows) { ++observer.skipped; return; }
    const auto ticks=static_cast<ULONGLONG>(event->EventHeader.TimeStamp.QuadPart);
    // ProcessTrace (no RAW_TIMESTAMP flag) converts QPC to UTC FILETIME.
    if (ticks<filetime_unix || ticks>=filetime_unix+50000000000000000ULL) return;
    ULONG status=0;
    if (id==complete_id)
        std::memcpy(&status,static_cast<const char*>(event->UserData)+sizeof(GUID),sizeof status);
    ++observer.rows;
    std::fprintf(output,"scan_etw_event utc_100ns=%llu id=%u status=%lu\n",
                ticks-filetime_unix,static_cast<unsigned>(id),status);
    std::fflush(output);
}

DWORD WINAPI process_events(void* context) {
    auto& observer=*static_cast<Observer*>(context);
    return ProcessTrace(&observer.consumer,1,nullptr,nullptr);
}

int error(unsigned stage, ULONG code) {
    std::fprintf(output,"scan_etw_setup stage=%u error=%lu\n",stage,code);
    return 2;
}
}

int wmain(int argc,wchar_t** argv) {
    Observer observer;
    Capture capture;
    const bool collect=argc==6 && std::wcscmp(argv[1],L"--collect")==0;
    if (!collect && argc!=3) return error(0,ERROR_INVALID_PARAMETER);
    const auto adapter=argv[collect ? 2 : 1];
    if (std::wcslen(adapter)!=38 || adapter[0]!=L'{' ||
        FAILED(CLSIDFromString(adapter,&observer.interface_guid))) return error(0,ERROR_INVALID_PARAMETER);
    wchar_t* tail{};
    const auto duration=std::wcstoul(argv[collect ? 3 : 2],&tail,10);
    if (!duration || duration>900 || *tail) return error(0,ERROR_INVALID_PARAMETER);
    if (collect) {
        const auto pid=std::wcstoul(argv[5],&tail,10);
        if (!pid || *tail) return error(0,ERROR_INVALID_PARAMETER);
        const auto opened=open_output(capture,argv[4],pid);
        if (opened!=ERROR_SUCCESS) return error(0,opened);
    }

    Session s;
    swprintf_s(s.name,L"SesameStream_WlanBegin_%lu",GetCurrentProcessId());
    s.props.Wnode.BufferSize=sizeof s;
    s.props.Wnode.Flags=WNODE_FLAG_TRACED_GUID;
    s.props.Wnode.ClientContext=1; // QPC
    s.props.LoggerNameOffset=offsetof(Session,name);
    s.props.LogFileMode=EVENT_TRACE_REAL_TIME_MODE | EVENT_TRACE_NO_PER_PROCESSOR_BUFFERING;
    s.props.BufferSize=16;
    s.props.MinimumBuffers=2;
    s.props.MaximumBuffers=4;
    s.props.FlushTimer=1;

    TRACEHANDLE session{};
    const auto start=StartTraceW(&session,s.name,&s.props);
    if (start!=ERROR_SUCCESS) return error(1,start);
    auto stop=[&]() {
        return ControlTraceW(session,nullptr,&s.props,EVENT_TRACE_CONTROL_STOP);
    };
    // Windows filters the provider to two manifest events. The callback
    // checks the event IDs again and reads only the interface key/status.
    IdFilter ids;
    EVENT_FILTER_DESCRIPTOR filter{};
    filter.Type=EVENT_FILTER_TYPE_EVENT_ID;
    filter.Ptr=reinterpret_cast<ULONGLONG>(&ids);
    filter.Size=offsetof(IdFilter,events)+sizeof(ids.events);
    ENABLE_TRACE_PARAMETERS parameters{};
    parameters.Version=ENABLE_TRACE_PARAMETERS_VERSION_2;
    parameters.EnableFilterDesc=&filter;
    parameters.FilterDescCount=1;
    const auto enabled=EnableTraceEx2(session,&wlan_provider,EVENT_CONTROL_CODE_ENABLE_PROVIDER,
                                     TRACE_LEVEL_INFORMATION,0,0,4000,&parameters);
    if (enabled!=ERROR_SUCCESS) { stop(); return error(2,enabled); }

    EVENT_TRACE_LOGFILEW config{};
    config.LoggerName=s.name;
    config.ProcessTraceMode=PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    config.Context=&observer;
    config.EventRecordCallback=event_record;
    observer.consumer=OpenTraceW(&config);
    if (observer.consumer==INVALID_PROCESSTRACE_HANDLE) {
        const auto code=GetLastError(); stop(); return error(3,code);
    }
    const auto worker=CreateThread(nullptr,0,process_events,&observer,0,nullptr);
    if (!worker) {
        const auto code=GetLastError(); stop(); CloseTrace(observer.consumer); return error(4,code);
    }
    std::fprintf(output,"scan_etw_setup stage=5 error=0 pid=%lu seconds=%lu\n",GetCurrentProcessId(),duration);
    std::fflush(output);

    HANDLE waits[3]={worker,capture.signal,capture.owner};
    const auto waited=WaitForMultipleObjects(collect ? 3 : 1,waits,FALSE,duration*1000);
    const bool normal=waited==WAIT_TIMEOUT || waited==WAIT_OBJECT_0+1 || waited==WAIT_OBJECT_0+2;
    const auto stopped=stop();
    if (WaitForSingleObject(worker,5000)==WAIT_TIMEOUT) {
        CloseTrace(observer.consumer);
        if (WaitForSingleObject(worker,5000)!=WAIT_OBJECT_0) {
            std::fprintf(output,"scan_etw_finish stop=%lu drain=1\n",stopped);
            std::fflush(output);
            // A callback could still be active: exit without destroying its
            // stack data or closing its file from this thread.
            ExitProcess(3);
        }
    } else {
        CloseTrace(observer.consumer);
    }
    DWORD process_code{};
    GetExitCodeThread(worker,&process_code);
    CloseHandle(worker);
    std::fprintf(output,"scan_etw_finish stop=%lu process=%lu early=%u events=%u lost=%lu buffer_lost=%lu capped=%u\n",
                stopped,process_code,static_cast<unsigned>(!normal),observer.rows,
                s.props.EventsLost,s.props.RealTimeBuffersLost,observer.skipped);
    return stopped==ERROR_SUCCESS && normal && process_code==ERROR_SUCCESS &&
           !s.props.EventsLost && !s.props.RealTimeBuffersLost && !observer.skipped ? 0 : 3;
}
