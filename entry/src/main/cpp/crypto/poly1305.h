#ifndef RUSTDESK_CORE_POLY1305_H
#define RUSTDESK_CORE_POLY1305_H

#include <cstdint>

class Poly1305 {
public:
    static const int KEY_SIZE = 32;
    static const int TAG_SIZE = 16;

    Poly1305();
    void setKey(const uint8_t* key);
    void update(const uint8_t* data, int length);
    void finish(uint8_t tag[TAG_SIZE]);

private:
    uint32_t r_[4];
    uint32_t s_[4];
    uint32_t acc_[5];
    uint8_t buf_[16];
    int bufPos_;
    int messageLen_;
};

#endif
