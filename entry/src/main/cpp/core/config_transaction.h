#ifndef RUSTDESK_CORE_CONFIG_TRANSACTION_H
#define RUSTDESK_CORE_CONFIG_TRANSACTION_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace config_transaction {
using Options = std::map<std::string, std::string>;

inline bool matches(const Options& current, const Options& expected) {
    for (const auto& item : expected) {
        const auto found = current.find(item.first);
        if ((found == current.end() ? std::string() : found->second) != item.second) return false;
    }
    return true;
}

enum class ReadResult { Ok, Missing, Error };

// Only report a missing file when the OS explicitly says it does not exist.
// A failed or incomplete read must not be mistaken for a new installation.
template <typename IO>
ReadResult readFile(IO& io, const std::string& path, std::vector<uint8_t>& bytes) {
    if (path.empty()) return ReadResult::Error;
    const auto opened = io.open(path);
    if (opened != ReadResult::Ok) return opened;
    std::vector<uint8_t> candidate;
    uint8_t buffer[8192];
    try {
        for (;;) {
            const auto count = io.read(buffer, sizeof(buffer));
            if (count < 0 || static_cast<size_t>(count) > sizeof(buffer)) {
                io.close();
                return ReadResult::Error;
            }
            if (count == 0) break;
            candidate.insert(candidate.end(), buffer, buffer + count);
        }
    } catch (...) {
        io.close();
        return ReadResult::Error;
    }
    if (!io.close()) return ReadResult::Error;
    bytes.swap(candidate);
    return ReadResult::Ok;
}

// The writer commits a complete candidate before the live in-memory settings
// are changed. Failed writes leave both the live settings and destination as-is.
template <typename Writer>
bool update(Options& current, const Options& changes, Writer&& persist) {
    Options next = current;
    for (const auto& item : changes) next[item.first] = item.second;
    if (!persist(next)) return false;
    current.swap(next);
    return true;
}

// IO owns its temporary file and must clean it up in cancel(). commit() must
// replace the destination atomically, or leave it untouched on failure.
template <typename IO>
bool writeFile(IO& io, const std::string& path, const std::vector<uint8_t>& bytes) {
    if (path.empty() || bytes.empty() || !io.open(path)) return false;
    size_t offset = 0;
    while (offset < bytes.size()) {
        const auto written = io.write(bytes.data() + offset, bytes.size() - offset);
        if (written <= 0 || static_cast<size_t>(written) > bytes.size() - offset) {
            io.cancel();
            return false;
        }
        offset += static_cast<size_t>(written);
    }
    if (!io.sync() || !io.close() || !io.commit()) {
        io.cancel();
        return false;
    }
    return true;
}
} // namespace config_transaction

#endif
