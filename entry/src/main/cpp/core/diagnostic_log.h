#ifndef RUSTDESK_CORE_DIAGNOSTIC_LOG_H
#define RUSTDESK_CORE_DIAGNOSTIC_LOG_H

#include <deque>
#include <mutex>
#include <string>

class DiagnosticLog {
public:
    static DiagnosticLog& instance();

    void setEnabled(bool enabled);
    void initialize(const std::string& filesDirectory);
    void append(const char* level, const char* component, const std::string& message);
    std::string exportText();
    void clear();

private:
    DiagnosticLog() = default;

    std::string makeLine(const char* level, const char* component, const std::string& message) const;
    std::string sanitize(const std::string& message) const;
    void appendLineLocked(const std::string& line);
    void rotateLocked();
    static std::string readFile(const std::string& path);

    std::mutex mutex_;
    std::string directory_;
    std::string currentPath_;
    std::string previousPath_;
    std::deque<std::string> pendingLines_;
    size_t currentBytes_{0};
    bool enabled_{false};
    bool initialized_{false};
};

#endif
