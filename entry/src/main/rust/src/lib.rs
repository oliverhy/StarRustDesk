use std::ffi::{CStr, CString};
use std::net::SocketAddr;
use std::os::raw::{c_char, c_uchar};
use std::sync::mpsc::{self, Sender};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use hbb_common::config::{CONNECT_TIMEOUT, READ_TIMEOUT, RELAY_PORT, RS_PUB_KEY};
use hbb_common::message_proto::{
    key_event, login_response, message, misc, supported_decoding, video_frame, AudioFormat,
    Clipboard, ClipboardFormat, CodecAbility, ControlKey, EncodedVideoFrames, Hash, ImageQuality,
    KeyEvent, IdPk, KeyboardMode, LoginRequest, Message as PeerMessage, Misc, MouseEvent,
    MultiClipboards, OptionMessage, OSLogin, PublicKey, SupportedDecoding, SwitchDisplay,
    TestDelay, VideoFrame,
};
use hbb_common::rendezvous_proto::{
    punch_hole_response, rendezvous_message, ConnType, NatType, PunchHoleRequest, RequestRelay,
    RendezvousMessage,
};
use hbb_common::sha2::{Digest, Sha256};
use hbb_common::sodiumoxide::{
    base64::{self, Variant},
    crypto::{box_, secretbox, sign},
};
use hbb_common::protobuf::MessageField;
use hbb_common::socket_client::{check_port, connect_tcp, connect_tcp_local, ipv4_to_ipv6};
use hbb_common::uuid::Uuid;
use hbb_common::{AddrMangle, Stream};
use protobuf::{Enum, Message};
use tokio::runtime::Runtime;

type FrameCallback = extern "C" fn(*const c_uchar, i32, i32, i32);
type EventCallback = extern "C" fn(*const c_char);
type AudioStartCallback = extern "C" fn(i32, i32) -> i32;
type AudioStopCallback = extern "C" fn();
type AudioFrameCallback = extern "C" fn(*const c_uchar, i32);

static CONNECTION: Mutex<Option<Stream>> = Mutex::new(None);
static FRAME_CALLBACK: Mutex<Option<FrameCallback>> = Mutex::new(None);
static EVENT_CALLBACK: Mutex<Option<EventCallback>> = Mutex::new(None);
static AUDIO_START_CALLBACK: Mutex<Option<AudioStartCallback>> = Mutex::new(None);
static AUDIO_STOP_CALLBACK: Mutex<Option<AudioStopCallback>> = Mutex::new(None);
static AUDIO_FRAME_CALLBACK: Mutex<Option<AudioFrameCallback>> = Mutex::new(None);
static PASSWORD_HASH: Mutex<Vec<u8>> = Mutex::new(Vec::new());
static CURRENT_PEER_ID: Mutex<String> = Mutex::new(String::new());
static DISPLAY_COUNT: Mutex<i32> = Mutex::new(1);
static CURRENT_DISPLAY: Mutex<i32> = Mutex::new(0);
static DISPLAY_INFOS: Mutex<Vec<(i32, i32, i32, i32)>> = Mutex::new(Vec::new());
static REMOTE_CLIPBOARD_TEXT: Mutex<Option<String>> = Mutex::new(None);
static LAST_SENT_CLIPBOARD_TEXT: Mutex<String> = Mutex::new(String::new());
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static PEER_MESSAGE_SENDER: Mutex<Option<Sender<QueuedPeerMessage>>> = Mutex::new(None);
static SESSION_ID: AtomicU64 = AtomicU64::new(0);
static LAST_FPS_HINT_MS: AtomicU64 = AtomicU64::new(0);
static LAST_VIDEO_RECEIVED_MS: AtomicU64 = AtomicU64::new(0);
static CONNECTION_ACTIVE: AtomicBool = AtomicBool::new(false);
static CONNECTION_ROUTE: AtomicI32 = AtomicI32::new(0);
static AUDIO_RESET_IN_PROGRESS: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy)]
struct PerformanceConfig {
    fps: i32,
    quality: ImageQuality,
}

struct QueuedPeerMessage {
    session_id: u64,
    message: PeerMessage,
}

static PERFORMANCE_CONFIG: Mutex<PerformanceConfig> = Mutex::new(PerformanceConfig {
    fps: 45,
    quality: ImageQuality::Low,
});

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

fn reset_display_state() {
    if let Ok(mut guard) = DISPLAY_COUNT.try_lock() {
        *guard = 1;
    }
    if let Ok(mut guard) = CURRENT_DISPLAY.try_lock() {
        *guard = 0;
    }
    if let Ok(mut guard) = DISPLAY_INFOS.try_lock() {
        guard.clear();
    }
}

fn clear_connection_for_session(session_id: u64) -> bool {
    clear_peer_message_sender();
    if let Ok(mut guard) = CONNECTION.try_lock() {
        if SESSION_ID.load(Ordering::SeqCst) == session_id {
            *guard = None;
        }
        return true;
    }
    emit_event("connection cleanup skipped: connection busy");
    false
}

fn clear_peer_message_sender() {
    if let Ok(mut guard) = PEER_MESSAGE_SENDER.try_lock() {
        *guard = None;
    }
}

#[no_mangle]
pub extern "C" fn rust_set_frame_callback(cb: Option<FrameCallback>) {
    if let Ok(mut guard) = FRAME_CALLBACK.lock() {
        *guard = cb;
    }
}

#[no_mangle]
pub extern "C" fn rust_set_event_callback(cb: Option<EventCallback>) {
    if let Ok(mut guard) = EVENT_CALLBACK.lock() {
        *guard = cb;
    }
}

#[no_mangle]
pub extern "C" fn rust_set_audio_callbacks(
    start_cb: Option<AudioStartCallback>,
    stop_cb: Option<AudioStopCallback>,
    frame_cb: Option<AudioFrameCallback>,
) {
    if let Ok(mut guard) = AUDIO_START_CALLBACK.lock() {
        *guard = start_cb;
    }
    if let Ok(mut guard) = AUDIO_STOP_CALLBACK.lock() {
        *guard = stop_cb;
    }
    if let Ok(mut guard) = AUDIO_FRAME_CALLBACK.lock() {
        *guard = frame_cb;
    }
}

#[no_mangle]
pub extern "C" fn rust_connect(
    peer_id: *const c_char,
    password: *const c_char,
    rendezvous_server: *const c_char,
    relay_server: *const c_char,
    server_key: *const c_char,
) -> i32 {
    if peer_id.is_null() {
        return -1;
    }

    let peer = match cstr_to_string(peer_id) {
        Some(s) if !s.is_empty() => s,
        _ => return -1,
    };
    emit_event("rust_connect entered");
    let session_id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    reset_display_state();
    let _ = clear_connection_for_session(session_id);
    emit_event("previous connection cleared");
    let pass = cstr_to_string(password).unwrap_or_default();
    let rv = cstr_to_string(rendezvous_server).unwrap_or_default();
    let relay_override = cstr_to_string(relay_server).unwrap_or_default();
    let key = cstr_to_string(server_key).unwrap_or_default();

    let Ok(mut password_guard) = PASSWORD_HASH.try_lock() else {
        emit_event("connect failed: credential lock busy");
        return -22;
    };
    *password_guard = pass.as_bytes().to_vec();
    drop(password_guard);

    let Ok(mut peer_guard) = CURRENT_PEER_ID.try_lock() else {
        emit_event("connect failed: peer lock busy");
        return -22;
    };
    *peer_guard = peer.clone();
    drop(peer_guard);

    clear_clipboard_state();

    let rendezvous_addr = with_port(if rv.is_empty() { "rustdesk.com" } else { &rv }, 21116);
    emit_event(&format!("connect start peer={peer} rendezvous={rendezvous_addr} relay_override={relay_override} key_set={}", !key.is_empty()));
    let rt = runtime();

    rt.block_on(async {
        let mut rv_conn = match connect_tcp(rendezvous_addr.clone(), CONNECT_TIMEOUT).await {
            Ok(s) => {
                emit_event("rendezvous tcp connected");
                s
            }
            Err(e) => {
                emit_event(&format!("rendezvous tcp failed: {e}"));
                return -1;
            }
        };

        let mut req = RendezvousMessage::new();
        req.set_punch_hole_request(PunchHoleRequest {
            id: peer.clone(),
            token: pass,
            nat_type: NatType::UNKNOWN_NAT.into(),
            licence_key: key.clone(),
            conn_type: ConnType::DEFAULT_CONN.into(),
            version: "1.2.0".to_string(),
            ..Default::default()
        });

        if rv_conn.send(&req).await.is_err() {
            emit_event("punch request send failed");
            return -2;
        }
        emit_event("punch request sent");

        let local_addr = rv_conn.local_addr();
        let response = match next_rendezvous(&mut rv_conn, READ_TIMEOUT).await {
            Some(msg) => {
                emit_event("rendezvous response received");
                msg
            }
            None => {
                emit_event("rendezvous response timeout");
                return -7;
            }
        };

        let mut peer_addr: Option<SocketAddr> = None;
        let mut relay_from_server = relay_override.clone();
        let mut signed_id_pk = Vec::new();

        match response.union {
            Some(rendezvous_message::Union::PunchHoleResponse(ph)) => {
                emit_event(&format!(
                    "punch response socket_addr={} relay={} pk_len={} other_failure={}",
                    ph.socket_addr.len(),
                    ph.relay_server,
                    ph.pk.len(),
                    ph.other_failure
                ));
                if !ph.other_failure.is_empty() {
                    return -13;
                }
                signed_id_pk = ph.pk.to_vec();
                if !ph.socket_addr.is_empty() {
                    peer_addr = Some(AddrMangle::decode(&ph.socket_addr));
                }
                if relay_from_server.is_empty() {
                    relay_from_server = ph.relay_server;
                }
                if peer_addr.is_none() && relay_from_server.is_empty() {
                    match ph.failure.enum_value() {
                        Ok(punch_hole_response::Failure::ID_NOT_EXIST) => return -8,
                        Ok(punch_hole_response::Failure::OFFLINE) => return -9,
                        Ok(punch_hole_response::Failure::LICENSE_MISMATCH) => return -10,
                        Ok(punch_hole_response::Failure::LICENSE_OVERUSE) => return -11,
                        Err(_) => return -3,
                    }
                }
            }
            Some(rendezvous_message::Union::PunchHole(ph)) => {
                emit_event(&format!(
                    "punch hole socket_addr={} relay={}",
                    ph.socket_addr.len(),
                    ph.relay_server
                ));
                if !ph.socket_addr.is_empty() {
                    peer_addr = Some(AddrMangle::decode(&ph.socket_addr));
                }
                if relay_from_server.is_empty() {
                    relay_from_server = ph.relay_server;
                }
            }
            Some(rendezvous_message::Union::RelayResponse(rr)) => {
                emit_event(&format!(
                    "relay response relay={} uuid_len={} pk_len={} refuse={}",
                    rr.relay_server,
                    rr.uuid.len(),
                    rr.pk().len(),
                    rr.refuse_reason
                ));
                if !rr.refuse_reason.is_empty() {
                    return -13;
                }
                signed_id_pk = rr.pk().to_vec();
                let relay = if rr.relay_server.is_empty() {
                    relay_from_server.clone()
                } else {
                    rr.relay_server.clone()
                };
                if relay.is_empty() || rr.uuid.is_empty() {
                    emit_event("relay response missing relay server or uuid");
                    return -4;
                }
                relay_from_server = relay;
                let addr = if !rr.socket_addr.is_empty() {
                    Some(AddrMangle::decode(&rr.socket_addr))
                } else {
                    None
                };
                if let Some(addr) = addr {
                    peer_addr = Some(addr);
                }
                let mut stream = match create_relay(&peer, &rr.uuid, &relay_from_server, &key, local_addr.is_ipv4()).await {
                    Ok(s) => {
                        emit_event("relay connected from relay response");
                        s
                    }
                    Err(e) => {
                        emit_event(&format!("relay response connect failed: {e}"));
                        return -15;
                    }
                };
                if secure_peer_connection(&peer, &signed_id_pk, &key, &mut stream)
                    .await
                    .is_err()
                {
                    emit_event("secure fallback failed");
                    return -16;
                }
                emit_event("secure fallback completed");

                if SESSION_ID.load(Ordering::SeqCst) != session_id {
                    emit_event("connect session stale before store");
                    return -19;
                }
                stream.set_send_timeout(5000);
                CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
                CONNECTION_ROUTE.store(2, Ordering::SeqCst);

                spawn_receive_loop(session_id, stream);
                emit_event("receive loop spawned");
                return 0;
            }
            _ => {
                emit_event(&format!(
                    "unexpected rendezvous response kind={}",
                    rendezvous_message_kind(&response.union)
                ));
                return -5;
            }
        }

        let mut stream = if let Some(addr) = peer_addr {
            emit_event(&format!("try direct peer addr={addr} local={local_addr}"));
            match connect_tcp_local(addr, Some(local_addr), 6000).await {
                Ok(s) => {
                    emit_event("direct peer connected");
                    CONNECTION_ROUTE.store(1, Ordering::SeqCst);
                    s
                }
                Err(_) if !relay_from_server.is_empty() => {
                    emit_event("direct peer failed, try relay");
                    match request_relay(&peer, &relay_from_server, &rendezvous_addr, &key).await {
                        Ok(s) => {
                            emit_event("relay connected");
                            CONNECTION_ROUTE.store(2, Ordering::SeqCst);
                            s
                        }
                        Err(e) => {
                            emit_event(&format!("relay failed: {e}"));
                            return -15;
                        }
                    }
                }
                Err(e) => {
                    emit_event(&format!("direct peer failed: {e}"));
                    return -14;
                }
            }
        } else if !relay_from_server.is_empty() {
            emit_event("no direct addr, try relay");
            match request_relay(&peer, &relay_from_server, &rendezvous_addr, &key).await {
                Ok(s) => {
                    emit_event("relay connected");
                    CONNECTION_ROUTE.store(2, Ordering::SeqCst);
                    s
                }
                Err(e) => {
                    emit_event(&format!("relay failed: {e}"));
                    return -15;
                }
            }
        } else {
            emit_event("no direct addr and no relay");
            return -4;
        };

        if secure_peer_connection(&peer, &signed_id_pk, &key, &mut stream)
            .await
            .is_err()
        {
            emit_event("secure fallback failed");
            return -16;
        }
        emit_event("secure fallback completed");

        if SESSION_ID.load(Ordering::SeqCst) != session_id {
            emit_event("connect session stale before store");
            return -19;
        }
        stream.set_send_timeout(5000);
        CONNECTION_ACTIVE.store(true, Ordering::SeqCst);

        spawn_receive_loop(session_id, stream);
        emit_event("receive loop spawned");
        0
    })
}

#[no_mangle]
pub extern "C" fn rust_set_performance_preset(preset: *const c_char) -> i32 {
    let preset = cstr_to_string(preset).unwrap_or_else(|| "smooth".to_string());
    let config = match preset.as_str() {
        "stable" => PerformanceConfig {
            fps: 30,
            quality: ImageQuality::Balanced,
        },
        "high_fps" => PerformanceConfig {
            fps: 60,
            quality: ImageQuality::Balanced,
        },
        "smooth" => PerformanceConfig {
            fps: 45,
            quality: ImageQuality::Low,
        },
        "silky" => PerformanceConfig {
            fps: 60,
            quality: ImageQuality::Low,
        },
        _ => PerformanceConfig {
            fps: 45,
            quality: ImageQuality::Low,
        },
    };
    if let Ok(mut guard) = PERFORMANCE_CONFIG.lock() {
        *guard = config;
    }
    0
}

#[no_mangle]
pub extern "C" fn rust_disconnect() -> i32 {
    let session_id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    reset_audio_async();
    reset_display_state();
    let _ = clear_connection_for_session(session_id);
    clear_clipboard_state();
    0
}

#[no_mangle]
pub extern "C" fn rust_get_connection_status() -> i32 {
    if CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        2
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn rust_get_connection_route() -> i32 {
    if CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        CONNECTION_ROUTE.load(Ordering::SeqCst)
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn rust_send_mouse_event(x: f64, y: f64, action: i32) -> i32 {
    let mask = match action {
        0 => 0,             // move
        1 => (1 << 3) | 1,  // left down
        2 => (1 << 3) | 2,  // left up
        3 => (2 << 3) | 1,  // right down
        4 => (2 << 3) | 2,  // right up
        _ => 0,
    };
    let (offset_x, offset_y) = current_display_origin();
    let mut msg = PeerMessage::new();
    msg.set_mouse_event(MouseEvent {
        mask,
        x: x as i32 + offset_x,
        y: y as i32 + offset_y,
        ..Default::default()
    });
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_mouse_wheel(delta_x: f64, delta_y: f64) -> i32 {
    let mut msg = PeerMessage::new();
    msg.set_mouse_event(MouseEvent {
        mask: 3,
        x: delta_x.round() as i32,
        y: delta_y.round() as i32,
        ..Default::default()
    });
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_key_event(key_code: i32, action: i32) -> i32 {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Legacy.into(),
        ..Default::default()
    };
    match key_code_to_control(key_code) {
        Some(ctrl) => event.set_control_key(ctrl),
        None => event.union = Some(key_event::Union::Chr(key_code.max(0) as u32)),
    }
    let mut msg = PeerMessage::new();
    msg.set_key_event(event);
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_physical_key_event(scan_code: i32, action: i32) -> i32 {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Map.into(),
        ..Default::default()
    };
    event.union = Some(key_event::Union::Chr(scan_code.max(0) as u32));
    let mut msg = PeerMessage::new();
    msg.set_key_event(event);
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_text(text: *const c_char) -> i32 {
    if text.is_null() {
        return -1;
    }
    let text = match unsafe { CStr::from_ptr(text) }.to_str() {
        Ok(value) => value,
        Err(_) => return -2,
    };
    if text.is_empty() {
        return 0;
    }
    let mut event = KeyEvent::new();
    event.set_seq(text.to_string());
    let mut msg = PeerMessage::new();
    msg.set_key_event(event);
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_clipboard_text(text: *const c_char) -> i32 {
    if text.is_null() {
        return -1;
    }
    let text = match unsafe { CStr::from_ptr(text) }.to_str() {
        Ok(value) => value.to_string(),
        Err(_) => return -2,
    };
    if text.is_empty() {
        return 0;
    }

    if let Ok(mut guard) = LAST_SENT_CLIPBOARD_TEXT.lock() {
        if *guard == text {
            return 0;
        }
        *guard = text.clone();
    }

    let compressed = hbb_common::compress::compress(text.as_bytes());
    let compress = compressed.len() < text.as_bytes().len();
    let content = if compress {
        compressed
    } else {
        text.into_bytes()
    };
    let clipboard = Clipboard {
        compress,
        content: content.into(),
        format: ClipboardFormat::Text.into(),
        ..Default::default()
    };
    let multi = MultiClipboards {
        clipboards: vec![clipboard],
        ..Default::default()
    };
    let mut msg = PeerMessage::new();
    msg.set_multi_clipboards(multi);
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_take_remote_clipboard_text() -> *mut c_char {
    let text = match REMOTE_CLIPBOARD_TEXT.try_lock() {
        Ok(mut guard) => guard.take().unwrap_or_default(),
        Err(_) => String::new(),
    };
    CString::new(text)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn rust_get_display_count() -> i32 {
    DISPLAY_COUNT.try_lock().map(|guard| *guard).unwrap_or(1).max(1)
}

#[no_mangle]
pub extern "C" fn rust_get_current_display() -> i32 {
    CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn rust_switch_display(display: i32) -> i32 {
    if display < 0 {
        return -1;
    }
    if let Ok(mut guard) = CURRENT_DISPLAY.try_lock() {
        *guard = display;
    }
    let mut misc = Misc::new();
    misc.set_switch_display(SwitchDisplay {
        display,
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_refresh_video() -> i32 {
    let display = CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0);
    let mut switch_misc = Misc::new();
    switch_misc.set_switch_display(SwitchDisplay {
        display,
        ..Default::default()
    });
    let mut switch_msg = PeerMessage::new();
    switch_msg.set_misc(switch_misc);
    let switch_result = queue_peer_message(switch_msg);
    if switch_result != 0 {
        return switch_result;
    }

    let mut refresh_misc = Misc::new();
    refresh_misc.set_refresh_video(true);
    let mut refresh_msg = PeerMessage::new();
    refresh_msg.set_misc(refresh_misc);
    let refresh_result = queue_peer_message(refresh_msg);
    if refresh_result != 0 {
        return refresh_result;
    }

    let mut received_misc = Misc::new();
    received_misc.set_video_received(true);
    let mut received_msg = PeerMessage::new();
    received_msg.set_misc(received_misc);
    queue_peer_message(received_msg)
}

#[no_mangle]
pub extern "C" fn rust_get_device_id() -> *mut c_char {
    let id = format!("{:03}-{:03}-{:03}", rand_simple(), rand_simple(), rand_simple());
    CString::new(id).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn rust_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr).to_string_lossy().trim().to_string() })
}

fn emit_event(message: &str) {
    let cb = match EVENT_CALLBACK.try_lock() {
        Ok(guard) => *guard,
        Err(_) => return,
    };
    if let Some(cb) = cb {
        if let Ok(c_message) = CString::new(message) {
            cb(c_message.as_ptr());
        }
    }
}

fn with_port(host: &str, port: i32) -> String {
    if host.contains(':') {
        host.to_string()
    } else {
        format!("{host}:{port}")
    }
}

fn rendezvous_message_kind(union: &Option<rendezvous_message::Union>) -> &'static str {
    match union {
        Some(rendezvous_message::Union::RegisterPeer(_)) => "register_peer",
        Some(rendezvous_message::Union::RegisterPeerResponse(_)) => "register_peer_response",
        Some(rendezvous_message::Union::PunchHoleRequest(_)) => "punch_hole_request",
        Some(rendezvous_message::Union::PunchHole(_)) => "punch_hole",
        Some(rendezvous_message::Union::PunchHoleSent(_)) => "punch_hole_sent",
        Some(rendezvous_message::Union::PunchHoleResponse(_)) => "punch_hole_response",
        Some(rendezvous_message::Union::FetchLocalAddr(_)) => "fetch_local_addr",
        Some(rendezvous_message::Union::LocalAddr(_)) => "local_addr",
        Some(rendezvous_message::Union::ConfigureUpdate(_)) => "configure_update",
        Some(rendezvous_message::Union::RegisterPk(_)) => "register_pk",
        Some(rendezvous_message::Union::RegisterPkResponse(_)) => "register_pk_response",
        Some(rendezvous_message::Union::SoftwareUpdate(_)) => "software_update",
        Some(rendezvous_message::Union::RequestRelay(_)) => "request_relay",
        Some(rendezvous_message::Union::RelayResponse(_)) => "relay_response",
        Some(rendezvous_message::Union::TestNatRequest(_)) => "test_nat_request",
        Some(rendezvous_message::Union::TestNatResponse(_)) => "test_nat_response",
        Some(rendezvous_message::Union::PeerDiscovery(_)) => "peer_discovery",
        Some(rendezvous_message::Union::OnlineRequest(_)) => "online_request",
        Some(rendezvous_message::Union::OnlineResponse(_)) => "online_response",
        Some(rendezvous_message::Union::KeyExchange(_)) => "key_exchange",
        Some(rendezvous_message::Union::Hc(_)) => "hc",
        Some(rendezvous_message::Union::HttpProxyRequest(_)) => "http_proxy_request",
        Some(rendezvous_message::Union::HttpProxyResponse(_)) => "http_proxy_response",
        Some(_) => "unknown",
        None => "none",
    }
}

fn should_skip_rendezvous_message(union: &Option<rendezvous_message::Union>) -> bool {
    matches!(
        union,
        Some(rendezvous_message::Union::KeyExchange(_))
            | Some(rendezvous_message::Union::ConfigureUpdate(_))
            | Some(rendezvous_message::Union::SoftwareUpdate(_))
            | Some(rendezvous_message::Union::Hc(_))
    )
}

async fn next_rendezvous(conn: &mut Stream, timeout: u64) -> Option<RendezvousMessage> {
    while let Some(Ok(bytes)) = conn.next_timeout(timeout).await {
        match RendezvousMessage::parse_from_bytes(&bytes) {
            Ok(msg) => {
                let kind = rendezvous_message_kind(&msg.union);
                if should_skip_rendezvous_message(&msg.union) {
                    emit_event(&format!("skip rendezvous message kind={kind}"));
                    continue;
                }
                emit_event(&format!("rendezvous message kind={kind}"));
                return Some(msg);
            }
            Err(e) => {
                emit_event(&format!(
                    "rendezvous parse failed len={} err={e}",
                    bytes.len()
                ));
            }
        }
    }
    None
}

async fn request_relay(
    peer: &str,
    relay_server: &str,
    rendezvous_server: &str,
    key: &str,
) -> Result<Stream, hbb_common::anyhow::Error> {
    let mut rv_conn = connect_tcp(rendezvous_server.to_string(), CONNECT_TIMEOUT).await?;
    let ipv4 = rv_conn.local_addr().is_ipv4();
    let uuid = Uuid::new_v4().to_string();

    let mut req = RendezvousMessage::new();
    req.set_request_relay(RequestRelay {
        id: peer.to_string(),
        uuid: uuid.clone(),
        relay_server: relay_server.to_string(),
        secure: false,
        ..Default::default()
    });
    rv_conn.send(&req).await?;

    match next_rendezvous(&mut rv_conn, CONNECT_TIMEOUT).await {
        Some(msg) => match msg.union {
            Some(rendezvous_message::Union::RelayResponse(resp)) if resp.refuse_reason.is_empty() => {}
            Some(rendezvous_message::Union::RelayResponse(resp)) => {
                hbb_common::bail!("relay refused: {}", resp.refuse_reason)
            }
            other => hbb_common::bail!(
                "relay refused: unexpected rendezvous response kind={}",
                rendezvous_message_kind(&other)
            ),
        },
        None => hbb_common::bail!("relay request timeout"),
    }

    create_relay(peer, &uuid, relay_server, key, ipv4).await
}

async fn create_relay(
    peer: &str,
    uuid: &str,
    relay_server: &str,
    key: &str,
    ipv4: bool,
) -> Result<Stream, hbb_common::anyhow::Error> {
    let mut relay_conn = connect_tcp(
        ipv4_to_ipv6(check_port(relay_server.to_string(), RELAY_PORT), ipv4),
        CONNECT_TIMEOUT,
    )
    .await?;

    let mut create = RendezvousMessage::new();
    create.set_request_relay(RequestRelay {
        licence_key: key.to_string(),
        id: peer.to_string(),
        uuid: uuid.to_string(),
        conn_type: ConnType::DEFAULT_CONN.into(),
        ..Default::default()
    });
    relay_conn.send(&create).await?;
    Ok(relay_conn)
}

async fn secure_peer_connection(
    peer_id: &str,
    signed_id_pk: &[u8],
    key: &str,
    conn: &mut Stream,
) -> Result<(), hbb_common::anyhow::Error> {
    let rs_pk = get_rs_pk(if key.is_empty() { RS_PUB_KEY } else { key });
    let mut sign_pk = None;

    if let (Some(rs_pk), false) = (rs_pk, signed_id_pk.is_empty()) {
        match decode_id_pk(signed_id_pk, &rs_pk) {
            Ok((id, pk)) if id == peer_id => {
                sign_pk = Some(sign::PublicKey(pk));
            }
            Ok((id, _)) => {
                emit_event(&format!("secure peer: rendezvous signed id mismatch id={id}"));
            }
            Err(e) => {
                emit_event(&format!("secure peer: invalid rendezvous signed id: {e}"));
            }
        }
    }

    let Some(sign_pk) = sign_pk else {
        emit_event("secure peer: unavailable");
        hbb_common::bail!("secure peer unavailable");
    };

    let Some(Ok(bytes)) = conn.next_timeout(READ_TIMEOUT).await else {
        emit_event("secure peer: wait signed id timeout");
        hbb_common::bail!("peer did not send signed id");
    };

    let msg = PeerMessage::parse_from_bytes(&bytes)?;
    let Some(message::Union::SignedId(signed_id)) = msg.union else {
        emit_event("secure peer: first peer msg not SignedId");
        hbb_common::bail!("peer did not send signed id");
    };

    match decode_id_pk(&signed_id.id, &sign_pk) {
        Ok((id, their_pk_b)) if id == peer_id => {
            let (asymmetric_value, symmetric_value, key) = create_symmetric_key_msg(their_pk_b);
            let mut msg_out = PeerMessage::new();
            msg_out.set_public_key(PublicKey {
                asymmetric_value,
                symmetric_value,
                ..Default::default()
            });
            conn.send(&msg_out).await?;
            conn.set_key(key);
            emit_event("secure peer: encrypted stream enabled");
        }
        Ok((id, _)) => {
            emit_event(&format!("secure peer: peer signed id mismatch id={id}"));
            hbb_common::bail!("peer signed id mismatch");
        }
        Err(e) => {
            emit_event(&format!("secure peer: invalid peer signed id: {e}"));
            hbb_common::bail!("invalid peer signed id");
        }
    }
    Ok(())
}

fn get_rs_pk(str_base64: &str) -> Option<sign::PublicKey> {
    base64::decode(str_base64, Variant::Original)
        .ok()
        .and_then(|pk| get_pk(&pk).map(sign::PublicKey))
}

fn get_pk(bytes: &[u8]) -> Option<[u8; 32]> {
    if bytes.len() != 32 {
        return None;
    }
    let mut pk = [0_u8; 32];
    pk.copy_from_slice(bytes);
    Some(pk)
}

fn decode_id_pk(signed: &[u8], key: &sign::PublicKey) -> Result<(String, [u8; 32]), hbb_common::anyhow::Error> {
    let verified = verify_signed_payload(signed, key)?;
    let res = IdPk::parse_from_bytes(&verified)?;
    let Some(pk) = get_pk(&res.pk) else {
        hbb_common::bail!("wrong public key length");
    };
    Ok((res.id, pk))
}

fn verify_signed_payload(signed: &[u8], key: &sign::PublicKey) -> Result<Vec<u8>, hbb_common::anyhow::Error> {
    sign::verify(signed, key).map_err(|_| hbb_common::anyhow::anyhow!("signature mismatch"))
}

fn create_symmetric_key_msg(their_pk_b: [u8; 32]) -> (hbb_common::bytes::Bytes, hbb_common::bytes::Bytes, secretbox::Key) {
    let their_pk_b = box_::PublicKey(their_pk_b);
    let (our_pk_b, out_sk_b) = box_::gen_keypair();
    let key = secretbox::gen_key();
    let nonce = box_::Nonce([0_u8; box_::NONCEBYTES]);
    let sealed_key = box_::seal(&key.0, &nonce, &their_pk_b, &out_sk_b);
    (Vec::from(our_pk_b.0).into(), sealed_key.into(), key)
}

fn spawn_receive_loop(session_id: u64, mut stream: Stream) {
    let (tx, rx) = mpsc::channel::<QueuedPeerMessage>();
    if let Ok(mut guard) = PEER_MESSAGE_SENDER.lock() {
        *guard = Some(tx);
    }
    thread::spawn(move || {
        let rt = runtime();
        rt.block_on(async {
            let mut stale = false;
            loop {
                if SESSION_ID.load(Ordering::SeqCst) != session_id {
                    stale = true;
                    break;
                }
                while let Ok(queued) = rx.try_recv() {
                    if SESSION_ID.load(Ordering::SeqCst) != queued.session_id {
                        emit_event("skip stale peer message");
                        continue;
                    }
                    if let Err(e) = stream.send(&queued.message).await {
                        emit_event(&format!("peer message send failed: {e}"));
                        mark_connection_lost(queued.session_id, &e.to_string());
                        return;
                    }
                }
                let bytes = stream.next_timeout(20).await;
                if SESSION_ID.load(Ordering::SeqCst) != session_id {
                    stale = true;
                    break;
                }

                match bytes {
                    Some(Ok(bytes)) => handle_peer_bytes(&bytes).await,
                    Some(Err(e)) => {
                        emit_event(&format!("receive loop error: {e}"));
                        break;
                    }
                    None => continue,
                }
            }
            if stale {
                emit_event("stale receive loop ended");
                return;
            }
            emit_event("receive loop ended");
            if SESSION_ID.load(Ordering::SeqCst) == session_id {
                CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
                CONNECTION_ROUTE.store(0, Ordering::SeqCst);
                reset_audio_async();
                reset_display_state();
                clear_peer_message_sender();
            }
        });
    });
}

async fn handle_peer_bytes(bytes: &[u8]) {
    let msg = match PeerMessage::parse_from_bytes(bytes) {
        Ok(m) => m,
        Err(e) => {
            emit_event(&format!("peer message parse failed len={} err={e}", bytes.len()));
            return;
        }
    };
    match msg.union {
        Some(message::Union::Hash(hash)) => {
            emit_event("peer message: Hash");
            send_login(hash).await;
        }
        Some(message::Union::LoginResponse(resp)) => {
            emit_event("peer message: LoginResponse");
            match resp.union {
                Some(login_response::Union::Error(err)) => {
                    emit_event(&format!("login response: error={err}"));
                    let _ = rust_disconnect();
                }
                Some(login_response::Union::PeerInfo(info)) => {
                    let display_count = info.displays.len().max(1) as i32;
                    let displays: Vec<(i32, i32, i32, i32)> = info
                        .displays
                        .iter()
                        .map(|display| (display.x, display.y, display.width, display.height))
                        .collect();
                    if let Ok(mut guard) = DISPLAY_COUNT.try_lock() {
                        *guard = display_count;
                    }
                    if let Ok(mut guard) = CURRENT_DISPLAY.try_lock() {
                        *guard = info.current_display;
                    }
                    if let Ok(mut guard) = DISPLAY_INFOS.try_lock() {
                        *guard = displays;
                    }
                    emit_event(&format!(
                        "login response: ok/peer info displays={} current={}",
                        display_count,
                        info.current_display
                    ));
                    send_performance_options(true).await;
                }
                _ => {
                    emit_event("login response: ok/peer info");
                    send_performance_options(true).await;
                }
            }
        }
        Some(message::Union::VideoFrame(frame)) => {
            forward_video_frame(frame);
        }
        Some(message::Union::TestDelay(delay)) => {
            send_test_delay_response(delay).await;
        }
        Some(message::Union::Clipboard(clipboard)) => {
            handle_remote_clipboards(vec![clipboard]);
        }
        Some(message::Union::MultiClipboards(multi_clipboards)) => {
            handle_remote_clipboards(multi_clipboards.clipboards);
        }
        Some(message::Union::Misc(misc_msg)) => handle_misc_message(misc_msg),
        Some(message::Union::AudioFrame(frame)) => handle_audio_frame(&frame.data),
        Some(message::Union::CursorData(_)) => emit_event("peer message: CursorData"),
        Some(message::Union::CursorPosition(_)) => {}
        Some(message::Union::CursorId(_)) => emit_event("peer message: CursorId"),
        Some(_) => {}
        None => emit_event("peer message: empty"),
    }
}

fn handle_misc_message(misc_msg: Misc) {
    match misc_msg.union {
        Some(misc::Union::AudioFormat(format)) => handle_audio_format(format),
        _ => emit_event("peer message: Misc"),
    }
}

fn handle_audio_format(format: AudioFormat) {
    let sample_rate = format.sample_rate as i32;
    let channels = format.channels.clamp(1, 2) as i32;
    let start_result = match AUDIO_START_CALLBACK.try_lock() {
        Ok(guard) => guard.map(|cb| cb(sample_rate, channels)).unwrap_or(-1),
        Err(_) => -1,
    };
    emit_event(&format!(
        "audio format received sample_rate={} channels={} start_result={}",
        sample_rate, channels, start_result
    ));
}

fn handle_audio_frame(data: &[u8]) {
    if data.is_empty() {
        return;
    }
    let frame_cb = match AUDIO_FRAME_CALLBACK.try_lock() {
        Ok(guard) => *guard,
        Err(_) => None,
    };
    if let Some(cb) = frame_cb {
        cb(data.as_ptr(), data.len() as i32);
    }
}

fn reset_audio() {
    let stop_cb = match AUDIO_STOP_CALLBACK.try_lock() {
        Ok(guard) => *guard,
        Err(_) => None,
    };
    if let Some(cb) = stop_cb {
        cb();
    }
}

fn reset_audio_async() {
    if AUDIO_RESET_IN_PROGRESS.swap(true, Ordering::SeqCst) {
        return;
    }
    thread::spawn(|| {
        reset_audio();
        AUDIO_RESET_IN_PROGRESS.store(false, Ordering::SeqCst);
    });
}

fn handle_remote_clipboards(clipboards: Vec<Clipboard>) {
    let Some(clipboard) = clipboards
        .into_iter()
        .find(|item| item.format.enum_value() == Ok(ClipboardFormat::Text))
    else {
        return;
    };

    let content = if clipboard.compress {
        hbb_common::compress::decompress(&clipboard.content)
    } else {
        clipboard.content.to_vec()
    };
    let Ok(text) = String::from_utf8(content) else {
        return;
    };
    if text.is_empty() {
        return;
    }
    if LAST_SENT_CLIPBOARD_TEXT
        .try_lock()
        .map(|guard| *guard == text)
        .unwrap_or(false)
    {
        return;
    }
    if let Ok(mut guard) = REMOTE_CLIPBOARD_TEXT.try_lock() {
        *guard = Some(text);
    }
    emit_event("remote clipboard text received");
}

fn clear_clipboard_state() {
    if let Ok(mut guard) = REMOTE_CLIPBOARD_TEXT.try_lock() {
        *guard = None;
    }
    if let Ok(mut guard) = LAST_SENT_CLIPBOARD_TEXT.try_lock() {
        guard.clear();
    }
}

async fn send_login(hash: Hash) {
    let performance = performance_config();
    let password = match PASSWORD_HASH.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => Vec::new(),
    };
    let peer_id = match CURRENT_PEER_ID.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => String::new(),
    };
    let mut response_password = Vec::new();
    if !password.is_empty() {
        let mut first = Sha256::new();
        first.update(&password);
        first.update(hash.salt.as_bytes());
        let first_hash = first.finalize();

        let mut second = Sha256::new();
        second.update(first_hash);
        second.update(hash.challenge.as_bytes());
        response_password = second.finalize().to_vec();
    }

    let login = LoginRequest {
        username: peer_id,
        password: response_password.into(),
        my_id: "harmony-client".to_string(),
        my_name: "StarRustDesk HarmonyOS".to_string(),
        my_platform: "HarmonyOS".to_string(),
        option: MessageField::some(OptionMessage {
            supported_decoding: MessageField::some(SupportedDecoding {
                ability_vp8: 0,
                ability_vp9: 1,
                ability_av1: 0,
                ability_h264: 1,
                ability_h265: 0,
                prefer: supported_decoding::PreferCodec::H264.into(),
                i444: MessageField::some(CodecAbility {
                    ..Default::default()
                }),
                ..Default::default()
            }),
            image_quality: performance.quality.into(),
            custom_fps: performance.fps,
            disable_audio: hbb_common::message_proto::option_message::BoolOption::No.into(),
            show_remote_cursor: hbb_common::message_proto::option_message::BoolOption::Yes.into(),
            ..Default::default()
        }),
        version: "1.2.0".to_string(),
        os_login: MessageField::some(OSLogin::new()),
        ..Default::default()
    };

    let mut out = PeerMessage::new();
    out.set_login_request(login);
    match send_peer_message_async(out).await {
        Ok(_) => emit_event("login request sent"),
        Err(e) => emit_event(&format!("login request send failed: {e}")),
    }
}

async fn send_performance_options(refresh_video: bool) {
    let performance = performance_config();
    let mut misc = Misc::new();
    misc.set_option(OptionMessage {
        image_quality: performance.quality.into(),
        custom_fps: performance.fps,
        supported_decoding: MessageField::some(SupportedDecoding {
            ability_vp8: 0,
            ability_vp9: 1,
            ability_av1: 0,
            ability_h264: 1,
            ability_h265: 0,
            prefer: supported_decoding::PreferCodec::H264.into(),
            i444: MessageField::some(CodecAbility {
                ..Default::default()
            }),
            ..Default::default()
        }),
        disable_audio: hbb_common::message_proto::option_message::BoolOption::No.into(),
        show_remote_cursor: hbb_common::message_proto::option_message::BoolOption::Yes.into(),
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    match send_peer_message_async(msg).await {
        Ok(_) => emit_event(&format!("performance options sent fps={} quality={} codec=h264", performance.fps, performance.quality.value())),
        Err(e) => emit_event(&format!("performance options send failed: {e}")),
    }

    send_auto_adjust_fps(performance.fps as u32).await;

    if refresh_video {
        let mut misc = Misc::new();
        misc.set_refresh_video(true);
        let mut msg = PeerMessage::new();
        msg.set_misc(misc);
        match send_peer_message_async(msg).await {
            Ok(_) => emit_event("refresh video sent"),
            Err(e) => emit_event(&format!("refresh video send failed: {e}")),
        }
    }
}

async fn send_auto_adjust_fps(fps: u32) {
    let mut misc = Misc::new();
    misc.set_auto_adjust_fps(fps);
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    match send_peer_message_async(msg).await {
        Ok(_) => emit_event(&format!("auto adjust fps sent fps={fps}")),
        Err(e) => emit_event(&format!("auto adjust fps send failed: {e}")),
    }
}

async fn send_auto_adjust_fps_if_due() {
    let now = now_ms();
    let last = LAST_FPS_HINT_MS.load(Ordering::Relaxed);
    if now.saturating_sub(last) < 3000 {
        return;
    }
    LAST_FPS_HINT_MS.store(now, Ordering::Relaxed);
    let performance = performance_config();
    send_auto_adjust_fps(performance.fps as u32).await;
}

fn performance_config() -> PerformanceConfig {
    PERFORMANCE_CONFIG
        .lock()
        .map(|guard| *guard)
        .unwrap_or(PerformanceConfig {
            fps: 45,
            quality: ImageQuality::Low,
        })
}

async fn send_test_delay_response(delay: TestDelay) {
    let mut msg = PeerMessage::new();
    msg.set_test_delay(delay);
    if let Err(e) = send_peer_message_async(msg).await {
        emit_event(&format!("test delay response send failed: {e}"));
    }
    send_auto_adjust_fps_if_due().await;
}

fn forward_video_frame(frame: VideoFrame) {
    let (data, codec_tag) = match frame.union {
        Some(video_frame::Union::Vp9s(frames)) => {
            (first_encoded_frame(frames), b'V')
        }
        Some(video_frame::Union::H264s(frames)) => {
            (first_encoded_frame(frames), b'H')
        }
        Some(video_frame::Union::H265s(frames)) => {
            (first_encoded_frame(frames), b'5')
        }
        Some(video_frame::Union::Vp8s(frames)) => {
            (first_encoded_frame(frames), b'8')
        }
        Some(video_frame::Union::Av1s(frames)) => {
            (first_encoded_frame(frames), b'A')
        }
        Some(video_frame::Union::Rgb(_)) => {
            emit_event("video frame: rgb metadata without raw payload");
            (Vec::new(), b'R')
        }
        Some(video_frame::Union::Yuv(_)) => {
            emit_event("video frame: yuv metadata without raw payload");
            (Vec::new(), b'Y')
        }
        Some(_) => {
            emit_event("video frame: unknown union");
            (Vec::new(), b'?')
        }
        None => {
            emit_event("video frame: empty union");
            (Vec::new(), b'?')
        }
    };
    if data.is_empty() {
        emit_event("video frame: empty data");
        return;
    }
    let mut tagged = Vec::with_capacity(data.len() + 5);
    tagged.extend_from_slice(b"SRD0");
    tagged.push(codec_tag);
    tagged.extend_from_slice(&data);
    if let Ok(guard) = FRAME_CALLBACK.lock() {
        if let Some(cb) = *guard {
            let (_, _, width, height) = current_display_rect();
            cb(tagged.as_ptr(), tagged.len() as i32, width, height);
        }
    }
    queue_video_received_if_due();
}

fn queue_video_received_if_due() {
    let now = now_ms();
    let last = LAST_VIDEO_RECEIVED_MS.load(Ordering::Relaxed);
    if now.saturating_sub(last) < 1000 {
        return;
    }
    LAST_VIDEO_RECEIVED_MS.store(now, Ordering::Relaxed);
    let mut misc = Misc::new();
    misc.set_video_received(true);
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    let _ = queue_peer_message(msg);
}

fn current_display_rect() -> (i32, i32, i32, i32) {
    let current = CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0);
    let index = current.max(0) as usize;
    DISPLAY_INFOS
        .try_lock()
        .ok()
        .and_then(|guard| guard.get(index).copied())
        .unwrap_or((0, 0, 1920, 1080))
}

fn current_display_origin() -> (i32, i32) {
    let (x, y, _, _) = current_display_rect();
    (x, y)
}

fn first_encoded_frame(frames: EncodedVideoFrames) -> Vec<u8> {
    frames
        .frames
        .into_iter()
        .next()
        .map(|f| f.data.to_vec())
        .unwrap_or_default()
}

fn queue_peer_message(msg: PeerMessage) -> i32 {
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        emit_event("peer message send failed: not connected");
        return -1;
    }
    enqueue_peer_message(msg).map(|_| 0).unwrap_or_else(|e| {
        emit_event(&format!("peer message send failed: {e}"));
        -2
    })
}

fn mark_connection_lost(session_id: u64, reason: &str) {
    if SESSION_ID.load(Ordering::SeqCst) != session_id {
        emit_event("skip stale connection lost");
        return;
    }
    emit_event(&format!("connection lost: {reason}"));
    SESSION_ID.fetch_add(1, Ordering::SeqCst);
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    reset_audio_async();
    reset_display_state();
    clear_peer_message_sender();
    if let Ok(mut guard) = CONNECTION.try_lock() {
        *guard = None;
    }
}

async fn send_peer_message_async(msg: PeerMessage) -> Result<(), hbb_common::anyhow::Error> {
    enqueue_peer_message(msg)
}

fn enqueue_peer_message(msg: PeerMessage) -> Result<(), hbb_common::anyhow::Error> {
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    let sender = PEER_MESSAGE_SENDER
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("sender lock poisoned"))?
        .clone()
        .ok_or_else(|| hbb_common::anyhow::anyhow!("not connected"))?;
    sender
        .send(QueuedPeerMessage {
            session_id,
            message: msg,
        })
        .map_err(|_| hbb_common::anyhow::anyhow!("sender closed"))
}

fn key_code_to_control(key_code: i32) -> Option<ControlKey> {
    match key_code {
        13 => Some(ControlKey::Return),
        27 => Some(ControlKey::Escape),
        32 => Some(ControlKey::Space),
        8 => Some(ControlKey::Backspace),
        9 => Some(ControlKey::Tab),
        37 => Some(ControlKey::LeftArrow),
        38 => Some(ControlKey::UpArrow),
        39 => Some(ControlKey::RightArrow),
        40 => Some(ControlKey::DownArrow),
        46 => Some(ControlKey::Delete),
        _ => None,
    }
}

fn rand_simple() -> u32 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .subsec_nanos();
    (nanos % 900 + 100) as u32
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}
