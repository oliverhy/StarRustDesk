#ifndef RUSTDESK_CORE_FFI_H
#define RUSTDESK_CORE_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int rust_set_api_account_context(const char* json);
int rust_connect(const char* peer_id, const char* password,
                 const char* rendezvous_server, const char* relay_server,
                 const char* server_key, const char* client_hwid,
                 const char* client_id, int force_relay,
                 int allow_insecure_fallback, int file_only,
                 int lock_after_disconnect, int privacy_mode, const char* os_password,
                 int transport_policy);
const char* rust_get_build_id(void);
void rust_set_video_codec_support(int h264_supported, int vp9_supported,
                                  int vp8_supported, int av1_supported, int h265_supported);
int rust_set_performance_preset(const char* preset);
int rust_set_game_mode(int enabled, int apply_live);
int rust_set_game_fps(int fps, int apply_live);
int rust_get_game_mode(void);
int rust_get_game_effective_fps(void);
int rust_set_high_performance(int enabled, int apply_live);
int rust_get_requested_performance_fps(void);
int rust_get_requested_bitrate_percent(void);
int rust_set_remote_cursor_visible(int visible);
int rust_set_audio_enabled(int enabled);
int rust_set_privacy_mode(int enabled);
int rust_get_privacy_mode_state(void);
int rust_send_chat_message(const char* text);
char* rust_take_chat_messages(void);
int rust_request_voice_call(void);
int rust_voice_call_state(void);
int rust_end_voice_call(void);
int rust_send_voice_frame(const uint8_t* data, int length);
int rust_set_background_video_mode(int enabled);
int rust_disconnect(void);
int rust_get_connection_status(void);
int rust_get_connection_route(void);
int rust_get_connection_transport(void);
int rust_get_connection_delay_ms(void);
uint64_t rust_get_connection_delay_sample(void);
int rust_get_connection_target_bitrate_kb(void);
int rust_send_mouse_event(double x, double y, int action, int modifier_mask);
int rust_send_mouse_wheel(double delta_x, double delta_y, int modifier_mask);
int rust_send_mobile_action(int action);
int rust_is_peer_android(void);
int rust_send_key_event(int key_code, int action, int modifier_mask);
int rust_send_printable_shortcut_key(int key_code, int modifier_mask);
int rust_send_ctrl_alt_del(void);
int rust_can_send_ctrl_alt_del(void);
int rust_send_physical_key_event(int usb_hid_code, int action, int modifier_mask);
int rust_get_input_capabilities(void);
int rust_set_input_modes(int mode, int relative);
int rust_send_mouse_relative(double dx, double dy, int modifier_mask);
int rust_send_text(const char* text);
int rust_send_2fa(const char* code, const char* client_hwid);
int rust_send_clipboard_text(const char* text);
int rust_request_remote_directory(const char* path);
int rust_remote_file_operation(int kind, const char* path, const char* name);
char* rust_take_file_operation_result(void);
void rust_cancel_file_operation(void);
int rust_start_recording(const char* path);
int rust_stop_recording(void);
int rust_get_recording_status(void);
char* rust_take_remote_directory_result(void);
int rust_start_file_upload(const char* local_path, const char* file_name, const char* remote_directory);
int rust_start_file_download_batch(const char* requests_json, const char* local_root);
char* rust_get_file_transfer_status(void);
int rust_cancel_file_transfer(void);
char* rust_take_remote_clipboard_text(void);
int rust_get_display_count(void);
int rust_get_current_display(void);
int rust_get_remote_cursor_position(int32_t* x, int32_t* y, uint64_t* sequence);
int rust_get_remote_cursor_data(uint64_t* id, int32_t* hotx, int32_t* hoty,
                                int32_t* width, int32_t* height, uint64_t* sequence,
                                unsigned char* colors, int32_t colors_capacity);
int rust_is_remote_cursor_embedded(void);
int rust_switch_display(int display);
int rust_refresh_video(void);
int rust_fallback_video_to_vp9(void);
int rust_query_peer_online_states(const char* peers_json, const char* rendezvous_server,
                                  const char* requester_id);
char* rust_take_peer_online_states(void);
typedef void (*rust_frame_callback_t)(const unsigned char* data, int length, int width, int height,
                                      int is_key, int64_t pts);
void rust_set_frame_callback(rust_frame_callback_t callback);
typedef void (*rust_secondary_frame_callback_t)(const unsigned char* data, int length, int width,
                                                int height, int is_key, int64_t pts, int display, int codec);
void rust_set_secondary_frame_callback(rust_secondary_frame_callback_t callback);
int rust_is_secondary_display_supported(void);
int rust_set_secondary_display(int display);
int rust_send_secondary_mouse_event(int display, double x, double y, int action, int modifier_mask);
int rust_send_secondary_wheel(int display, double x, double y, double dx, double dy, int modifier_mask);
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
