#include "diagnostic_log.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <sys/stat.h>

namespace {
constexpr size_t MAX_LOG_FILE_BYTES = 2 * 1024 * 1024;
constexpr size_t MAX_PENDING_LINES = 500;
constexpr size_t MAX_LOG_LINE_BYTES = 4096;

size_t fileSize(const std::string& path) {
    struct stat info {};
    if (stat(path.c_str(), &info) != 0 || info.st_size < 0) {
        return 0;
    }
    return static_cast<size_t>(info.st_size);
}

std::string lowerCopy(const std::string& value) {
    std::string lowered = value;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return lowered;
}

// Also used when exporting files written by an older version. Numeric keyboard
// positions are sensitive even if the original character was never logged.
std::string redactKeyboardRecord(std::string value) {
    std::string lowered = lowerCopy(value);
    const bool keyboard = (lowered.find("input-trace:") != std::string::npos &&
                           lowered.find("type=key") != std::string::npos) ||
        lowered.find("inputtrace") != std::string::npos ||
        lowered.find("sendkeyevent") != std::string::npos ||
        lowered.find("sendphysicalkeyevent") != std::string::npos ||
        lowered.find("native_key_forwarded") != std::string::npos ||
        lowered.find("shifted_number_forwarded") != std::string::npos ||
        lowered.find("keyboard map unsupported") != std::string::npos ||
        lowered.find("[input-shortcut]") != std::string::npos ||
        lowered.find("[input-modifier]") != std::string::npos ||
        lowered.find("printable_key=") != std::string::npos ||
        lowered.find("virtual_key=") != std::string::npos;
    if (!keyboard) return value;
    const char* fields[] = {"key=", "code=", "hid=", "keycode=", "key_code=", "hid_code=",
        "scan_code=", "scancode=", "char=", "unicode=", "printable_key=", "virtual_key="};
    for (const char* field : fields) {
        const std::string needle(field);
        size_t position = 0;
        while ((position = lowered.find(needle, position)) != std::string::npos) {
            if (position > 0 && (std::isalnum(static_cast<unsigned char>(lowered[position - 1])) ||
                                lowered[position - 1] == '_')) {
                position += needle.size();
                continue;
            }
            const size_t start = position + needle.size();
            size_t end = value.find_first_of(" ,;]}\r\n\t", start);
            if (end == std::string::npos) end = value.size();
            value.replace(start, end - start, "redacted");
            lowered = lowerCopy(value);
            position = start + 8;
        }
    }
    return value;
}
}

DiagnosticLog& DiagnosticLog::instance() {
    static DiagnosticLog log;
    return log;
}

void DiagnosticLog::setEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(mutex_);
    enabled_ = enabled;
    if (!enabled_) {
        pendingLines_.clear();
    }
}

void DiagnosticLog::initialize(const std::string& filesDirectory) {
    if (filesDirectory.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    directory_ = filesDirectory + "/diagnostics";
    mkdir(directory_.c_str(), 0700);
    currentPath_ = directory_ + "/starrustdesk-current.log";
    previousPath_ = directory_ + "/starrustdesk-previous.log";
    currentBytes_ = fileSize(currentPath_);
    initialized_ = true;
    if (currentBytes_ >= MAX_LOG_FILE_BYTES) {
        rotateLocked();
    }
    while (!pendingLines_.empty()) {
        appendLineLocked(pendingLines_.front());
        pendingLines_.pop_front();
    }
}

void DiagnosticLog::append(const char* level, const char* component, const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_) {
        return;
    }
    std::string line = makeLine(level, component, message);
    if (!initialized_) {
        while (pendingLines_.size() >= MAX_PENDING_LINES) {
            pendingLines_.pop_front();
        }
        pendingLines_.push_back(std::move(line));
        return;
    }
    appendLineLocked(line);
}

std::string DiagnosticLog::exportText() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::ostringstream output;
    output << "芝麻远控 diagnostic log\n"
           << "Passwords, verification codes, clipboard content and cryptographic secrets are not recorded.\n"
           << "Keyboard content, physical key positions and scan codes are redacted.\n";
    const auto appendArchive = [this, &output](const std::string& text) {
        std::istringstream lines(text);
        std::string line;
        while (std::getline(lines, line)) output << sanitize(line) << '\n';
    };
    if (!previousPath_.empty()) {
        std::string previous = readFile(previousPath_);
        if (!previous.empty()) {
            output << "\n===== PREVIOUS LOG =====\n";
            appendArchive(previous);
        }
    }
    if (!currentPath_.empty()) {
        std::string current = readFile(currentPath_);
        if (!current.empty()) {
            output << "\n===== CURRENT LOG =====\n";
            appendArchive(current);
        }
    }
    if (!initialized_ && !pendingLines_.empty()) {
        output << "\n===== IN-MEMORY LOG =====\n";
        for (const std::string& line : pendingLines_) {
            appendArchive(line);
        }
    }
    return output.str();
}

void DiagnosticLog::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    pendingLines_.clear();
    if (!currentPath_.empty()) {
        std::remove(currentPath_.c_str());
    }
    if (!previousPath_.empty()) {
        std::remove(previousPath_.c_str());
    }
    currentBytes_ = 0;
}

std::string DiagnosticLog::makeLine(const char* level, const char* component,
                                    const std::string& message) const {
    auto now = std::chrono::system_clock::now();
    auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;
    std::time_t timestamp = std::chrono::system_clock::to_time_t(now);
    std::tm localTime {};
    localtime_r(&timestamp, &localTime);
    std::ostringstream line;
    line << std::put_time(&localTime, "%Y-%m-%d %H:%M:%S") << '.'
         << std::setfill('0') << std::setw(3) << millis.count()
         << " [" << (level == nullptr ? "I" : level) << "]"
         << " [" << (component == nullptr ? "app" : component) << "] "
         << sanitize(message) << '\n';
    return line.str();
}

std::string DiagnosticLog::sanitize(const std::string& message) const {
    std::string sanitized;
    sanitized.reserve(std::min(message.size(), MAX_LOG_LINE_BYTES));
    for (char character : message) {
        if (character == '\r' || character == '\n' || character == '\t') {
            sanitized.push_back(' ');
        } else if (static_cast<unsigned char>(character) >= 0x20) {
            sanitized.push_back(character);
        }
        if (sanitized.size() >= MAX_LOG_LINE_BYTES) {
            sanitized.append("...[truncated]");
            break;
        }
    }

    const char* sensitiveKeys[] = {
        "password=", "password:", "passwd=", "secret=", "token=",
        "2fa_code=", "verification_code=", "clipboard_text=", "private_key="
    };
    for (const char* key : sensitiveKeys) {
        std::string lowered = lowerCopy(sanitized);
        std::string needle(key);
        size_t position = 0;
        while ((position = lowered.find(needle, position)) != std::string::npos) {
            size_t valueStart = position + needle.size();
            size_t valueEnd = sanitized.find_first_of(" ,;]}", valueStart);
            if (valueEnd == std::string::npos) {
                valueEnd = sanitized.size();
            }
            sanitized.replace(valueStart, valueEnd - valueStart, "<redacted>");
            lowered = lowerCopy(sanitized);
            position = valueStart + 10;
        }
    }
    return redactKeyboardRecord(std::move(sanitized));
}

void DiagnosticLog::appendLineLocked(const std::string& line) {
    if (currentBytes_ + line.size() > MAX_LOG_FILE_BYTES) {
        rotateLocked();
    }
    std::ofstream stream(currentPath_, std::ios::out | std::ios::app | std::ios::binary);
    if (!stream.is_open()) {
        return;
    }
    stream.write(line.data(), static_cast<std::streamsize>(line.size()));
    stream.flush();
    if (stream.good()) {
        currentBytes_ += line.size();
    }
}

void DiagnosticLog::rotateLocked() {
    if (!previousPath_.empty()) {
        std::remove(previousPath_.c_str());
    }
    if (!currentPath_.empty()) {
        std::rename(currentPath_.c_str(), previousPath_.c_str());
    }
    currentBytes_ = 0;
}

std::string DiagnosticLog::readFile(const std::string& path) {
    std::ifstream stream(path, std::ios::in | std::ios::binary);
    if (!stream.is_open()) {
        return std::string();
    }
    std::ostringstream content;
    content << stream.rdbuf();
    return content.str();
}
