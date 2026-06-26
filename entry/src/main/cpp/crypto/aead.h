#ifndef RUSTDESK_CORE_AEAD_H
#define RUSTDESK_CORE_AEAD_H

#include <cstdint>
#include "chacha20.h"
#include "poly1305.h"

class AEAD {
public:
    static const int KEY_SIZE = 32;
    static const int NONCE_SIZE = 12;
    static const int TAG_SIZE = 16;

    AEAD();
    void setKey(const uint8_t* key);
    void setNonce(const uint8_t* nonce);

    int encrypt(const uint8_t* plaintext, int plaintextLen,
                const uint8_t* aad, int aadLen,
                uint8_t* ciphertext, uint8_t tag[TAG_SIZE]);

    int decrypt(const uint8_t* ciphertext, int ciphertextLen,
                const uint8_t* aad, int aadLen,
                const uint8_t* tag, uint8_t* plaintext);

    static void generateKey(uint8_t key[KEY_SIZE]);
    static void deriveKey(const uint8_t* password, int passwordLen,
                          const uint8_t* salt, int saltLen,
                          uint8_t key[KEY_SIZE]);

private:
    void poly1305KeyGen(const uint8_t* key, uint8_t polyKey[Poly1305::KEY_SIZE]);
    ChaCha20 chacha20_;
    uint8_t key_[KEY_SIZE];
    uint8_t nonce_[NONCE_SIZE];
};

#endif
