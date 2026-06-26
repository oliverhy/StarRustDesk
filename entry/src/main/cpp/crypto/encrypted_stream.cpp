#include "encrypted_stream.h"
#include <cstring>

EncryptedStream::EncryptedStream() : sendCounter_(0), recvCounter_(0) {
    memset(key_, 0, AEAD::KEY_SIZE);
}

void EncryptedStream::setKey(const uint8_t* key) {
    memcpy(key_, key, AEAD::KEY_SIZE);
}

void EncryptedStream::setSendNonce(uint64_t counter) {
    sendCounter_ = counter;
}

void EncryptedStream::setRecvNonce(uint64_t counter) {
    recvCounter_ = counter;
}

std::vector<uint8_t> EncryptedStream::pack(const uint8_t* data, int length) {
    std::vector<uint8_t> packet(length + OVERHEAD);

    // Write nonce (first 8 bytes = counter LE, last 4 bytes = 0)
    uint8_t nonce[NONCE_SIZE];
    memset(nonce, 0, NONCE_SIZE);
    for (int i = 0; i < 8; i++) {
        nonce[i] = (uint8_t)(sendCounter_ >> (i * 8));
    }
    memcpy(packet.data(), nonce, NONCE_SIZE);

    // Encrypt
    aead_.setKey(key_);
    aead_.setNonce(nonce);
    uint8_t tag[AEAD::TAG_SIZE];
    aead_.encrypt(data, length, nullptr, 0, packet.data() + NONCE_SIZE, tag);
    memcpy(packet.data() + NONCE_SIZE + length, tag, TAG_SIZE);

    sendCounter_++;
    return packet;
}

int EncryptedStream::unpack(const uint8_t* packet, int packetLen, std::vector<uint8_t>& output) {
    if (packetLen < OVERHEAD) return -1;

    int cipherLen = packetLen - OVERHEAD;

    // Read nonce
    uint8_t nonce[NONCE_SIZE];
    memcpy(nonce, packet, NONCE_SIZE);

    // Verify nonce counter matches expected
    uint64_t counter = 0;
    for (int i = 0; i < 8; i++) {
        counter |= ((uint64_t)nonce[i]) << (i * 8);
    }
    if (counter != recvCounter_) return -1;

    // Decrypt
    aead_.setKey(key_);
    aead_.setNonce(nonce);
    output.resize(cipherLen);
    int result = aead_.decrypt(packet + NONCE_SIZE, cipherLen,
                               nullptr, 0,
                               packet + NONCE_SIZE + cipherLen,
                               output.data());
    if (result == 0) {
        recvCounter_++;
    }
    return result;
}
