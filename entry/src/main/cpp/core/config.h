#ifndef RUSTDESK_CORE_CONFIG_H
#define RUSTDESK_CORE_CONFIG_H

#include <string>
#include <map>

class Config {
public:
    static Config& instance();

    void load();
    void save();

    std::string get(const std::string& key, const std::string& defaultValue = "");
    void set(const std::string& key, const std::string& value);

    std::map<std::string, std::string> getAll();

private:
    Config() {}
    std::map<std::string, std::string> options_;
    std::string configPath_;
};

#endif
