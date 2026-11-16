#ifndef RUSTDESK_CORE_CONFIG_H
#define RUSTDESK_CORE_CONFIG_H

#include <string>
#include <map>
#include <mutex>

class Config {
public:
    static Config& instance();

    void load();
    bool save();

    std::string get(const std::string& key, const std::string& defaultValue = "");
    void set(const std::string& key, const std::string& value);
    // Atomically persist a complete candidate before exposing it to readers.
    bool setOptionsAndSave(const std::map<std::string, std::string>& changes,
                           bool* accountContextChanged = nullptr);
    // 0 committed; -2 write failure; -3 a checked value changed concurrently.
    int compareAndSetOptionsAndSave(const std::map<std::string, std::string>& expected,
                                    const std::map<std::string, std::string>& changes,
                                    bool* accountContextChanged = nullptr);

    std::map<std::string, std::string> getAll();

private:
    Config() {}
    std::map<std::string, std::string> options_;
    std::string configPath_;
    bool writable_ = false;
    std::mutex mutex_;
};

#endif
