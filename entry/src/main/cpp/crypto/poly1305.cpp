#include "poly1305.h"
#include <cstring>

static inline uint32_t read32le(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void write32le(uint8_t* p, uint32_t v) {
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}

Poly1305::Poly1305() : bufPos_(0), messageLen_(0) {
    memset(r_, 0, sizeof(r_));
    memset(s_, 0, sizeof(s_));
    memset(acc_, 0, sizeof(acc_));
    memset(buf_, 0, sizeof(buf_));
}

void Poly1305::setKey(const uint8_t* key) {
    // r = key[0..15] with bottom 2 bits of each 32-bit word cleared
    r_[0] = read32le(key) & 0x0ffffffc;
    r_[1] = (read32le(key + 4) & 0x0ffffffc);
    r_[2] = (read32le(key + 8) & 0x0ffffffc);
    r_[3] = (read32le(key + 12) & 0x0ffffffc);
    // s = key[16..31]
    s_[0] = read32le(key + 16);
    s_[1] = read32le(key + 20);
    s_[2] = read32le(key + 24);
    s_[3] = read32le(key + 28);
}

void Poly1305::update(const uint8_t* data, int length) {
    for (int i = 0; i < length; i++) {
        buf_[bufPos_++] = data[i];
        if (bufPos_ == 16) {
            // Process block
            uint32_t n[4];
            n[0] = read32le(buf_) & 0x03ffffff;
            n[1] = (read32le(buf_ + 4) >> 2) & 0x03ffffff;
            n[2] = (read32le(buf_ + 8) >> 4) & 0x03ffffff;
            n[3] = (read32le(buf_ + 12) >> 6) & 0x03ffffff;

            // acc += n
            uint64_t carry = 0;
            acc_[0] += n[0]; carry = acc_[0] >> 26; acc_[0] &= 0x3ffffff;
            acc_[1] += n[1] + (uint32_t)carry; carry = acc_[1] >> 26; acc_[1] &= 0x3ffffff;
            acc_[2] += n[2] + (uint32_t)carry; carry = acc_[2] >> 26; acc_[2] &= 0x3ffffff;
            acc_[3] += n[3] + (uint32_t)carry; carry = acc_[3] >> 26; acc_[3] &= 0x3ffffff;
            acc_[4] += (uint32_t)carry; carry = acc_[4] >> 26; acc_[4] &= 0x3ffffff;
            acc_[0] += (uint32_t)carry * 5;

            // acc *= r
            uint32_t t[5];
            for (int j = 0; j < 5; j++) {
                uint64_t sum = 0;
                for (int k = 0; k < 5; k++) {
                    if (j + k < 4) {
                        sum += (uint64_t)acc_[j] * r_[k];
                    } else {
                        sum += (uint64_t)acc_[j] * r_[k] * 5;
                    }
                }
                t[j] = (uint32_t)(sum & 0x3ffffff);
                carry = sum >> 26;
                if (j + 1 < 5) {
                    t[j + 1] += (uint32_t)carry;
                } else {
                    t[0] += (uint32_t)carry * 5;
                }
            }
            memcpy(acc_, t, sizeof(t));

            bufPos_ = 0;
        }
    }
    messageLen_ += length;
}

void Poly1305::finish(uint8_t tag[TAG_SIZE]) {
    if (bufPos_ > 0) {
        // Pad with 0x01 then zeros
        buf_[bufPos_++] = 1;
        while (bufPos_ < 16) {
            buf_[bufPos_++] = 0;
        }

        uint32_t n[4];
        n[0] = read32le(buf_) & 0x03ffffff;
        n[1] = (read32le(buf_ + 4) >> 2) & 0x03ffffff;
        n[2] = (read32le(buf_ + 8) >> 4) & 0x03ffffff;
        n[3] = (read32le(buf_ + 12) >> 6) & 0x03ffffff;

        uint64_t carry = 0;
        acc_[0] += n[0]; carry = acc_[0] >> 26; acc_[0] &= 0x3ffffff;
        acc_[1] += n[1] + (uint32_t)carry; carry = acc_[1] >> 26; acc_[1] &= 0x3ffffff;
        acc_[2] += n[2] + (uint32_t)carry; carry = acc_[2] >> 26; acc_[2] &= 0x3ffffff;
        acc_[3] += n[3] + (uint32_t)carry; carry = acc_[3] >> 26; acc_[3] &= 0x3ffffff;
        acc_[4] += (uint32_t)carry; carry = acc_[4] >> 26; acc_[4] &= 0x3ffffff;
        acc_[0] += (uint32_t)carry * 5;
    }

    // Fully reduce acc
    uint32_t carry = 0;
    // acc[4] -> acc[0] * 5
    uint64_t c = (uint64_t)acc_[4] * 5;
    acc_[0] += (uint32_t)(c & 0x3ffffff); c >>= 26;
    acc_[1] += (uint32_t)c; c >>= 26;
    acc_[2] += (uint32_t)c; c >>= 26;
    acc_[3] += (uint32_t)c; c >>= 26;
    acc_[4] = (uint32_t)c;

    // acc - p
    uint32_t t[5];
    t[0] = acc_[0] - 0x3ffffff;
    t[1] = acc_[1] - 0x3ffffff;
    t[2] = acc_[2] - 0x3ffffff;
    t[3] = acc_[3] - 0x3ffffff;
    t[4] = acc_[4] - 0x3ffffff;

    // If borrow, use original
    if (t[4] >> 31) {
        t[0] = acc_[0]; t[1] = acc_[1]; t[2] = acc_[2]; t[3] = acc_[3]; t[4] = acc_[4];
    }

    // Pack into tag
    write32le(tag, t[0] | (t[1] << 26));
    write32le(tag + 4, (t[1] >> 6) | (t[2] << 20));
    write32le(tag + 8, (t[2] >> 12) | (t[3] << 14));
    write32le(tag + 12, (t[3] >> 18) | (t[4] << 8));

    // Add s
    uint32_t carry2 = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t sum = read32le(tag + i * 4) + s_[i] + carry2;
        write32le(tag + i * 4, sum);
        carry2 = (sum < read32le(tag + i * 4)) ? 1 : 0;
    }
}
