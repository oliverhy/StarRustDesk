use super::*;
use hbb_common::message_proto::{FileResponse, FileTransferBlock, FileTransferDigest, FileTransferDone, FileTransferError};

struct FileFixture(PathBuf);
impl FileFixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("starrd-transfer-test-{}", Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for FileFixture {
    fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
}

struct Harness {
    client: Stream,
    peer: Stream,
    read: Vec<TransferJob>,
    write: Vec<TransferJob>,
    download: DownloadBatchState,
    upload: Option<UploadTransferState>,
    fixture: FileFixture,
    session: u64,
}

impl Harness {
    async fn new() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let client = tokio::net::TcpStream::connect(addr).await.unwrap();
        let (peer, peer_addr) = listener.accept().await.unwrap();
        Self { client: Stream::from(client, addr), peer: Stream::from(peer, peer_addr),
            read: Vec::new(), write: Vec::new(), download: DownloadBatchState::default(),
            upload: None, fixture: FileFixture::new(), session: SESSION_ID.load(Ordering::SeqCst) }
    }

    async fn next(&mut self) -> PeerMessage {
        let bytes = tokio::time::timeout(Duration::from_secs(2), self.peer.next())
            .await.expect("peer reply timed out").unwrap().unwrap();
        PeerMessage::parse_from_bytes(&bytes).unwrap()
    }

    async fn command(&mut self, command: QueuedPeerCommand) {
        assert!(send_file_command(command, self.session, &mut self.client, &mut self.read,
            &mut self.write, &mut self.download, &mut self.upload).await);
    }

    async fn reply(&mut self, response: FileResponse) {
        // Exercise real framing as well as the production dispatcher.
        let mut message = PeerMessage::new();
        message.set_file_response(response);
        self.peer.send(&message).await.unwrap();
        let bytes = tokio::time::timeout(Duration::from_secs(2), self.client.next()).await.unwrap().unwrap().unwrap();
        let Some(message::Union::FileResponse(response)) = PeerMessage::parse_from_bytes(&bytes).unwrap().union else { panic!("not a file reply"); };
        handle_file_session_response(response, &mut self.read, &mut self.write,
            &mut self.download, &mut self.upload, &mut self.client).await;
    }

    async fn done(&mut self, id: i32) {
        let mut response = FileResponse::new();
        response.set_done(FileTransferDone { id, ..Default::default() });
        self.reply(response).await;
    }

    async fn start_upload(&mut self, data: &[u8], overwrite: bool) -> i32 {
        let id = next_file_job_id();
        let path = self.fixture.0.join(format!("upload-{id}.bin"));
        std::fs::write(&path, data).unwrap();
        let job = TransferJob::new_read(id, JobType::Generic, "/remote/file.bin".into(),
            DataSource::FilePath(path), 0, true, false, true).unwrap();
        let receive = fs::new_receive(id, "/remote/file.bin".into(), 0, job.files().clone(), job.total_size());
        self.command(QueuedPeerCommand::StartUpload { session_id: self.session, job, receive }).await;
        assert!(matches!(self.next().await.union, Some(message::Union::FileAction(_))));
        drive_file_upload(&mut self.read, &mut self.upload, &mut self.client).await;
        let Some(message::Union::FileResponse(response)) = self.next().await.union else { panic!("expected digest"); };
        assert!(matches!(response.union, Some(file_response::Union::Digest(_))));
        if overwrite {
            let mut response = FileResponse::new();
            response.set_digest(FileTransferDigest { id, file_num: 0, is_upload: true,
                file_size: data.len() as u64, ..Default::default() });
            self.reply(response).await;
            assert!(matches!(self.next().await.union, Some(message::Union::FileAction(_))));
        } else {
            handle_file_send_confirm(FileTransferSendConfirmRequest { id, file_num: 0,
                union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)), ..Default::default() },
                &mut self.read, &mut self.upload).await;
        }
        id
    }

    async fn send_all(&mut self, expected: &[u8]) {
        let mut received = Vec::new();
        for _ in 0..20 {
            drive_file_upload(&mut self.read, &mut self.upload, &mut self.client).await;
            let Some(message::Union::FileResponse(response)) = self.next().await.union else { panic!("expected file data"); };
            match response.union {
                Some(file_response::Union::Block(block)) => {
                    if block.compressed { received.extend(hbb_common::compress::decompress(&block.data)); }
                    else { received.extend_from_slice(&block.data); }
                }
                Some(file_response::Union::Done(_)) => break,
                _ => panic!("unexpected file response"),
            }
        }
        assert_eq!(received, expected, "wire data must equal the selected local file");
        assert!(self.read.is_empty());
        assert!(self.upload.as_ref().unwrap().waiting_confirmation);
        assert_eq!(status()["state"], "waiting_confirmation");
        assert_eq!(status()["direction"], "upload");
    }
}

fn status() -> serde_json::Value {
    serde_json::from_str(&FILE_TRANSFER_STATUS.lock().unwrap()).unwrap()
}

#[test]
fn small_and_empty_uploads_complete_only_after_matching_peer_ack() {
    runtime().block_on(async {
        for (data, overwrite) in [(vec![47; 52510], false), (Vec::new(), true)] {
            let mut h = Harness::new().await;
            let id = h.start_upload(&data, overwrite).await;
            h.send_all(&data).await;
            h.done(id + 1000).await;
            assert_eq!(status()["state"], "waiting_confirmation");
            h.done(id).await;
            assert_eq!(status()["state"], "completed");
            assert_eq!(status()["direction"], "upload");
            assert_eq!(status()["transferred"], data.len() as u64);
            let terminal = status();
            h.done(id).await;
            assert_eq!(status(), terminal, "duplicate Done cannot create an empty download");
        }
    });
}

#[test]
fn late_upload_replies_cannot_corrupt_next_upload_or_cancelled_task() {
    runtime().block_on(async {
        let mut h = Harness::new().await;
        let old = h.start_upload(b"first", false).await;
        h.send_all(b"first").await;
        h.done(old).await;
        let current = h.start_upload(b"second", true).await;
        let before = status();
        h.done(old).await;
        let mut response = FileResponse::new();
        response.set_block(FileTransferBlock { id: old, data: vec![1, 2].into(), ..Default::default() });
        h.reply(response).await;
        assert_eq!(status(), before);
        h.send_all(b"second").await;
        h.command(QueuedPeerCommand::CancelTransfer { session_id: h.session }).await;
        let Some(message::Union::FileAction(action)) = h.next().await.union else { panic!("expected cancel"); };
        assert!(matches!(action.union, Some(file_action::Union::Cancel(cancel)) if cancel.id == current));
        let cancelled = status();
        assert_eq!(cancelled["state"], "cancelled");
        assert_eq!(cancelled["transferred"], 6);
        h.done(current).await;
        assert_eq!(status(), cancelled);
    });
}

#[test]
fn missing_upload_ack_times_out_without_claiming_success() {
    runtime().block_on(async {
        let mut h = Harness::new().await;
        let id = h.start_upload(b"ack missing", false).await;
        h.send_all(b"ack missing").await;
        check_file_transfer_timeout(&mut h.read, &mut h.write, &mut h.upload, &mut h.download,
            &mut h.client, Instant::now() + Duration::from_secs(31)).await;
        assert_eq!(status()["state"], "failed");
        assert_eq!(status()["direction"], "upload");
        assert!(status()["error"].as_str().unwrap().contains("确认超时"));
        let terminal = status();
        h.done(id).await;
        assert_eq!(status(), terminal);
    });
}

#[test]
fn remote_error_after_upload_data_is_still_reported_as_upload_failure() {
    runtime().block_on(async {
        let mut h = Harness::new().await;
        let id = h.start_upload(b"write failed", true).await;
        h.send_all(b"write failed").await;
        let mut response = FileResponse::new();
        response.set_error(FileTransferError { id, error: "permission denied".into(), ..Default::default() });
        h.reply(response).await;
        assert_eq!(status()["state"], "failed");
        assert_eq!(status()["direction"], "upload");
        assert_eq!(status()["transferred"], 12);
        assert!(h.upload.is_none());
    });
}

#[test]
fn download_batch_routes_only_matching_jobs_and_resolves_idle_timeout() {
    runtime().block_on(async {
        let mut h = Harness::new().await;
        let ids = [next_file_job_id(), next_file_job_id()];
        let commands = ids.iter().map(|id| DownloadJobCommand {
            job: TransferJob::new_write(*id, JobType::Generic, "/remote/file".into(),
                DataSource::FilePath(h.fixture.0.clone()), 0, true, true, true),
            send: fs::new_send(*id, JobType::Generic, "/remote/file".into(), 0, true),
        }).collect();
        h.command(QueuedPeerCommand::StartDownload { session_id: h.session, jobs: commands }).await;
        h.next().await;
        h.next().await;
        h.done(ids[0]).await;
        assert_eq!(status()["state"], "transferring");
        assert_eq!(status()["completedItems"], 1);
        h.done(ids[0]).await;
        assert_eq!(status()["completedItems"], 1);
        h.done(ids[1]).await;
        assert_eq!(status()["state"], "completed");
        assert_eq!(status()["completedItems"], 2);
        h.download.active = true;
        h.download.watchdog = Some(TransferWatchdog::new(Instant::now()));
        check_file_transfer_timeout(&mut h.read, &mut h.write, &mut h.upload, &mut h.download,
            &mut h.client, Instant::now() + Duration::from_secs(61)).await;
        assert_eq!(status()["state"], "failed");
        assert_eq!(status()["direction"], "download");
    });
}

#[test]
fn download_writes_real_bytes_and_late_upload_done_cannot_finish_the_batch() {
    runtime().block_on(async {
        let mut h = Harness::new().await;
        let old = h.start_upload(b"previous upload", false).await;
        h.send_all(b"previous upload").await;
        h.done(old).await;
        let id = next_file_job_id();
        let job = TransferJob::new_write(id, JobType::Generic, "/remote/download.bin".into(),
            DataSource::FilePath(h.fixture.0.clone()), 0, true, true, true);
        h.command(QueuedPeerCommand::StartDownload { session_id: h.session, jobs: vec![DownloadJobCommand {
            job, send: fs::new_send(id, JobType::Generic, "/remote/download.bin".into(), 0, true),
        }] }).await;
        h.next().await;
        let mut directory = hbb_common::message_proto::FileDirectory::new();
        directory.id = id;
        directory.entries.push(hbb_common::message_proto::FileEntry {
            name: "download.bin".into(), size: 4, ..Default::default()
        });
        let mut response = FileResponse::new();
        response.set_dir(directory);
        h.reply(response).await;
        h.done(old).await;
        assert_eq!(status()["state"], "transferring");
        assert_eq!(status()["direction"], "download");
        let mut response = FileResponse::new();
        response.set_block(FileTransferBlock { id, file_num: 0, data: b"data".to_vec().into(), ..Default::default() });
        h.reply(response).await;
        assert_eq!(status()["transferred"], 4);
        h.done(id).await;
        assert_eq!(status()["state"], "completed");
        assert_eq!(std::fs::read(h.fixture.0.join("download.bin")).unwrap(), b"data");
        let terminal = status();
        h.done(old).await;
        assert_eq!(status(), terminal);
    });
}

#[test]
fn upload_waiting_for_initial_permission_expires_and_diagnostic_events_are_content_free() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(value: *const c_char) {
        if let Some(value) = cstr_to_string(value) { EVENTS.lock().unwrap().push(value); }
    }
    struct Restore(Option<EventCallback>);
    impl Drop for Restore {
        fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; }
    }
    let _restore = Restore(EVENT_CALLBACK.lock().unwrap().replace(capture));
    EVENTS.lock().unwrap().clear();
    runtime().block_on(async {
        let mut h = Harness::new().await;
        let id = h.start_upload(b"PRIVATE_FILE_CONTENT", false).await;
        check_file_transfer_timeout(&mut h.read, &mut h.write, &mut h.upload, &mut h.download,
            &mut h.client, Instant::now() + Duration::from_secs(61)).await;
        assert_eq!(status()["state"], "failed");
        assert!(h.read.is_empty());
        let log = EVENTS.lock().unwrap().join("\n");
        assert!(log.contains(&format!("job={id}")));
        assert!(log.contains("reason=data_timeout"));
        assert!(!log.contains(&format!("upload-{id}.bin")));
        for forbidden in ["PRIVATE_FILE_CONTENT", "/remote/file.bin", "password", "token="] {
            assert!(!log.contains(forbidden), "diagnostic must not contain {forbidden}");
        }
    });
}

#[test]
fn file_session_exit_fails_pending_task_but_preserves_terminal_state_and_new_session() {
    let id = SESSION_ID.load(Ordering::SeqCst);
    for direction in ["upload", "download"] {
        for state in ["starting", "transferring", "waiting_confirmation"] {
            set_file_transfer_status_detail(direction, state, 12, 30, "", 0, 1);
            drop(FileSessionTransferGuard(id));
            assert_eq!(status()["state"], "failed");
            assert_eq!(status()["direction"], direction);
            assert_eq!(status()["transferred"], 12);
        }
    }
    set_file_transfer_status("completed", 30, 30, "");
    drop(FileSessionTransferGuard(id));
    assert_eq!(status()["state"], "completed");
    set_file_transfer_status("starting", 0, 30, "");
    drop(FileSessionTransferGuard(id + 1));
    assert_eq!(status()["state"], "starting");
}
