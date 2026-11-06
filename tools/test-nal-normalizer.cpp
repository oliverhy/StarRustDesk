#include "../entry/src/main/cpp/core/nal_normalizer.h"
#include <cassert>
#include <vector>

int main() {
    const uint8_t annex[] = {0,0,0,1,0x67,0x01};
    assert(normalizeAnnexBNals(annex, sizeof(annex), 64) == std::vector<uint8_t>(annex, annex + sizeof(annex)));
    const uint8_t prefixed[] = {0,0,0,2,0x67,0x01, 0,0,0,1,0x65};
    const std::vector<uint8_t> expected = {0,0,0,1,0x67,0x01, 0,0,0,1,0x65};
    assert(normalizeAnnexBNals(prefixed, sizeof(prefixed), 64) == expected);
    const uint8_t bare[] = {0x65, 0x01};
    assert((normalizeAnnexBNals(bare, sizeof(bare), 64) == std::vector<uint8_t>{0,0,0,1,0x65,0x01}));
    const uint8_t malicious[] = {0,0,0,1,0x67,0xff,0xff,0xff,0xff};
    const uint8_t badSecond[] = {0,0,0,2,0x67,0x01, 0xff,0xff,0xff,0xff};
    assert(normalizeAnnexBNals(badSecond, sizeof(badSecond), 64).empty());
    assert(normalizeAnnexBNals(nullptr, 2, 64).empty());
    assert(normalizeAnnexBNals(bare, sizeof(bare), 4).empty());
    assert(normalizeAnnexBNals(malicious, sizeof(malicious), 4).empty());
    const uint8_t overflow[] = {0xff,0xff,0xff,0xff,0x01};
    assert(normalizeAnnexBNals(overflow, sizeof(overflow), 64).size() == 9);
}
