#include <cassert>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <iostream>
#include <string>
#include <sys/stat.h>
#ifdef _WIN32
#include <direct.h>
static int test_mkdir(const char* path, int) { return _mkdir(path); }
static std::tm* localtime_r(const std::time_t* time, std::tm* out) {
    return localtime_s(out, time) == 0 ? out : nullptr;
}
#define mkdir test_mkdir
#endif

// Exercise the production writer, sanitizer and exporter, including old files.
#include "../entry/src/main/cpp/core/diagnostic_log.cpp"

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string root = argv[1];
    auto& log = DiagnosticLog::instance();
    log.initialize(root);
    log.setEnabled(true);
    const std::string current = root + "/diagnostics/starrustdesk-current.log";
    const std::string previous = root + "/diagnostics/starrustdesk-previous.log";
    {
        std::ofstream out(previous);
        out << "[rust] input-trace: stage=queue type=key key=scan:123456 down=true mode=1 modifiers=[29]\n"
            << "[input] native_key_forwarded code=234567 hid=345678 modifiers=2 modifier_valid=1\n"
            << "[input] shifted_number_forwarded hid=456789 repeat=0\n"
            << "[input-shortcut] printable_key=567890 modifiers=1 result=0\n"
            << "[input-shortcut] virtual_key=PageUp code=678901\n"
            << "[input-modifier] source=key key=789012 action=1 mask=0 result=0\n"
            << "[rust] input-trace: stage=network_sent type=key key=control:890123 down=false\n";
    }
    {
        std::ofstream out(current);
        out << "[native] InputTrace napi_physical hid=901234 action=0 result=0\n"
            << "[native] InputTrace napi_key key=123450 action=1 result=0\n"
            << "[native] InputTrace letter char=synthetic-char action=0 result=0\n"
            << "[native] SendKeyEvent key=234560 action=1 result=-3\n"
            << "[rust] keyboard map unsupported hid=345670 peer_platform=Windows\n";
    }
    log.append("I", "rust", "input-trace: stage=queue type=key key=scan:456780 down=true mode=1");
    log.append("I", "rust", "input-trace: stage=network_send type=key key=unicode:567800 down=false");
    log.append("I", "input", "native_key_forwarded CODE=678000 HID=789000 modifiers=1");
    log.append("I", "video-layout", "display_restore remote_default=1 selected=1 count=2 source=remote_default result=0");
    log.append("I", "rust", "input-trace: stage=queue type=mouse mask=9 x=10 y=20 modifiers=[]");
    log.append("I", "auth", "password=synthetic-pass token=synthetic-token");
    const std::string text = log.exportText();
    for (const char* secret : {"123456", "234567", "345678", "456789", "567890", "678901", "789012",
             "890123", "901234", "123450", "234560", "345670", "456780", "567800", "678000", "789000",
             "synthetic-char", "PageUp", "synthetic-pass", "synthetic-token", "scan:", "unicode:"}) {
        assert(text.find(secret) == std::string::npos);
    }
    assert(text.find("===== PREVIOUS LOG =====") != std::string::npos);
    assert(text.find("===== CURRENT LOG =====") != std::string::npos);
    assert(text.find("source=remote_default result=0\n") != std::string::npos);
    assert(text.find("type=mouse mask=9 x=10 y=20") != std::string::npos);
    assert(text.find("stage=network_send type=key key=redacted down=false") != std::string::npos);
    assert(text.find("repeat=0") != std::string::npos);
    assert(text.find("result=-3") != std::string::npos);
    std::ifstream stored(current);
    const std::string disk((std::istreambuf_iterator<char>(stored)), {});
    assert(disk.find("456780") == std::string::npos && disk.find("567800") == std::string::npos);
    log.setEnabled(false);
    log.append("I", "input", "disabled-marker");
    assert(log.exportText().find("disabled-marker") == std::string::npos);
    std::cout << "PASS input log privacy: production writer, legacy current/previous export, content redaction, preserved stages and disabled gate\n";
}
