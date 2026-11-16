#include "config.h"
#include "config_transaction.h"
#include "crypto/aead.h"
#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
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
        bytes.size() - CONFIG_MAGIC_LEN - AEAD::NONCE_SIZE - AEAD::TAG_SIZE > static_cast<size_t>(INT_MAX) ||
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
    if (plaintext.size() > static_cast<size_t>(INT_MAX)) return {};
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
    if (aead.encrypt(reinterpret_cast<const uint8_t*>(plaintext.data()),
                 static_cast<int>(plaintext.size()),
                 reinterpret_cast<const uint8_t*>(CONFIG_MAGIC),
                 static_cast<int>(CONFIG_MAGIC_LEN),
                 ciphertext.data(),
                 tag) != 0) return {};

    std::vector<uint8_t> output;
    output.insert(output.end(), CONFIG_MAGIC, CONFIG_MAGIC + CONFIG_MAGIC_LEN);
    output.insert(output.end(), nonce, nonce + AEAD::NONCE_SIZE);
    output.insert(output.end(), tag, tag + AEAD::TAG_SIZE);
    output.insert(output.end(), ciphertext.begin(), ciphertext.end());
    return output;
}

// Temporary files are created in the destination directory, so rename is an
// atomic same-filesystem replacement. Existing data is never truncated first.
class PosixAtomicFile {
public:
    ~PosixAtomicFile() { cancel(); }
    bool open(const std::string& target) {
        target_ = target;
        std::string pattern = target + ".tmp.XXXXXX";
        temp_.reserve(pattern.size());
        std::vector<char> name(pattern.begin(), pattern.end());
        name.push_back('\0');
        fd_ = ::mkstemp(name.data());
        if (fd_ < 0) return false;
        temp_ = name.data();
        if (::fcntl(fd_, F_SETFD, FD_CLOEXEC) != 0) { cancel(); return false; }
        return true;
    }
    std::ptrdiff_t write(const uint8_t* data, size_t length) {
        const size_t chunk = std::min(length, static_cast<size_t>(SSIZE_MAX));
        ssize_t result;
        do { result = ::write(fd_, data, chunk); } while (result < 0 && errno == EINTR);
        return static_cast<std::ptrdiff_t>(result);
    }
    bool sync() {
        int result;
        do { result = ::fsync(fd_); } while (result < 0 && errno == EINTR);
        return result == 0;
    }
    bool close() {
        const int fd = fd_;
        fd_ = -1;
        return fd >= 0 && ::close(fd) == 0;
    }
    bool commit() {
        // Prepare everything that can allocate before the atomic rename.
        const size_t slash = target_.find_last_of('/');
        const std::string dir = slash == std::string::npos ? "." : (slash == 0 ? "/" : target_.substr(0, slash));
        const int dirFd = ::open(dir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (::rename(temp_.c_str(), target_.c_str()) != 0) {
            if (dirFd >= 0) (void)::close(dirFd);
            return false;
        }
        temp_.clear();
        // Directory sync is best effort: after rename the new file is active
        // and reporting failure could no longer promise the old file remains.
        if (dirFd >= 0) { (void)::fsync(dirFd); (void)::close(dirFd); }
        return true;
    }
    void cancel() {
        if (fd_ >= 0) { (void)::close(fd_); fd_ = -1; }
        if (!temp_.empty()) { (void)::unlink(temp_.c_str()); temp_.clear(); }
    }
private:
    int fd_ = -1;
    std::string temp_;
    std::string target_;
};

bool save_snapshot(const std::string& path, const config_transaction::Options& options) {
    auto encrypted = encrypt_config(serialize_options(options));
    PosixAtomicFile file;
    return config_transaction::writeFile(file, path, encrypted);
}

class PosixConfigReader {
public:
    ~PosixConfigReader() { if (fd_ >= 0) (void)::close(fd_); }
    config_transaction::ReadResult open(const std::string& path) {
        fd_ = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd_ >= 0) return config_transaction::ReadResult::Ok;
        return errno == ENOENT ? config_transaction::ReadResult::Missing : config_transaction::ReadResult::Error;
    }
    std::ptrdiff_t read(uint8_t* buffer, size_t length) {
        ssize_t result;
        do { result = ::read(fd_, buffer, length); } while (result < 0 && errno == EINTR);
        return static_cast<std::ptrdiff_t>(result);
    }
    bool close() {
        const int fd = fd_;
        fd_ = -1;
        return fd >= 0 && ::close(fd) == 0;
    }
private:
    int fd_ = -1;
};
}

Config& Config::instance() {
    static Config config;
    return config;
}

void Config::load() {
    std::lock_guard<std::mutex> lock(mutex_);
    options_.clear();
    writable_ = false;

    // Use HarmonyOS app persistent data path
    configPath_ = "/data/storage/el2/base/haps/entry/files/rustdesk_config.txt";

    PosixConfigReader file;
    std::vector<uint8_t> bytes;
    const auto read = config_transaction::readFile(file, configPath_, bytes);
    if (read == config_transaction::ReadResult::Missing) { writable_ = true; return; }
    if (read != config_transaction::ReadResult::Ok) return;

    std::string content;
    bool encrypted = decrypt_config(bytes, content);
    if (!encrypted) {
        // Refuse to overwrite an unreadable encrypted file, including a
        // truncated header. It may contain existing connections and settings.
        if (!bytes.empty() && std::equal(bytes.begin(), bytes.begin() + std::min(bytes.size(), CONFIG_MAGIC_LEN),
                                         reinterpret_cast<const uint8_t*>(CONFIG_MAGIC))) {
            return;
        }
        if (!bytes.empty()) content.assign(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    }
    options_ = parse_options(content);
    writable_ = true;
    if (!encrypted && !options_.empty()) {
        try { (void)save_snapshot(configPath_, options_); } catch (...) {}
    }
}

bool Config::save() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!writable_) return false;
    try { return save_snapshot(configPath_, options_); } catch (...) { return false; }
}

std::string Config::get(const std::string& key, const std::string& defaultValue) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = options_.find(key);
    if (it != options_.end()) {
        return it->second;
    }
    return defaultValue;
}

void Config::set(const std::string& key, const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex_);
    options_[key] = value;
}

bool Config::setOptionsAndSave(const std::map<std::string, std::string>& changes,
                               bool* accountContextChanged) {
    return compareAndSetOptionsAndSave({}, changes, accountContextChanged) == 0;
}

int Config::compareAndSetOptionsAndSave(const std::map<std::string, std::string>& expected,
                                        const std::map<std::string, std::string>& changes,
                                        bool* accountContextChanged) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (accountContextChanged) *accountContextChanged = false;
    if (!writable_) return -2;
    if (!config_transaction::matches(options_, expected)) return -3;
    bool contextChanged = false;
    for (const char* key : {"custom-rendezvous-server", "api-server", "key"}) {
        const auto change = changes.find(key);
        const auto old = options_.find(key);
        const std::string previous = old == options_.end() ? "" : old->second;
        if (change != changes.end() && change->second != previous) contextChanged = true;
    }
    try {
        if (!config_transaction::update(options_, changes,
            [this](const auto& candidate) { return save_snapshot(configPath_, candidate); })) return -2;
    } catch (...) { return -2; }
    if (accountContextChanged) *accountContextChanged = contextChanged;
    return 0;
}

std::map<std::string, std::string> Config::getAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    return options_;
}
