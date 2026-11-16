#include "../../entry/src/main/cpp/core/config_transaction.h"
#include <cassert>
#include <algorithm>
#include <cstring>
#include <string>

using config_transaction::Options;

enum class Failure { None, Open, Write, ShortWriteThenFail, ZeroWrite, Sync, Close, Rename };

struct FakeFile {
    Failure failure = Failure::None;
    std::string disk;
    std::string temp;
    int writes = 0;
    bool cancelled = false;
    bool opened = false;
    bool closed = false;

    bool open(const std::string&) { opened = failure != Failure::Open; return opened; }
    std::ptrdiff_t write(const uint8_t* data, size_t size) {
        ++writes;
        if (failure == Failure::Write || (failure == Failure::ShortWriteThenFail && writes > 1)) return -1;
        if (failure == Failure::ZeroWrite) return 0;
        const size_t count = failure == Failure::ShortWriteThenFail ? 1 : size;
        temp.append(reinterpret_cast<const char*>(data), count);
        return static_cast<std::ptrdiff_t>(count);
    }
    bool sync() { return failure != Failure::Sync; }
    bool close() { closed = true; return failure != Failure::Close; }
    bool commit() {
        if (failure == Failure::Rename) return false;
        disk = temp;
        temp.clear();
        return true;
    }
    void cancel() { cancelled = true; temp.clear(); }
};

struct FakeReader {
    config_transaction::ReadResult status = config_transaction::ReadResult::Ok;
    std::string data = "complete-existing-config";
    size_t offset = 0;
    bool failAfterPartial = false;
    bool failClose = false;
    bool closed = false;
    config_transaction::ReadResult open(const std::string&) { return status; }
    std::ptrdiff_t read(uint8_t* out, size_t size) {
        if (failAfterPartial && offset > 0) return -1;
        const size_t count = std::min({size, data.size() - offset, static_cast<size_t>(4)});
        std::memcpy(out, data.data() + offset, count);
        offset += count;
        return static_cast<std::ptrdiff_t>(count);
    }
    bool close() { closed = true; return !failClose; }
};

std::string serialize(const Options& options) {
    std::string result;
    for (const auto& item : options) result += item.first + "=" + item.second + "\n";
    return result;
}

int main() {
    using config_transaction::ReadResult;
    for (const ReadResult failure : {ReadResult::Missing, ReadResult::Error}) {
        FakeReader reader; reader.status = failure;
        std::vector<uint8_t> unchanged{9};
        assert(config_transaction::readFile(reader, "synthetic-path", unchanged) == failure);
        assert(unchanged == std::vector<uint8_t>{9} && !reader.closed);
    }
    for (int failure = 0; failure < 2; ++failure) {
        FakeReader reader; reader.failAfterPartial = failure == 0; reader.failClose = failure == 1;
        std::vector<uint8_t> unchanged{9};
        assert(config_transaction::readFile(reader, "synthetic-path", unchanged) == ReadResult::Error);
        assert(unchanged == std::vector<uint8_t>{9} && reader.closed);
    }
    FakeReader reader;
    std::vector<uint8_t> read;
    assert(config_transaction::readFile(reader, "synthetic-path", read) == ReadResult::Ok);
    assert(std::string(read.begin(), read.end()) == reader.data && reader.closed);

    const Options previous{{"custom-rendezvous-server", "old.invalid"}, {"relay-server", "old-relay.invalid"},
        {"api-server", "old-api.invalid"}, {"key", "old-key"}, {"saved-connections", "keep-user-data"},
        {"theme", "dark"}};
    const Options changes{{"custom-rendezvous-server", "new.invalid"}, {"relay-server", ""},
        {"api-server", "https://new.invalid"}, {"key", "new-key=="}};
    assert(config_transaction::matches(previous, Options{{"theme", "dark"}, {"missing-option", ""}}));
    assert(!config_transaction::matches(previous, Options{{"theme", "light"}}));
    for (Failure failure : {Failure::Open, Failure::Write, Failure::ShortWriteThenFail,
         Failure::ZeroWrite, Failure::Sync, Failure::Close, Failure::Rename}) {
        Options live = previous;
        FakeFile file; file.failure = failure; file.disk = serialize(previous);
        const bool saved = config_transaction::update(live, changes, [&](const Options& candidate) {
            const auto data = serialize(candidate);
            return config_transaction::writeFile(file, "synthetic-path", std::vector<uint8_t>(data.begin(), data.end()));
        });
        assert(!saved && live == previous && file.disk == serialize(previous));
        if (failure != Failure::Open) assert(file.cancelled && file.temp.empty());
    }

    Options live = previous;
    FakeFile file; file.disk = serialize(previous);
    assert(config_transaction::update(live, changes, [&](const Options& candidate) {
        const auto data = serialize(candidate);
        return config_transaction::writeFile(file, "synthetic-path", std::vector<uint8_t>(data.begin(), data.end()));
    }));
    assert(live.at("custom-rendezvous-server") == "new.invalid");
    assert(live.at("relay-server").empty() && live.at("key") == "new-key==");
    assert(live.at("saved-connections") == "keep-user-data" && live.at("theme") == "dark");
    assert(file.disk == serialize(live) && file.temp.empty() && !file.cancelled);

    FakeFile invalid;
    assert(!config_transaction::writeFile(invalid, "", std::vector<uint8_t>{1}));
    assert(!config_transaction::writeFile(invalid, "synthetic-path", std::vector<uint8_t>{}));
    assert(!invalid.opened);
}
