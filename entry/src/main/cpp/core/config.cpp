#include "config.h"
#include "crypto/aead.h"
#include <cstring>
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <unistd.h>
#include <vector>

namespace {
constexpr const char* CONFIG_MAGIC = "SRDCFG1\n";
constexpr size_t CONFIG_MAGIC_LEN = 8;
constexpr uint8_t CONFIG_SALT[] = {
    0x53, 0x74, 0x61, 0x72, 0x52, 0x75, 0x73, 0x74,
    0x44, 0x65, 0x73, 0x6b, 0x48, 0x4d, 0x4f, 0x53
};

std::string device_secret() {
    char hostname[256] = {0};
    if (gethostname(hostname, sizeof(hostname)) != 0 || hostname[0] == '\0') {
        strcpy(hostname, "HarmonyOS");
    }
    return std::string("StarRustDesk-local-config-v1:") + hostname +
           ":/data/storage/el2/base/haps/entry/files";
}

void derive_config_key(uint8_t key[AEAD::KEY_SIZE]) {
    std::string secret = device_secret();
    AEAD::deriveKey(reinterpret_cast<const uint8_t*>(secret.data()),
                    static_cast<int>(secret.size()),
                    CONFIG_SALT,
                    static_cast<int>(sizeof(CONFIG_SALT)),
                    key);
}

std::string serialize_options(const std::map<std::string, std::string>& options) {
    std::ostringstream out;
    for (const auto& pair : options) {
        out << pair.first << "=" << pair.second << "\n";
    }
    return out.str();
}

std::map<std::string, std::string> parse_options(const std::string& content) {
    std::map<std::string, std::string> options;
    std::istringstream input(content);
    std::string line;
    while (std::getline(input, line)) {
        size_t pos = line.find('=');
        if (pos != std::string::npos) {
            std::string key = line.substr(0, pos);
            std::string value = line.substr(pos + 1);
            options[key] = value;
        }
    }
    return options;
}

bool decrypt_config(const std::vector<uint8_t>& bytes, std::string& plaintext) {
    if (bytes.size() < CONFIG_MAGIC_LEN + AEAD::NONCE_SIZE + AEAD::TAG_SIZE ||
        memcmp(bytes.data(), CONFIG_MAGIC, CONFIG_MAGIC_LEN) != 0) {
        return false;
    }

    const uint8_t* nonce = bytes.data() + CONFIG_MAGIC_LEN;
    const uint8_t* tag = nonce + AEAD::NONCE_SIZE;
    const uint8_t* ciphertext = tag + AEAD::TAG_SIZE;
    int ciphertextLen = static_cast<int>(bytes.size() - CONFIG_MAGIC_LEN - AEAD::NONCE_SIZE - AEAD::TAG_SIZE);

    uint8_t key[AEAD::KEY_SIZE] = {0};
    derive_config_key(key);

    AEAD aead;
    aead.setKey(key);
    aead.setNonce(nonce);
    std::vector<uint8_t> plain(ciphertextLen);
    if (aead.decrypt(ciphertext, ciphertextLen,
                     reinterpret_cast<const uint8_t*>(CONFIG_MAGIC),
                     static_cast<int>(CONFIG_MAGIC_LEN),
                     tag,
                     plain.data()) != 0) {
        return false;
    }
    plaintext.assign(reinterpret_cast<const char*>(plain.data()), plain.size());
    return true;
}

std::vector<uint8_t> encrypt_config(const std::string& plaintext) {
    uint8_t key[AEAD::KEY_SIZE] = {0};
    uint8_t randomBytes[AEAD::KEY_SIZE] = {0};
    uint8_t nonce[AEAD::NONCE_SIZE] = {0};
    uint8_t tag[AEAD::TAG_SIZE] = {0};
    derive_config_key(key);
    AEAD::generateKey(randomBytes);
    memcpy(nonce, randomBytes, AEAD::NONCE_SIZE);

    AEAD aead;
    aead.setKey(key);
    aead.setNonce(nonce);
    std::vector<uint8_t> ciphertext(plaintext.size());
    aead.encrypt(reinterpret_cast<const uint8_t*>(plaintext.data()),
                 static_cast<int>(plaintext.size()),
                 reinterpret_cast<const uint8_t*>(CONFIG_MAGIC),
                 static_cast<int>(CONFIG_MAGIC_LEN),
                 ciphertext.data(),
                 tag);

    std::vector<uint8_t> output;
    output.insert(output.end(), CONFIG_MAGIC, CONFIG_MAGIC + CONFIG_MAGIC_LEN);
    output.insert(output.end(), nonce, nonce + AEAD::NONCE_SIZE);
    output.insert(output.end(), tag, tag + AEAD::TAG_SIZE);
    output.insert(output.end(), ciphertext.begin(), ciphertext.end());
    return output;
}
}

Config& Config::instance() {
    static Config config;
    return config;
}

void Config::load() {
    options_.clear();

    // Use HarmonyOS app persistent data path
    configPath_ = "/data/storage/el2/base/haps/entry/files/rustdesk_config.txt";

    std::ifstream file(configPath_, std::ios::binary);
    if (!file.is_open()) {
        return;
    }

    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    file.close();

    std::string content;
    bool encrypted = decrypt_config(bytes, content);
    if (!encrypted) {
        if (bytes.size() >= CONFIG_MAGIC_LEN && memcmp(bytes.data(), CONFIG_MAGIC, CONFIG_MAGIC_LEN) == 0) {
            return;
        }
        content.assign(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    }
    options_ = parse_options(content);
    if (!encrypted && !options_.empty()) {
        save();
    }
}

void Config::save() {
    std::ofstream file(configPath_, std::ios::binary | std::ios::trunc);
    if (!file.is_open()) {
        return;
    }

    std::string plaintext = serialize_options(options_);
    std::vector<uint8_t> encrypted = encrypt_config(plaintext);
    file.write(reinterpret_cast<const char*>(encrypted.data()), static_cast<std::streamsize>(encrypted.size()));
    file.close();
}

std::string Config::get(const std::string& key, const std::string& defaultValue) {
    auto it = options_.find(key);
    if (it != options_.end()) {
        return it->second;
    }
    return defaultValue;
}

void Config::set(const std::string& key, const std::string& value) {
    options_[key] = value;
}

std::map<std::string, std::string> Config::getAll() {
    return options_;
}
