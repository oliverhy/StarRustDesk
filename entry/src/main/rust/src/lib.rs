use std::collections::BTreeMap;
mod kcp_stream;
#[cfg(test)]
mod keyboard_tests;
#[cfg(test)]
mod network_tests;
#[cfg(test)]
mod security_tests;
use std::ffi::{CStr, CString};
use std::net::{IpAddr, SocketAddr};
use std::os::raw::{c_char, c_uchar};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use hbb_common::config::{
    Config, READ_TIMEOUT, RELAY_PORT, RENDEZVOUS_PORT, RENDEZVOUS_SERVERS, RS_PUB_KEY,
};
use hbb_common::fs::{self, DataSource, JobType, TransferJob};
use hbb_common::futures::future::{select_ok, BoxFuture, FutureExt};
use hbb_common::message_proto::{
    file_action, file_response, file_transfer_send_confirm_request, key_event, login_response,
    message, misc, supported_decoding, video_frame, AudioFormat, Auth2FA, CaptureDisplays,
    Clipboard, ClipboardFormat, CodecAbility, ControlKey, CursorData, EncodedVideoFrames,
    FileAction, FileTransfer, FileTransferCancel, FileTransferSendConfirmRequest, Hash, IdPk,
    ImageQuality, KeyEvent, KeyboardMode, LoginRequest, Message as PeerMessage, Misc, MouseEvent,
    OSLogin, OptionMessage, PublicKey, ReadDir, SupportedDecoding, SwitchDisplay, TestDelay,
    VideoFrame,
};
use hbb_common::protobuf::MessageField;
use hbb_common::rendezvous_proto::{
    punch_hole_response, rendezvous_message, ConnType, KeyExchange, NatType, OnlineRequest,
    PunchHoleRequest, RendezvousMessage, RequestRelay, TestNatRequest,
};
use hbb_common::sha2::{Digest, Sha256};
use hbb_common::socket_client::{
    check_port, connect_tcp, connect_tcp_local, ipv4_to_ipv6, new_direct_udp_for, split_host_port,
};
use hbb_common::sodiumoxide::{
    base64::{self, Variant},
    crypto::{box_, secretbox, sign},
};
use hbb_common::tokio::net::UdpSocket;
use hbb_common::uuid::Uuid;
use hbb_common::webrtc::WebRTCStream;
use hbb_common::{AddrMangle, Stream};
use protobuf::{Enum, EnumOrUnknown, Message};
use tokio::runtime::Runtime;
use tokio::sync::mpsc as tokio_mpsc;

use crate::kcp_stream::KcpStream;

type FrameCallback = extern "C" fn(*const c_uchar, i32, i32, i32, i32, i64);
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
static CURRENT_CLIENT_HWID: Mutex<Vec<u8>> = Mutex::new(Vec::new());
static CURRENT_CLIENT_ID: Mutex<String> = Mutex::new(String::new());
static DISPLAY_COUNT: Mutex<i32> = Mutex::new(1);
static CURRENT_DISPLAY: Mutex<i32> = Mutex::new(0);
static DISPLAY_INFOS: Mutex<Vec<(i32, i32, i32, i32, bool)>> = Mutex::new(Vec::new());
static PEER_SUPPORTS_MULTI_DISPLAY_FRAMES: AtomicBool = AtomicBool::new(false);
static LAST_DROPPED_DISPLAY_FRAME_LOG_MS: AtomicU64 = AtomicU64::new(0);
static PEER_IS_ANDROID: AtomicBool = AtomicBool::new(false);
static PEER_SAS_ENABLED: AtomicBool = AtomicBool::new(false);
static CURRENT_PEER_PLATFORM: Mutex<String> = Mutex::new(String::new());
static CURRENT_PEER_VERSION: Mutex<String> = Mutex::new(String::new());
static REMOTE_CURSOR_X: AtomicI32 = AtomicI32::new(0);
static REMOTE_CURSOR_Y: AtomicI32 = AtomicI32::new(0);
static REMOTE_CURSOR_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static REMOTE_CURSOR_VALID: AtomicBool = AtomicBool::new(false);
static REMOTE_CURSOR_IMAGES: Mutex<BTreeMap<u64, RemoteCursorImage>> = Mutex::new(BTreeMap::new());
static REMOTE_CURSOR_IMAGE_ID: AtomicU64 = AtomicU64::new(0);
static REMOTE_CURSOR_IMAGE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static REMOTE_CURSOR_IMAGE_VALID: AtomicBool = AtomicBool::new(false);
static REMOTE_CLIPBOARD_TEXT: Mutex<Option<String>> = Mutex::new(None);
static LAST_SENT_CLIPBOARD_TEXT: Mutex<String> = Mutex::new(String::new());
static REMOTE_DIRECTORY_RESULT: Mutex<String> = Mutex::new(String::new());
static FILE_TRANSFER_STATUS: Mutex<String> = Mutex::new(String::new());
static PEER_ONLINE_RESULT: Mutex<String> = Mutex::new(String::new());
static PEER_ONLINE_QUERY_ACTIVE: AtomicBool = AtomicBool::new(false);
static NEXT_FILE_JOB_ID: AtomicI32 = AtomicI32::new(10_000);
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static PEER_MESSAGE_SENDER: Mutex<Option<(u64, tokio_mpsc::UnboundedSender<QueuedPeerCommand>)>> =
    Mutex::new(None);
static PEER_TASK_CONTROL: Mutex<Option<PeerTaskControl>> = Mutex::new(None);
static FILE_MESSAGE_SENDER: Mutex<Option<Sender<QueuedPeerCommand>>> = Mutex::new(None);
static CURRENT_CONNECTION_CONFIG: Mutex<Option<ConnectionConfig>> = Mutex::new(None);
static SESSION_ID: AtomicU64 = AtomicU64::new(0);
static PROTOCOL_SESSION_ID: AtomicU64 = AtomicU64::new(0);
static LAST_FPS_HINT_MS: AtomicU64 = AtomicU64::new(0);
static LAST_VIDEO_RECEIVED_MS: AtomicU64 = AtomicU64::new(0);
static CONNECTION_ACTIVE: AtomicBool = AtomicBool::new(false);
static CONNECTION_ROUTE: AtomicI32 = AtomicI32::new(0);
static CONNECTION_TRANSPORT: AtomicI32 = AtomicI32::new(0);
static CONNECTION_DELAY_MS: AtomicI32 = AtomicI32::new(0);
static CONNECTION_TARGET_BITRATE_KB: AtomicI32 = AtomicI32::new(0);
static AUDIO_RESET_IN_PROGRESS: AtomicBool = AtomicBool::new(false);
static REMOTE_AUDIO_ENABLED: AtomicBool = AtomicBool::new(true);
static BACKGROUND_VIDEO_MODE: AtomicBool = AtomicBool::new(false);
static ALLOW_INSECURE_SESSION: AtomicBool = AtomicBool::new(false);
// Conservative defaults keep older native shells safe until they report the
// decoders that can actually be created on the current device.
static H264_DECODER_SUPPORTED: AtomicBool = AtomicBool::new(true);
static VP9_DECODER_SUPPORTED: AtomicBool = AtomicBool::new(false);
static VP8_DECODER_SUPPORTED: AtomicBool = AtomicBool::new(false);
static AV1_DECODER_SUPPORTED: AtomicBool = AtomicBool::new(false);
static H265_DECODER_SUPPORTED: AtomicBool = AtomicBool::new(false);
// The HarmonyOS client draws a low-latency local cursor by default. Ask the
// controlled peer to embed its cursor only when that local overlay is disabled,
// otherwise the delayed video cursor and local cursor are both visible.
static SHOW_REMOTE_CURSOR: AtomicBool = AtomicBool::new(true);
static PEER_ROUTE_HISTORY_LOCK: Mutex<()> = Mutex::new(());

const DIRECT_CONNECT_TIMEOUT: u64 = 1_500;
const DIRECT_ONLY_CONNECT_TIMEOUT: u64 = 5_000;
const LOCAL_DIRECT_CONNECT_TIMEOUT: u64 = 800;
const SERVER_CONNECT_TIMEOUT: u64 = 8_000;
const RENDEZVOUS_REPLY_TIMEOUT: u64 = 6_000;
const CONNECTION_DEADLINE: Duration = Duration::from_secs(28);
const ONLINE_QUERY_DEADLINE: Duration = Duration::from_secs(10);
// RustDesk wire-protocol compatibility version, not the HarmonyOS package version.
const RUSTDESK_PROTOCOL_VERSION: &str = "1.5.0";
const PUNCH_REPLY_TIMEOUTS: [u64; 3] = [1_500, 2_500, 4_000];
const NAT_PROBE_TIMEOUT: u64 = 1_500;
const PEER_ROUTE_HISTORY_OPTION: &str = "peer-route-history-v1";
const PEER_ROUTE_HISTORY_TTL_MS: u64 = 30 * 60 * 1_000;
const PEER_ROUTE_HISTORY_MAX_ENTRIES: usize = 128;
const PEER_ROUTE_HISTORY_MAX_FAILURES: u8 = 3;

#[derive(Clone, Copy)]
struct PerformanceConfig {
    fps: i32,
    quality: ImageQuality,
}

enum QueuedPeerCommand {
    Message {
        session_id: u64,
        message: PeerMessage,
    },
    StartUpload {
        session_id: u64,
        job: TransferJob,
        receive: PeerMessage,
    },
    StartDownload {
        session_id: u64,
        jobs: Vec<DownloadJobCommand>,
    },
    CancelTransfer {
        session_id: u64,
    },
    Close {
        session_id: u64,
        completed: Sender<()>,
    },
}

struct DownloadJobCommand {
    job: TransferJob,
    send: PeerMessage,
}

#[derive(Default)]
struct DownloadBatchState {
    active: bool,
    total_jobs: usize,
    completed_jobs: usize,
    completed_bytes: u64,
    total_bytes: u64,
}

struct PeerTaskControl {
    session_id: u64,
    abort_handle: tokio::task::AbortHandle,
    completed: mpsc::Receiver<()>,
}

struct PeerTaskCompletion(Option<Sender<()>>);

impl Drop for PeerTaskCompletion {
    fn drop(&mut self) {
        if let Some(completed) = self.0.take() {
            let _ = completed.send(());
        }
    }
}

#[derive(Clone)]
struct ConnectionConfig {
    peer: String,
    password: String,
    rendezvous_addr: String,
    relay_override: String,
    key: String,
    client_hwid: Vec<u8>,
    client_id: String,
}

#[derive(Clone, Debug, Default, serde::Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(default, rename_all = "camelCase")]
struct PeerRouteRecord {
    route: i32,
    transport: i32,
    direct_failures: u8,
    direct_failure_ms: u64,
    updated_ms: u64,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct RemoteDirectoryEntry {
    name: String,
    entry_type: i32,
    size: u64,
    modified_time: u64,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct RemoteDirectoryResult {
    path: String,
    entries: Vec<RemoteDirectoryEntry>,
    error: String,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FileTransferStatus {
    session_id: u64,
    state: String,
    transferred: u64,
    total: u64,
    error: String,
    direction: String,
    completed_items: usize,
    total_items: usize,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PeerOnlineState {
    id: String,
    online: bool,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PeerOnlineResult {
    peers: Vec<PeerOnlineState>,
    error: String,
    server: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileDownloadRequest {
    remote_path: String,
    local_name: String,
    is_directory: bool,
}

static PERFORMANCE_CONFIG: Mutex<PerformanceConfig> = Mutex::new(PerformanceConfig {
    fps: 45,
    quality: ImageQuality::Low,
});

#[derive(Clone)]
struct RemoteCursorImage {
    id: u64,
    hotx: i32,
    hoty: i32,
    width: i32,
    height: i32,
    colors: Vec<u8>,
}

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

fn new_protocol_session_id() -> u64 {
    let uuid = Uuid::new_v4().as_u128();
    let session_id = (uuid as u64) ^ ((uuid >> 64) as u64);
    if session_id == 0 {
        1
    } else {
        session_id
    }
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
    PEER_SUPPORTS_MULTI_DISPLAY_FRAMES.store(false, Ordering::SeqCst);
    LAST_DROPPED_DISPLAY_FRAME_LOG_MS.store(0, Ordering::Relaxed);
    PEER_IS_ANDROID.store(false, Ordering::SeqCst);
    PEER_SAS_ENABLED.store(false, Ordering::SeqCst);
    if let Ok(mut guard) = CURRENT_PEER_PLATFORM.try_lock() {
        guard.clear();
    }
    if let Ok(mut guard) = CURRENT_PEER_VERSION.try_lock() {
        guard.clear();
    }
    REMOTE_CURSOR_VALID.store(false, Ordering::SeqCst);
    REMOTE_CURSOR_SEQUENCE.fetch_add(1, Ordering::SeqCst);
    REMOTE_CURSOR_IMAGE_VALID.store(false, Ordering::SeqCst);
    REMOTE_CURSOR_IMAGE_ID.store(0, Ordering::SeqCst);
    REMOTE_CURSOR_IMAGE_SEQUENCE.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut guard) = REMOTE_CURSOR_IMAGES.try_lock() {
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

fn clear_peer_message_sender_for_session(session_id: u64) {
    if let Ok(mut guard) = PEER_MESSAGE_SENDER.try_lock() {
        if guard
            .as_ref()
            .is_some_and(|(stored_session_id, _)| *stored_session_id == session_id)
        {
            *guard = None;
        }
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
pub extern "C" fn rust_set_video_codec_support(
    h264_supported: i32,
    vp9_supported: i32,
    vp8_supported: i32,
    av1_supported: i32,
    h265_supported: i32,
) {
    let h264 = h264_supported != 0;
    let vp9 = vp9_supported != 0;
    let vp8 = vp8_supported != 0;
    let av1 = av1_supported != 0;
    let h265 = h265_supported != 0;
    H264_DECODER_SUPPORTED.store(h264, Ordering::SeqCst);
    VP9_DECODER_SUPPORTED.store(vp9, Ordering::SeqCst);
    VP8_DECODER_SUPPORTED.store(vp8, Ordering::SeqCst);
    AV1_DECODER_SUPPORTED.store(av1, Ordering::SeqCst);
    H265_DECODER_SUPPORTED.store(h265, Ordering::SeqCst);
    emit_event(&format!(
        "video decoder capabilities h264={} vp9={} vp8={} av1={} h265={}",
        if h264 { "yes" } else { "no" },
        if vp9 { "yes" } else { "no" },
        if vp8 { "yes" } else { "no" },
        if av1 { "yes" } else { "no" },
        if h265 { "yes" } else { "no" }
    ));
}

#[no_mangle]
pub extern "C" fn rust_get_build_id() -> *const c_char {
    b"official-quality-monitor-20260911-r3\0".as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn rust_connect(
    peer_id: *const c_char,
    password: *const c_char,
    rendezvous_server: *const c_char,
    relay_server: *const c_char,
    server_key: *const c_char,
    client_hwid: *const c_char,
    client_id: *const c_char,
    force_relay: i32,
    allow_insecure_fallback: i32,
) -> i32 {
    if peer_id.is_null() {
        return -1;
    }

    let peer = match cstr_to_string(peer_id) {
        Some(s) if !s.is_empty() => s,
        _ => return -1,
    };
    // Classify before contacting rendezvous. Malformed literals must not leak
    // to a public server as IDs.
    let direct_addr = match direct_peer_addr(&peer) {
        Ok(address) => address,
        Err(error) => {
            emit_event(error);
            return -23;
        }
    };
    emit_event("rust_connect entered");
    let session_id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    PROTOCOL_SESSION_ID.store(new_protocol_session_id(), Ordering::SeqCst);
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    CONNECTION_TRANSPORT.store(0, Ordering::SeqCst);
    CONNECTION_DELAY_MS.store(0, Ordering::SeqCst);
    CONNECTION_TARGET_BITRATE_KB.store(0, Ordering::SeqCst);
    ALLOW_INSECURE_SESSION.store(allow_insecure_fallback != 0, Ordering::SeqCst);
    reset_display_state();
    let _ = clear_connection_for_session(session_id);
    emit_event("previous connection cleared");
    let pass = cstr_to_string(password).unwrap_or_default();
    let rv = cstr_to_string(rendezvous_server).unwrap_or_default();
    let relay_override = cstr_to_string(relay_server).unwrap_or_default();
    let key = cstr_to_string(server_key).unwrap_or_default();
    let key = default_server_key(&rv, &key);
    let client_hwid = cstr_to_string(client_hwid).unwrap_or_default().into_bytes();
    let client_id = cstr_to_string(client_id).unwrap_or_else(|| "harmony-client".to_string());

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

    if let Ok(mut hwid_guard) = CURRENT_CLIENT_HWID.lock() {
        *hwid_guard = client_hwid.clone();
    }
    if let Ok(mut client_id_guard) = CURRENT_CLIENT_ID.lock() {
        *client_id_guard = client_id.clone();
    }

    clear_clipboard_state();

    let public_server = rv.trim().is_empty();
    let rendezvous_candidates = if direct_addr.is_some() {
        Vec::new()
    } else {
        rendezvous_candidates(&rv)
    };
    let rendezvous_addr = rendezvous_candidates.first().cloned().unwrap_or_default();
    if let Ok(mut config) = CURRENT_CONNECTION_CONFIG.lock() {
        *config = Some(ConnectionConfig {
            peer: peer.clone(),
            password: pass.clone(),
            rendezvous_addr: rendezvous_addr.clone(),
            relay_override: relay_override.clone(),
            key: key.clone(),
            client_hwid,
            client_id,
        });
    }
    emit_event(&format!("connect start peer={peer} rendezvous={rendezvous_addr} relay_override={relay_override} key_set={}", !key.is_empty()));
    let rt = runtime();

    rt.block_on(async {
      match await_connection_attempt(session_id, &SESSION_ID, CONNECTION_DEADLINE, async {
        if let Some(address) = direct_addr {
            // Upstream Client::_start selects the direct listener for literals,
            // even with force_relay. No rendezvous identity exists on this route.
            // This is never a fallback after an ID/signature validation failure.
            let mut stream = match connect_ip_literal(address).await {
                Ok(stream) => stream,
                Err(error) => {
                    emit_event(&format!("IP direct connection failed: {error}"));
                    return -14;
                }
            };
            if SESSION_ID.load(Ordering::SeqCst) != session_id { return -19; }
            stream.set_send_timeout(5000);
            CONNECTION_ROUTE.store(1, Ordering::SeqCst);
            CONNECTION_TRANSPORT.store(stream_transport_code(&stream), Ordering::SeqCst);
            CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
            spawn_receive_loop(session_id, stream, None);
            emit_event("IP direct connected; rendezvous bypassed; awaiting peer login challenge");
            return 0;
        }
        let (mut rv_conn, active_rendezvous_addr) = match connect_rendezvous(&rendezvous_candidates).await {
            Ok(value) => value,
            Err(error) => {
                emit_event(&format!("rendezvous tcp failed: {error}"));
                return -1;
            }
        };
        emit_event("rendezvous tcp connected");
        if let Ok(mut config) = CURRENT_CONNECTION_CONFIG.lock() {
            if let Some(config) = config.as_mut() {
                config.rendezvous_addr = active_rendezvous_addr.clone();
            }
        }

        let nat_type = if force_relay != 0 {
            NatType::SYMMETRIC
        } else {
            let cached = NatType::from_i32(Config::get_nat_type()).unwrap_or(NatType::UNKNOWN_NAT);
            if cached == NatType::UNKNOWN_NAT {
                // NAT classification improves later attempts, but it must not
                // delay the current connection before its first punch request.
                let probe_server = active_rendezvous_addr.clone();
                tokio::spawn(async move {
                    let _ = detect_nat_type(&probe_server, public_server).await;
                });
            }
            cached
        };
        let preparation_policy = transport_preparation_policy(public_server, force_relay != 0);
        let preparation_started = Instant::now();
        let udp_future = async {
            if preparation_policy.udp_kcp {
                prepare_udp_punch_socket(&active_rendezvous_addr, public_server).await
            } else {
                None
            }
        };
        let ipv6_future = async {
            if preparation_policy.ipv6_kcp {
                match tokio::time::timeout(
                    Duration::from_millis(IPV6_PREPARATION_TIMEOUT),
                    prepare_ipv6_punch_socket(&active_rendezvous_addr),
                ).await {
                    Ok(candidate) => candidate,
                    Err(_) => {
                        emit_event("ipv6 preparation skipped after fast budget");
                        None
                    }
                }
            } else {
                None
            }
        };
        let webrtc_future = async {
            if preparation_policy.webrtc {
                prepare_webrtc_offerer(false).await
            } else {
                None
            }
        };
        let (udp_candidate, ipv6_candidate, webrtc_candidate) =
            tokio::join!(udp_future, ipv6_future, webrtc_future);
        emit_event(&format!(
            "transport preparation completed elapsed_ms={} udp={} ipv6={} webrtc={}",
            preparation_started.elapsed().as_millis(),
            udp_candidate.is_some(),
            ipv6_candidate.is_some(),
            webrtc_candidate.is_some(),
        ));
        let udp_port = udp_candidate.as_ref().map(|(_, port)| *port).unwrap_or(0);
        let socket_addr_v6 = ipv6_candidate
            .as_ref()
            .map(|(_, address)| address.clone())
            .unwrap_or_default();
        let webrtc_sdp_offer = webrtc_candidate
            .as_ref()
            .map(|(_, endpoint)| endpoint.clone())
            .unwrap_or_default();
        let req = punch_hole_request(
            &peer,
            &key,
            ConnType::DEFAULT_CONN,
            force_relay != 0,
            nat_type,
            udp_port,
            socket_addr_v6,
            webrtc_sdp_offer,
        );

        let local_addr = rv_conn.local_addr();
        let response = match send_punch_request(&mut rv_conn, &req, public_server).await {
            Ok(Some(msg)) => {
                emit_event("rendezvous response received");
                msg
            }
            Ok(None) => {
                emit_event("rendezvous response timeout");
                return -7;
            }
            Err(()) => return -2,
        };

        let mut peer_addr: Option<SocketAddr> = None;
        let mut relay_from_server = relay_override.clone();
        let mut signed_id_pk = Vec::new();
        let mut is_local = false;
        let mut peer_nat_type = NatType::UNKNOWN_NAT;
        let mut peer_is_udp = false;
        let mut peer_ipv6_addr: Option<SocketAddr> = None;
        let mut webrtc_sdp_answer = String::new();
        let mut relay_uuid: Option<String> = None;

        match response.union {
            Some(rendezvous_message::Union::PunchHoleResponse(ph)) => {
                is_local = ph.is_local();
                peer_nat_type = ph.nat_type();
                emit_event(&format!(
                    "punch response socket_addr={} relay_set={} pk_len={} is_local={} peer_nat={} udp={} refusal={}",
                    ph.socket_addr.len(),
                    !ph.relay_server.is_empty(),
                    ph.pk.len(),
                    is_local,
                    peer_nat_type.value(),
                    ph.is_udp,
                    classify_rendezvous_refusal(&ph.other_failure)
                ));
                if !ph.other_failure.is_empty() {
                    emit_event(&format!("rendezvous rejected source=punch category={}",
                        classify_rendezvous_refusal(&ph.other_failure)));
                    return -13;
                }
                signed_id_pk = ph.pk.to_vec();
                peer_is_udp = ph.is_udp;
                if !ph.socket_addr.is_empty() {
                    peer_addr = Some(AddrMangle::decode(&ph.socket_addr));
                }
                if !ph.socket_addr_v6.is_empty() {
                    let address = AddrMangle::decode(&ph.socket_addr_v6);
                    if address.port() > 0 {
                        peer_ipv6_addr = Some(address);
                    }
                }
                webrtc_sdp_answer = ph.webrtc_sdp_answer;
                if relay_from_server.is_empty() {
                    relay_from_server = ph.relay_server;
                }
                if peer_addr.is_none()
                    && peer_ipv6_addr.is_none()
                    && webrtc_sdp_answer.is_empty()
                    && relay_from_server.is_empty()
                {
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
                if !ph.socket_addr_v6.is_empty() {
                    let address = AddrMangle::decode(&ph.socket_addr_v6);
                    if address.port() > 0 {
                        peer_ipv6_addr = Some(address);
                    }
                }
                if relay_from_server.is_empty() {
                    relay_from_server = ph.relay_server;
                }
            }
            Some(rendezvous_message::Union::RelayResponse(rr)) => {
                emit_event(&format!(
                    "relay response relay_set={} uuid_len={} pk_len={} refusal={}",
                    !rr.relay_server.is_empty(),
                    rr.uuid.len(),
                    rr.pk().len(),
                    classify_rendezvous_refusal(&rr.refuse_reason)
                ));
                if !rr.refuse_reason.is_empty() {
                    emit_event(&format!("rendezvous rejected source=relay category={}",
                        classify_rendezvous_refusal(&rr.refuse_reason)));
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
                relay_uuid = Some(rr.uuid);
                if !rr.socket_addr_v6.is_empty() {
                    let address = AddrMangle::decode(&rr.socket_addr_v6);
                    if address.port() > 0 {
                        peer_ipv6_addr = Some(address);
                    }
                }
                webrtc_sdp_answer = rr.webrtc_sdp_answer;
            }
            _ => {
                emit_event(&format!(
                    "unexpected rendezvous response kind={}",
                    rendezvous_message_kind(&response.union)
                ));
                return -5;
            }
        }

        // The TCP punch reuses the rendezvous connection's local endpoint.
        // The UDP/KCP sockets and WebRTC ICE sockets were prepared independently.
        drop(rv_conn);

        let mut udp_socket = udp_candidate.map(|(socket, _)| socket);
        if force_relay != 0 || !peer_is_udp {
            udp_socket = None;
        } else if let (Some(socket), Some(address)) = (udp_socket.as_ref(), peer_addr) {
            if let Err(error) = socket.connect(address).await {
                emit_event(&format!("udp peer endpoint rejected: {error}"));
                udp_socket = None;
            }
        } else {
            udp_socket = None;
        }

        let mut ipv6_socket = ipv6_candidate.map(|(socket, _)| socket);
        if force_relay != 0 {
            ipv6_socket = None;
        } else if let (Some(socket), Some(address)) = (ipv6_socket.as_ref(), peer_ipv6_addr) {
            if let Err(error) = socket.connect(address).await {
                emit_event(&format!("ipv6 peer endpoint rejected: {error}"));
                ipv6_socket = None;
            }
        } else {
            ipv6_socket = None;
        }

        let mut webrtc_stream = webrtc_candidate.map(|(stream, _)| stream);
        if let Some(stream) = webrtc_stream.as_ref() {
            if webrtc_sdp_answer.is_empty() {
                stream.close().await;
                webrtc_stream = None;
            } else if let Err(error) = stream.set_remote_endpoint(&webrtc_sdp_answer).await {
                emit_event(&format!("webrtc answer rejected: {error}"));
                stream.close().await;
                webrtc_stream = None;
            }
        }

        let direct_failures = recent_peer_direct_failures(&peer, now_ms());
        let direct_timeout = official_direct_timeout(
            is_local,
            peer_nat_type,
            nat_type,
            !relay_from_server.is_empty(),
            direct_failures,
        );
        let tcp_peer = if force_relay == 0 && !peer_is_udp { peer_addr } else { None };
        emit_event(&format!(
            "transport race tcp={} udp_kcp={} ipv6_kcp={} webrtc={} timeout={direct_timeout}",
            tcp_peer.is_some(),
            udp_socket.is_some(),
            ipv6_socket.is_some(),
            webrtc_stream.is_some(),
        ));
        let direct_result = connect_direct_transports(
            tcp_peer,
            local_addr,
            direct_timeout,
            udp_socket,
            ipv6_socket,
            webrtc_stream,
            if force_relay != 0 { 2 } else { 1 },
        ).await;

        let mut selected = match direct_result {
            Ok(transport) => {
                emit_event(&format!("transport connected type={}", transport.label));
                transport
            }
            Err(direct_error) if !relay_from_server.is_empty() => {
                emit_event(&format!("direct transports failed: {direct_error}; try relay"));
                if force_relay == 0 {
                    record_peer_direct_failure(&peer, now_ms());
                }
                let relay_result = if let Some(uuid) = relay_uuid.as_deref() {
                    create_relay(
                        &peer,
                        uuid,
                        &relay_from_server,
                        &key,
                        local_addr.is_ipv4(),
                    ).await
                } else {
                    request_relay(
                        &peer,
                        &relay_from_server,
                        &active_rendezvous_addr,
                        !signed_id_pk.is_empty(),
                        &key,
                        "",
                    ).await
                };
                match relay_result {
                    Ok(stream) => {
                        let transport = stream_transport_code(&stream);
                        ConnectedTransport {
                            stream,
                            kcp: None,
                            label: stream_transport_label(transport),
                            route: 2,
                            transport,
                        }
                    }
                    Err(error) => {
                        emit_event(&format!("relay failed: {error}"));
                        return -15;
                    }
                }
            }
            Err(error) => {
                emit_event(&format!("all direct transports failed: {error}"));
                return -14;
            }
        };

        if let Err(error) = secure_peer_connection(
            &peer,
            &signed_id_pk,
            &key,
            &mut selected.stream,
            allow_insecure_fallback != 0,
        ).await {
            if selected.stream.is_webrtc() && !relay_from_server.is_empty() {
                emit_event(&format!("webrtc secure handshake failed: {error}; try relay"));
                record_peer_direct_failure(&peer, now_ms());
                selected.stream.close_webrtc().await;
                let mut relay = match request_relay(
                    &peer,
                    &relay_from_server,
                    &active_rendezvous_addr,
                    !signed_id_pk.is_empty(),
                    &key,
                    "",
                ).await {
                    Ok(stream) => stream,
                    Err(relay_error) => {
                        emit_event(&format!("webrtc relay fallback failed: {relay_error}"));
                        return -15;
                    }
                };
                if secure_peer_connection(
                    &peer,
                    &signed_id_pk,
                    &key,
                    &mut relay,
                    allow_insecure_fallback != 0,
                ).await.is_err() {
                    emit_event("secure relay fallback failed");
                    return -16;
                }
                let transport = stream_transport_code(&relay);
                selected = ConnectedTransport {
                    stream: relay,
                    kcp: None,
                    label: stream_transport_label(transport),
                    route: 2,
                    transport,
                };
            } else {
                emit_event("secure fallback failed");
                return if matches!(error.to_string().as_str(), "invalid server key" | "server key mismatch") {
                    -24
                } else {
                    -16
                };
            }
        }
        emit_event("secure fallback completed");

        if SESSION_ID.load(Ordering::SeqCst) != session_id {
            emit_event("connect session stale before store");
            return -19;
        }
        record_peer_route_success(&peer, selected.route, selected.transport, now_ms());
        selected.stream.set_send_timeout(5000);
        CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
        CONNECTION_ROUTE.store(selected.route, Ordering::SeqCst);
        CONNECTION_TRANSPORT.store(selected.transport, Ordering::SeqCst);

        spawn_receive_loop(session_id, selected.stream, selected.kcp);
        emit_event(&format!("receive loop spawned transport={}", selected.label));
        0
        }).await {
            Ok(result) => result,
            Err(ConnectionAttemptError::Cancelled) => {
                emit_event(&format!("connect cancelled session={session_id}"));
                -19
            }
            Err(ConnectionAttemptError::Deadline) => {
                emit_event(&format!("connect deadline exceeded session={session_id}"));
                -20
            }
      }
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
pub extern "C" fn rust_set_remote_cursor_visible(visible: i32) -> i32 {
    let visible = visible != 0;
    SHOW_REMOTE_CURSOR.store(visible, Ordering::SeqCst);
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        return 0;
    }

    let mut misc = Misc::new();
    misc.set_option(OptionMessage {
        show_remote_cursor: if visible {
            hbb_common::message_proto::option_message::BoolOption::Yes
        } else {
            hbb_common::message_proto::option_message::BoolOption::No
        }
        .into(),
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    let result = queue_peer_message(msg);
    if result == 0 {
        emit_event(&format!(
            "remote cursor visibility updated: {}",
            if visible { "video" } else { "local-overlay" }
        ));
    }
    result
}

#[no_mangle]
pub extern "C" fn rust_set_audio_enabled(enabled: i32) -> i32 {
    let enabled = enabled != 0;
    REMOTE_AUDIO_ENABLED.store(enabled, Ordering::SeqCst);
    if !enabled {
        reset_audio_async();
    }
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        return 0;
    }

    let mut misc = Misc::new();
    misc.set_option(OptionMessage {
        disable_audio: if enabled {
            hbb_common::message_proto::option_message::BoolOption::No
        } else {
            hbb_common::message_proto::option_message::BoolOption::Yes
        }
        .into(),
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    let result = queue_peer_message(msg);
    if result == 0 {
        emit_event(&format!(
            "remote audio updated: {}",
            if enabled { "enabled" } else { "disabled" }
        ));
    }
    result
}

#[no_mangle]
pub extern "C" fn rust_set_background_video_mode(enabled: i32) -> i32 {
    let enabled = enabled != 0;
    BACKGROUND_VIDEO_MODE.store(enabled, Ordering::SeqCst);
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        return 0;
    }

    let performance = performance_config();
    let mut misc = Misc::new();
    misc.set_option(OptionMessage {
        image_quality: performance.quality.into(),
        custom_fps: performance.fps,
        supported_decoding: MessageField::some(supported_decoding_options(false)),
        disable_audio: if REMOTE_AUDIO_ENABLED.load(Ordering::SeqCst) {
            hbb_common::message_proto::option_message::BoolOption::No
        } else {
            hbb_common::message_proto::option_message::BoolOption::Yes
        }
        .into(),
        show_remote_cursor: if SHOW_REMOTE_CURSOR.load(Ordering::SeqCst) {
            hbb_common::message_proto::option_message::BoolOption::Yes
        } else {
            hbb_common::message_proto::option_message::BoolOption::No
        }
        .into(),
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    let result = queue_peer_message(msg);
    if result != 0 {
        return result;
    }
    emit_event(&format!(
        "background video mode updated: {} fps={}",
        enabled, performance.fps
    ));
    if enabled {
        let mut fps_misc = Misc::new();
        fps_misc.set_auto_adjust_fps(performance.fps as u32);
        let mut fps_msg = PeerMessage::new();
        fps_msg.set_misc(fps_misc);
        queue_peer_message(fps_msg)
    } else {
        rust_refresh_video()
    }
}

#[no_mangle]
pub extern "C" fn rust_disconnect() -> i32 {
    let closing_session_id = SESSION_ID.load(Ordering::SeqCst);
    let graceful_close_completed = request_graceful_peer_close(closing_session_id);
    finish_peer_task(closing_session_id, graceful_close_completed);
    let session_id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    set_file_transfer_status("idle", 0, 0, "");
    if let Ok(mut sender) = FILE_MESSAGE_SENDER.lock() {
        *sender = None;
    }
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    CONNECTION_TRANSPORT.store(0, Ordering::SeqCst);
    CONNECTION_DELAY_MS.store(0, Ordering::SeqCst);
    CONNECTION_TARGET_BITRATE_KB.store(0, Ordering::SeqCst);
    ALLOW_INSECURE_SESSION.store(false, Ordering::SeqCst);
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
    // Keep the attempted route visible through a failed secure handshake.
    // Connect/disconnect already reset it; ACTIVE is set only after verification.
    CONNECTION_ROUTE.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn rust_get_connection_transport() -> i32 {
    CONNECTION_TRANSPORT.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn rust_get_connection_delay_ms() -> i32 {
    CONNECTION_DELAY_MS.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn rust_get_connection_target_bitrate_kb() -> i32 {
    CONNECTION_TARGET_BITRATE_KB.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn rust_send_mouse_event(x: f64, y: f64, action: i32, modifier_mask: i32) -> i32 {
    let mask = match action {
        0 => 0,            // move
        1 => (1 << 3) | 1, // left down
        2 => (1 << 3) | 2, // left up
        3 => (2 << 3) | 1, // right down
        4 => (2 << 3) | 2, // right up
        _ => 0,
    };
    let (offset_x, offset_y) = current_display_origin();
    let mut msg = PeerMessage::new();
    msg.set_mouse_event(MouseEvent {
        mask,
        x: x as i32 + offset_x,
        y: y as i32 + offset_y,
        modifiers: modifier_mask_to_controls(modifier_mask),
        ..Default::default()
    });
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_mouse_wheel(delta_x: f64, delta_y: f64, modifier_mask: i32) -> i32 {
    let mut msg = PeerMessage::new();
    msg.set_mouse_event(MouseEvent {
        mask: 3,
        x: delta_x.round() as i32,
        y: delta_y.round() as i32,
        modifiers: modifier_mask_to_controls(modifier_mask),
        ..Default::default()
    });
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_key_event(key_code: i32, action: i32, modifier_mask: i32) -> i32 {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Legacy.into(),
        // RustDesk's sender does not repeat the modifier represented by the
        // current key event inside the modifier list.
        modifiers: modifier_mask_to_controls(modifier_mask & !modifier_bit_for_key_code(key_code)),
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
pub extern "C" fn rust_send_physical_key_event(
    usb_hid_code: i32,
    action: i32,
    modifier_mask: i32,
) -> i32 {
    let peer_platform = CURRENT_PEER_PLATFORM
        .lock()
        .map(|guard| guard.clone())
        .unwrap_or_default();
    let Some(peer_code) = map_usb_hid_to_peer_code(usb_hid_code.max(0) as u32, &peer_platform)
    else {
        emit_event(&format!(
            "keyboard map unsupported hid={} peer_platform={}",
            usb_hid_code,
            if peer_platform.is_empty() {
                "unknown"
            } else {
                peer_platform.as_str()
            }
        ));
        return -3;
    };
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Map.into(),
        modifiers: modifier_mask_to_controls(modifier_mask),
        ..Default::default()
    };
    event.union = Some(key_event::Union::Chr(peer_code));
    let mut msg = PeerMessage::new();
    msg.set_key_event(event);
    queue_peer_message(msg)
}

fn ctrl_alt_del_event(peer_platform: &str) -> KeyEvent {
    let mut event = KeyEvent {
        mode: KeyboardMode::Legacy.into(),
        ..Default::default()
    };
    if peer_platform.eq_ignore_ascii_case("windows") {
        // Windows secure attention sequence. This must be handled by the
        // installed RustDesk service and cannot be synthesized as three normal
        // key presses from a mobile client.
        event.set_control_key(ControlKey::CtrlAltDel);
        event.down = true;
    } else {
        // RustDesk's official client uses a normal Ctrl+Alt+Delete press for
        // supported non-Windows peers such as Linux.
        event.set_control_key(ControlKey::Delete);
        event.modifiers = modifier_mask_to_controls(1 | 4);
        event.press = true;
    }
    event
}

#[no_mangle]
pub extern "C" fn rust_send_ctrl_alt_del() -> i32 {
    let peer_platform = CURRENT_PEER_PLATFORM
        .lock()
        .map(|guard| guard.clone())
        .unwrap_or_default();
    let mut msg = PeerMessage::new();
    msg.set_key_event(ctrl_alt_del_event(&peer_platform));
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_can_send_ctrl_alt_del() -> i32 {
    let peer_platform = CURRENT_PEER_PLATFORM
        .lock()
        .map(|guard| guard.to_ascii_lowercase())
        .unwrap_or_default();
    if peer_platform.contains("linux")
        || (peer_platform.contains("windows") && PEER_SAS_ENABLED.load(Ordering::SeqCst))
    {
        1
    } else {
        0
    }
}

fn lookup_usb_hid_code(
    hid: u32,
    letters: &[u32; 26],
    digits: &[u32; 10],
    printable: &[u32; 17],
) -> Option<u32> {
    let code = match hid {
        0x04..=0x1D => letters[(hid - 0x04) as usize],
        0x1E..=0x27 => digits[(hid - 0x1E) as usize],
        0x28..=0x38 => printable[(hid - 0x28) as usize],
        _ => 0,
    };
    (code != 0).then_some(code)
}

fn usb_hid_to_windows_scan_code(hid: u32) -> Option<u32> {
    const LETTERS: [u32; 26] = [
        0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18,
        0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C,
    ];
    const DIGITS: [u32; 10] = [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B];
    const PRINTABLE: [u32; 17] = [
        0x1C, 0x01, 0x0E, 0x0F, 0x39, 0x0C, 0x0D, 0x1A, 0x1B, 0x2B, 0, 0x27, 0x28, 0x29, 0x33,
        0x34, 0x35,
    ];
    lookup_usb_hid_code(hid, &LETTERS, &DIGITS, &PRINTABLE)
}

fn usb_hid_to_linux_xorg_code(hid: u32) -> Option<u32> {
    // RustDesk's Linux Map receiver expects Xorg/XKB keycodes, which are
    // Linux evdev codes plus the X11 offset of eight.
    const LETTERS: [u32; 26] = [
        38, 56, 54, 40, 26, 41, 42, 43, 31, 44, 45, 46, 58, 57, 32, 33, 24, 27, 39, 28, 30, 55, 25,
        53, 29, 52,
    ];
    const DIGITS: [u32; 10] = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19];
    const PRINTABLE: [u32; 17] = [
        36, 9, 22, 23, 65, 20, 21, 34, 35, 51, 0, 47, 48, 49, 59, 60, 61,
    ];
    lookup_usb_hid_code(hid, &LETTERS, &DIGITS, &PRINTABLE)
}

fn usb_hid_to_macos_code(hid: u32) -> Option<u32> {
    const LETTERS: [u32; 26] = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16,
        6,
    ];
    const DIGITS: [u32; 10] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29];
    const PRINTABLE: [u32; 17] = [
        36,
        53,
        51,
        48,
        49,
        27,
        24,
        33,
        30,
        42,
        u32::MAX,
        41,
        39,
        50,
        43,
        47,
        44,
    ];
    // macOS virtual keycode 0 is a valid A key, so use a sentinel for the
    // unsupported HID 0x32 slot instead of treating zero as missing.
    let code = match hid {
        0x04..=0x1D => LETTERS[(hid - 0x04) as usize],
        0x1E..=0x27 => DIGITS[(hid - 0x1E) as usize],
        0x28..=0x38 => PRINTABLE[(hid - 0x28) as usize],
        _ => u32::MAX,
    };
    (code != u32::MAX).then_some(code)
}

fn usb_hid_to_android_code(hid: u32) -> Option<u32> {
    const LETTERS: [u32; 26] = [
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
        52, 53, 54,
    ];
    const DIGITS: [u32; 10] = [8, 9, 10, 11, 12, 13, 14, 15, 16, 7];
    const PRINTABLE: [u32; 17] = [
        66, 111, 67, 61, 62, 69, 70, 71, 72, 73, 0, 74, 75, 68, 55, 56, 76,
    ];
    lookup_usb_hid_code(hid, &LETTERS, &DIGITS, &PRINTABLE)
}

fn map_usb_hid_to_peer_code(hid: u32, peer_platform: &str) -> Option<u32> {
    let platform = peer_platform.trim().to_ascii_lowercase();
    if platform.contains("linux") {
        usb_hid_to_linux_xorg_code(hid)
    } else if platform.contains("android") {
        usb_hid_to_android_code(hid)
    } else if platform.contains("mac") || platform.contains("darwin") || platform.contains("osx") {
        usb_hid_to_macos_code(hid)
    } else {
        // Preserve the previous Windows behavior for Windows and for old peers
        // that do not report a platform string.
        usb_hid_to_windows_scan_code(hid)
    }
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
    let mut msg = PeerMessage::new();
    msg.set_clipboard(clipboard);
    emit_event("local clipboard text sent");
    queue_peer_message(msg)
}

fn queue_mouse_mask(mask: i32) -> i32 {
    let mut msg = PeerMessage::new();
    msg.set_mouse_event(MouseEvent {
        mask,
        ..Default::default()
    });
    queue_peer_message(msg)
}

fn queue_mapped_key(scan_code: u32, down: bool) -> i32 {
    let mut event = KeyEvent {
        down,
        mode: KeyboardMode::Map.into(),
        ..Default::default()
    };
    event.union = Some(key_event::Union::Chr(scan_code));
    let mut msg = PeerMessage::new();
    msg.set_key_event(event);
    queue_peer_message(msg)
}

fn version_at_least(version: &str, required: [u32; 3]) -> bool {
    if version.trim().is_empty() {
        return true;
    }
    let mut parsed = [0_u32; 3];
    for (index, part) in version.split('.').take(3).enumerate() {
        let digits: String = part.chars().take_while(|ch| ch.is_ascii_digit()).collect();
        parsed[index] = digits.parse::<u32>().unwrap_or(0);
    }
    parsed >= required
}

/// Sends the Android controlled-side actions used by the official RustDesk
/// client. Android's accessibility service maps the back mouse button to Back,
/// a short middle-button click to Home, and a held middle-button click to
/// Recents. Volume and power use Flutter's USB HID usages in map mode.
#[no_mangle]
pub extern "C" fn rust_send_mobile_action(action: i32) -> i32 {
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        return -1;
    }
    if !PEER_IS_ANDROID.load(Ordering::SeqCst) {
        return -2;
    }

    const BACK_UP: i32 = (8 << 3) | 2;
    const RIGHT_UP: i32 = (2 << 3) | 2;
    const MIDDLE_DOWN: i32 = (4 << 3) | 1;
    const MIDDLE_UP: i32 = (4 << 3) | 2;
    const HID_POWER: u32 = 0x66;
    const HID_VOLUME_UP: u32 = 0x80;
    const HID_VOLUME_DOWN: u32 = 0x81;

    let result = match action {
        0 => {
            let peer_version = CURRENT_PEER_VERSION
                .lock()
                .map(|guard| guard.clone())
                .unwrap_or_default();
            // RustDesk before 1.3.8 used right-button release for Android Back.
            queue_mouse_mask(if version_at_least(&peer_version, [1, 3, 8]) {
                BACK_UP
            } else {
                RIGHT_UP
            })
        }
        1 => {
            let down_result = queue_mouse_mask(MIDDLE_DOWN);
            if down_result == 0 {
                queue_mouse_mask(MIDDLE_UP)
            } else {
                down_result
            }
        }
        2 => {
            let down_result = queue_mouse_mask(MIDDLE_DOWN);
            if down_result == 0 {
                let session_id = SESSION_ID.load(Ordering::SeqCst);
                runtime().spawn(async move {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    if SESSION_ID.load(Ordering::SeqCst) == session_id
                        && CONNECTION_ACTIVE.load(Ordering::SeqCst)
                    {
                        let _ = queue_mouse_mask(MIDDLE_UP);
                    }
                });
            }
            down_result
        }
        3 | 4 | 5 => {
            let scan_code = match action {
                3 => HID_VOLUME_UP,
                4 => HID_VOLUME_DOWN,
                _ => HID_POWER,
            };
            let down_result = queue_mapped_key(scan_code, true);
            if down_result == 0 {
                let session_id = SESSION_ID.load(Ordering::SeqCst);
                runtime().spawn(async move {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    if SESSION_ID.load(Ordering::SeqCst) == session_id
                        && CONNECTION_ACTIVE.load(Ordering::SeqCst)
                    {
                        let _ = queue_mapped_key(scan_code, false);
                    }
                });
            }
            down_result
        }
        _ => -3,
    };
    emit_event(&format!("mobile action: action={action} result={result}"));
    result
}

#[no_mangle]
pub extern "C" fn rust_is_peer_android() -> i32 {
    if CONNECTION_ACTIVE.load(Ordering::SeqCst) && PEER_IS_ANDROID.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn rust_send_2fa(code: *const c_char, client_hwid: *const c_char) -> i32 {
    let Some(code) = cstr_to_string(code) else {
        return -1;
    };
    if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
        return -2;
    }
    let hwid = cstr_to_string(client_hwid).unwrap_or_default().into_bytes();
    if let Ok(mut hwid_guard) = CURRENT_CLIENT_HWID.lock() {
        *hwid_guard = hwid.clone();
    }
    if let Ok(mut config_guard) = CURRENT_CONNECTION_CONFIG.lock() {
        if let Some(config) = config_guard.as_mut() {
            config.client_hwid = hwid.clone();
        }
    }

    let mut msg = PeerMessage::new();
    msg.set_auth_2fa(Auth2FA {
        code,
        hwid: hwid.into(),
        ..Default::default()
    });
    emit_event("2fa response queued");
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_request_remote_directory(path: *const c_char) -> i32 {
    let Some(mut path) = cstr_to_string(path) else {
        return -1;
    };
    if path.is_empty() {
        path = "/".to_string();
    }
    if path.len() > 4096 || path.bytes().any(|byte| byte == 0) {
        return -2;
    }
    if let Ok(mut result) = REMOTE_DIRECTORY_RESULT.lock() {
        result.clear();
    }
    let mut action = FileAction::new();
    action.set_read_dir(ReadDir {
        path,
        include_hidden: false,
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_file_action(action);
    let Some(sender) = ensure_file_session() else {
        return -3;
    };
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    sender
        .send(QueuedPeerCommand::Message {
            session_id,
            message: msg,
        })
        .map(|_| 0)
        .unwrap_or(-4)
}

#[no_mangle]
pub extern "C" fn rust_take_remote_directory_result() -> *mut c_char {
    let value = REMOTE_DIRECTORY_RESULT
        .lock()
        .map(|mut result| std::mem::take(&mut *result))
        .unwrap_or_default();
    CString::new(value)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn rust_start_file_upload(
    local_path: *const c_char,
    file_name: *const c_char,
    remote_directory: *const c_char,
) -> i32 {
    let Some(local_path) = cstr_to_string(local_path) else {
        return -1;
    };
    let Some(file_name) = cstr_to_string(file_name) else {
        return -1;
    };
    let Some(remote_directory) = cstr_to_string(remote_directory) else {
        return -1;
    };
    if file_name.is_empty()
        || file_name.len() > 255
        || file_name.contains(['/', '\\', '\0'])
        || remote_directory.is_empty()
        || remote_directory.len() > 4096
    {
        return -2;
    }
    let Ok(metadata) = std::fs::metadata(&local_path) else {
        return -3;
    };
    if !metadata.is_file() {
        return -4;
    }

    let separator = if remote_directory.contains('\\') || remote_directory.ends_with(':') {
        '\\'
    } else {
        '/'
    };
    let remote_path = if remote_directory.ends_with(['/', '\\']) {
        format!("{remote_directory}{file_name}")
    } else {
        format!("{remote_directory}{separator}{file_name}")
    };
    let id = (SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        % i32::MAX as u128) as i32;
    let mut job = match TransferJob::new_read(
        id,
        JobType::Generic,
        remote_path.clone(),
        DataSource::FilePath(PathBuf::from(local_path)),
        0,
        false,
        false,
        true,
    ) {
        Ok(job) => job,
        Err(_) => return -5,
    };
    job.set_overwrite_strategy(Some(true));
    let receive = fs::new_receive(id, remote_path, 0, job.files().clone(), job.total_size());
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    let Some(sender) = ensure_file_session() else {
        return -6;
    };
    set_file_transfer_status("starting", 0, job.total_size(), "");
    sender
        .send(QueuedPeerCommand::StartUpload {
            session_id,
            job,
            receive,
        })
        .map(|_| 0)
        .unwrap_or(-7)
}

#[no_mangle]
pub extern "C" fn rust_start_file_download_batch(
    requests_json: *const c_char,
    local_root: *const c_char,
) -> i32 {
    let Some(requests_json) = cstr_to_string(requests_json) else {
        return -1;
    };
    let Some(local_root) = cstr_to_string(local_root) else {
        return -1;
    };
    if local_root.is_empty() || local_root.len() > 4096 || local_root.bytes().any(|byte| byte == 0)
    {
        return -2;
    }
    let Ok(requests) = serde_json::from_str::<Vec<FileDownloadRequest>>(&requests_json) else {
        return -3;
    };
    if requests.is_empty() || requests.len() > 100 {
        return -4;
    }
    if std::fs::create_dir_all(&local_root).is_err() {
        return -5;
    }

    let mut commands = Vec::with_capacity(requests.len());
    for request in requests {
        if request.remote_path.is_empty()
            || request.remote_path.len() > 4096
            || request.remote_path.bytes().any(|byte| byte == 0)
            || request.local_name.is_empty()
            || request.local_name.len() > 255
            || request.local_name == "."
            || request.local_name == ".."
            || request.local_name.contains(['/', '\\', '\0'])
        {
            return -6;
        }
        let local_path = PathBuf::from(&local_root).join(&request.local_name);
        if request.is_directory && std::fs::create_dir_all(&local_path).is_err() {
            return -7;
        }
        let id = next_file_job_id();
        let mut job = TransferJob::new_write(
            id,
            JobType::Generic,
            request.remote_path.clone(),
            DataSource::FilePath(local_path),
            0,
            false,
            true,
            true,
        );
        job.set_overwrite_strategy(Some(true));
        let send = fs::new_send(id, JobType::Generic, request.remote_path, 0, false);
        commands.push(DownloadJobCommand { job, send });
    }

    let Some(sender) = ensure_file_session() else {
        return -8;
    };
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    set_file_transfer_status_detail("download", "starting", 0, 0, "", 0, commands.len());
    sender
        .send(QueuedPeerCommand::StartDownload {
            session_id,
            jobs: commands,
        })
        .map(|_| 0)
        .unwrap_or(-9)
}

fn next_file_job_id() -> i32 {
    let id = NEXT_FILE_JOB_ID.fetch_add(1, Ordering::SeqCst);
    if id >= i32::MAX - 1_000 {
        NEXT_FILE_JOB_ID.store(10_000, Ordering::SeqCst);
    }
    id.max(1)
}

#[no_mangle]
pub extern "C" fn rust_get_file_transfer_status() -> *mut c_char {
    let value = FILE_TRANSFER_STATUS
        .lock()
        .map(|status| status.clone())
        .unwrap_or_default();
    CString::new(value)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn rust_cancel_file_transfer() -> i32 {
    let Some(sender) = FILE_MESSAGE_SENDER
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
    else {
        return -1;
    };
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    sender
        .send(QueuedPeerCommand::CancelTransfer { session_id })
        .map(|_| 0)
        .unwrap_or(-2)
}

fn ensure_file_session() -> Option<Sender<QueuedPeerCommand>> {
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        return None;
    }
    if let Some(sender) = FILE_MESSAGE_SENDER
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
    {
        return Some(sender);
    }
    let config = CURRENT_CONNECTION_CONFIG.lock().ok()?.clone()?;
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    let (sender, receiver) = mpsc::channel::<QueuedPeerCommand>();
    if let Ok(mut current) = FILE_MESSAGE_SENDER.lock() {
        *current = Some(sender.clone());
    } else {
        return None;
    }
    thread::spawn(move || {
        runtime().block_on(run_file_session(session_id, config, receiver));
        if SESSION_ID.load(Ordering::SeqCst) == session_id {
            if let Ok(mut current) = FILE_MESSAGE_SENDER.lock() {
                *current = None;
            }
        }
    });
    Some(sender)
}

async fn run_file_session(
    session_id: u64,
    config: ConnectionConfig,
    receiver: mpsc::Receiver<QueuedPeerCommand>,
) {
    emit_event("file-session:connecting");
    let connection = await_connection_attempt(
        session_id,
        &SESSION_ID,
        CONNECTION_DEADLINE,
        connect_file_stream(&config),
    )
    .await;
    let result = match connection {
        Err(ConnectionAttemptError::Cancelled) => return,
        Err(ConnectionAttemptError::Deadline) => {
            Err("file connection deadline exceeded".to_string())
        }
        Ok(result) => result,
    };
    if SESSION_ID.load(Ordering::SeqCst) != session_id {
        return;
    }
    let mut stream = match result {
        Ok(stream) => stream,
        Err(error) => {
            set_remote_directory_result(RemoteDirectoryResult {
                path: String::new(),
                entries: Vec::new(),
                error,
            });
            return;
        }
    };
    stream.set_send_timeout(5000);
    let mut authenticated = false;
    let mut pending = Vec::new();
    let mut read_jobs: Vec<TransferJob> = Vec::new();
    let mut write_jobs: Vec<TransferJob> = Vec::new();
    let mut download_state = DownloadBatchState::default();
    loop {
        if SESSION_ID.load(Ordering::SeqCst) != session_id {
            return;
        }
        while let Ok(command) = receiver.try_recv() {
            if authenticated {
                if !send_file_command(
                    command,
                    session_id,
                    &mut stream,
                    &mut read_jobs,
                    &mut write_jobs,
                    &mut download_state,
                )
                .await
                {
                    return;
                }
            } else {
                pending.push(command);
            }
        }
        if authenticated && !read_jobs.is_empty() {
            let total = read_jobs[0].total_size();
            if let Err(error) = fs::handle_read_jobs(&mut read_jobs, &mut stream).await {
                set_file_transfer_status("failed", 0, total, &error.to_string());
                read_jobs.clear();
            } else if let Some(job) = read_jobs.first() {
                set_file_transfer_status("transferring", job.finished_size(), job.total_size(), "");
            } else {
                set_file_transfer_status("completed", total, total, "");
            }
        }
        match stream.next_timeout(20).await {
            Some(Ok(bytes)) => {
                let Ok(message) = PeerMessage::parse_from_bytes(&bytes) else {
                    continue;
                };
                match message.union {
                    Some(message::Union::Hash(hash)) => {
                        if let Err(error) = send_file_login(hash, &config, &mut stream).await {
                            set_remote_directory_result(RemoteDirectoryResult {
                                path: String::new(),
                                entries: Vec::new(),
                                error: error.to_string(),
                            });
                            return;
                        }
                    }
                    Some(message::Union::LoginResponse(response)) => match response.union {
                        Some(login_response::Union::Error(error)) => {
                            set_remote_directory_result(RemoteDirectoryResult {
                                path: String::new(),
                                entries: Vec::new(),
                                error,
                            });
                            return;
                        }
                        _ => {
                            authenticated = true;
                            emit_event("file-session:authenticated");
                            for command in pending.drain(..) {
                                if is_root_directory_command(&command) {
                                    continue;
                                }
                                if !send_file_command(
                                    command,
                                    session_id,
                                    &mut stream,
                                    &mut read_jobs,
                                    &mut write_jobs,
                                    &mut download_state,
                                )
                                .await
                                {
                                    return;
                                }
                            }
                        }
                    },
                    Some(message::Union::FileResponse(response)) => {
                        handle_file_session_response(
                            response,
                            &mut read_jobs,
                            &mut write_jobs,
                            &mut download_state,
                            &mut stream,
                        )
                        .await;
                    }
                    Some(message::Union::FileAction(action)) => {
                        if let Some(file_action::Union::SendConfirm(confirm)) = action.union {
                            if let Some(job) = fs::get_job(confirm.id, &mut read_jobs) {
                                job.confirm(&confirm).await;
                                emit_event("file-session:upload-confirmed");
                            }
                        }
                    }
                    _ => {}
                }
            }
            Some(Err(error)) => {
                set_file_transfer_status("failed", 0, 0, &error.to_string());
                return;
            }
            None => {}
        }
    }
}

fn is_root_directory_command(command: &QueuedPeerCommand) -> bool {
    let QueuedPeerCommand::Message { message, .. } = command else {
        return false;
    };
    let Some(message::Union::FileAction(action)) = &message.union else {
        return false;
    };
    matches!(
        &action.union,
        Some(file_action::Union::ReadDir(read_dir)) if read_dir.path == "/"
    )
}

async fn send_file_command(
    command: QueuedPeerCommand,
    session_id: u64,
    stream: &mut Stream,
    read_jobs: &mut Vec<TransferJob>,
    write_jobs: &mut Vec<TransferJob>,
    download_state: &mut DownloadBatchState,
) -> bool {
    match command {
        QueuedPeerCommand::Message {
            session_id: command_session,
            message,
        } => command_session == session_id && stream.send(&message).await.is_ok(),
        QueuedPeerCommand::StartUpload {
            session_id: command_session,
            job,
            receive,
        } => {
            if command_session != session_id || stream.send(&receive).await.is_err() {
                return false;
            }
            read_jobs.clear();
            write_jobs.clear();
            *download_state = DownloadBatchState::default();
            let total = job.total_size();
            read_jobs.push(job);
            set_file_transfer_status("transferring", 0, total, "");
            true
        }
        QueuedPeerCommand::StartDownload {
            session_id: command_session,
            jobs,
        } => {
            if command_session != session_id || jobs.is_empty() {
                return false;
            }
            read_jobs.clear();
            write_jobs.clear();
            *download_state = DownloadBatchState {
                active: true,
                total_jobs: jobs.len(),
                ..Default::default()
            };
            for command in jobs {
                if stream.send(&command.send).await.is_err() {
                    set_download_transfer_status(
                        "failed",
                        write_jobs,
                        download_state,
                        "发送下载请求失败",
                    );
                    write_jobs.clear();
                    download_state.active = false;
                    return false;
                }
                write_jobs.push(command.job);
            }
            set_download_transfer_status("transferring", write_jobs, download_state, "");
            emit_event(&format!(
                "file-session:download-started items={}",
                download_state.total_jobs
            ));
            true
        }
        QueuedPeerCommand::CancelTransfer {
            session_id: command_session,
        } => {
            if command_session != session_id {
                return true;
            }
            let is_download = download_state.active || !write_jobs.is_empty();
            let direction = if is_download { "download" } else { "upload" };
            let completed_items = download_state.completed_jobs;
            let total_items = if is_download {
                download_state.total_jobs
            } else {
                1
            };
            let completed_bytes = download_state.completed_bytes;
            let active_finished = write_jobs
                .iter()
                .map(TransferJob::finished_size)
                .sum::<u64>();
            let active_total = write_jobs.iter().map(TransferJob::total_size).sum::<u64>();
            let upload_finished = read_jobs
                .iter()
                .map(TransferJob::finished_size)
                .sum::<u64>();
            let upload_total = read_jobs.iter().map(TransferJob::total_size).sum::<u64>();

            for job in read_jobs.iter().chain(write_jobs.iter()) {
                let mut action = FileAction::new();
                action.set_cancel(FileTransferCancel {
                    id: job.id(),
                    ..Default::default()
                });
                let mut message = PeerMessage::new();
                message.set_file_action(action);
                let _ = stream.send(&message).await;
            }
            for job in write_jobs.iter() {
                job.remove_download_file();
            }
            read_jobs.clear();
            write_jobs.clear();
            *download_state = DownloadBatchState::default();

            let transferred = if is_download {
                completed_bytes.saturating_add(active_finished)
            } else {
                upload_finished
            };
            let total = if is_download {
                completed_bytes.saturating_add(active_total)
            } else {
                upload_total
            };
            set_file_transfer_status_detail(
                direction,
                "cancelled",
                transferred,
                total,
                "",
                completed_items,
                total_items,
            );
            emit_event(&format!(
                "file-session:transfer-cancelled direction={direction}"
            ));
            true
        }
        QueuedPeerCommand::Close { completed, .. } => {
            let _ = completed.send(());
            false
        }
    }
}

async fn send_file_login(
    hash: Hash,
    config: &ConnectionConfig,
    stream: &mut Stream,
) -> Result<(), hbb_common::anyhow::Error> {
    let response_password = if config.password.is_empty() {
        Vec::new()
    } else {
        let mut first = Sha256::new();
        first.update(config.password.as_bytes());
        first.update(hash.salt.as_bytes());
        let mut second = Sha256::new();
        second.update(first.finalize());
        second.update(hash.challenge.as_bytes());
        second.finalize().to_vec()
    };
    let mut login = LoginRequest {
        username: config.peer.clone(),
        password: response_password.into(),
        my_id: config.client_id.clone(),
        my_name: "StarRustDesk HarmonyOS".to_string(),
        my_platform: "HarmonyOS".to_string(),
        session_id: PROTOCOL_SESSION_ID.load(Ordering::SeqCst),
        version: "1.2.0".to_string(),
        os_login: MessageField::some(OSLogin::new()),
        hwid: config.client_hwid.clone().into(),
        ..Default::default()
    };
    login.set_file_transfer(FileTransfer {
        dir: "/".to_string(),
        show_hidden: false,
        ..Default::default()
    });
    let mut message = PeerMessage::new();
    message.set_login_request(login);
    stream.send(&message).await
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
    DISPLAY_COUNT
        .try_lock()
        .map(|guard| *guard)
        .unwrap_or(1)
        .max(1)
}

#[no_mangle]
pub extern "C" fn rust_get_current_display() -> i32 {
    CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn rust_get_remote_cursor_position(
    x: *mut i32,
    y: *mut i32,
    sequence: *mut u64,
) -> i32 {
    if !REMOTE_CURSOR_VALID.load(Ordering::SeqCst)
        || x.is_null()
        || y.is_null()
        || sequence.is_null()
    {
        return 0;
    }
    let (origin_x, origin_y) = current_display_origin();
    unsafe {
        *x = REMOTE_CURSOR_X.load(Ordering::SeqCst) - origin_x;
        *y = REMOTE_CURSOR_Y.load(Ordering::SeqCst) - origin_y;
        *sequence = REMOTE_CURSOR_SEQUENCE.load(Ordering::SeqCst);
    }
    1
}

#[no_mangle]
pub extern "C" fn rust_get_remote_cursor_data(
    id: *mut u64,
    hotx: *mut i32,
    hoty: *mut i32,
    width: *mut i32,
    height: *mut i32,
    sequence: *mut u64,
    colors: *mut c_uchar,
    colors_capacity: i32,
) -> i32 {
    if !REMOTE_CURSOR_IMAGE_VALID.load(Ordering::SeqCst)
        || id.is_null()
        || hotx.is_null()
        || hoty.is_null()
        || width.is_null()
        || height.is_null()
        || sequence.is_null()
    {
        return 0;
    }
    let current_id = REMOTE_CURSOR_IMAGE_ID.load(Ordering::SeqCst);
    let Ok(guard) = REMOTE_CURSOR_IMAGES.lock() else {
        return 0;
    };
    let Some(cursor) = guard.get(&current_id) else {
        return 0;
    };
    let required = cursor.colors.len().min(i32::MAX as usize) as i32;
    unsafe {
        *id = cursor.id;
        *hotx = cursor.hotx;
        *hoty = cursor.hoty;
        *width = cursor.width;
        *height = cursor.height;
        *sequence = REMOTE_CURSOR_IMAGE_SEQUENCE.load(Ordering::SeqCst);
        if !colors.is_null() && colors_capacity >= required && required > 0 {
            std::ptr::copy_nonoverlapping(cursor.colors.as_ptr(), colors, required as usize);
        }
    }
    required
}

#[no_mangle]
pub extern "C" fn rust_is_remote_cursor_embedded() -> i32 {
    let current = CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0);
    let index = current.max(0) as usize;
    DISPLAY_INFOS
        .try_lock()
        .ok()
        .and_then(|guard| guard.get(index).map(|display| display.4))
        .unwrap_or(false) as i32
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
    let switch_result = queue_peer_message(msg);
    if switch_result != 0 {
        return switch_result;
    }

    // Since RustDesk 1.2.4 a client advertising multi-UI support must also
    // narrow the capture subscription. Without this message every newly
    // selected monitor remains subscribed and its VideoFrames are interleaved
    // on our single HarmonyOS rendering surface.
    let mut capture_misc = Misc::new();
    capture_misc.set_capture_displays(CaptureDisplays {
        set: vec![display],
        ..Default::default()
    });
    let mut capture_msg = PeerMessage::new();
    capture_msg.set_misc(capture_misc);
    let capture_result = queue_peer_message(capture_msg);
    emit_event(&format!(
        "switch display requested display={display} capture_set_result={capture_result}"
    ));
    capture_result
}

#[no_mangle]
pub extern "C" fn rust_refresh_video() -> i32 {
    let mut refresh_misc = Misc::new();
    refresh_misc.set_refresh_video(true);
    let mut refresh_msg = PeerMessage::new();
    refresh_msg.set_misc(refresh_misc);
    let refresh_result = queue_peer_message(refresh_msg);
    if refresh_result != 0 {
        return refresh_result;
    }
    queue_video_received()
}

#[no_mangle]
pub extern "C" fn rust_fallback_video_to_vp9() -> i32 {
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        return -1;
    }
    if !VP9_DECODER_SUPPORTED.load(Ordering::SeqCst) {
        emit_event("video fallback skipped: vp9 decoder unavailable");
        return -3;
    }
    let performance = performance_config();
    let mut option_misc = Misc::new();
    option_misc.set_option(OptionMessage {
        image_quality: performance.quality.into(),
        custom_fps: performance.fps,
        supported_decoding: MessageField::some(supported_decoding_options(true)),
        disable_audio: if REMOTE_AUDIO_ENABLED.load(Ordering::SeqCst) {
            hbb_common::message_proto::option_message::BoolOption::No
        } else {
            hbb_common::message_proto::option_message::BoolOption::Yes
        }
        .into(),
        show_remote_cursor: if SHOW_REMOTE_CURSOR.load(Ordering::SeqCst) {
            hbb_common::message_proto::option_message::BoolOption::Yes
        } else {
            hbb_common::message_proto::option_message::BoolOption::No
        }
        .into(),
        ..Default::default()
    });
    let mut option_msg = PeerMessage::new();
    option_msg.set_misc(option_misc);
    let option_result = queue_peer_message(option_msg);
    if option_result != 0 {
        return option_result;
    }
    emit_event("video fallback: requested vp9");
    rust_refresh_video()
}

#[no_mangle]
pub extern "C" fn rust_query_peer_online_states(
    peers_json: *const c_char,
    rendezvous_server: *const c_char,
    requester_id: *const c_char,
) -> i32 {
    let peers_json = match cstr_to_string(peers_json) {
        Some(value) if !value.is_empty() => value,
        _ => return -1,
    };
    let mut peers: Vec<String> = match serde_json::from_str(&peers_json) {
        Ok(value) => value,
        Err(_) => return -2,
    };
    peers.retain(|peer| !peer.trim().is_empty());
    peers.sort();
    peers.dedup();
    if peers.is_empty() || peers.len() > 512 {
        return -3;
    }
    if PEER_ONLINE_QUERY_ACTIVE.swap(true, Ordering::SeqCst) {
        return 1;
    }

    let server = cstr_to_string(rendezvous_server)
        .unwrap_or_default()
        .trim()
        .to_string();
    // OnlineRequest is handled by hbbs on the auxiliary NAT-test port, which
    // is one lower than the normal rendezvous port (21115 for the default
    // 21116 service). Sending it to the main port makes hbbs close the stream
    // without an OnlineResponse.
    let rendezvous_addr = online_query_addr(&server);
    let requester_id = cstr_to_string(requester_id).unwrap_or_else(|| "harmony-client".to_string());
    if let Ok(guard) = PEER_ONLINE_RESULT.lock() {
        if !guard.is_empty() {
            PEER_ONLINE_QUERY_ACTIVE.store(false, Ordering::SeqCst);
            return 1;
        }
    }
    emit_event(&format!("online state query started count={}", peers.len()));

    runtime().spawn(async move {
        let started = Instant::now();
        let result = match tokio::time::timeout(
            ONLINE_QUERY_DEADLINE,
            query_peer_online_states(peers, rendezvous_addr, requester_id),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err("online query deadline exceeded (including DNS)".to_string()),
        };
        let payload = match result {
            Ok(states) => {
                emit_event(&format!(
                    "online state query completed count={} online={} elapsed_ms={}",
                    states.len(),
                    states.iter().filter(|peer| peer.online).count(),
                    started.elapsed().as_millis()
                ));
                PeerOnlineResult {
                    peers: states,
                    error: String::new(),
                    server: server.clone(),
                }
            }
            Err(error) => {
                emit_event(&format!("online state query failed: {error}"));
                PeerOnlineResult {
                    peers: Vec::new(),
                    error,
                    server,
                }
            }
        };
        if let Ok(serialized) = serde_json::to_string(&payload) {
            if let Ok(mut guard) = PEER_ONLINE_RESULT.lock() {
                *guard = serialized;
            }
        }
        PEER_ONLINE_QUERY_ACTIVE.store(false, Ordering::SeqCst);
    });
    0
}

async fn query_peer_online_states(
    peers: Vec<String>,
    rendezvous_addr: String,
    requester_id: String,
) -> Result<Vec<PeerOnlineState>, String> {
    // hbbs knows IDs, not IP listeners. Omit literals so callers retain an
    // unknown status instead of leaking local addresses or inventing offline.
    let peers: Vec<_> = peers
        .into_iter()
        .filter(|peer| matches!(direct_peer_addr(peer), Ok(None)))
        .collect();
    if peers.is_empty() {
        return Ok(Vec::new());
    }
    let mut connection = connect_transport_endpoint(
        rendezvous_addr,
        EndpointRole::Rendezvous,
        SERVER_CONNECT_TIMEOUT,
    )
    .await
    .map_err(|error| format!("connect failed: {error}"))?;
    let mut request = RendezvousMessage::new();
    request.set_online_request(OnlineRequest {
        id: requester_id,
        peers: peers.clone(),
        ..Default::default()
    });
    connection
        .send(&request)
        .await
        .map_err(|error| format!("send failed: {error}"))?;
    let response = next_rendezvous(&mut connection, RENDEZVOUS_REPLY_TIMEOUT)
        .await
        .ok_or_else(|| "response timeout".to_string())?;
    let online = match response.union {
        Some(rendezvous_message::Union::OnlineResponse(value)) => value,
        _ => return Err("unexpected response".to_string()),
    };
    let states = online.states.as_ref();
    if states.len() < (peers.len() + 7) / 8 {
        return Err("truncated online response".to_string());
    }
    Ok(peers
        .into_iter()
        .enumerate()
        .map(|(index, id)| {
            let byte = states.get(index / 8).copied().unwrap_or(0);
            let mask = 0x80_u8 >> (index % 8);
            PeerOnlineState {
                id,
                online: byte & mask != 0,
            }
        })
        .collect())
}

#[no_mangle]
pub extern "C" fn rust_take_peer_online_states() -> *mut c_char {
    let result = PEER_ONLINE_RESULT
        .lock()
        .map(|mut guard| std::mem::take(&mut *guard))
        .unwrap_or_default();
    CString::new(result).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn rust_get_device_id() -> *mut c_char {
    let id = format!(
        "{:03}-{:03}-{:03}",
        rand_simple(),
        rand_simple(),
        rand_simple()
    );
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

#[derive(Debug, PartialEq, Eq)]
enum ConnectionAttemptError {
    Cancelled,
    Deadline,
}

async fn await_connection_attempt<T>(
    session_id: u64,
    current_session: &AtomicU64,
    deadline: Duration,
    attempt: impl std::future::Future<Output = T>,
) -> Result<T, ConnectionAttemptError> {
    tokio::select! {
        biased;
        _ = async {
            while current_session.load(Ordering::SeqCst) == session_id {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        } => Err(ConnectionAttemptError::Cancelled),
        _ = tokio::time::sleep(deadline) => Err(ConnectionAttemptError::Deadline),
        result = attempt => Ok(result),
    }
}

fn direct_peer_addr(peer: &str) -> Result<Option<SocketAddr>, &'static str> {
    let peer = peer.trim();
    let address = peer.parse::<SocketAddr>().ok().or_else(|| {
        // Parse bare IPv6 as a whole: a trailing numeric component is not a
        // port. IPv6 with a port must use [address]:port.
        let ip = peer
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .unwrap_or(peer);
        ip.parse::<IpAddr>()
            .ok()
            .map(|ip| SocketAddr::new(ip, (RELAY_PORT + 1) as u16))
    });
    if let Some(address) = address {
        if address.port() == 0 {
            return Err("invalid direct IP port");
        }
        return Ok(Some(address));
    }
    if peer.is_empty()
        || peer.contains([':', '[', ']'])
        || (peer.contains('.') && peer.chars().all(|c| c.is_ascii_digit() || c == '.'))
    {
        return Err("invalid direct IP address or port");
    }
    Ok(None)
}

async fn connect_ip_literal(address: SocketAddr) -> hbb_common::ResultType<Stream> {
    // Match upstream's IP-listener protocol: no PunchHoleRequest, no empty
    // compatibility handshake, no signed-ID exchange. The receive loop handles
    // the listener's Hash/password challenge normally.
    tokio::time::timeout(
        Duration::from_millis(SERVER_CONNECT_TIMEOUT),
        connect_tcp_local(address, None, SERVER_CONNECT_TIMEOUT),
    )
    .await?
}

fn default_server_key(server: &str, key: &str) -> String {
    // Upstream common::get_key supplies RS_PUB_KEY for public service access.
    // Never replace an explicit key (even invalid: validation must fail closed)
    // or inject a public key into a custom self-hosted configuration.
    if server.trim().is_empty() && key.is_empty() {
        RS_PUB_KEY.to_string()
    } else {
        key.to_string()
    }
}

fn punch_hole_request(
    peer: &str,
    key: &str,
    conn_type: ConnType,
    force_relay: bool,
    nat_type: NatType,
    udp_port: u16,
    socket_addr_v6: Vec<u8>,
    webrtc_sdp_offer: String,
) -> RendezvousMessage {
    // Deliberately no password parameter. The remote password belongs only to
    // peer login; token is an account access token, not a password or server key.
    let mut request = RendezvousMessage::new();
    request.set_punch_hole_request(PunchHoleRequest {
        id: peer.to_string(),
        token: String::new(),
        nat_type: nat_type.into(),
        licence_key: key.to_string(),
        conn_type: conn_type.into(),
        force_relay,
        version: RUSTDESK_PROTOCOL_VERSION.to_string(),
        udp_port: udp_port as i32,
        socket_addr_v6: socket_addr_v6.into(),
        webrtc_sdp_offer,
        ..Default::default()
    });
    request
}

fn default_rendezvous_addr(server: &str) -> String {
    // Public bootstrap shipped by upstream hbb_common (config.rs). Its full
    // desktop client can also use configured/latency-selected servers; this
    // standalone core has no discovery mediator and uses the shipped bootstrap.
    // Never redirect an explicitly configured self-hosted server to public.
    with_port(
        if server.trim().is_empty() {
            RENDEZVOUS_SERVERS[0]
        } else {
            server
        },
        RENDEZVOUS_PORT,
    )
}

fn rendezvous_candidates(server: &str) -> Vec<String> {
    if !server.trim().is_empty() {
        return vec![default_rendezvous_addr(server)];
    }
    let mut candidates = Vec::new();
    // StarRustDesk keeps self-hosted settings outside hbb_common. Reading
    // Config::get_rendezvous_server(s) here could therefore leak a stale
    // custom-rendezvous-server into the public-server path. Only consume the
    // server list delivered by an official ConfigureUpdate plus the built-in
    // official bootstrap list.
    for candidate in Config::get_option("rendezvous-servers")
        .split(',')
        .map(str::trim)
        .filter(|candidate| !candidate.is_empty())
        .map(str::to_string)
        .chain(RENDEZVOUS_SERVERS.iter().map(|server| server.to_string()))
    {
        let candidate = with_port(&candidate, RENDEZVOUS_PORT);
        if !candidates.contains(&candidate) {
            candidates.push(candidate);
        }
    }
    if candidates.is_empty() {
        candidates.push(default_rendezvous_addr(""));
    }
    candidates
}

#[derive(Clone, Copy)]
enum EndpointRole {
    Rendezvous,
    Relay,
}

fn websocket_fallback_candidates(endpoint: &str, role: EndpointRole) -> Vec<String> {
    if endpoint.starts_with("ws://") || endpoint.starts_with("wss://") {
        return Vec::new();
    }
    let Some((host, port)) = split_host_port(endpoint) else {
        return Vec::new();
    };
    let host_without_brackets = host.trim_start_matches('[').trim_end_matches(']');
    let is_ip = host_without_brackets.parse::<IpAddr>().is_ok();
    let path = match role {
        EndpointRole::Rendezvous => "/ws/id",
        EndpointRole::Relay => "/ws/relay",
    };
    let websocket_port = port + 2;
    let mut candidates = Vec::new();
    if is_ip {
        candidates.push(format!("ws://{host}:{websocket_port}"));
    } else {
        // Official deployments commonly expose the path on HTTPS/443, while
        // self-hosted deployments commonly expose the dedicated +2 port.
        candidates.push(format!("wss://{host_without_brackets}{path}"));
        candidates.push(format!(
            "ws://{host_without_brackets}:{websocket_port}{path}"
        ));
        candidates.push(format!("ws://{host_without_brackets}{path}"));
    }
    candidates
}

async fn connect_transport_endpoint(
    endpoint: String,
    role: EndpointRole,
    timeout_ms: u64,
) -> hbb_common::ResultType<Stream> {
    let mut candidates = vec![endpoint.clone()];
    candidates.extend(websocket_fallback_candidates(&endpoint, role));
    let attempts: Vec<BoxFuture<'static, hbb_common::ResultType<(Stream, usize)>>> = candidates
        .into_iter()
        .enumerate()
        .map(|(index, candidate)| {
            async move {
                connect_tcp(candidate, timeout_ms)
                    .await
                    .map(|stream| (stream, index))
            }
            .boxed()
        })
        .collect();
    let ((stream, index), _) = select_ok(attempts).await?;
    if index > 0 {
        emit_event(match role {
            EndpointRole::Rendezvous => "rendezvous websocket fallback connected",
            EndpointRole::Relay => "relay websocket fallback connected",
        });
    }
    Ok(stream)
}

async fn connect_rendezvous(candidates: &[String]) -> Result<(Stream, String), String> {
    if candidates.is_empty() {
        return Err("no rendezvous server configured".to_string());
    }
    let total = candidates.len();
    let attempts: Vec<BoxFuture<'static, Result<(Stream, String), String>>> = candidates
        .iter()
        .cloned()
        .enumerate()
        .map(|(index, candidate)| {
            async move {
                emit_event(&format!(
                    "rendezvous candidate attempt={}/{}",
                    index + 1,
                    total
                ));
                connect_transport_endpoint(
                    candidate.clone(),
                    EndpointRole::Rendezvous,
                    SERVER_CONNECT_TIMEOUT,
                )
                .await
                .map(|stream| (stream, candidate))
                .map_err(|error| error.to_string())
            }
            .boxed()
        })
        .collect();
    select_ok(attempts)
        .await
        .map(|(winner, _)| winner)
        .map_err(|error| error.to_string())
}

struct ConnectedTransport {
    stream: Stream,
    kcp: Option<KcpStream>,
    label: &'static str,
    route: i32,
    transport: i32,
}

const TRANSPORT_TCP: i32 = 1;
const TRANSPORT_UDP_KCP: i32 = 2;
const TRANSPORT_IPV6_KCP: i32 = 3;
const TRANSPORT_WEBRTC: i32 = 4;
const TRANSPORT_WEBSOCKET: i32 = 5;

fn stream_transport_code(stream: &Stream) -> i32 {
    match stream {
        Stream::Tcp(_) => TRANSPORT_TCP,
        Stream::WebSocket(_) => TRANSPORT_WEBSOCKET,
        Stream::WebRTC(_) => TRANSPORT_WEBRTC,
    }
}

fn stream_transport_label(transport: i32) -> &'static str {
    match transport {
        TRANSPORT_TCP => "TCP",
        TRANSPORT_UDP_KCP => "UDP/KCP",
        TRANSPORT_IPV6_KCP => "IPv6/KCP",
        TRANSPORT_WEBRTC => "WebRTC",
        TRANSPORT_WEBSOCKET => "WebSocket",
        _ => "Unknown",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TransportPreparationPolicy {
    udp_kcp: bool,
    ipv6_kcp: bool,
    webrtc: bool,
}

fn transport_preparation_policy(
    public_server: bool,
    force_relay: bool,
) -> TransportPreparationPolicy {
    if force_relay {
        return TransportPreparationPolicy {
            udp_kcp: false,
            ipv6_kcp: false,
            webrtc: false,
        };
    }
    TransportPreparationPolicy {
        udp_kcp: true,
        ipv6_kcp: true,
        // A self-hosted hbbs/hbbr does not advertise WebRTC capability before
        // PunchHoleRequest. Starting ICE unconditionally made every custom
        // connection wait for STUN even when the server could never use it.
        webrtc: public_server,
    }
}

const UDP_NAT_TEST_TIMEOUT: Duration = Duration::from_millis(300);
const IPV6_PREPARATION_TIMEOUT: u64 = 300;
const WEBRTC_OFFER_TIMEOUT: u64 = 500;
const WEBRTC_CONNECT_TIMEOUT: u64 = 3_500;
const PUNCH_PROBE: [u8; 4] = *b"RDP?";
const PUNCH_ACK: [u8; 4] = *b"RDP!";
const PUNCH_PACKET_LEN: usize = 12;

async fn prepare_udp_punch_socket(
    rendezvous: &str,
    public_server: bool,
) -> Option<(Arc<UdpSocket>, u16)> {
    let (socket, server_addr) = match new_direct_udp_for(rendezvous).await {
        Ok(value) => value,
        Err(error) => {
            emit_event(&format!("udp mapping socket unavailable: {error}"));
            return None;
        }
    };
    let request = {
        let mut message = RendezvousMessage::new();
        message.set_test_nat_request(TestNatRequest {
            serial: Config::get_serial(),
            ..Default::default()
        });
        match message.write_to_bytes() {
            Ok(bytes) => bytes,
            Err(error) => {
                emit_event(&format!("udp mapping request encode failed: {error}"));
                return None;
            }
        }
    };
    let socket_for_probe = socket.clone();
    let result = tokio::time::timeout(UDP_NAT_TEST_TIMEOUT, async move {
        let mut retry = Duration::from_millis(20);
        let mut buf = [0_u8; 1500];
        loop {
            let _ = socket_for_probe.send_to(&request, server_addr).await;
            match tokio::time::timeout(retry, socket_for_probe.recv_from(&mut buf)).await {
                Ok(Ok((size, source))) if source.ip() == server_addr.ip() => {
                    let Ok(message) = RendezvousMessage::parse_from_bytes(&buf[..size]) else {
                        continue;
                    };
                    if let Some(rendezvous_message::Union::TestNatResponse(response)) =
                        message.union
                    {
                        if public_server {
                            if let Some(update) = response.cu.as_ref() {
                                apply_rendezvous_config_update(update);
                            }
                        }
                        if response.port > 0 && response.port <= u16::MAX as i32 {
                            return Some(response.port as u16);
                        }
                    }
                }
                _ => {}
            }
            retry = std::cmp::min(retry.mul_f64(1.5), Duration::from_millis(180));
        }
    })
    .await
    .ok()
    .flatten();
    match result {
        Some(port) => {
            emit_event(&format!("udp mapping available port={port}"));
            Some((socket, port))
        }
        None => {
            emit_event("udp mapping unavailable; keep tcp/webrtc/relay fallbacks");
            None
        }
    }
}

async fn prepare_ipv6_punch_socket(rendezvous: &str) -> Option<(Arc<UdpSocket>, Vec<u8>)> {
    let addresses = hbb_common::tokio::net::lookup_host(rendezvous).await.ok()?;
    let server = addresses.into_iter().find(SocketAddr::is_ipv6)?;
    let probe = UdpSocket::bind("[::]:0").await.ok()?;
    probe.connect(server).await.ok()?;
    let local = probe.local_addr().ok()?;
    if local.ip().is_unspecified() || local.ip().is_loopback() {
        return None;
    }
    drop(probe);
    let socket = Arc::new(UdpSocket::bind(SocketAddr::new(local.ip(), 0)).await.ok()?);
    let advertised = AddrMangle::encode(socket.local_addr().ok()?);
    emit_event("ipv6 punch candidate prepared");
    Some((socket, advertised))
}

async fn prepare_webrtc_offerer(force_relay: bool) -> Option<(WebRTCStream, String)> {
    let stream = match tokio::time::timeout(
        Duration::from_millis(WEBRTC_OFFER_TIMEOUT),
        WebRTCStream::new("", force_relay, WEBRTC_CONNECT_TIMEOUT),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            emit_event(&format!("webrtc offer unavailable: {error}"));
            return None;
        }
        Err(_) => {
            emit_event("webrtc offer skipped after fast budget");
            return None;
        }
    };
    match stream.get_local_endpoint().await {
        Ok(endpoint) => {
            emit_event("webrtc offer prepared");
            Some((stream, endpoint))
        }
        Err(error) => {
            emit_event(&format!("webrtc local endpoint unavailable: {error}"));
            None
        }
    }
}

fn punch_packet(tag: &[u8; 4], transaction: u64) -> [u8; PUNCH_PACKET_LEN] {
    let mut packet = [0_u8; PUNCH_PACKET_LEN];
    packet[..4].copy_from_slice(tag);
    packet[4..].copy_from_slice(&transaction.to_le_bytes());
    packet
}

fn punch_transaction(packet: &[u8], tag: &[u8; 4]) -> Option<u64> {
    if packet.len() != PUNCH_PACKET_LEN || packet[..4] != tag[..] {
        return None;
    }
    packet[4..].try_into().ok().map(u64::from_le_bytes)
}

async fn punch_udp(socket: Arc<UdpSocket>) -> hbb_common::ResultType<()> {
    let transaction =
        ((hbb_common::time_based_rand() as u64) << 32) | hbb_common::time_based_rand() as u64;
    let probe = punch_packet(&PUNCH_PROBE, transaction);
    let mut buf = [0_u8; 1500];
    while socket.try_recv(&mut buf).is_ok() {}
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut retry = Duration::from_millis(20);
    loop {
        socket.send(&probe).await.ok();
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            hbb_common::bail!("UDP punch timeout");
        }
        match tokio::time::timeout(std::cmp::min(retry, remaining), socket.recv(&mut buf)).await {
            Ok(Ok(size)) => {
                if punch_transaction(&buf[..size], &PUNCH_ACK) == Some(transaction) {
                    return Ok(());
                }
                if let Some(peer_transaction) = punch_transaction(&buf[..size], &PUNCH_PROBE) {
                    socket
                        .send(&punch_packet(&PUNCH_ACK, peer_transaction))
                        .await
                        .ok();
                } else if size > 0 {
                    return Ok(());
                }
            }
            Ok(Err(_)) => tokio::time::sleep(Duration::from_millis(10)).await,
            Err(_) => {}
        }
        retry = std::cmp::min(retry.mul_f64(1.5), Duration::from_millis(200));
    }
}

async fn connect_udp_kcp(
    socket: Arc<UdpSocket>,
    label: &'static str,
    timeout_ms: u64,
) -> hbb_common::ResultType<ConnectedTransport> {
    punch_udp(socket.clone()).await?;
    let (kcp, stream) = KcpStream::connect(socket, Duration::from_millis(timeout_ms)).await?;
    Ok(ConnectedTransport {
        stream,
        kcp: Some(kcp),
        label,
        route: 1,
        transport: if label == "IPv6/KCP" {
            TRANSPORT_IPV6_KCP
        } else {
            TRANSPORT_UDP_KCP
        },
    })
}

async fn connect_direct_transports(
    tcp_peer: Option<SocketAddr>,
    local_addr: SocketAddr,
    timeout_ms: u64,
    udp: Option<Arc<UdpSocket>>,
    ipv6: Option<Arc<UdpSocket>>,
    webrtc: Option<WebRTCStream>,
    webrtc_route: i32,
) -> Result<ConnectedTransport, String> {
    let mut attempts: Vec<BoxFuture<'static, hbb_common::ResultType<ConnectedTransport>>> =
        Vec::new();
    if let Some(peer) = tcp_peer {
        attempts.push(
            async move {
                let stream = connect_direct_peer(peer, local_addr, timeout_ms).await?;
                Ok(ConnectedTransport {
                    stream,
                    kcp: None,
                    label: "TCP",
                    route: 1,
                    transport: TRANSPORT_TCP,
                })
            }
            .boxed(),
        );
    }
    if let Some(socket) = udp {
        attempts.push(connect_udp_kcp(socket, "UDP/KCP", timeout_ms).boxed());
    }
    if let Some(socket) = ipv6 {
        attempts.push(connect_udp_kcp(socket, "IPv6/KCP", timeout_ms).boxed());
    }
    if let Some(mut stream) = webrtc {
        attempts.push(
            async move {
                stream.wait_connected(WEBRTC_CONNECT_TIMEOUT).await?;
                Ok(ConnectedTransport {
                    stream: Stream::WebRTC(stream),
                    kcp: None,
                    label: "WebRTC",
                    route: webrtc_route,
                    transport: TRANSPORT_WEBRTC,
                })
            }
            .boxed(),
        );
    }
    if attempts.is_empty() {
        return Err("no direct transport candidate".to_string());
    }
    select_ok(attempts)
        .await
        .map(|(winner, _)| winner)
        .map_err(|error| error.to_string())
}

async fn send_punch_request(
    conn: &mut Stream,
    request: &RendezvousMessage,
    allow_config_updates: bool,
) -> Result<Option<RendezvousMessage>, ()> {
    for (index, reply_timeout) in PUNCH_REPLY_TIMEOUTS.into_iter().enumerate() {
        let attempt = index + 1;
        if conn.send(request).await.is_err() {
            emit_event("punch request send failed");
            return Err(());
        }
        emit_event(&format!(
            "punch request sent attempt={attempt}/{}",
            PUNCH_REPLY_TIMEOUTS.len()
        ));
        if let Some(response) =
            next_rendezvous_with_updates(conn, reply_timeout, allow_config_updates).await
        {
            return Ok(Some(response));
        }
    }
    Ok(None)
}

async fn detect_nat_type(server: &str, public_server: bool) -> NatType {
    let cached = NatType::from_i32(Config::get_nat_type()).unwrap_or(NatType::UNKNOWN_NAT);
    if cached != NatType::UNKNOWN_NAT {
        return cached;
    }
    let mut request = RendezvousMessage::new();
    request.set_test_nat_request(TestNatRequest {
        serial: Config::get_serial(),
        ..Default::default()
    });
    let mut ports = [0_i32; 2];
    let mut local_addr = None;
    for (index, endpoint) in [server.to_string(), online_query_addr(server)]
        .into_iter()
        .enumerate()
    {
        let Ok(mut socket) = connect_tcp_local(endpoint, local_addr, NAT_PROBE_TIMEOUT).await
        else {
            emit_event("nat probe unavailable");
            return NatType::UNKNOWN_NAT;
        };
        if index == 0 {
            local_addr = Some(socket.local_addr());
        }
        if socket.send(&request).await.is_err() {
            return NatType::UNKNOWN_NAT;
        }
        let Some(response) = next_rendezvous(&mut socket, NAT_PROBE_TIMEOUT).await else {
            return NatType::UNKNOWN_NAT;
        };
        let Some(rendezvous_message::Union::TestNatResponse(response)) = response.union else {
            return NatType::UNKNOWN_NAT;
        };
        ports[index] = response.port;
        if public_server {
            if let Some(update) = response.cu.as_ref() {
                apply_rendezvous_config_update(update);
            }
        }
    }
    let detected = if ports[0] > 0 && ports[1] > 0 {
        if ports[0] == ports[1] {
            NatType::ASYMMETRIC
        } else {
            NatType::SYMMETRIC
        }
    } else {
        NatType::UNKNOWN_NAT
    };
    if detected != NatType::UNKNOWN_NAT {
        Config::set_nat_type(detected.value());
    }
    emit_event(&format!("nat probe completed type={}", detected.value()));
    detected
}

fn apply_rendezvous_config_update(update: &hbb_common::rendezvous_proto::ConfigUpdate) {
    if !update.rendezvous_servers.is_empty() {
        Config::set_option(
            "rendezvous-servers".to_string(),
            update.rendezvous_servers.join(","),
        );
    }
    Config::set_serial(update.serial);
    emit_event(&format!(
        "rendezvous configuration updated serial={} servers={}",
        update.serial,
        update.rendezvous_servers.len()
    ));
}

fn classify_rendezvous_refusal(reason: &str) -> &'static str {
    if reason.is_empty() {
        return "none";
    }
    let reason = reason.to_ascii_lowercase();
    if reason.contains("version") || reason.contains("update") || reason.contains("old client") {
        "client_version"
    } else if reason.contains("license") || reason.contains("licence") || reason.contains("key") {
        "server_key"
    } else if reason.contains("token") || reason.contains("auth") || reason.contains("login") {
        "authentication"
    } else if reason.contains("rate") || reason.contains("frequent") || reason.contains("limit") {
        "rate_limit"
    } else if reason.contains("deny") || reason.contains("forbid") || reason.contains("block") {
        "policy"
    } else if reason.contains("busy")
        || reason.contains("overload")
        || reason.contains("unavailable")
    {
        "server_busy"
    } else {
        "other"
    }
}

fn official_direct_timeout(
    is_local: bool,
    peer_nat_type: NatType,
    _local_nat_type: NatType,
    relay_available: bool,
    recent_direct_failures: u8,
) -> u64 {
    if is_local || peer_nat_type == NatType::SYMMETRIC {
        return LOCAL_DIRECT_CONNECT_TIMEOUT;
    }
    if relay_available {
        return if recent_direct_failures > 0 {
            LOCAL_DIRECT_CONNECT_TIMEOUT
        } else {
            DIRECT_CONNECT_TIMEOUT
        };
    }
    DIRECT_ONLY_CONNECT_TIMEOUT
}

fn peer_route_history_key(peer: &str) -> String {
    Sha256::digest(peer.trim().as_bytes())[..12]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn load_peer_route_history() -> BTreeMap<String, PeerRouteRecord> {
    serde_json::from_str(&Config::get_option(PEER_ROUTE_HISTORY_OPTION)).unwrap_or_default()
}

fn prune_peer_route_history(history: &mut BTreeMap<String, PeerRouteRecord>, now: u64) {
    history.retain(|_, record| {
        record.updated_ms > 0 && now.saturating_sub(record.updated_ms) <= PEER_ROUTE_HISTORY_TTL_MS
    });
    if history.len() <= PEER_ROUTE_HISTORY_MAX_ENTRIES {
        return;
    }
    let mut oldest = history
        .iter()
        .map(|(key, record)| (record.updated_ms, key.clone()))
        .collect::<Vec<_>>();
    oldest.sort_unstable();
    for (_, key) in oldest
        .into_iter()
        .take(history.len() - PEER_ROUTE_HISTORY_MAX_ENTRIES)
    {
        history.remove(&key);
    }
}

fn apply_peer_direct_failure(
    history: &mut BTreeMap<String, PeerRouteRecord>,
    peer_key: String,
    now: u64,
) -> u8 {
    let record = history.entry(peer_key).or_default();
    record.direct_failures = record
        .direct_failures
        .saturating_add(1)
        .min(PEER_ROUTE_HISTORY_MAX_FAILURES);
    record.direct_failure_ms = now;
    record.updated_ms = now;
    record.direct_failures
}

fn apply_peer_route_success(
    history: &mut BTreeMap<String, PeerRouteRecord>,
    peer_key: String,
    route: i32,
    transport: i32,
    now: u64,
) -> PeerRouteRecord {
    let record = history.entry(peer_key).or_default();
    record.route = route;
    record.transport = transport;
    record.updated_ms = now;
    if route == 1 {
        record.direct_failures = 0;
        record.direct_failure_ms = 0;
    }
    record.clone()
}

fn recent_direct_failures(record: Option<&PeerRouteRecord>, now: u64) -> u8 {
    record
        .filter(|record| {
            record.direct_failure_ms > 0
                && now.saturating_sub(record.direct_failure_ms) <= PEER_ROUTE_HISTORY_TTL_MS
        })
        .map(|record| record.direct_failures)
        .unwrap_or(0)
}

fn recent_peer_direct_failures(peer: &str, now: u64) -> u8 {
    let Ok(_guard) = PEER_ROUTE_HISTORY_LOCK.lock() else {
        return 0;
    };
    let history = load_peer_route_history();
    recent_direct_failures(history.get(&peer_route_history_key(peer)), now)
}

fn save_peer_route_history(history: &BTreeMap<String, PeerRouteRecord>) {
    if let Ok(serialized) = serde_json::to_string(history) {
        Config::set_option(PEER_ROUTE_HISTORY_OPTION.to_string(), serialized);
    }
}

fn record_peer_direct_failure(peer: &str, now: u64) {
    let Ok(_guard) = PEER_ROUTE_HISTORY_LOCK.lock() else {
        return;
    };
    let mut history = load_peer_route_history();
    let failures = apply_peer_direct_failure(&mut history, peer_route_history_key(peer), now);
    prune_peer_route_history(&mut history, now);
    save_peer_route_history(&history);
    emit_event(&format!("route history direct_failure count={failures}"));
}

fn record_peer_route_success(peer: &str, route: i32, transport: i32, now: u64) {
    let Ok(_guard) = PEER_ROUTE_HISTORY_LOCK.lock() else {
        return;
    };
    let mut history = load_peer_route_history();
    let record = apply_peer_route_success(
        &mut history,
        peer_route_history_key(peer),
        route,
        transport,
        now,
    );
    prune_peer_route_history(&mut history, now);
    save_peer_route_history(&history);
    emit_event(&format!(
        "route history success route={} transport={} direct_failures={}",
        record.route, record.transport, record.direct_failures
    ));
}

fn with_port(host: &str, port: i32) -> String {
    let host = host.trim();
    if host.starts_with("ws://") || host.starts_with("wss://") {
        return host.to_string();
    }
    if host.is_empty() {
        return format!("127.0.0.1:{port}");
    }
    if host.parse::<SocketAddr>().is_ok() {
        return host.to_string();
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return match ip {
            IpAddr::V4(_) => format!("{host}:{port}"),
            IpAddr::V6(_) => format!("[{host}]:{port}"),
        };
    }
    if host.starts_with('[') && host.ends_with(']') {
        return format!("{host}:{port}");
    }
    if host.matches(':').count() == 1 {
        if let Some((_, port_text)) = host.rsplit_once(':') {
            if port_text.parse::<u16>().is_ok() {
                return host.to_string();
            }
        }
    }
    format!("{host}:{port}")
}

fn online_query_addr(server: &str) -> String {
    let rendezvous_addr = default_rendezvous_addr(server);
    if let Ok(mut addr) = rendezvous_addr.parse::<SocketAddr>() {
        if addr.port() > 1 {
            addr.set_port(addr.port() - 1);
        }
        return addr.to_string();
    }
    if let Some((host, port_text)) = rendezvous_addr.rsplit_once(':') {
        if let Ok(port) = port_text.parse::<u16>() {
            if port > 1 {
                return format!("{host}:{}", port - 1);
            }
        }
    }
    with_port(server, 21115)
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
            | Some(rendezvous_message::Union::SoftwareUpdate(_))
            | Some(rendezvous_message::Union::Hc(_))
    )
}

async fn next_rendezvous(conn: &mut Stream, timeout: u64) -> Option<RendezvousMessage> {
    next_rendezvous_with_updates(conn, timeout, false).await
}

async fn next_rendezvous_with_updates(
    conn: &mut Stream,
    timeout: u64,
    allow_config_updates: bool,
) -> Option<RendezvousMessage> {
    let deadline = tokio::time::Instant::now() + Duration::from_millis(timeout);
    tokio::time::timeout_at(deadline, async {
        while let Some(Ok(bytes)) = conn.next_timeout(timeout).await {
            match RendezvousMessage::parse_from_bytes(&bytes) {
                Ok(msg) => {
                    let kind = rendezvous_message_kind(&msg.union);
                    if let Some(rendezvous_message::Union::ConfigureUpdate(update)) =
                        msg.union.as_ref()
                    {
                        if allow_config_updates {
                            apply_rendezvous_config_update(update);
                        } else {
                            emit_event("skip rendezvous message kind=configure_update");
                        }
                        continue;
                    }
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
    })
    .await
    .ok()
    .flatten()
}

async fn connect_direct_peer(
    addr: SocketAddr,
    local: SocketAddr,
    timeout: u64,
) -> hbb_common::ResultType<Stream> {
    // Reuse the punch-hole port, but don't force IPv4 peers through an
    // unrelated IPv6 socket and external nip.io DNS on dual-stack Wi-Fi.
    let deadline = tokio::time::Instant::now() + Duration::from_millis(timeout);
    let attempt = async {
        if addr.is_ipv4() != local.is_ipv4() {
            let mut matching = hbb_common::config::Config::get_any_listen_addr(addr.is_ipv4());
            matching.set_port(local.port());
            if let Ok(Ok(stream)) = tokio::time::timeout(
                Duration::from_millis(timeout / 2),
                connect_tcp_local(addr, Some(matching), timeout / 2),
            )
            .await
            {
                emit_event("direct peer address-family fallback connected");
                return Ok(stream);
            }
        }
        connect_tcp_local(addr, Some(local), timeout).await
    };
    tokio::time::timeout_at(deadline, attempt).await?
}

async fn connect_file_stream(config: &ConnectionConfig) -> Result<Stream, String> {
    if let Some(address) = direct_peer_addr(&config.peer).map_err(str::to_string)? {
        return connect_ip_literal(address)
            .await
            .map_err(|error| error.to_string());
    }
    let mut rendezvous = connect_transport_endpoint(
        config.rendezvous_addr.clone(),
        EndpointRole::Rendezvous,
        SERVER_CONNECT_TIMEOUT,
    )
    .await
    .map_err(|error| error.to_string())?;
    let request = punch_hole_request(
        &config.peer,
        &config.key,
        ConnType::FILE_TRANSFER,
        false,
        NatType::from_i32(Config::get_nat_type()).unwrap_or(NatType::UNKNOWN_NAT),
        0,
        Vec::new(),
        String::new(),
    );
    rendezvous
        .send(&request)
        .await
        .map_err(|error| error.to_string())?;
    let local_addr = rendezvous.local_addr();
    let response = next_rendezvous(&mut rendezvous, RENDEZVOUS_REPLY_TIMEOUT)
        .await
        .ok_or_else(|| "文件传输连接超时".to_string())?;
    let mut peer_addr = None;
    let mut relay = config.relay_override.clone();
    let mut signed_id_pk = Vec::new();
    let mut is_local = false;
    if let Some(rendezvous_message::Union::RelayResponse(response)) = response.union {
        if !response.refuse_reason.is_empty() {
            return Err(response.refuse_reason);
        }
        signed_id_pk = response.pk().to_vec();
        if relay.is_empty() {
            relay = response.relay_server;
        }
        if relay.is_empty() || response.uuid.is_empty() {
            return Err("文件中继信息不完整".to_string());
        }
        let mut stream = create_relay_with_type(
            &config.peer,
            &response.uuid,
            &relay,
            &config.key,
            local_addr.is_ipv4(),
            ConnType::FILE_TRANSFER,
        )
        .await
        .map_err(|error| error.to_string())?;
        secure_peer_connection(
            &config.peer,
            &signed_id_pk,
            &config.key,
            &mut stream,
            ALLOW_INSECURE_SESSION.load(Ordering::SeqCst),
        )
        .await
        .map_err(|error| error.to_string())?;
        return Ok(stream);
    } else {
        match response.union {
            Some(rendezvous_message::Union::PunchHoleResponse(response)) => {
                is_local = response.is_local();
                if !response.other_failure.is_empty() {
                    return Err(response.other_failure);
                }
                signed_id_pk = response.pk.to_vec();
                if !response.socket_addr.is_empty() {
                    peer_addr = Some(AddrMangle::decode(&response.socket_addr));
                }
                if relay.is_empty() {
                    relay = response.relay_server;
                }
            }
            Some(rendezvous_message::Union::PunchHole(response)) => {
                if !response.socket_addr.is_empty() {
                    peer_addr = Some(AddrMangle::decode(&response.socket_addr));
                }
                if relay.is_empty() {
                    relay = response.relay_server;
                }
            }
            _ => return Err("文件传输握手响应无效".to_string()),
        }
    }

    drop(rendezvous);

    let mut stream = if let Some(address) = peer_addr {
        let direct_timeout = if is_local {
            LOCAL_DIRECT_CONNECT_TIMEOUT
        } else {
            DIRECT_CONNECT_TIMEOUT
        };
        match connect_direct_peer(address, local_addr, direct_timeout).await {
            Ok(stream) => stream,
            Err(_) if !relay.is_empty() => request_relay_with_type(
                &config.peer,
                &relay,
                &config.rendezvous_addr,
                !signed_id_pk.is_empty(),
                &config.key,
                "",
                ConnType::FILE_TRANSFER,
            )
            .await
            .map_err(|error| error.to_string())?,
            Err(error) => return Err(error.to_string()),
        }
    } else if !relay.is_empty() {
        request_relay_with_type(
            &config.peer,
            &relay,
            &config.rendezvous_addr,
            !signed_id_pk.is_empty(),
            &config.key,
            "",
            ConnType::FILE_TRANSFER,
        )
        .await
        .map_err(|error| error.to_string())?
    } else {
        return Err("远端没有可用的文件传输路径".to_string());
    };
    secure_peer_connection(
        &config.peer,
        &signed_id_pk,
        &config.key,
        &mut stream,
        ALLOW_INSECURE_SESSION.load(Ordering::SeqCst),
    )
    .await
    .map_err(|error| error.to_string())?;
    Ok(stream)
}

async fn request_relay(
    peer: &str,
    relay_server: &str,
    rendezvous_server: &str,
    secure: bool,
    key: &str,
    token: &str,
) -> Result<Stream, hbb_common::anyhow::Error> {
    request_relay_with_type(
        peer,
        relay_server,
        rendezvous_server,
        secure,
        key,
        token,
        ConnType::DEFAULT_CONN,
    )
    .await
}

async fn request_relay_with_type(
    peer: &str,
    relay_server: &str,
    rendezvous_server: &str,
    secure: bool,
    key: &str,
    token: &str,
    conn_type: ConnType,
) -> Result<Stream, hbb_common::anyhow::Error> {
    let mut last_error = "relay request timeout".to_string();

    for attempt in 1..=3 {
        // hbbs pairs every retry by a fresh source socket and UUID. Reusing the
        // first rendezvous socket can leave a valid peer waiting on another
        // relay slot, which is why the official clients reconnect per attempt.
        let mut rv_conn = match connect_transport_endpoint(
            rendezvous_server.to_string(),
            EndpointRole::Rendezvous,
            SERVER_CONNECT_TIMEOUT,
        )
        .await
        {
            Ok(conn) => conn,
            Err(error) => {
                last_error = error.to_string();
                emit_event(&format!("relay request attempt={attempt}/3 tcp_failed"));
                continue;
            }
        };
        if !key.is_empty() && !token.is_empty() {
            secure_rendezvous_connection(&mut rv_conn, key).await?;
        }
        let ipv4 = rv_conn.local_addr().is_ipv4();
        let uuid = Uuid::new_v4().to_string();
        emit_event(&format!(
            "relay request attempt={attempt}/3 secure={secure} token_set={} conn_type={}",
            !token.is_empty(),
            conn_type.value()
        ));

        let mut req = RendezvousMessage::new();
        req.set_request_relay(RequestRelay {
            id: peer.to_string(),
            token: token.to_string(),
            uuid: uuid.clone(),
            relay_server: relay_server.to_string(),
            secure,
            conn_type: conn_type.into(),
            ..Default::default()
        });
        rv_conn.send(&req).await?;

        match next_rendezvous(&mut rv_conn, RENDEZVOUS_REPLY_TIMEOUT).await {
            Some(msg) => match msg.union {
                Some(rendezvous_message::Union::RelayResponse(resp))
                    if resp.refuse_reason.is_empty() =>
                {
                    emit_event(&format!("relay request accepted attempt={attempt}/3"));
                    return create_relay_with_type(peer, &uuid, relay_server, key, ipv4, conn_type)
                        .await;
                }
                Some(rendezvous_message::Union::RelayResponse(resp)) => {
                    hbb_common::bail!("relay refused: {}", resp.refuse_reason)
                }
                other => {
                    last_error = format!(
                        "unexpected rendezvous response kind={}",
                        rendezvous_message_kind(&other)
                    );
                    emit_event(&format!(
                        "relay request attempt={attempt}/3 failed: {last_error}"
                    ));
                }
            },
            None => {
                last_error = "relay request timeout".to_string();
                emit_event(&format!(
                    "relay request attempt={attempt}/3 failed: {last_error}"
                ));
            }
        }
    }

    hbb_common::bail!("{last_error} after 3 attempts")
}

async fn secure_rendezvous_connection(
    conn: &mut Stream,
    key: &str,
) -> Result<(), hbb_common::anyhow::Error> {
    let Some(rs_pk) = get_rs_pk(key) else {
        hbb_common::bail!("invalid rendezvous server public key");
    };

    let Some(Ok(bytes)) = conn.next_timeout(READ_TIMEOUT).await else {
        // Older self-hosted servers may not advertise transport encryption.
        // Keep the plain TCP path available in that case, matching upstream.
        return Ok(());
    };
    let Ok(message) = RendezvousMessage::parse_from_bytes(&bytes) else {
        return Ok(());
    };
    let Some(rendezvous_message::Union::KeyExchange(exchange)) = message.union else {
        return Ok(());
    };
    if exchange.keys.len() != 1 {
        hbb_common::bail!("invalid rendezvous key exchange message");
    }

    let their_pk = verify_signed_payload(&exchange.keys[0], &rs_pk)?;
    let Some(their_pk) = get_pk(&their_pk) else {
        hbb_common::bail!("invalid rendezvous key length");
    };
    let (asymmetric_value, symmetric_value, secret_key) = create_symmetric_key_msg(their_pk);
    let mut response = RendezvousMessage::new();
    response.set_key_exchange(KeyExchange {
        keys: vec![asymmetric_value, symmetric_value],
        ..Default::default()
    });
    conn.send(&response).await?;
    conn.set_key(secret_key);
    emit_event("rendezvous relay request encrypted");
    Ok(())
}

async fn create_relay(
    peer: &str,
    uuid: &str,
    relay_server: &str,
    key: &str,
    ipv4: bool,
) -> Result<Stream, hbb_common::anyhow::Error> {
    create_relay_with_type(peer, uuid, relay_server, key, ipv4, ConnType::DEFAULT_CONN).await
}

async fn create_relay_with_type(
    peer: &str,
    uuid: &str,
    relay_server: &str,
    key: &str,
    ipv4: bool,
    conn_type: ConnType,
) -> Result<Stream, hbb_common::anyhow::Error> {
    let relay_addr = check_port(relay_server.to_string(), RELAY_PORT);
    let mut relay_conn = match connect_transport_endpoint(
        relay_addr.clone(),
        EndpointRole::Relay,
        SERVER_CONNECT_TIMEOUT,
    )
    .await
    {
        Ok(conn) => conn,
        Err(error) => {
            let fallback = ipv4_to_ipv6(relay_addr.clone(), ipv4);
            if fallback == relay_addr {
                return Err(error);
            }
            emit_event("relay address-family fallback started");
            connect_transport_endpoint(fallback, EndpointRole::Relay, SERVER_CONNECT_TIMEOUT)
                .await?
        }
    };
    relay_conn.set_send_timeout(5000);

    let mut create = RendezvousMessage::new();
    create.set_request_relay(RequestRelay {
        licence_key: key.to_string(),
        id: peer.to_string(),
        uuid: uuid.to_string(),
        conn_type: conn_type.into(),
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
    allow_insecure_fallback: bool,
) -> Result<(), hbb_common::anyhow::Error> {
    let rs_pk = get_rs_pk(if key.is_empty() { RS_PUB_KEY } else { key });
    if rs_pk.is_none() {
        if allow_insecure_fallback {
            emit_event("secure peer: invalid_server_key user_approved_insecure_once");
            conn.send(&PeerMessage::new()).await?;
            return Ok(());
        }
        emit_event("secure peer: rejected reason=invalid_server_key");
        hbb_common::bail!("invalid server key");
    }
    let mut sign_pk = None;

    if let (Some(rs_pk), false) = (rs_pk, signed_id_pk.is_empty()) {
        match decode_id_pk(signed_id_pk, &rs_pk) {
            Ok((id, pk)) if id == peer_id => {
                sign_pk = Some(sign::PublicKey(pk));
            }
            Ok((_, _)) => {
                if allow_insecure_fallback {
                    emit_event("secure peer: rendezvous_id_mismatch user_approved_insecure_once");
                    conn.send(&PeerMessage::new()).await?;
                    return Ok(());
                }
                emit_event("secure peer: rejected reason=rendezvous_id_mismatch");
                hbb_common::bail!("server key mismatch");
            }
            Err(_) => {
                if allow_insecure_fallback {
                    emit_event(
                        "secure peer: invalid_rendezvous_signature user_approved_insecure_once",
                    );
                    conn.send(&PeerMessage::new()).await?;
                    return Ok(());
                }
                emit_event("secure peer: rejected reason=invalid_rendezvous_signature");
                hbb_common::bail!("server key mismatch");
            }
        }
    }

    let Some(sign_pk) = sign_pk else {
        emit_event("secure peer: signature_unavailable; use non-secure connection");
        // Keep compatibility with peers that are waiting for the client's
        // first handshake message before continuing without encryption.
        conn.send(&PeerMessage::new()).await?;
        return Ok(());
    };

    let Some(Ok(bytes)) = conn.next_timeout(READ_TIMEOUT).await else {
        emit_event("secure peer: wait signed id timeout");
        hbb_common::bail!("peer did not send signed id");
    };

    let msg = match PeerMessage::parse_from_bytes(&bytes) {
        Ok(msg) => msg,
        Err(_) => {
            emit_event("secure peer: rejected reason=invalid_handshake_message");
            hbb_common::bail!("invalid handshake message");
        }
    };
    let Some(message::Union::SignedId(signed_id)) = msg.union else {
        emit_event("secure peer: rejected reason=expected_signed_id");
        hbb_common::bail!("expected signed id");
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
        Ok((_, _)) => {
            emit_event("secure peer: rejected reason=peer_id_mismatch");
            hbb_common::bail!("peer signed id mismatch");
        }
        Err(_) => {
            emit_event("secure peer: rejected reason=invalid_peer_signature");
            hbb_common::bail!("invalid peer signature");
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

fn decode_id_pk(
    signed: &[u8],
    key: &sign::PublicKey,
) -> Result<(String, [u8; 32]), hbb_common::anyhow::Error> {
    let verified = verify_signed_payload(signed, key)?;
    let res = IdPk::parse_from_bytes(&verified)?;
    let Some(pk) = get_pk(&res.pk) else {
        hbb_common::bail!("wrong public key length");
    };
    Ok((res.id, pk))
}

fn verify_signed_payload(
    signed: &[u8],
    key: &sign::PublicKey,
) -> Result<Vec<u8>, hbb_common::anyhow::Error> {
    sign::verify(signed, key).map_err(|_| hbb_common::anyhow::anyhow!("signature mismatch"))
}

fn create_symmetric_key_msg(
    their_pk_b: [u8; 32],
) -> (
    hbb_common::bytes::Bytes,
    hbb_common::bytes::Bytes,
    secretbox::Key,
) {
    let their_pk_b = box_::PublicKey(their_pk_b);
    let (our_pk_b, out_sk_b) = box_::gen_keypair();
    let key = secretbox::gen_key();
    let nonce = box_::Nonce([0_u8; box_::NONCEBYTES]);
    let sealed_key = box_::seal(&key.0, &nonce, &their_pk_b, &out_sk_b);
    (Vec::from(our_pk_b.0).into(), sealed_key.into(), key)
}

fn spawn_receive_loop(session_id: u64, mut stream: Stream, kcp_guard: Option<KcpStream>) {
    let (tx, mut rx) = tokio_mpsc::unbounded_channel::<QueuedPeerCommand>();
    if let Ok(mut guard) = PEER_MESSAGE_SENDER.lock() {
        *guard = Some((session_id, tx));
    }
    let (task_completed, task_completed_receiver) = mpsc::channel();
    let task = runtime().spawn(async move {
            let _task_completion = PeerTaskCompletion(Some(task_completed));
            let _kcp_guard = kcp_guard;
            let mut stale = false;
            let mut read_jobs: Vec<TransferJob> = Vec::new();
            let receive_started_at = Instant::now();
            let mut received_messages = 0_u64;
            let mut video_messages = 0_u64;
            let mut test_delay_messages = 0_u64;
            let mut misc_messages = 0_u64;
            let mut last_message_kind = "none";
            let mut last_message_at = receive_started_at;
            emit_event(&format!("receive loop started session_id={session_id}"));
            loop {
                if SESSION_ID.load(Ordering::SeqCst) != session_id {
                    stale = true;
                    break;
                }
                let had_upload = !read_jobs.is_empty();
                if had_upload {
                    let total = read_jobs[0].total_size();
                    if let Err(error) = fs::handle_read_jobs(&mut read_jobs, &mut stream).await {
                        set_file_transfer_status("failed", 0, total, &error.to_string());
                        read_jobs.clear();
                    } else if let Some(job) = read_jobs.first() {
                        set_file_transfer_status("transferring", job.finished_size(), job.total_size(), "");
                    } else {
                        set_file_transfer_status("completed", total, total, "");
                    }
                }
                let keep_running = tokio::select! {
                    command = rx.recv() => {
                        let Some(command) = command else {
                            emit_event("peer command channel closed");
                            break;
                        };
                        let command_session_id = match &command {
                            QueuedPeerCommand::Message { session_id, .. }
                            | QueuedPeerCommand::StartUpload { session_id, .. }
                            | QueuedPeerCommand::StartDownload { session_id, .. }
                            | QueuedPeerCommand::CancelTransfer { session_id }
                            | QueuedPeerCommand::Close { session_id, .. } => *session_id,
                        };
                        if SESSION_ID.load(Ordering::SeqCst) != command_session_id {
                            emit_event("skip stale peer command");
                            true
                        } else {
                            match command {
                                QueuedPeerCommand::Message { message, .. } => {
                                    trace_input_message("network_send", &message);
                                    if let Err(e) = stream.send(&message).await {
                                        emit_event(&format!("peer message send failed: {e}"));
                                        mark_connection_lost(command_session_id, &e.to_string());
                                        return;
                                    }
                                    trace_input_message("network_sent", &message);
                                    true
                                }
                                QueuedPeerCommand::StartUpload { job, receive, .. } => {
                                    read_jobs.clear();
                                    if let Err(e) = stream.send(&receive).await {
                                        set_file_transfer_status("failed", 0, job.total_size(), &e.to_string());
                                    } else {
                                        read_jobs.push(job);
                                        set_file_transfer_status("transferring", 0, read_jobs[0].total_size(), "");
                                    }
                                    true
                                }
                                QueuedPeerCommand::StartDownload { .. } => {
                                    set_file_transfer_status_detail(
                                        "download", "failed", 0, 0,
                                        "下载请求进入了错误的连接通道", 0, 0,
                                    );
                                    true
                                }
                                QueuedPeerCommand::CancelTransfer { .. } => {
                                    set_file_transfer_status_detail(
                                        "download", "cancelled", 0, 0, "", 0, 0,
                                    );
                                    true
                                }
                                QueuedPeerCommand::Close { completed, .. } => {
                                    let mut misc = Misc::new();
                                    misc.set_close_reason(String::new());
                                    let mut message = PeerMessage::new();
                                    message.set_misc(misc);
                                    let result = stream.send(&message).await;
                                    if let Err(error) = result {
                                        emit_event(&format!("close reason send failed: {error}"));
                                    } else {
                                        emit_event("close reason sent");
                                        // EOF/reset is the observable point at which the host has
                                        // completed old video-subscriber cleanup. The deadline is
                                        // only a safety fallback for non-compliant peers.
                                        let deadline = Instant::now() + Duration::from_millis(1200);
                                        loop {
                                            if Instant::now() >= deadline {
                                                emit_event("close wait: peer close timeout");
                                                break;
                                            }
                                            match hbb_common::timeout(20, stream.next()).await {
                                                Ok(None) => {
                                                    emit_event("close wait: peer eof observed");
                                                    break;
                                                }
                                                Ok(Some(Err(_))) => {
                                                    emit_event("close wait: peer close observed");
                                                    break;
                                                }
                                                Ok(Some(Ok(_))) | Err(_) => continue,
                                            }
                                        }
                                    }
                                    let _ = completed.send(());
                                    return;
                                }
                            }
                        }
                    }
                    bytes = stream.next() => {
                        match bytes {
                            Some(Ok(bytes)) => {
                                let message_kind =
                                    handle_peer_bytes(&bytes, &mut read_jobs, &mut stream).await;
                                received_messages += 1;
                                if message_kind == "video_frame" {
                                    video_messages += 1;
                                } else if message_kind == "test_delay" {
                                    test_delay_messages += 1;
                                } else if message_kind.starts_with("misc_") {
                                    misc_messages += 1;
                                }
                                last_message_kind = message_kind;
                                last_message_at = Instant::now();
                                true
                            }
                            Some(Err(e)) => {
                                emit_event(&format!(
                                    "receive loop error session_id={} elapsed_ms={} received={} video={} test_delay={} misc={} last_message={} last_message_age_ms={} route={} error={}",
                                    session_id,
                                    receive_started_at.elapsed().as_millis(),
                                    received_messages,
                                    video_messages,
                                    test_delay_messages,
                                    misc_messages,
                                    last_message_kind,
                                    last_message_at.elapsed().as_millis(),
                                    CONNECTION_ROUTE.load(Ordering::SeqCst),
                                    sanitize_remote_value(e.to_string(), 256),
                                ));
                                false
                            }
                            None => {
                                emit_event(&format!(
                                    "receive loop peer eof session_id={} elapsed_ms={} received={} video={} test_delay={} misc={} last_message={} last_message_age_ms={} route={} active={}",
                                    session_id,
                                    receive_started_at.elapsed().as_millis(),
                                    received_messages,
                                    video_messages,
                                    test_delay_messages,
                                    misc_messages,
                                    last_message_kind,
                                    last_message_at.elapsed().as_millis(),
                                    CONNECTION_ROUTE.load(Ordering::SeqCst),
                                    CONNECTION_ACTIVE.load(Ordering::SeqCst),
                                ));
                                false
                            }
                        }
                    }
                };
                if !keep_running {
                    break;
                }
            }
            if stale {
                emit_event("stale receive loop ended");
                return;
            }
            emit_event(&format!(
                "receive loop ended session_id={} elapsed_ms={} received={} video={} test_delay={} misc={} last_message={} last_message_age_ms={}",
                session_id,
                receive_started_at.elapsed().as_millis(),
                received_messages,
                video_messages,
                test_delay_messages,
                misc_messages,
                last_message_kind,
                last_message_at.elapsed().as_millis(),
            ));
            stream.close_webrtc().await;
            if SESSION_ID.load(Ordering::SeqCst) == session_id {
                CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
                CONNECTION_ROUTE.store(0, Ordering::SeqCst);
                CONNECTION_TRANSPORT.store(0, Ordering::SeqCst);
                CONNECTION_DELAY_MS.store(0, Ordering::SeqCst);
                CONNECTION_TARGET_BITRATE_KB.store(0, Ordering::SeqCst);
                reset_audio_async();
                reset_display_state();
                clear_peer_message_sender_for_session(session_id);
            }
    });
    if let Ok(mut guard) = PEER_TASK_CONTROL.lock() {
        *guard = Some(PeerTaskControl {
            session_id,
            abort_handle: task.abort_handle(),
            completed: task_completed_receiver,
        });
    }
}

async fn handle_peer_bytes(
    bytes: &[u8],
    read_jobs: &mut Vec<TransferJob>,
    stream: &mut Stream,
) -> &'static str {
    let msg = match PeerMessage::parse_from_bytes(bytes) {
        Ok(m) => m,
        Err(e) => {
            emit_event(&format!(
                "peer message parse failed len={} err={e}",
                bytes.len()
            ));
            return "parse_error";
        }
    };
    match msg.union {
        Some(message::Union::Hash(hash)) => {
            emit_event("peer message: Hash");
            send_login(hash).await;
            "hash"
        }
        Some(message::Union::LoginResponse(resp)) => {
            emit_event("peer message: LoginResponse");
            match resp.union {
                Some(login_response::Union::Error(err)) => {
                    if err == "2FA Required" {
                        emit_event(&format!(
                            "login response: 2fa-required enable_trusted_devices={}",
                            if resp.enable_trusted_devices { 1 } else { 0 }
                        ));
                    } else if err == "Wrong 2FA Code" {
                        emit_event("login response: 2fa-wrong");
                    } else {
                        emit_event(&format!("login response: error={err}"));
                        let _ = rust_disconnect();
                    }
                }
                Some(login_response::Union::PeerInfo(info)) => {
                    let is_android = info.platform.eq_ignore_ascii_case("android");
                    PEER_IS_ANDROID.store(is_android, Ordering::SeqCst);
                    PEER_SAS_ENABLED.store(info.sas_enabled, Ordering::SeqCst);
                    if let Ok(mut guard) = CURRENT_PEER_PLATFORM.try_lock() {
                        *guard = info.platform.clone();
                    }
                    if let Ok(mut guard) = CURRENT_PEER_VERSION.try_lock() {
                        *guard = info.version.clone();
                    }
                    PEER_SUPPORTS_MULTI_DISPLAY_FRAMES.store(
                        !info.version.trim().is_empty()
                            && version_at_least(&info.version, [1, 2, 4]),
                        Ordering::SeqCst,
                    );
                    let display_count = info.displays.len().max(1) as i32;
                    let displays: Vec<(i32, i32, i32, i32, bool)> = info
                        .displays
                        .iter()
                        .map(|display| {
                            (
                                display.x,
                                display.y,
                                display.width,
                                display.height,
                                display.cursor_embedded,
                            )
                        })
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
                        "login response: ok/peer info platform={} version={} displays={} current={}",
                        info.platform,
                        info.version,
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
            "login_response"
        }
        Some(message::Union::VideoFrame(frame)) => {
            forward_video_frame(frame);
            "video_frame"
        }
        Some(message::Union::TestDelay(delay)) => {
            send_test_delay_response(delay, stream).await;
            "test_delay"
        }
        Some(message::Union::Clipboard(clipboard)) => {
            handle_remote_clipboards(vec![clipboard]);
            "clipboard"
        }
        Some(message::Union::MultiClipboards(multi_clipboards)) => {
            handle_remote_clipboards(multi_clipboards.clipboards);
            "multi_clipboards"
        }
        Some(message::Union::Misc(misc_msg)) => handle_misc_message(misc_msg),
        Some(message::Union::AudioFrame(frame)) => {
            handle_audio_frame(&frame.data);
            "audio_frame"
        }
        Some(message::Union::FileResponse(response)) => {
            handle_file_response(response, read_jobs, stream).await;
            "file_response"
        }
        Some(message::Union::CursorData(cursor)) => {
            handle_remote_cursor_data(cursor);
            "cursor_data"
        }
        Some(message::Union::CursorPosition(position)) => {
            REMOTE_CURSOR_X.store(position.x, Ordering::SeqCst);
            REMOTE_CURSOR_Y.store(position.y, Ordering::SeqCst);
            REMOTE_CURSOR_VALID.store(true, Ordering::SeqCst);
            REMOTE_CURSOR_SEQUENCE.fetch_add(1, Ordering::SeqCst);
            "cursor_position"
        }
        Some(message::Union::CursorId(id)) => {
            select_remote_cursor_image(id);
            "cursor_id"
        }
        Some(_) => {
            emit_event("peer message: unhandled type");
            "unhandled"
        }
        None => {
            emit_event("peer message: empty");
            "empty"
        }
    }
}

fn handle_remote_cursor_data(cursor: CursorData) {
    if cursor.width <= 0 || cursor.height <= 0 || cursor.width > 512 || cursor.height > 512 {
        emit_event(&format!(
            "remote cursor rejected id={} size={}x{} reason=invalid_dimensions",
            cursor.id, cursor.width, cursor.height
        ));
        return;
    }
    let Some(expected) = (cursor.width as usize)
        .checked_mul(cursor.height as usize)
        .and_then(|pixels| pixels.checked_mul(4))
    else {
        emit_event("remote cursor rejected reason=size_overflow");
        return;
    };
    let colors = hbb_common::compress::decompress(&cursor.colors);
    if colors.len() != expected {
        emit_event(&format!(
            "remote cursor rejected id={} size={}x{} rgba={} expected={}",
            cursor.id,
            cursor.width,
            cursor.height,
            colors.len(),
            expected
        ));
        return;
    }
    let image = RemoteCursorImage {
        id: cursor.id,
        hotx: cursor.hotx.clamp(0, cursor.width.saturating_sub(1)),
        hoty: cursor.hoty.clamp(0, cursor.height.saturating_sub(1)),
        width: cursor.width,
        height: cursor.height,
        colors,
    };
    if let Ok(mut guard) = REMOTE_CURSOR_IMAGES.lock() {
        guard.insert(image.id, image.clone());
        while guard.len() > 64 {
            if let Some(stale_id) = guard.keys().copied().find(|id| *id != image.id) {
                guard.remove(&stale_id);
            } else {
                break;
            }
        }
    } else {
        emit_event("remote cursor cache unavailable");
        return;
    }
    REMOTE_CURSOR_IMAGE_ID.store(image.id, Ordering::SeqCst);
    REMOTE_CURSOR_IMAGE_VALID.store(true, Ordering::SeqCst);
    REMOTE_CURSOR_IMAGE_SEQUENCE.fetch_add(1, Ordering::SeqCst);
    emit_event(&format!(
        "remote cursor data id={} size={}x{} hotspot={},{}",
        image.id, image.width, image.height, image.hotx, image.hoty
    ));
}

fn select_remote_cursor_image(id: u64) {
    let found = REMOTE_CURSOR_IMAGES
        .lock()
        .map(|guard| guard.contains_key(&id))
        .unwrap_or(false);
    if found {
        REMOTE_CURSOR_IMAGE_ID.store(id, Ordering::SeqCst);
        REMOTE_CURSOR_IMAGE_VALID.store(true, Ordering::SeqCst);
        REMOTE_CURSOR_IMAGE_SEQUENCE.fetch_add(1, Ordering::SeqCst);
    } else {
        emit_event(&format!("remote cursor id={} not cached", id));
    }
}

async fn handle_file_session_response(
    response: hbb_common::message_proto::FileResponse,
    read_jobs: &mut Vec<TransferJob>,
    write_jobs: &mut Vec<TransferJob>,
    download_state: &mut DownloadBatchState,
    stream: &mut Stream,
) {
    match response.union {
        Some(file_response::Union::Dir(directory)) => {
            if fs::get_job_immutable(directory.id, write_jobs).is_none() {
                let mut response = hbb_common::message_proto::FileResponse::new();
                response.set_dir(directory);
                handle_file_response(response, read_jobs, stream).await;
                return;
            }
            let mut entries = directory.entries;
            fs::transform_windows_path(&mut entries);
            let mut error = String::new();
            if let Some(job) = fs::get_job(directory.id, write_jobs) {
                let previous_total = job.total_size();
                match job.set_files(entries) {
                    Ok(()) => {
                        job.set_finished_size_on_resume();
                        download_state.total_bytes = download_state
                            .total_bytes
                            .saturating_sub(previous_total)
                            .saturating_add(job.total_size());
                    }
                    Err(err) => error = err.to_string(),
                }
            }
            if error.is_empty() {
                set_download_transfer_status("transferring", write_jobs, download_state, "");
            } else {
                set_download_transfer_status("failed", write_jobs, download_state, &error);
                write_jobs.clear();
                download_state.active = false;
            }
        }
        Some(file_response::Union::Digest(digest)) if !digest.is_upload => {
            if let Some(job) = fs::get_job(digest.id, write_jobs) {
                job.set_digest(digest.file_size, digest.last_modified);
                let confirm = FileTransferSendConfirmRequest {
                    id: digest.id,
                    file_num: digest.file_num,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                    ..Default::default()
                };
                job.confirm(&confirm).await;
                if let Err(error) = stream.send(&fs::new_send_confirm(confirm)).await {
                    set_download_transfer_status(
                        "failed",
                        write_jobs,
                        download_state,
                        &error.to_string(),
                    );
                    write_jobs.clear();
                    download_state.active = false;
                }
            }
        }
        Some(file_response::Union::Block(block)) => {
            let mut error = String::new();
            if let Some(job) = fs::get_job(block.id, write_jobs) {
                if let Err(err) = job.write(block).await {
                    error = err.to_string();
                }
            }
            if error.is_empty() {
                set_download_transfer_status("transferring", write_jobs, download_state, "");
            } else {
                set_download_transfer_status("failed", write_jobs, download_state, &error);
                write_jobs.clear();
                download_state.active = false;
            }
        }
        Some(file_response::Union::Done(done)) => {
            if let Some(job) = fs::remove_job(done.id, write_jobs) {
                job.modify_time();
                download_state.completed_bytes = download_state
                    .completed_bytes
                    .saturating_add(job.finished_size());
                download_state.completed_jobs = download_state.completed_jobs.saturating_add(1);
            }
            if download_state.active
                && download_state.completed_jobs >= download_state.total_jobs
                && write_jobs.is_empty()
            {
                set_download_transfer_status("completed", write_jobs, download_state, "");
                download_state.active = false;
                emit_event(&format!(
                    "file-session:download-completed items={} bytes={}",
                    download_state.completed_jobs, download_state.completed_bytes
                ));
            } else {
                set_download_transfer_status("transferring", write_jobs, download_state, "");
            }
        }
        Some(file_response::Union::Error(error)) => {
            if fs::remove_job(error.id, write_jobs).is_some() {
                let message = sanitize_remote_value(error.error, 512);
                set_download_transfer_status("failed", write_jobs, download_state, &message);
                write_jobs.clear();
                download_state.active = false;
            } else {
                let mut response = hbb_common::message_proto::FileResponse::new();
                response.set_error(error);
                handle_file_response(response, read_jobs, stream).await;
            }
        }
        union => {
            let mut response = hbb_common::message_proto::FileResponse::new();
            response.union = union;
            handle_file_response(response, read_jobs, stream).await;
        }
    }
}

async fn handle_file_response(
    response: hbb_common::message_proto::FileResponse,
    read_jobs: &mut Vec<TransferJob>,
    stream: &mut Stream,
) {
    match response.union {
        Some(file_response::Union::Dir(directory)) => {
            let path = sanitize_remote_value(directory.path, 4096);
            let entries = directory
                .entries
                .into_iter()
                .take(2048)
                .filter_map(|entry| {
                    let name = sanitize_remote_value(entry.name, 512);
                    if name.is_empty() {
                        return None;
                    }
                    Some(RemoteDirectoryEntry {
                        name,
                        entry_type: entry.entry_type.value(),
                        size: entry.size,
                        modified_time: entry.modified_time,
                    })
                })
                .collect();
            set_remote_directory_result(RemoteDirectoryResult {
                path,
                entries,
                error: String::new(),
            });
        }
        Some(file_response::Union::Digest(digest)) if digest.is_upload => {
            if let Some(job) = fs::get_job(digest.id, read_jobs) {
                let confirm = FileTransferSendConfirmRequest {
                    id: digest.id,
                    file_num: digest.file_num,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                    ..Default::default()
                };
                job.confirm(&confirm).await;
                if let Err(error) = stream.send(&fs::new_send_confirm(confirm)).await {
                    set_file_transfer_status(
                        "failed",
                        job.finished_size(),
                        job.total_size(),
                        &error.to_string(),
                    );
                }
            }
        }
        Some(file_response::Union::Error(error)) => {
            let message = sanitize_remote_value(error.error, 512);
            if fs::remove_job(error.id, read_jobs).is_some() {
                set_file_transfer_status("failed", 0, 0, &message);
            } else {
                set_remote_directory_result(RemoteDirectoryResult {
                    path: String::new(),
                    entries: Vec::new(),
                    error: message,
                });
            }
        }
        _ => {}
    }
}

fn sanitize_remote_value(value: String, max_len: usize) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(max_len)
        .collect()
}

fn set_remote_directory_result(result: RemoteDirectoryResult) {
    if let Ok(json) = serde_json::to_string(&result) {
        if let Ok(mut value) = REMOTE_DIRECTORY_RESULT.lock() {
            *value = json;
        }
    }
}

fn set_file_transfer_status(state: &str, transferred: u64, total: u64, error: &str) {
    set_file_transfer_status_detail("upload", state, transferred, total, error, 0, 1);
}

fn set_download_transfer_status(
    state: &str,
    write_jobs: &[TransferJob],
    download_state: &DownloadBatchState,
    error: &str,
) {
    let active_finished = write_jobs
        .iter()
        .map(TransferJob::finished_size)
        .sum::<u64>();
    let active_total = write_jobs.iter().map(TransferJob::total_size).sum::<u64>();
    let total = download_state
        .total_bytes
        .max(download_state.completed_bytes.saturating_add(active_total));
    set_file_transfer_status_detail(
        "download",
        state,
        download_state
            .completed_bytes
            .saturating_add(active_finished),
        total,
        error,
        download_state.completed_jobs,
        download_state.total_jobs,
    );
}

fn set_file_transfer_status_detail(
    direction: &str,
    state: &str,
    transferred: u64,
    total: u64,
    error: &str,
    completed_items: usize,
    total_items: usize,
) {
    let status = FileTransferStatus {
        session_id: SESSION_ID.load(Ordering::SeqCst),
        state: state.to_string(),
        transferred,
        total,
        error: sanitize_remote_value(error.to_string(), 512),
        direction: direction.to_string(),
        completed_items,
        total_items,
    };
    if let Ok(json) = serde_json::to_string(&status) {
        if let Ok(mut value) = FILE_TRANSFER_STATUS.lock() {
            *value = json;
        }
    }
}

fn handle_misc_message(misc_msg: Misc) -> &'static str {
    match misc_msg.union {
        Some(misc::Union::AudioFormat(format)) => {
            handle_audio_format(format);
            "misc_audio_format"
        }
        Some(misc::Union::SwitchDisplay(display)) => {
            let index = display.display.max(0) as usize;
            // The HarmonyOS client owns a single selected surface. Keep the
            // local selection as the source of truth because an acknowledgement
            // from an old subscription can still be queued ahead of the new
            // capture set and must not switch the UI back.
            let selected_display = CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0);
            if let Ok(mut guard) = DISPLAY_INFOS.try_lock() {
                if guard.len() <= index {
                    guard.resize(index + 1, (0, 0, 1920, 1080, false));
                }
                let previous = guard[index];
                guard[index] = (
                    display.x,
                    display.y,
                    if display.width > 0 {
                        display.width
                    } else {
                        previous.2
                    },
                    if display.height > 0 {
                        display.height
                    } else {
                        previous.3
                    },
                    display.cursor_embedded,
                );
            }
            REMOTE_CURSOR_SEQUENCE.fetch_add(1, Ordering::SeqCst);
            emit_event(&format!(
                "switch display received display={} selected={} size={}x{} cursor_embedded={}",
                display.display,
                selected_display,
                display.width,
                display.height,
                display.cursor_embedded
            ));
            "misc_switch_display"
        }
        Some(misc::Union::CloseReason(reason)) => {
            let reason = sanitize_remote_value(reason, 256);
            emit_event(&format!(
                "peer close reason received value={}",
                if reason.is_empty() { "empty" } else { &reason }
            ));
            "misc_close_reason"
        }
        Some(_) => {
            emit_event("peer message: Misc kind=other");
            "misc_other"
        }
        None => {
            emit_event("peer message: Misc kind=empty");
            "misc_empty"
        }
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
    let client_hwid = match CURRENT_CLIENT_HWID.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => Vec::new(),
    };
    let client_id = match CURRENT_CLIENT_ID.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => "harmony-client".to_string(),
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
        my_id: client_id,
        my_name: "StarRustDesk HarmonyOS".to_string(),
        my_platform: "HarmonyOS".to_string(),
        option: MessageField::some(OptionMessage {
            supported_decoding: MessageField::some(supported_decoding_options(false)),
            image_quality: performance.quality.into(),
            custom_fps: performance.fps,
            disable_audio: if REMOTE_AUDIO_ENABLED.load(Ordering::SeqCst) {
                hbb_common::message_proto::option_message::BoolOption::No
            } else {
                hbb_common::message_proto::option_message::BoolOption::Yes
            }
            .into(),
            enable_file_transfer: hbb_common::message_proto::option_message::BoolOption::Yes.into(),
            show_remote_cursor: if SHOW_REMOTE_CURSOR.load(Ordering::SeqCst) {
                hbb_common::message_proto::option_message::BoolOption::Yes
            } else {
                hbb_common::message_proto::option_message::BoolOption::No
            }
            .into(),
            ..Default::default()
        }),
        session_id: PROTOCOL_SESSION_ID.load(Ordering::SeqCst),
        version: RUSTDESK_PROTOCOL_VERSION.to_string(),
        os_login: MessageField::some(OSLogin::new()),
        hwid: client_hwid.into(),
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
        supported_decoding: MessageField::some(supported_decoding_options(false)),
        disable_audio: if REMOTE_AUDIO_ENABLED.load(Ordering::SeqCst) {
            hbb_common::message_proto::option_message::BoolOption::No
        } else {
            hbb_common::message_proto::option_message::BoolOption::Yes
        }
        .into(),
        show_remote_cursor: if SHOW_REMOTE_CURSOR.load(Ordering::SeqCst) {
            hbb_common::message_proto::option_message::BoolOption::Yes
        } else {
            hbb_common::message_proto::option_message::BoolOption::No
        }
        .into(),
        ..Default::default()
    });
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    match send_peer_message_async(msg).await {
        Ok(_) => emit_event(&format!(
            "performance options sent fps={} quality={} codec={} h264={} vp9={} vp8={} av1={} h265={}",
            performance.fps,
            performance.quality.value(),
            preferred_codec_name(false),
            H264_DECODER_SUPPORTED.load(Ordering::SeqCst),
            VP9_DECODER_SUPPORTED.load(Ordering::SeqCst),
            VP8_DECODER_SUPPORTED.load(Ordering::SeqCst),
            AV1_DECODER_SUPPORTED.load(Ordering::SeqCst),
            H265_DECODER_SUPPORTED.load(Ordering::SeqCst)
        )),
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
        let mut received_misc = Misc::new();
        received_misc.set_video_received(true);
        let mut received_msg = PeerMessage::new();
        received_msg.set_misc(received_misc);
        match send_peer_message_async(received_msg).await {
            Ok(_) => emit_event("initial video received ack sent"),
            Err(e) => emit_event(&format!("initial video received ack failed: {e}")),
        }
    }
}

fn supported_decoding_options(prefer_vp9: bool) -> SupportedDecoding {
    let h264_supported = H264_DECODER_SUPPORTED.load(Ordering::SeqCst);
    let vp9_supported = VP9_DECODER_SUPPORTED.load(Ordering::SeqCst);
    let vp8_supported = VP8_DECODER_SUPPORTED.load(Ordering::SeqCst);
    let av1_supported = AV1_DECODER_SUPPORTED.load(Ordering::SeqCst);
    let h265_supported = H265_DECODER_SUPPORTED.load(Ordering::SeqCst);
    // Match the official RustDesk negotiation policy: advertise every decoder
    // that is actually available and let the controlled peer choose the best
    // mutually supported codec. The server's Auto preference favors H.265
    // over H.264 when hardware encoding is available. VP9 is pinned only by
    // the explicit decoder-recovery path.
    let use_vp9 = prefer_vp9 && vp9_supported;
    SupportedDecoding {
        ability_vp8: if vp8_supported { 1 } else { 0 },
        ability_vp9: if vp9_supported { 1 } else { 0 },
        ability_av1: if av1_supported { 1 } else { 0 },
        ability_h264: if h264_supported { 1 } else { 0 },
        ability_h265: if h265_supported { 1 } else { 0 },
        prefer: if use_vp9 {
            supported_decoding::PreferCodec::VP9.into()
        } else {
            supported_decoding::PreferCodec::Auto.into()
        },
        i444: MessageField::some(CodecAbility {
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn preferred_codec_name(prefer_vp9: bool) -> &'static str {
    let vp9_supported = VP9_DECODER_SUPPORTED.load(Ordering::SeqCst);
    if prefer_vp9 && vp9_supported {
        "vp9"
    } else {
        "auto"
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
    let configured = PERFORMANCE_CONFIG
        .lock()
        .map(|guard| *guard)
        .unwrap_or(PerformanceConfig {
            fps: 45,
            quality: ImageQuality::Low,
        });
    if BACKGROUND_VIDEO_MODE.load(Ordering::SeqCst) {
        PerformanceConfig {
            fps: 2,
            quality: ImageQuality::Low,
        }
    } else {
        configured
    }
}

async fn send_test_delay_response(delay: TestDelay, stream: &mut Stream) {
    let should_respond = !delay.from_client;
    if let Some((delay_ms, target_bitrate_kb)) = test_delay_quality_values(&delay) {
        CONNECTION_DELAY_MS.store(delay_ms, Ordering::Relaxed);
        CONNECTION_TARGET_BITRATE_KB.store(target_bitrate_kb, Ordering::Relaxed);
    }
    emit_event(&format!(
        "test delay received time={} from_client={} last_delay={} target_bitrate={} action={}",
        delay.time,
        delay.from_client,
        delay.last_delay,
        delay.target_bitrate,
        if should_respond { "respond" } else { "ignore" },
    ));
    if !should_respond {
        send_auto_adjust_fps_if_due().await;
        return;
    }
    let mut msg = PeerMessage::new();
    msg.set_test_delay(delay);
    if let Err(e) = stream.send(&msg).await {
        emit_event(&format!(
            "test delay response send failed: {}",
            sanitize_remote_value(e.to_string(), 256)
        ));
    } else {
        emit_event("test delay response sent");
    }
    send_auto_adjust_fps_if_due().await;
}

fn test_delay_quality_values(delay: &TestDelay) -> Option<(i32, i32)> {
    if delay.from_client {
        None
    } else {
        Some((
            i32::try_from(delay.last_delay).unwrap_or(i32::MAX),
            i32::try_from(delay.target_bitrate).unwrap_or(i32::MAX),
        ))
    }
}

fn forward_video_frame(frame: VideoFrame) {
    let frame_display = frame.display.max(0);
    let current_display = CURRENT_DISPLAY.lock().map(|guard| *guard).unwrap_or(0);
    if !should_forward_video_display(
        frame_display,
        current_display,
        PEER_SUPPORTS_MULTI_DISPLAY_FRAMES.load(Ordering::SeqCst),
    ) {
        let now = now_ms();
        let last = LAST_DROPPED_DISPLAY_FRAME_LOG_MS.load(Ordering::Relaxed);
        if now.saturating_sub(last) >= 2_000
            && LAST_DROPPED_DISPLAY_FRAME_LOG_MS
                .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
        {
            emit_event(&format!(
                "video frame: ignored stale display={} selected={}",
                frame_display, current_display
            ));
        }
        return;
    }
    let forwarded = match frame.union {
        Some(video_frame::Union::Vp9s(frames)) => forward_encoded_frames(frames, b'V'),
        Some(video_frame::Union::H264s(frames)) => forward_encoded_frames(frames, b'H'),
        Some(video_frame::Union::H265s(frames)) => forward_encoded_frames(frames, b'5'),
        Some(video_frame::Union::Vp8s(frames)) => forward_encoded_frames(frames, b'8'),
        Some(video_frame::Union::Av1s(frames)) => forward_encoded_frames(frames, b'A'),
        Some(video_frame::Union::Rgb(_)) => {
            emit_event("video frame: rgb metadata without raw payload");
            0
        }
        Some(video_frame::Union::Yuv(_)) => {
            emit_event("video frame: yuv metadata without raw payload");
            0
        }
        Some(_) => {
            emit_event("video frame: unknown union");
            0
        }
        None => {
            emit_event("video frame: empty union");
            0
        }
    };
    if forwarded == 0 {
        emit_event("video frame: empty data");
        return;
    }
    queue_video_received_if_due();
}

fn should_forward_video_display(
    frame_display: i32,
    current_display: i32,
    supports_display_tag: bool,
) -> bool {
    !supports_display_tag || frame_display == current_display
}

fn forward_encoded_frames(frames: EncodedVideoFrames, codec_tag: u8) -> usize {
    let frame_count = frames.frames.len();
    if frame_count > 1 {
        emit_event(&format!("video frame: batch count={frame_count}"));
    }
    let callback = FRAME_CALLBACK.lock().ok().and_then(|guard| *guard);
    let Some(cb) = callback else {
        return 0;
    };
    let (_, _, width, height) = current_display_rect();
    let mut forwarded = 0;
    for frame in frames.frames {
        if frame.data.is_empty() {
            continue;
        }
        let mut tagged = Vec::with_capacity(frame.data.len() + 5);
        tagged.extend_from_slice(b"SRD0");
        tagged.push(codec_tag);
        tagged.extend_from_slice(&frame.data);
        cb(
            tagged.as_ptr(),
            tagged.len() as i32,
            width,
            height,
            i32::from(frame.key),
            frame.pts,
        );
        forwarded += 1;
    }
    forwarded
}

fn queue_video_received_if_due() {
    let now = now_ms();
    let last = LAST_VIDEO_RECEIVED_MS.load(Ordering::Relaxed);
    if now.saturating_sub(last) < 1000 {
        return;
    }
    LAST_VIDEO_RECEIVED_MS.store(now, Ordering::Relaxed);
    let _ = queue_video_received();
}

fn queue_video_received() -> i32 {
    let mut misc = Misc::new();
    misc.set_video_received(true);
    let mut msg = PeerMessage::new();
    msg.set_misc(misc);
    queue_peer_message(msg)
}

fn current_display_rect() -> (i32, i32, i32, i32) {
    let current = CURRENT_DISPLAY.try_lock().map(|guard| *guard).unwrap_or(0);
    let index = current.max(0) as usize;
    DISPLAY_INFOS
        .try_lock()
        .ok()
        .and_then(|guard| {
            guard
                .get(index)
                .map(|display| (display.0, display.1, display.2, display.3))
        })
        .unwrap_or((0, 0, 1920, 1080))
}

fn current_display_origin() -> (i32, i32) {
    let (x, y, _, _) = current_display_rect();
    (x, y)
}

fn queue_peer_message(msg: PeerMessage) -> i32 {
    trace_input_message("queue", &msg);
    if !CONNECTION_ACTIVE.load(Ordering::SeqCst) {
        emit_event("peer message send failed: not connected");
        return -1;
    }
    enqueue_peer_message(msg).map(|_| 0).unwrap_or_else(|e| {
        emit_event(&format!("peer message send failed: {e}"));
        -2
    })
}

fn request_graceful_peer_close(session_id: u64) -> bool {
    let sender = PEER_MESSAGE_SENDER.lock().ok().and_then(|guard| {
        guard
            .as_ref()
            .filter(|(stored_session_id, _)| *stored_session_id == session_id)
            .map(|(_, sender)| sender.clone())
    });
    let Some(sender) = sender else {
        emit_event("close request: active sender unavailable");
        return false;
    };
    let (completed, receiver) = mpsc::channel();
    if let Err(error) = sender.send(QueuedPeerCommand::Close {
        session_id,
        completed,
    }) {
        emit_event(&format!("close request: command send failed: {error}"));
        return false;
    }
    if receiver.recv_timeout(Duration::from_millis(250)).is_err() {
        emit_event("close request: completion timeout");
        return false;
    }
    true
}

fn finish_peer_task(session_id: u64, graceful_close_completed: bool) {
    let control = PEER_TASK_CONTROL.lock().ok().and_then(|mut guard| {
        if guard
            .as_ref()
            .is_some_and(|control| control.session_id == session_id)
        {
            guard.take()
        } else {
            None
        }
    });
    let Some(control) = control else {
        return;
    };
    if !graceful_close_completed {
        emit_event("peer task abort: unresponsive session");
        control.abort_handle.abort();
    }
    if control
        .completed
        .recv_timeout(Duration::from_millis(500))
        .is_err()
    {
        emit_event("peer task abort: completion timeout");
        control.abort_handle.abort();
        let _ = control.completed.recv_timeout(Duration::from_millis(250));
    }
}

fn mark_connection_lost(session_id: u64, reason: &str) {
    if SESSION_ID.load(Ordering::SeqCst) != session_id {
        emit_event("skip stale connection lost");
        return;
    }
    emit_event(&format!("connection lost: {reason}"));
    SESSION_ID.fetch_add(1, Ordering::SeqCst);
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    set_file_transfer_status("failed", 0, 0, "connection lost");
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    CONNECTION_TRANSPORT.store(0, Ordering::SeqCst);
    CONNECTION_DELAY_MS.store(0, Ordering::SeqCst);
    CONNECTION_TARGET_BITRATE_KB.store(0, Ordering::SeqCst);
    reset_audio_async();
    reset_display_state();
    clear_peer_message_sender_for_session(session_id);
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
        .as_ref()
        .filter(|(stored_session_id, _)| *stored_session_id == session_id)
        .map(|(_, sender)| sender.clone())
        .ok_or_else(|| hbb_common::anyhow::anyhow!("not connected"))?;
    sender
        .send(QueuedPeerCommand::Message {
            session_id,
            message: msg,
        })
        .map_err(|_| hbb_common::anyhow::anyhow!("sender closed"))
}

fn key_code_to_control(key_code: i32) -> Option<ControlKey> {
    match key_code {
        16 => Some(ControlKey::Shift),
        161 => Some(ControlKey::RShift),
        17 => Some(ControlKey::Control),
        163 => Some(ControlKey::RControl),
        18 => Some(ControlKey::Alt),
        165 => Some(ControlKey::RAlt),
        20 => Some(ControlKey::CapsLock),
        13 => Some(ControlKey::Return),
        27 => Some(ControlKey::Escape),
        32 => Some(ControlKey::Space),
        8 => Some(ControlKey::Backspace),
        9 => Some(ControlKey::Tab),
        37 => Some(ControlKey::LeftArrow),
        38 => Some(ControlKey::UpArrow),
        39 => Some(ControlKey::RightArrow),
        40 => Some(ControlKey::DownArrow),
        33 => Some(ControlKey::PageUp),
        34 => Some(ControlKey::PageDown),
        35 => Some(ControlKey::End),
        36 => Some(ControlKey::Home),
        45 => Some(ControlKey::Insert),
        46 => Some(ControlKey::Delete),
        19 => Some(ControlKey::Pause),
        44 => Some(ControlKey::Snapshot),
        93 => Some(ControlKey::Apps),
        145 => Some(ControlKey::Scroll),
        91 => Some(ControlKey::Meta),
        92 => Some(ControlKey::RWin),
        112 => Some(ControlKey::F1),
        113 => Some(ControlKey::F2),
        114 => Some(ControlKey::F3),
        115 => Some(ControlKey::F4),
        116 => Some(ControlKey::F5),
        117 => Some(ControlKey::F6),
        118 => Some(ControlKey::F7),
        119 => Some(ControlKey::F8),
        120 => Some(ControlKey::F9),
        121 => Some(ControlKey::F10),
        122 => Some(ControlKey::F11),
        123 => Some(ControlKey::F12),
        _ => None,
    }
}

fn modifier_bit_for_key_code(key_code: i32) -> i32 {
    match key_code {
        17 | 163 => 1,
        16 | 161 => 2,
        18 | 165 => 4,
        91 | 92 => 8,
        20 => 16,
        _ => 0,
    }
}

fn modifier_mask_to_controls(modifier_mask: i32) -> Vec<EnumOrUnknown<ControlKey>> {
    let mut modifiers = Vec::new();
    if modifier_mask & 1 != 0 {
        modifiers.push(ControlKey::Control.into());
    }
    if modifier_mask & 2 != 0 {
        modifiers.push(ControlKey::Shift.into());
    }
    if modifier_mask & 4 != 0 {
        modifiers.push(ControlKey::Alt.into());
    }
    if modifier_mask & 8 != 0 {
        modifiers.push(ControlKey::Meta.into());
    }
    if modifier_mask & 16 != 0 {
        modifiers.push(ControlKey::CapsLock.into());
    }
    modifiers
}

fn trace_input_message(stage: &str, msg: &PeerMessage) {
    match &msg.union {
        Some(message::Union::MouseEvent(event)) if event.mask & 7 != 0 => {
            let modifiers = event
                .modifiers
                .iter()
                .map(|modifier| modifier.value().to_string())
                .collect::<Vec<_>>()
                .join(",");
            emit_event(&format!(
                "input-trace: stage={stage} type=mouse mask={} x={} y={} modifiers=[{}]",
                event.mask, event.x, event.y, modifiers
            ));
        }
        Some(message::Union::KeyEvent(event)) => {
            let key = match &event.union {
                Some(key_event::Union::ControlKey(control)) => {
                    format!("control:{}", control.value())
                }
                Some(key_event::Union::Chr(chr)) => format!("scan:{chr}"),
                Some(_) => "other".to_string(),
                None => "none".to_string(),
            };
            let modifiers = event
                .modifiers
                .iter()
                .map(|modifier| modifier.value().to_string())
                .collect::<Vec<_>>()
                .join(",");
            emit_event(&format!(
                "input-trace: stage={stage} type=key key={key} down={} press={} mode={} modifiers=[{}]",
                event.down,
                event.press,
                event.mode.value(),
                modifiers
            ));
        }
        _ => {}
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
