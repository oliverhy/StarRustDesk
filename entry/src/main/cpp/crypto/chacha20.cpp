#include "chacha20.h"
#include <cstring>

static inline uint32_t rotl32(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}

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

static const char* CONSTANTS = "expand 32-byte k";

ChaCha20::ChaCha20() : counter_(0), blockPos_(0) {
    memset(key_, 0, KEY_SIZE);
    memset(nonce_, 0, NONCE_SIZE);
    memset(block_, 0, BLOCK_SIZE);
}

void ChaCha20::setKey(const uint8_t* key, int keyLen) {
    memcpy(key_, key, keyLen < KEY_SIZE ? keyLen : KEY_SIZE);
}

void ChaCha20::setNonce(const uint8_t* nonce, int nonceLen) {
    memcpy(nonce_, nonce, nonceLen < NONCE_SIZE ? nonceLen : NONCE_SIZE);
}

void ChaCha20::setCounter(uint32_t counter) {
    counter_ = counter;
}

void ChaCha20::quarterRound(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d) {
    a += b; d ^= a; d = rotl32(d, 16);
    c += d; b ^= c; b = rotl32(b, 12);
    a += b; d ^= a; d = rotl32(d, 8);
    c += d; b ^= c; b = rotl32(b, 7);
}

void ChaCha20::blockFunction(uint8_t output[BLOCK_SIZE]) {
    uint32_t x[16];
    memcpy(x, state_, sizeof(x));

    for (int i = 0; i < 10; i++) {
        quarterRound(x[0], x[4], x[8], x[12]);
        quarterRound(x[1], x[5], x[9], x[13]);
        quarterRound(x[2], x[6], x[10], x[14]);
        quarterRound(x[3], x[7], x[11], x[15]);
        quarterRound(x[0], x[5], x[10], x[15]);
        quarterRound(x[1], x[6], x[11], x[12]);
        quarterRound(x[2], x[7], x[8], x[13]);
        quarterRound(x[3], x[4], x[9], x[14]);
    }

    for (int i = 0; i < 16; i++) {
        write32le(output + i * 4, x[i] + state_[i]);
    }
}

void ChaCha20::encrypt(const uint8_t* input, uint8_t* output, int length) {
    // Initialize state
    memcpy(state_, CONSTANTS, 16);
    write32le((uint8_t*)&state_[4], read32le(key_));
    write32le((uint8_t*)&state_[5], read32le(key_ + 4));
    write32le((uint8_t*)&state_[6], read32le(key_ + 8));
    write32le((uint8_t*)&state_[7], read32le(key_ + 12));
    write32le((uint8_t*)&state_[8], read32le(key_ + 16));
    write32le((uint8_t*)&state_[9], read32le(key_ + 20));
    write32le((uint8_t*)&state_[10], read32le(key_ + 24));
    write32le((uint8_t*)&state_[11], read32le(key_ + 28));
    state_[12] = counter_;
    memcpy(&state_[13], nonce_, 12);

    for (int i = 0; i < length; i++) {
        if (blockPos_ == 0) {
            blockFunction(block_);
            state_[12]++;
        }
        output[i] = input[i] ^ block_[blockPos_];
        blockPos_ = (blockPos_ + 1) & 63;
    }
}

void ChaCha20::decrypt(const uint8_t* input, uint8_t* output, int length) {
    encrypt(input, output, length);
}
