#include "aead.h"
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <unistd.h>
#include <fcntl.h>

static void secure_random(uint8_t* buf, int len) {
    int fd = open("/dev/urandom", O_RDONLY);
    int total = 0;
    if (fd >= 0) {
        while (total < len) {
            int n = read(fd, buf + total, len - total);
            if (n > 0) total += n;
            else break;
        }
        close(fd);
    }
    // Fallback: use ChaCha20 if urandom fails
    if (total < len) {
        ChaCha20 fallback;
        uint8_t seed[32] = {0};
        for (int i = 0; i < 32; i++) {
            seed[i] = (uint8_t)((uintptr_t)&seed ^ (uintptr_t)buf ^ time(nullptr));
        }
        fallback.setKey(seed);
        fallback.setNonce(seed);
        fallback.encrypt(buf + total, buf + total, len - total);
    }
}

AEAD::AEAD() {
    memset(key_, 0, KEY_SIZE);
    memset(nonce_, 0, NONCE_SIZE);
}

void AEAD::setKey(const uint8_t* key) {
    memcpy(key_, key, KEY_SIZE);
}

void AEAD::setNonce(const uint8_t* nonce) {
    memcpy(nonce_, nonce, NONCE_SIZE);
}

void AEAD::poly1305KeyGen(const uint8_t* key, uint8_t polyKey[Poly1305::KEY_SIZE]) {
    chacha20_.setKey(key);
    chacha20_.setNonce(nonce_);
    chacha20_.setCounter(0);
    uint8_t block[ChaCha20::BLOCK_SIZE];
    memset(block, 0, ChaCha20::BLOCK_SIZE);
    chacha20_.encrypt(block, polyKey, Poly1305::KEY_SIZE);
}

int AEAD::encrypt(const uint8_t* plaintext, int plaintextLen,
                  const uint8_t* aad, int aadLen,
                  uint8_t* ciphertext, uint8_t tag[TAG_SIZE]) {
    // Generate Poly1305 key from ChaCha20 keystream at counter 0
    uint8_t polyKey[Poly1305::KEY_SIZE];
    poly1305KeyGen(key_, polyKey);

    // Encrypt with ChaCha20 starting at counter 1
    chacha20_.setKey(key_);
    chacha20_.setNonce(nonce_);
    chacha20_.setCounter(1);
    chacha20_.encrypt(plaintext, ciphertext, plaintextLen);

    // Compute Poly1305 tag over AAD + ciphertext
    Poly1305 poly;
    poly.setKey(polyKey);
    if (aad && aadLen > 0) {
        poly.update(aad, aadLen);
    }
    // Pad AAD to 16 bytes
    int aadPad = (16 - (aadLen % 16)) % 16;
    uint8_t zero[16] = {0};
    if (aadPad > 0) {
        poly.update(zero, aadPad);
    }
    poly.update(ciphertext, plaintextLen);
    int ctPad = (16 - (plaintextLen % 16)) % 16;
    if (ctPad > 0) {
        poly.update(zero, ctPad);
    }
    // Append lengths as 64-bit LE
    uint8_t lenBlock[8];
    uint64_t aadLen64 = (uint64_t)aadLen;
    uint64_t ctLen64 = (uint64_t)plaintextLen;
    for (int i = 0; i < 8; i++) {
        lenBlock[i] = (uint8_t)(aadLen64 >> (i * 8));
    }
    poly.update(lenBlock, 8);
    for (int i = 0; i < 8; i++) {
        lenBlock[i] = (uint8_t)(ctLen64 >> (i * 8));
    }
    poly.update(lenBlock, 8);

    poly.finish(tag);
    return 0;
}

int AEAD::decrypt(const uint8_t* ciphertext, int ciphertextLen,
                  const uint8_t* aad, int aadLen,
                  const uint8_t* tag, uint8_t* plaintext) {
    // Verify tag first
    uint8_t computedTag[TAG_SIZE];
    uint8_t polyKey[Poly1305::KEY_SIZE];
    poly1305KeyGen(key_, polyKey);

    chacha20_.setKey(key_);
    chacha20_.setNonce(nonce_);
    chacha20_.setCounter(1);

    Poly1305 poly;
    poly.setKey(polyKey);
    if (aad && aadLen > 0) {
        poly.update(aad, aadLen);
    }
    int aadPad = (16 - (aadLen % 16)) % 16;
    uint8_t zero[16] = {0};
    if (aadPad > 0) {
        poly.update(zero, aadPad);
    }
    poly.update(ciphertext, ciphertextLen);
    int ctPad = (16 - (ciphertextLen % 16)) % 16;
    if (ctPad > 0) {
        poly.update(zero, ctPad);
    }
    uint8_t lenBlock[8];
    uint64_t aadLen64 = (uint64_t)aadLen;
    uint64_t ctLen64 = (uint64_t)ciphertextLen;
    for (int i = 0; i < 8; i++) {
        lenBlock[i] = (uint8_t)(aadLen64 >> (i * 8));
    }
    poly.update(lenBlock, 8);
    for (int i = 0; i < 8; i++) {
        lenBlock[i] = (uint8_t)(ctLen64 >> (i * 8));
    }
    poly.update(lenBlock, 8);
    poly.finish(computedTag);

    // Constant-time tag comparison
    int diff = 0;
    for (int i = 0; i < TAG_SIZE; i++) {
        diff |= tag[i] ^ computedTag[i];
    }
    if (diff != 0) {
        return -1;
    }

    // Decrypt
    chacha20_.encrypt(ciphertext, plaintext, ciphertextLen);
    return 0;
}

void AEAD::generateKey(uint8_t key[KEY_SIZE]) {
    secure_random(key, KEY_SIZE);
}

void AEAD::deriveKey(const uint8_t* password, int passwordLen,
                     const uint8_t* salt, int saltLen,
                     uint8_t key[KEY_SIZE]) {
    // Simple iterative hash-based KDF (PBKDF2-like using ChaCha20 as PRF)
    // In production, use a proper PBKDF2/Argon2 implementation
    memset(key, 0, KEY_SIZE);
    uint8_t state[64];
    int pos = 0;
    // Mix password
    for (int i = 0; i < passwordLen && pos < 64; i++) {
        state[pos++] = password[i];
    }
    // Mix salt
    for (int i = 0; i < saltLen && pos < 64; i++) {
        state[pos++] = salt[i];
    }
    // Pad to 64 bytes
    while (pos < 64) {
        state[pos++] = 0;
    }
    // Multiple rounds of ChaCha20 mixing
    ChaCha20 mixer;
    mixer.setKey(state);
    mixer.setNonce(state + 32);
    mixer.encrypt(key, key, KEY_SIZE);
    // Second round with derived key as input
    mixer.setKey(key);
    mixer.setNonce(key + 20);
    mixer.encrypt(key, key, KEY_SIZE);
}
