#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { SR_WAIT_IDR=1, SR_WAIT_RFI=2, SR_OUTPUT=4, SR_SPEC=8, SR_LOST=16, SR_FEC_COMPLETE=32, SR_ABANDON=64 };
void sr_begin(int enabled);
void sr_end(void);
void sr_socket(int fd,int end);
void sr_read(int fd,uint32_t hint);
void sr_old(uint32_t hint);
void sr_bad(uint32_t hint);
void sr_auth(uint32_t hint,int queued);
void sr_mark(uint32_t frame,unsigned flag);
void sr_abandon(uint32_t frame,unsigned have,unsigned need,uint32_t now);
void sr_gap(uint32_t first,uint32_t count);
int sesame_lan_retry_on_confirmed_wait(void);
void sesame_lan_observe_admitted(uint32_t frame,int parity);
#ifdef __cplusplus
}
#endif
