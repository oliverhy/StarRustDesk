use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::net::{IpAddr, SocketAddr};
use std::os::raw::{c_char, c_uchar};
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use hbb_common::config::{CONNECT_TIMEOUT, READ_TIMEOUT, RELAY_PORT, RS_PUB_KEY};
use hbb_common::fs::{self, DataSource, JobType, TransferJob};
use hbb_common::message_proto::{
    file_action, file_response, file_transfer_send_confirm_request, key_event, login_response,
    message, misc, supported_decoding, video_frame, AudioFormat, Clipboard, ClipboardFormat,
    Auth2FA, CodecAbility, ControlKey, CursorData, EncodedVideoFrames, FileAction, FileTransfer,
    FileTransferCancel, FileTransferSendConfirmRequest, Hash, ImageQuality, KeyEvent, IdPk, KeyboardMode, LoginRequest,
    Message as PeerMessage,
    Misc, MouseEvent, ReadDir,
    OptionMessage, OSLogin, PublicKey, SupportedDecoding, SwitchDisplay,
    TestDelay, VideoFrame,
};
use hbb_common::rendezvous_proto::{
    punch_hole_response, rendezvous_message, ConnType, KeyExchange, NatType, OnlineRequest,
    PunchHoleRequest, RequestRelay, RendezvousMessage,
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
use protobuf::{Enum, EnumOrUnknown, Message};
use tokio::runtime::Runtime;
use tokio::sync::mpsc as tokio_mpsc;

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
static PEER_IS_ANDROID: AtomicBool = AtomicBool::new(false);
static CURRENT_PEER_VERSION: Mutex<String> = Mutex::new(String::new());
static REMOTE_CURSOR_X: AtomicI32 = AtomicI32::new(0);
static REMOTE_CURSOR_Y: AtomicI32 = AtomicI32::new(0);
static REMOTE_CURSOR_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static REMOTE_CURSOR_VALID: AtomicBool = AtomicBool::new(false);
static REMOTE_CURSOR_IMAGES: Mutex<BTreeMap<u64, RemoteCursorImage>> =
    Mutex::new(BTreeMap::new());
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
static PEER_MESSAGE_SENDER: Mutex<Option<(u64, tokio_mpsc::UnboundedSender<QueuedPeerCommand>)>> = Mutex::new(None);
static PEER_TASK_CONTROL: Mutex<Option<PeerTaskControl>> = Mutex::new(None);
static FILE_MESSAGE_SENDER: Mutex<Option<Sender<QueuedPeerCommand>>> = Mutex::new(None);
static CURRENT_CONNECTION_CONFIG: Mutex<Option<ConnectionConfig>> = Mutex::new(None);
static SESSION_ID: AtomicU64 = AtomicU64::new(0);
static PROTOCOL_SESSION_ID: AtomicU64 = AtomicU64::new(0);
static LAST_FPS_HINT_MS: AtomicU64 = AtomicU64::new(0);
static LAST_VIDEO_RECEIVED_MS: AtomicU64 = AtomicU64::new(0);
static CONNECTION_ACTIVE: AtomicBool = AtomicBool::new(false);
static CONNECTION_ROUTE: AtomicI32 = AtomicI32::new(0);
static AUDIO_RESET_IN_PROGRESS: AtomicBool = AtomicBool::new(false);
static REMOTE_AUDIO_ENABLED: AtomicBool = AtomicBool::new(true);
static BACKGROUND_VIDEO_MODE: AtomicBool = AtomicBool::new(false);
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

const DIRECT_CONNECT_TIMEOUT: u64 = 6_000;
const LOCAL_DIRECT_CONNECT_TIMEOUT: u64 = 1_000;

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
    if session_id == 0 { 1 } else { session_id }
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
    PEER_IS_ANDROID.store(false, Ordering::SeqCst);
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
        if guard.as_ref().is_some_and(|(stored_session_id, _)| *stored_session_id == session_id) {
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
pub extern "C" fn rust_connect(
    peer_id: *const c_char,
    password: *const c_char,
    rendezvous_server: *const c_char,
    relay_server: *const c_char,
    server_key: *const c_char,
    client_hwid: *const c_char,
    client_id: *const c_char,
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
    PROTOCOL_SESSION_ID.store(new_protocol_session_id(), Ordering::SeqCst);
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    reset_display_state();
    let _ = clear_connection_for_session(session_id);
    emit_event("previous connection cleared");
    let pass = cstr_to_string(password).unwrap_or_default();
    let rv = cstr_to_string(rendezvous_server).unwrap_or_default();
    let relay_override = cstr_to_string(relay_server).unwrap_or_default();
    let key = cstr_to_string(server_key).unwrap_or_default();
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

    let rendezvous_addr = with_port(if rv.is_empty() { "rustdesk.com" } else { &rv }, 21116);
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
            // RustDesk's rendezvous token is the signed-in account/server
            // access token, not the remote-control password. This client does
            // not currently expose account login, so keep it empty.
            token: String::new(),
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
        let mut is_local = false;

        match response.union {
            Some(rendezvous_message::Union::PunchHoleResponse(ph)) => {
                is_local = ph.is_local();
                emit_event(&format!(
                    "punch response socket_addr={} relay={} pk_len={} is_local={} other_failure={}",
                    ph.socket_addr.len(),
                    ph.relay_server,
                    ph.pk.len(),
                    is_local,
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

        // The direct connection must reuse the rendezvous connection's local
        // endpoint. Release the original socket first, especially for the
        // same-intranet path where the peer address is a LAN endpoint.
        drop(rv_conn);

        let mut stream = if let Some(addr) = peer_addr {
            let direct_timeout = if is_local {
                LOCAL_DIRECT_CONNECT_TIMEOUT
            } else {
                DIRECT_CONNECT_TIMEOUT
            };
            emit_event(&format!(
                "try direct peer addr={addr} local={local_addr} is_local={is_local} timeout={direct_timeout}"
            ));
            match connect_tcp_local(addr, Some(local_addr), direct_timeout).await {
                Ok(s) => {
                    emit_event("direct peer connected");
                    CONNECTION_ROUTE.store(1, Ordering::SeqCst);
                    s
                }
                Err(e) if !relay_from_server.is_empty() => {
                    emit_event(&format!("direct peer failed: {e}; try relay"));
                    match request_relay(
                        &peer,
                        &relay_from_server,
                        &rendezvous_addr,
                        !signed_id_pk.is_empty(),
                        &key,
                        "",
                    )
                    .await
                    {
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
            match request_relay(
                &peer,
                &relay_from_server,
                &rendezvous_addr,
                !signed_id_pk.is_empty(),
                &key,
                "",
            )
            .await
            {
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
        emit_event(&format!("remote audio updated: {}", if enabled { "enabled" } else { "disabled" }));
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
    emit_event(&format!("background video mode updated: {} fps={}", enabled, performance.fps));
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
pub extern "C" fn rust_send_mouse_event(
    x: f64,
    y: f64,
    action: i32,
    modifier_mask: i32,
) -> i32 {
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
        modifiers: modifier_mask_to_controls(modifier_mask),
        ..Default::default()
    });
    queue_peer_message(msg)
}

#[no_mangle]
pub extern "C" fn rust_send_mouse_wheel(
    delta_x: f64,
    delta_y: f64,
    modifier_mask: i32,
) -> i32 {
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
        modifiers: modifier_mask_to_controls(modifier_mask),
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
    scan_code: i32,
    action: i32,
    modifier_mask: i32,
) -> i32 {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Map.into(),
        modifiers: modifier_mask_to_controls(modifier_mask),
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
    if CONNECTION_ACTIVE.load(Ordering::SeqCst)
        && PEER_IS_ANDROID.load(Ordering::SeqCst)
    {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn rust_send_2fa(code: *const c_char, client_hwid: *const c_char) -> i32 {
    let Some(code) = cstr_to_string(code) else { return -1 };
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
    let Some(mut path) = cstr_to_string(path) else { return -1 };
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
    let Some(sender) = ensure_file_session() else { return -3 };
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    sender
        .send(QueuedPeerCommand::Message { session_id, message: msg })
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
    let Some(local_path) = cstr_to_string(local_path) else { return -1 };
    let Some(file_name) = cstr_to_string(file_name) else { return -1 };
    let Some(remote_directory) = cstr_to_string(remote_directory) else { return -1 };
    if file_name.is_empty()
        || file_name.len() > 255
        || file_name.contains(['/', '\\', '\0'])
        || remote_directory.is_empty()
        || remote_directory.len() > 4096
    {
        return -2;
    }
    let Ok(metadata) = std::fs::metadata(&local_path) else { return -3 };
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
    let Some(sender) = ensure_file_session() else { return -6 };
    set_file_transfer_status("starting", 0, job.total_size(), "");
    sender
        .send(QueuedPeerCommand::StartUpload { session_id, job, receive })
        .map(|_| 0)
        .unwrap_or(-7)
}

#[no_mangle]
pub extern "C" fn rust_start_file_download_batch(
    requests_json: *const c_char,
    local_root: *const c_char,
) -> i32 {
    let Some(requests_json) = cstr_to_string(requests_json) else { return -1 };
    let Some(local_root) = cstr_to_string(local_root) else { return -1 };
    if local_root.is_empty() || local_root.len() > 4096 || local_root.bytes().any(|byte| byte == 0) {
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

    let Some(sender) = ensure_file_session() else { return -8 };
    let session_id = SESSION_ID.load(Ordering::SeqCst);
    set_file_transfer_status_detail("download", "starting", 0, 0, "", 0, commands.len());
    sender
        .send(QueuedPeerCommand::StartDownload { session_id, jobs: commands })
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
    let value = FILE_TRANSFER_STATUS.lock().map(|status| status.clone()).unwrap_or_default();
    CString::new(value)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn rust_cancel_file_transfer() -> i32 {
    let Some(sender) = FILE_MESSAGE_SENDER.lock().ok().and_then(|guard| guard.clone()) else {
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
    if let Some(sender) = FILE_MESSAGE_SENDER.lock().ok().and_then(|guard| guard.clone()) {
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
    let mut stream = match connect_file_stream(&config).await {
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
                ).await {
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
                let Ok(message) = PeerMessage::parse_from_bytes(&bytes) else { continue };
                match message.union {
                    Some(message::Union::Hash(hash)) => {
                        if let Err(error) = send_file_login(hash, &config, &mut stream).await {
                            set_remote_directory_result(RemoteDirectoryResult {
                                path: String::new(), entries: Vec::new(), error: error.to_string(),
                            });
                            return;
                        }
                    }
                    Some(message::Union::LoginResponse(response)) => match response.union {
                        Some(login_response::Union::Error(error)) => {
                            set_remote_directory_result(RemoteDirectoryResult {
                                path: String::new(), entries: Vec::new(), error,
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
                                ).await {
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
                        ).await;
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
    let QueuedPeerCommand::Message { message, .. } = command else { return false };
    let Some(message::Union::FileAction(action)) = &message.union else { return false };
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
        QueuedPeerCommand::Message { session_id: command_session, message } => {
            command_session == session_id && stream.send(&message).await.is_ok()
        }
        QueuedPeerCommand::StartUpload { session_id: command_session, job, receive } => {
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
        QueuedPeerCommand::StartDownload { session_id: command_session, jobs } => {
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
                    set_download_transfer_status("failed", write_jobs, download_state, "发送下载请求失败");
                    write_jobs.clear();
                    download_state.active = false;
                    return false;
                }
                write_jobs.push(command.job);
            }
            set_download_transfer_status("transferring", write_jobs, download_state, "");
            emit_event(&format!("file-session:download-started items={}", download_state.total_jobs));
            true
        }
        QueuedPeerCommand::CancelTransfer { session_id: command_session } => {
            if command_session != session_id {
                return true;
            }
            let is_download = download_state.active || !write_jobs.is_empty();
            let direction = if is_download { "download" } else { "upload" };
            let completed_items = download_state.completed_jobs;
            let total_items = if is_download { download_state.total_jobs } else { 1 };
            let completed_bytes = download_state.completed_bytes;
            let active_finished = write_jobs.iter().map(TransferJob::finished_size).sum::<u64>();
            let active_total = write_jobs.iter().map(TransferJob::total_size).sum::<u64>();
            let upload_finished = read_jobs.iter().map(TransferJob::finished_size).sum::<u64>();
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
                direction, "cancelled", transferred, total, "", completed_items, total_items,
            );
            emit_event(&format!("file-session:transfer-cancelled direction={direction}"));
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
    DISPLAY_COUNT.try_lock().map(|guard| *guard).unwrap_or(1).max(1)
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
    if !REMOTE_CURSOR_VALID.load(Ordering::SeqCst) || x.is_null() || y.is_null() || sequence.is_null() {
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
    queue_peer_message(msg)
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

    let server = cstr_to_string(rendezvous_server).unwrap_or_default();
    // OnlineRequest is handled by hbbs on the auxiliary NAT-test port, which
    // is one lower than the normal rendezvous port (21115 for the default
    // 21116 service). Sending it to the main port makes hbbs close the stream
    // without an OnlineResponse.
    let rendezvous_addr = online_query_addr(&server);
    let requester_id = cstr_to_string(requester_id).unwrap_or_else(|| "harmony-client".to_string());
    if let Ok(mut guard) = PEER_ONLINE_RESULT.lock() {
        guard.clear();
    }
    emit_event(&format!("online state query started count={}", peers.len()));

    runtime().spawn(async move {
        let result = query_peer_online_states(peers, rendezvous_addr, requester_id).await;
        let payload = match result {
            Ok(states) => {
                emit_event(&format!("online state query completed count={}", states.len()));
                PeerOnlineResult {
                    peers: states,
                    error: String::new(),
                }
            }
            Err(error) => {
                emit_event(&format!("online state query failed: {error}"));
                PeerOnlineResult {
                    peers: Vec::new(),
                    error,
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
    let mut connection = connect_tcp(rendezvous_addr, CONNECT_TIMEOUT)
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
    let response = next_rendezvous(&mut connection, READ_TIMEOUT)
        .await
        .ok_or_else(|| "response timeout".to_string())?;
    let online = match response.union {
        Some(rendezvous_message::Union::OnlineResponse(value)) => value,
        _ => return Err("unexpected response".to_string()),
    };
    let states = online.states.as_ref();
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
    let host = host.trim();
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
    let rendezvous_addr = with_port(
        if server.trim().is_empty() {
            "rustdesk.com"
        } else {
            server
        },
        21116,
    );
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

async fn connect_file_stream(config: &ConnectionConfig) -> Result<Stream, String> {
    let mut rendezvous = connect_tcp(config.rendezvous_addr.clone(), CONNECT_TIMEOUT)
        .await
        .map_err(|error| error.to_string())?;
    let mut request = RendezvousMessage::new();
    request.set_punch_hole_request(PunchHoleRequest {
        id: config.peer.clone(),
        token: String::new(),
        nat_type: NatType::UNKNOWN_NAT.into(),
        licence_key: config.key.clone(),
        conn_type: ConnType::FILE_TRANSFER.into(),
        version: "1.2.0".to_string(),
        ..Default::default()
    });
    rendezvous.send(&request).await.map_err(|error| error.to_string())?;
    let local_addr = rendezvous.local_addr();
    let response = next_rendezvous(&mut rendezvous, READ_TIMEOUT)
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
        secure_peer_connection(&config.peer, &signed_id_pk, &config.key, &mut stream)
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
        match connect_tcp_local(address, Some(local_addr), direct_timeout).await {
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
    secure_peer_connection(&config.peer, &signed_id_pk, &config.key, &mut stream)
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
        let mut rv_conn = connect_tcp(rendezvous_server.to_string(), CONNECT_TIMEOUT).await?;
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

        match next_rendezvous(&mut rv_conn, CONNECT_TIMEOUT).await {
            Some(msg) => match msg.union {
                Some(rendezvous_message::Union::RelayResponse(resp))
                    if resp.refuse_reason.is_empty() =>
                {
                    emit_event(&format!("relay request accepted attempt={attempt}/3"));
                    return create_relay_with_type(
                        peer,
                        &uuid,
                        relay_server,
                        key,
                        ipv4,
                        conn_type,
                    )
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
        emit_event("secure peer: unavailable; use non-secure connection");
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
        Err(e) => {
            emit_event(&format!(
                "secure peer: invalid handshake message: {e}; use non-secure connection"
            ));
            conn.send(&PeerMessage::new()).await?;
            return Ok(());
        }
    };
    let Some(message::Union::SignedId(signed_id)) = msg.union else {
        emit_event("secure peer: first peer msg not SignedId; use non-secure connection");
        conn.send(&PeerMessage::new()).await?;
        return Ok(());
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
            emit_event(&format!(
                "secure peer: peer signed id mismatch id={id}; use non-secure connection"
            ));
            conn.send(&PeerMessage::new()).await?;
        }
        Err(e) => {
            emit_event(&format!(
                "secure peer: invalid peer signed id: {e}; use non-secure connection"
            ));
            let mut msg_out = PeerMessage::new();
            msg_out.set_public_key(PublicKey::new());
            conn.send(&msg_out).await?;
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
    let (tx, mut rx) = tokio_mpsc::unbounded_channel::<QueuedPeerCommand>();
    if let Ok(mut guard) = PEER_MESSAGE_SENDER.lock() {
        *guard = Some((session_id, tx));
    }
    let (task_completed, task_completed_receiver) = mpsc::channel();
    let task = runtime().spawn(async move {
            let _task_completion = PeerTaskCompletion(Some(task_completed));
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
            if SESSION_ID.load(Ordering::SeqCst) == session_id {
                CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
                CONNECTION_ROUTE.store(0, Ordering::SeqCst);
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
            emit_event(&format!("peer message parse failed len={} err={e}", bytes.len()));
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
                    if let Ok(mut guard) = CURRENT_PEER_VERSION.try_lock() {
                        *guard = info.version.clone();
                    }
                    let display_count = info.displays.len().max(1) as i32;
                    let displays: Vec<(i32, i32, i32, i32, bool)> = info
                        .displays
                        .iter()
                        .map(|display| (display.x, display.y, display.width, display.height, display.cursor_embedded))
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
                    set_download_transfer_status("failed", write_jobs, download_state, &error.to_string());
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
                download_state.completed_bytes = download_state.completed_bytes.saturating_add(job.finished_size());
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
                    set_file_transfer_status("failed", job.finished_size(), job.total_size(), &error.to_string());
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
    let active_total = write_jobs
        .iter()
        .map(TransferJob::total_size)
        .sum::<u64>();
    let total = download_state.total_bytes.max(
        download_state.completed_bytes.saturating_add(active_total),
    );
    set_file_transfer_status_detail(
        "download",
        state,
        download_state.completed_bytes.saturating_add(active_finished),
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
            if let Ok(mut guard) = CURRENT_DISPLAY.try_lock() {
                *guard = display.display.max(0);
            }
            if let Ok(mut guard) = DISPLAY_INFOS.try_lock() {
                if guard.len() <= index {
                    guard.resize(index + 1, (0, 0, 1920, 1080, false));
                }
                let previous = guard[index];
                guard[index] = (
                    display.x,
                    display.y,
                    if display.width > 0 { display.width } else { previous.2 },
                    if display.height > 0 { display.height } else { previous.3 },
                    display.cursor_embedded,
                );
            }
            REMOTE_CURSOR_SEQUENCE.fetch_add(1, Ordering::SeqCst);
            emit_event(&format!(
                "switch display received display={} size={}x{} cursor_embedded={}",
                display.display, display.width, display.height, display.cursor_embedded
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
        version: "1.2.0".to_string(),
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

fn forward_video_frame(frame: VideoFrame) {
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
        .and_then(|guard| guard.get(index).map(|display| (display.0, display.1, display.2, display.3)))
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
    let sender = PEER_MESSAGE_SENDER
        .lock()
        .ok()
        .and_then(|guard| {
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
    if let Err(error) = sender
        .send(QueuedPeerCommand::Close {
            session_id,
            completed,
        })
    {
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
        let _ = control
            .completed
            .recv_timeout(Duration::from_millis(250));
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
        17 => Some(ControlKey::Control),
        18 => Some(ControlKey::Alt),
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
        46 => Some(ControlKey::Delete),
        91 => Some(ControlKey::Meta),
        _ => None,
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
                Some(key_event::Union::ControlKey(control)) => format!("control:{}", control.value()),
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
