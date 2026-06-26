#ifndef RUSTDESK_CORE_CHACHA20_H
#define RUSTDESK_CORE_CHACHA20_H

#include <cstdint>
#include <cstring>

class ChaCha20 {
public:
    static const int KEY_SIZE = 32;
    static const int NONCE_SIZE = 12;
    static const int BLOCK_SIZE = 64;

    ChaCha20();
    void setKey(const uint8_t* key, int keyLen = KEY_SIZE);
    void setNonce(const uint8_t* nonce, int nonceLen = NONCE_SIZE);
    void setCounter(uint32_t counter);
    void encrypt(const uint8_t* input, uint8_t* output, int length);
    void decrypt(const uint8_t* input, uint8_t* output, int length);

private:
    void quarterRound(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d);
    void blockFunction(uint8_t output[BLOCK_SIZE]);
    uint32_t state_[16];
    uint8_t key_[KEY_SIZE];
    uint8_t nonce_[NONCE_SIZE];
    uint32_t counter_;
    uint8_t block_[BLOCK_SIZE];
    int blockPos_;
};

#endif
