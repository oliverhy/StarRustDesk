#ifndef RUSTDESK_CORE_ENCRYPTED_STREAM_H
#define RUSTDESK_CORE_ENCRYPTED_STREAM_H

#include <cstdint>
#include <vector>
#include "crypto/aead.h"

class EncryptedStream {
public:
    EncryptedStream();
    void setKey(const uint8_t* key);
    void setSendNonce(uint64_t counter);
    void setRecvNonce(uint64_t counter);

    // Encrypt data for sending (prepends nonce, appends tag)
    std::vector<uint8_t> pack(const uint8_t* data, int length);

    // Decrypt received data (expects nonce + ciphertext + tag)
    // Returns -1 on auth failure
    int unpack(const uint8_t* packet, int packetLen, std::vector<uint8_t>& output);

    static const int NONCE_SIZE = 12;
    static const int TAG_SIZE = 16;
    static const int OVERHEAD = NONCE_SIZE + TAG_SIZE;

private:
    AEAD aead_;
    uint8_t key_[AEAD::KEY_SIZE];
    uint64_t sendCounter_;
    uint64_t recvCounter_;
};

#endif
