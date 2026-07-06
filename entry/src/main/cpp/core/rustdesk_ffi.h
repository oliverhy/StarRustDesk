#ifndef RUSTDESK_CORE_FFI_H
#define RUSTDESK_CORE_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

int rust_connect(const char* peer_id, const char* password,
                 const char* rendezvous_server, const char* relay_server,
                 const char* server_key);
int rust_set_performance_preset(const char* preset);
int rust_disconnect(void);
int rust_get_connection_status(void);
int rust_get_connection_route(void);
int rust_send_mouse_event(double x, double y, int action);
int rust_send_mouse_wheel(double delta_x, double delta_y);
int rust_send_key_event(int key_code, int action);
int rust_send_physical_key_event(int scan_code, int action);
int rust_send_text(const char* text);
int rust_send_clipboard_text(const char* text);
char* rust_take_remote_clipboard_text(void);
int rust_get_display_count(void);
int rust_get_current_display(void);
int rust_switch_display(int display);
int rust_refresh_video(void);
typedef void (*rust_frame_callback_t)(const unsigned char* data, int length, int width, int height);
void rust_set_frame_callback(rust_frame_callback_t callback);
typedef void (*rust_event_callback_t)(const char* message);
void rust_set_event_callback(rust_event_callback_t callback);
typedef int (*rust_audio_start_callback_t)(int sample_rate, int channels);
typedef void (*rust_audio_stop_callback_t)(void);
typedef void (*rust_audio_frame_callback_t)(const unsigned char* data, int length);
void rust_set_audio_callbacks(rust_audio_start_callback_t start_callback,
                              rust_audio_stop_callback_t stop_callback,
                              rust_audio_frame_callback_t frame_callback);
char* rust_get_device_id(void);
void rust_free_string(char* s);

#ifdef __cplusplus
}
#endif

#endif
