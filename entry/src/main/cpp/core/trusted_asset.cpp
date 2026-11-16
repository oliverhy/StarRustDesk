#include <asset/asset_api.h>
#include <cstdint>
#include <cstring>
#include <string>

// The alias is a domain-separated hash, never a peer ID or credential.
// These functions do not log either the alias or secret, even on failure.
namespace {
constexpr size_t SCOPE_SIZE = 32;
constexpr size_t TOKEN_SIZE = 32;

std::string alias_for(const uint8_t* scope) {
    static constexpr char HEX[] = "0123456789abcdef";
    std::string alias = "starrustdesk.trusted-device.v2.";
    alias.reserve(alias.size() + SCOPE_SIZE * 2);
    for (size_t i = 0; i < SCOPE_SIZE; ++i) {
        alias.push_back(HEX[scope[i] >> 4]);
        alias.push_back(HEX[scope[i] & 15]);
    }
    return alias;
}

Asset_Attr bytes_attr(Asset_Tag tag, const uint8_t* data, size_t length) {
    Asset_Attr result{};
    result.tag = tag;
    result.value.blob.size = static_cast<uint32_t>(length);
    result.value.blob.data = const_cast<uint8_t*>(data);
    return result;
}

Asset_Attr number_attr(Asset_Tag tag, uint32_t value) {
    Asset_Attr result{};
    result.tag = tag;
    result.value.u32 = value;
    return result;
}
}

// Returns 0 for a valid credential, 1 if it does not exist, and -1 otherwise.
extern "C" int srd_trusted_asset_load(const uint8_t* scope, size_t scope_len,
                                     uint8_t* token, size_t token_len) {
    if (!scope || scope_len != SCOPE_SIZE || !token || token_len != TOKEN_SIZE) return -1;
    std::memset(token, 0, TOKEN_SIZE);
    const std::string alias = alias_for(scope);
    Asset_Attr query[] = {
        bytes_attr(ASSET_TAG_ALIAS, reinterpret_cast<const uint8_t*>(alias.data()), alias.size()),
        number_attr(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ALL)
    };
    Asset_ResultSet result{};
    const int32_t status = OH_Asset_Query(query, 2, &result);
    if (status == ASSET_NOT_FOUND) return 1;
    if (status != ASSET_SUCCESS) return -1;
    // A malformed/obsolete stored item is not a usable credential. Permit a
    // fresh explicit enrollment, which replaces it atomically; never send it.
    int outcome = result.count <= 1 ? 1 : -1;
    if (result.count == 1 && result.results) {
        const Asset_Attr* secret = OH_Asset_ParseAttr(&result.results[0], ASSET_TAG_SECRET);
        if (secret && secret->value.blob.data && secret->value.blob.size == TOKEN_SIZE) {
            std::memcpy(token, secret->value.blob.data, TOKEN_SIZE);
            outcome = 0;
        }
    }
    OH_Asset_FreeResultSet(&result);
    return outcome;
}

// A conflict is updated by the system service, not by deleting the old item
// first. Credentials never participate in application/cloud backup or sync.
extern "C" int srd_trusted_asset_save(const uint8_t* scope, size_t scope_len,
                                     const uint8_t* token, size_t token_len) {
    if (!scope || scope_len != SCOPE_SIZE || !token || token_len != TOKEN_SIZE) return -1;
    const std::string alias = alias_for(scope);
    Asset_Attr attrs[] = {
        bytes_attr(ASSET_TAG_ALIAS, reinterpret_cast<const uint8_t*>(alias.data()), alias.size()),
        bytes_attr(ASSET_TAG_SECRET, token, TOKEN_SIZE),
        number_attr(ASSET_TAG_ACCESSIBILITY, ASSET_ACCESSIBILITY_DEVICE_FIRST_UNLOCKED),
        number_attr(ASSET_TAG_SYNC_TYPE, ASSET_SYNC_TYPE_NEVER),
        number_attr(ASSET_TAG_CONFLICT_RESOLUTION, ASSET_CONFLICT_OVERWRITE)
    };
    return OH_Asset_Add(attrs, 5) == ASSET_SUCCESS ? 0 : -1;
}
