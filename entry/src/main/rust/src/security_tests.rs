use super::*;
use hbb_common::message_proto::SignedId;

#[test]
fn remote_file_operations_reject_roots_and_consume_their_own_results() {
    for path in ["", "/", "\\", "C:", "C:\\", "D:/", "/home/../", "../file", "a/./b", "a\nfile"] {
        assert!(!safe_remote_operation_path(path), "{path:?}");
    }
    for path in ["/home/user/file.txt", "C:\\Users\\test\\file.txt", "relative-file"] {
        assert!(safe_remote_operation_path(path), "{path:?}");
    }
    let id = next_file_job_id();
    FILE_OPERATION_ID.store(id, Ordering::SeqCst);
    let mut reply = hbb_common::message_proto::FileResponse::new();
    reply.set_done(hbb_common::message_proto::FileTransferDone { id, ..Default::default() });
    assert!(consume_file_operation_result(&reply));
    assert_eq!(FILE_OPERATION_ID.load(Ordering::SeqCst), 0);
    assert!(FILE_OPERATION_RESULT.lock().unwrap().contains("\"ok\":true"));
    let cancelled = next_file_job_id();
    FILE_OPERATION_ID.store(cancelled, Ordering::SeqCst);
    rust_cancel_file_operation();
    let mut late = hbb_common::message_proto::FileResponse::new();
    late.set_error(hbb_common::message_proto::FileTransferError { id: cancelled, error: "late".into(), ..Default::default() });
    assert!(consume_file_operation_result(&late));
    assert!(FILE_OPERATION_RESULT.lock().unwrap().is_empty());
}

async fn stream_pair() -> (Stream, Stream) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let client = tokio::net::TcpStream::connect(addr).await.unwrap();
    let (server, peer) = listener.accept().await.unwrap();
    (Stream::from(client, addr), Stream::from(server, peer))
}

static LOGIN_DIAGNOSTIC_EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());

extern "C" fn collect_login_event(value: *const c_char) {
    if let Some(value) = cstr_to_string(value) {
        LOGIN_DIAGNOSTIC_EVENTS.lock().unwrap().push(value);
    }
}

#[test]
fn login_challenge_reaches_the_network_and_diagnostics_never_include_secrets() {
    // Run the real receive task, Hash handler, queue and network writer against
    // a loopback peer. Receiving LoginRequest proves this is not just queue success.
    let previous_callback = EVENT_CALLBACK.lock().unwrap().replace(collect_login_event);
    LOGIN_DIAGNOSTIC_EVENTS.lock().unwrap().clear();
    let session_id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    FILE_ONLY_SESSION.store(false, Ordering::SeqCst);
    CURRENT_PEER_ID.lock().unwrap().clone_from(&"case-Sensitive-peer".to_string());
    *PASSWORD_HASH.lock().unwrap() = b"private-login-password".to_vec();
    runtime().block_on(async {
        let (client, mut peer) = stream_pair().await;
        spawn_receive_loop(session_id, client, None);
        // A silent open socket must remain available until the peer supplies its challenge.
        assert!(peer.next_timeout(25).await.is_none());
        let mut challenge = PeerMessage::new();
        challenge.set_hash(Hash { salt: "private-salt".into(), challenge: "private-challenge".into(), ..Default::default() });
        peer.send(&challenge).await.unwrap();
        let bytes = peer.next_timeout(1500).await.expect("login was never written").unwrap();
        let request = PeerMessage::parse_from_bytes(&bytes).unwrap();
        let Some(message::Union::LoginRequest(request)) = request.union else { panic!("expected login request"); };
        assert_eq!(request.username, "case-Sensitive-peer");
        assert!(!request.password.is_empty());
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if LOGIN_DIAGNOSTIC_EVENTS.lock().unwrap().iter().any(|s| s == "login request sent") { break; }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }).await.unwrap();
        drop(peer);
    });
    finish_peer_task(session_id, false);
    let events = LOGIN_DIAGNOSTIC_EVENTS.lock().unwrap().clone();
    let position = |prefix: &str| events.iter().position(|event| event.starts_with(prefix)).unwrap();
    assert!(position("peer-login: transport_ready") < position("peer-login: first_packet"));
    assert!(position("peer message: Hash") < position("peer-login: request_queued"));
    assert!(position("peer-login: request_queued") < position("peer-login: request_write_start"));
    assert!(position("peer-login: request_write_start") < position("login request sent"));
    let log = events.join("\n");
    for private in ["private-login-password", "private-salt", "private-challenge", "case-Sensitive-peer"] {
        assert!(!log.contains(private), "private login data leaked into diagnostics");
    }
    *EVENT_CALLBACK.lock().unwrap() = previous_callback;
    PASSWORD_HASH.lock().unwrap().clear();
}

#[test]
fn account_rendezvous_requires_verified_encryption_without_downgrade() {
    runtime().block_on(async {
        let (rs_pk, rs_sk) = sign::gen_keypair();
        let key = base64::encode(&rs_pk.0, Variant::Original);
        let (mut client, mut server) = stream_pair().await;
        server.send(&RendezvousMessage::new()).await.unwrap();
        assert!(secure_rendezvous_connection(&mut client, &key, RendezvousHandshakeContext::Account).await.is_err());
        assert!(!client.is_secured());
        assert!(server.next_timeout(30).await.is_none());

        let (mut client, mut server) = stream_pair().await;
        let (encryption_pk, _) = box_::gen_keypair();
        let mut exchange = RendezvousMessage::new();
        exchange.set_key_exchange(KeyExchange {
            keys: vec![sign::sign(&encryption_pk.0, &rs_sk).into()],
            ..Default::default()
        });
        server.send(&exchange).await.unwrap();
        secure_rendezvous_connection(&mut client, &key, RendezvousHandshakeContext::Account).await.unwrap();
        assert!(client.is_secured());
        let response = server.next_timeout(1000).await.unwrap().unwrap();
        assert!(matches!(RendezvousMessage::parse_from_bytes(&response).unwrap().union,
            Some(rendezvous_message::Union::KeyExchange(_))));
    });
}

#[test]
fn account_handshake_reports_safe_stages_and_never_sends_secrets_on_failure() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(value: *const c_char) {
        if let Some(value) = cstr_to_string(value) { EVENTS.lock().unwrap().push(value); }
    }
    struct RestoreCallback(Option<EventCallback>);
    impl Drop for RestoreCallback {
        fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; }
    }
    EVENTS.lock().unwrap().clear();
    let _restore = RestoreCallback(EVENT_CALLBACK.lock().unwrap().replace(capture));
    let context = RendezvousHandshakeContext::Account;
    runtime().block_on(async {
        let (rs_pk, rs_sk) = sign::gen_keypair();
        let key = base64::encode(&rs_pk.0, Variant::Original);

        // A silent server remains connected: distinguish this from EOF and
        // verify no account token or other request is sent while waiting.
        let (mut client, mut peer) = stream_pair().await;
        let result = secure_rendezvous_connection_with_timeout(&mut client, &key, context, 35).await;
        assert_eq!(result, Err(RendezvousHandshakeError::ReceiveTimeout));
        assert!(!client.is_secured());
        assert!(peer.next_timeout(25).await.is_none());

        let (mut client, peer) = stream_pair().await;
        drop(peer);
        assert_eq!(secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await,
            Err(RendezvousHandshakeError::ReceiveClosed));

        let (mut client, mut peer) = stream_pair().await;
        peer.send_raw(b"\xffTEST_RAW_RESPONSE_DO_NOT_LOG TEST_PASSWORD_DO_NOT_LOG".to_vec()).await.unwrap();
        assert_eq!(secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await,
            Err(RendezvousHandshakeError::DecodeError));
        assert!(peer.next_timeout(25).await.is_none());

        let (mut client, mut peer) = stream_pair().await;
        let mut other = RendezvousMessage::new();
        other.set_punch_hole_response(hbb_common::rendezvous_proto::PunchHoleResponse {
            other_failure: "TEST_TOKEN_DO_NOT_LOG TEST_PASSWORD_DO_NOT_LOG TEST_RAW_RESPONSE_DO_NOT_LOG".into(),
            ..Default::default()
        });
        peer.send(&other).await.unwrap();
        assert_eq!(secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await,
            Err(RendezvousHandshakeError::UnexpectedMessage));
        assert!(peer.next_timeout(25).await.is_none());

        let (mut client, mut peer) = stream_pair().await;
        let mut exchange = RendezvousMessage::new();
        exchange.set_key_exchange(KeyExchange::new());
        peer.send(&exchange).await.unwrap();
        assert_eq!(secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await,
            Err(RendezvousHandshakeError::InvalidExchange));
        assert!(peer.next_timeout(25).await.is_none());

        let (mut client, mut peer) = stream_pair().await;
        let (_, other_sk) = sign::gen_keypair();
        let mut exchange = RendezvousMessage::new();
        exchange.set_key_exchange(KeyExchange {
            keys: vec![sign::sign(b"TEST_SERVER_KEY_DO_NOT_LOG", &other_sk).into()],
            ..Default::default()
        });
        peer.send(&exchange).await.unwrap();
        assert_eq!(secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await,
            Err(RendezvousHandshakeError::SignatureInvalid));
        assert!(peer.next_timeout(25).await.is_none());

        let (mut client, mut peer) = stream_pair().await;
        let mut exchange = RendezvousMessage::new();
        exchange.set_key_exchange(KeyExchange {
            keys: vec![sign::sign(b"TEST_SHORT_KEY_DO_NOT_LOG", &rs_sk).into()],
            ..Default::default()
        });
        peer.send(&exchange).await.unwrap();
        assert_eq!(secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await,
            Err(RendezvousHandshakeError::InvalidPeerKey));
        assert!(peer.next_timeout(25).await.is_none());

        let (mut client, mut peer) = stream_pair().await;
        let (encryption_pk, _) = box_::gen_keypair();
        let mut exchange = RendezvousMessage::new();
        let mut key_exchange = KeyExchange {
            keys: vec![sign::sign(&encryption_pk.0, &rs_sk).into()],
            ..Default::default()
        };
        key_exchange.special_fields.mut_unknown_fields()
            .add_length_delimited(88, b"TEST_SIGNED_PARAMS_DO_NOT_LOG".to_vec());
        exchange.set_key_exchange(key_exchange);
        peer.send(&exchange).await.unwrap();
        secure_rendezvous_connection_with_timeout(&mut client, &key, context, 500).await.unwrap();
        assert!(client.is_secured());
        let response = peer.next_timeout(500).await.unwrap().unwrap();
        assert!(matches!(RendezvousMessage::parse_from_bytes(&response).unwrap().union,
            Some(rendezvous_message::Union::KeyExchange(_))));
    });
    let events = EVENTS.lock().unwrap();
    let log = events.join("\n");
    for expected in ["step=wait_server_key outcome=receive_timeout", "step=wait_server_key outcome=receive_closed",
        "step=decode_response outcome=decode_error", "kind=punch_hole_response",
        "step=decode_response outcome=unexpected_message", "step=validate_exchange outcome=invalid_exchange",
        "step=verify_server_signature outcome=signature_invalid", "step=validate_server_exchange_key outcome=invalid_peer_key",
        "step=validate_exchange outcome=received unknown_fields=true", "step=send_client_key outcome=start",
        "step=secure_channel outcome=ready"] {
        assert!(log.contains(expected), "missing fixed diagnostic category {expected}");
    }
    for private in ["TEST_TOKEN_DO_NOT_LOG", "TEST_PASSWORD_DO_NOT_LOG", "TEST_RAW_RESPONSE_DO_NOT_LOG",
        "TEST_SERVER_KEY_DO_NOT_LOG", "TEST_SHORT_KEY_DO_NOT_LOG", "TEST_SIGNED_PARAMS_DO_NOT_LOG"] {
        assert!(!log.contains(private), "handshake diagnostics exposed private data");
    }
}

#[test]
fn account_handshake_result_codes_do_not_confuse_refusal_and_transport_errors() {
    for (error, code) in [
        (RendezvousHandshakeError::ReceiveTimeout, -29), (RendezvousHandshakeError::SendTimeout, -29),
        (RendezvousHandshakeError::ReceiveClosed, -30), (RendezvousHandshakeError::ReceiveError, -31),
        (RendezvousHandshakeError::SendError, -31), (RendezvousHandshakeError::DecodeError, -32),
        (RendezvousHandshakeError::UnexpectedMessage, -32), (RendezvousHandshakeError::InvalidExchange, -32),
        (RendezvousHandshakeError::InvalidServerKey, -33), (RendezvousHandshakeError::SignatureInvalid, -33),
        (RendezvousHandshakeError::InvalidPeerKey, -33),
    ] {
        assert_eq!(error.connection_result(), code);
        assert_ne!(code, -13, "a handshake failure is not a server refusal");
    }
}

async fn accept_verified_test_handshake(peer: &mut Stream, signer: &sign::SecretKey) {
    let (server_pk, server_sk) = box_::gen_keypair();
    let mut exchange = RendezvousMessage::new();
    exchange.set_key_exchange(KeyExchange {
        keys: vec![sign::sign(&server_pk.0, signer).into()],
        ..Default::default()
    });
    peer.send(&exchange).await.unwrap();
    let bytes = peer.next_timeout(1_000).await.expect("missing client key exchange").unwrap();
    let message = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
    let Some(rendezvous_message::Union::KeyExchange(exchange)) = message.union else {
        panic!("only key exchange may be sent before authentication");
    };
    assert_eq!(exchange.keys.len(), 2);
    let client_pk = box_::PublicKey(exchange.keys[0].as_ref().try_into().unwrap());
    let secret = box_::open(&exchange.keys[1], &box_::Nonce([0; box_::NONCEBYTES]),
        &client_pk, &server_sk).unwrap();
    peer.set_key(secretbox::Key(secret.as_slice().try_into().unwrap()));
}

#[test]
fn weak_network_account_handshake_hedges_safely_and_only_sends_token_after_verification() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(value: *const c_char) {
        if let Some(value) = cstr_to_string(value) { EVENTS.lock().unwrap().push(value); }
    }
    struct RestoreCallback(Option<EventCallback>);
    impl Drop for RestoreCallback {
        fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; }
    }
    EVENTS.lock().unwrap().clear();
    let _restore = RestoreCallback(EVENT_CALLBACK.lock().unwrap().replace(capture));
    runtime().block_on(async {
        let (sign_pk, sign_sk) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut original = Stream::from(socket, addr);
        let server = tokio::spawn(async move {
            let (socket, addr) = tokio::time::timeout(Duration::from_secs(1), listener.accept()).await.unwrap().unwrap();
            let mut backup = Stream::from(socket, addr);
            // Both sockets are open but neither may carry account data while
            // waiting for the signed server key.
            assert!(tokio::time::timeout(Duration::from_millis(15), original.next()).await.is_err());
            assert!(tokio::time::timeout(Duration::from_millis(15), backup.next()).await.is_err());
            accept_verified_test_handshake(&mut backup, &sign_sk).await;
            let bytes = backup.next_timeout(1_000).await.unwrap().unwrap();
            let request = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
            assert_eq!(request.punch_hole_request().token, "TEST_RETRY_TOKEN_DO_NOT_LOG");
            assert!(matches!(tokio::time::timeout(Duration::from_secs(1), original.next()).await,
                Ok(None) | Ok(Some(Err(_)))));
        });
        let mut winner = secure_rendezvous_with_retry_options(client, &endpoint.to_string(), &key,
            RendezvousHandshakeContext::Account, Duration::from_millis(20), 1_000, 1_000).await.unwrap();
        assert!(winner.is_secured());
        let mut request = punch_hole_request("test-peer", &key, ConnType::DEFAULT_CONN, false,
            NatType::UNKNOWN_NAT, 0, Vec::new(), String::new());
        api_account::attach(&mut request, "TEST_RETRY_TOKEN_DO_NOT_LOG");
        winner.send(&request).await.unwrap();
        server.await.unwrap();
    });
    let log = EVENTS.lock().unwrap().join("\n");
    assert!(log.contains("action=hedge original_pending=true"));
    assert!(log.contains("outcome=verified winner=2"));
    assert!(log.contains("context=account step=wait_server_key outcome=start"));
    for private in ["TEST_RETRY_TOKEN_DO_NOT_LOG", "test-peer", "127.0.0.1"] {
        assert!(!log.contains(private), "retry diagnostics exposed sensitive data");
    }
}

#[test]
fn weak_network_handshake_keeps_original_and_retries_transient_eof_without_downgrade() {
    runtime().block_on(async {
        let (sign_pk, sign_sk) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut original = Stream::from(socket, addr);
        let server = tokio::spawn(async move {
            let (socket, addr) = tokio::time::timeout(Duration::from_secs(1), listener.accept()).await.unwrap().unwrap();
            let backup = Stream::from(socket, addr);
            drop(backup); // Failure of the hedge must not cancel a viable original.
            accept_verified_test_handshake(&mut original, &sign_sk).await;
        });
        let winner = secure_rendezvous_with_retry_options(client, &endpoint.to_string(), &key,
            RendezvousHandshakeContext::Account, Duration::from_millis(20), 1_000, 1_000).await.unwrap();
        assert!(winner.is_secured());
        server.await.unwrap();

        let (sign_pk, sign_sk) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, _) = listener.accept().await.unwrap();
        drop(socket); // EOF triggers the backup immediately, not after the hedge delay.
        let server = tokio::spawn(async move {
            let (socket, addr) = tokio::time::timeout(Duration::from_millis(600), listener.accept()).await.unwrap().unwrap();
            let mut backup = Stream::from(socket, addr);
            accept_verified_test_handshake(&mut backup, &sign_sk).await;
        });
        let winner = secure_rendezvous_with_retry_options(client, &endpoint.to_string(), &key,
            RendezvousHandshakeContext::Account, Duration::from_secs(2), 1_000, 1_000).await.unwrap();
        assert!(winner.is_secured());
        server.await.unwrap();
    });
}

#[test]
fn invalid_handshake_does_not_retry_and_cancellation_closes_both_sockets() {
    runtime().block_on(async {
        let (sign_pk, _) = sign::gen_keypair();
        let (_, wrong_sign_sk) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut peer = Stream::from(socket, addr);
        let (server_pk, _) = box_::gen_keypair();
        let mut exchange = RendezvousMessage::new();
        exchange.set_key_exchange(KeyExchange { keys: vec![sign::sign(&server_pk.0, &wrong_sign_sk).into()], ..Default::default() });
        peer.send(&exchange).await.unwrap();
        let result = secure_rendezvous_with_retry_options(client, &endpoint.to_string(), &key,
            RendezvousHandshakeContext::Account, Duration::from_millis(300), 1_000, 1_000).await;
        assert!(matches!(result, Err(RendezvousHandshakeError::SignatureInvalid)));
        assert!(tokio::time::timeout(Duration::from_millis(80), listener.accept()).await.is_err());
        assert!(matches!(tokio::time::timeout(Duration::from_secs(1), peer.next()).await,
            Ok(None) | Ok(Some(Err(_)))));

        let (sign_pk, _) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut original = Stream::from(socket, addr);
        let server = tokio::spawn(async move {
            let (socket, addr) = tokio::time::timeout(Duration::from_secs(1), listener.accept()).await.unwrap().unwrap();
            let mut backup = Stream::from(socket, addr);
            assert!(matches!(tokio::time::timeout(Duration::from_secs(1), original.next()).await,
                Ok(None) | Ok(Some(Err(_)))));
            assert!(matches!(tokio::time::timeout(Duration::from_secs(1), backup.next()).await,
                Ok(None) | Ok(Some(Err(_)))));
        });
        let epoch = AtomicU64::new(1);
        let endpoint_name = endpoint.to_string();
        let attempt = secure_rendezvous_with_retry_options(client, &endpoint_name, &key,
            RendezvousHandshakeContext::Account, Duration::from_millis(20), 2_000, 1_000);
        let cancel = async {
            tokio::time::sleep(Duration::from_millis(120)).await;
            epoch.store(2, Ordering::SeqCst);
        };
        let (result, ()) = tokio::join!(await_connection_attempt(1, &epoch, Duration::from_secs(2), attempt), cancel);
        assert!(matches!(result, Err(ConnectionAttemptError::Cancelled)));
        server.await.unwrap();
    });
}

#[test]
fn invalid_backup_signature_cancels_pending_original_without_sending_credentials() {
    runtime().block_on(async {
        let (sign_pk, _) = sign::gen_keypair();
        let (_, wrong_sign_sk) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut original = Stream::from(socket, addr);
        let server = tokio::spawn(async move {
            let (socket, addr) = tokio::time::timeout(Duration::from_secs(1), listener.accept()).await.unwrap().unwrap();
            let mut backup = Stream::from(socket, addr);
            assert!(tokio::time::timeout(Duration::from_millis(15), backup.next()).await.is_err());
            let (server_pk, _) = box_::gen_keypair();
            let mut invalid = RendezvousMessage::new();
            invalid.set_key_exchange(KeyExchange { keys: vec![sign::sign(&server_pk.0, &wrong_sign_sk).into()], ..Default::default() });
            backup.send(&invalid).await.unwrap();
            assert!(matches!(tokio::time::timeout(Duration::from_secs(1), original.next()).await,
                Ok(None) | Ok(Some(Err(_)))));
            assert!(matches!(tokio::time::timeout(Duration::from_secs(1), backup.next()).await,
                Ok(None) | Ok(Some(Err(_)))));
        });
        let result = secure_rendezvous_with_retry_options(client, &endpoint.to_string(), &key,
            RendezvousHandshakeContext::Account, Duration::from_millis(20), 1_000, 1_000).await;
        assert!(matches!(result, Err(RendezvousHandshakeError::SignatureInvalid)));
        server.await.unwrap();
    });
}

#[test]
fn weak_network_path_diagnostics_do_not_serialize_errors_or_credentials() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(value: *const c_char) {
        if let Some(value) = cstr_to_string(value) { EVENTS.lock().unwrap().push(value); }
    }
    struct RestoreCallback(Option<EventCallback>);
    impl Drop for RestoreCallback {
        fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; }
    }
    EVENTS.lock().unwrap().clear();
    let _restore = RestoreCallback(EVENT_CALLBACK.lock().unwrap().replace(capture));
    runtime().block_on(async {
        let result = trace_direct_candidate("tcp", async {
            Err(hbb_common::anyhow::anyhow!("TEST_TOKEN_DO_NOT_LOG TEST_PASSWORD_DO_NOT_LOG TEST_SERVER_DO_NOT_LOG"))
        }).await;
        assert!(result.is_err());
    });
    let log = EVENTS.lock().unwrap().join("\n");
    assert!(log.contains("phase=direct_attempt kind=tcp action=start"));
    assert!(log.contains("phase=direct_attempt kind=tcp outcome=failed"));
    for private in ["TEST_TOKEN_DO_NOT_LOG", "TEST_PASSWORD_DO_NOT_LOG", "TEST_SERVER_DO_NOT_LOG"] {
        assert!(!log.contains(private));
    }
}

#[test]
fn udp_probe_overlaps_account_handshake_without_sending_token_or_applying_updates() {
    runtime().block_on(async {
        let (sign_pk, sign_sk) = sign::gen_keypair();
        let key = base64::encode(&sign_pk.0, Variant::Original);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        let udp = UdpSocket::bind(endpoint).await.unwrap();
        let client = connect_tcp(endpoint, 1_000).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut peer = Stream::from(socket, addr);
        let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
        let udp_server = tokio::spawn(async move {
            let mut bytes = [0_u8; 1500];
            let (size, source) = tokio::time::timeout(Duration::from_secs(1), udp.recv_from(&mut bytes)).await.unwrap().unwrap();
            let request = RendezvousMessage::parse_from_bytes(&bytes[..size]).unwrap();
            assert!(matches!(request.union, Some(rendezvous_message::Union::TestNatRequest(_))));
            let mut response = RendezvousMessage::new();
            response.set_test_nat_response(hbb_common::rendezvous_proto::TestNatResponse {
                port: 45678,
                cu: MessageField::some(hbb_common::rendezvous_proto::ConfigUpdate {
                    serial: 37, rendezvous_servers: vec!["test.example.invalid".to_string()],
                    ..Default::default()
                }),
                ..Default::default()
            });
            udp.send_to(&response.write_to_bytes().unwrap(), source).await.unwrap();
            seen_tx.send(()).unwrap();
        });
        let tcp_server = tokio::spawn(async move {
            // If preparation is accidentally serialized after authentication,
            // the server cannot send this key and the test times out.
            tokio::time::timeout(Duration::from_secs(1), seen_rx).await.unwrap().unwrap();
            accept_verified_test_handshake(&mut peer, &sign_sk).await;
        });
        let policy = TransportPreparationPolicy { udp_kcp: true, ipv6_kcp: false, webrtc: false };
        let (secured, (udp_candidate, ipv6_candidate)) = tokio::time::timeout(Duration::from_secs(2),
            prepare_authenticated_rendezvous(client, &endpoint.to_string(), &key, true, true, policy,
                GameTransportPolicy::Automatic)).await.unwrap().unwrap();
        assert!(secured.is_secured());
        let udp_candidate = udp_candidate.expect("missing UDP mapping");
        assert_eq!(udp_candidate.port, 45678);
        let update = udp_candidate.config_update.expect("public update should be deferred for the caller");
        assert_eq!(update.serial, 37);
        assert!(ipv6_candidate.is_none());
        udp_server.await.unwrap();
        tcp_server.await.unwrap();
    });
}

fn signed_identity(id: &str, pk: [u8; 32], signer: &sign::SecretKey) -> Vec<u8> {
    let payload = IdPk {
        id: id.into(),
        pk: pk.to_vec().into(),
        ..Default::default()
    };
    sign::sign(&payload.write_to_bytes().unwrap(), signer)
}

#[test]
fn secure_handshake_requires_consent_for_unsigned_peer() {
    runtime().block_on(async {
        let (rs_pk, rs_sk) = sign::gen_keypair();
        let (peer_pk, peer_sk) = sign::gen_keypair();
        let key = base64::encode(&rs_pk.0, Variant::Original);
        let signed = signed_identity("test-peer", peer_pk.0, &rs_sk);
        let (mut client, mut peer) = stream_pair().await;
        let (encryption_pk, _) = box_::gen_keypair();
        let mut message = PeerMessage::new();
        message.set_signed_id(SignedId {
            id: signed_identity("test-peer", encryption_pk.0, &peer_sk).into(),
            ..Default::default()
        });
        peer.send(&message).await.unwrap();
        secure_peer_connection("test-peer", &signed, &key, &mut client, INSECURE_NONE)
            .await
            .unwrap();
        assert!(client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        assert!(matches!(
            PeerMessage::parse_from_bytes(&response).unwrap().union,
            Some(message::Union::PublicKey(_))
        ));

        let (mut client, mut peer) = stream_pair().await;
        let error = secure_peer_connection("test-peer", &[], &key, &mut client, INSECURE_NONE)
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), MISSING_PEER_SIGNATURE);
        assert_eq!(peer_security_error_code(&error), -34);
        assert!(!client.is_secured());
        assert!(peer.next_timeout(30).await.is_none());

        for reason in [INSECURE_SERVER_KEY, INSECURE_DIRECT_ENDPOINT] {
            let (mut client, mut peer) = stream_pair().await;
            let error = secure_peer_connection("test-peer", &[], &key, &mut client, reason).await.unwrap_err();
            assert_eq!(error.to_string(), MISSING_PEER_SIGNATURE);
            assert!(peer.next_timeout(30).await.is_none());
            let (mut client, mut peer) = stream_pair().await;
            let error = secure_peer_connection("test-peer", &[], "invalid-key", &mut client,
                INSECURE_MISSING_SIGNATURE).await.unwrap_err();
            assert_eq!(error.to_string(), "invalid server key");
            assert!(peer.next_timeout(30).await.is_none());
        }

        let (mut client, mut peer) = stream_pair().await;
        assert!(!secure_peer_connection("test-peer", &[], &key, &mut client, INSECURE_MISSING_SIGNATURE)
            .await.unwrap());
        assert!(!client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        assert!(PeerMessage::parse_from_bytes(&response).unwrap().union.is_none());
    });
}

#[test]
fn direct_connection_requires_consent_before_opening_socket() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = std::ffi::CString::new(listener.local_addr().unwrap().to_string()).unwrap();
    for file_only in [0, 1] {
        for reason in [INSECURE_NONE, INSECURE_SERVER_KEY, INSECURE_MISSING_SIGNATURE, 99] {
            assert_eq!(rust_connect(address.as_ptr(), std::ptr::null(), std::ptr::null(),
                std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(),
                0, reason, file_only, 0, 0, std::ptr::null(), 1), -35);
            assert_eq!(listener.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
        }
    }
    assert_eq!(rust_connect(address.as_ptr(), std::ptr::null(), std::ptr::null(),
        std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(),
        0, INSECURE_DIRECT_ENDPOINT, 0, 0, 0, std::ptr::null(), 1), 0);
    assert!(listener.accept().is_ok());
    rust_disconnect();
}

#[test]
fn delay_samples_are_atomic_fresh_and_never_taken_from_file_transfer() {
    let previous_sample = CONNECTION_DELAY_SAMPLE.swap(0, Ordering::SeqCst);
    let previous_delay = CONNECTION_DELAY_MS.swap(0, Ordering::SeqCst);
    let previous_bitrate = CONNECTION_TARGET_BITRATE_KB.swap(0, Ordering::SeqCst);
    runtime().block_on(async {
        let (mut client, _peer) = stream_pair().await;
        let mut delay = TestDelay::new();
        delay.last_delay = 1400;
        delay.target_bitrate = 1000;
        send_test_delay_response(delay.clone(), &mut client, false).await;
        assert_eq!(rust_get_connection_delay_sample(), 0, "file transfer must not pollute control-session quality");
        send_test_delay_response(delay.clone(), &mut client, true).await;
        assert_eq!(rust_get_connection_delay_sample(), (1_u64 << 32) | 1400);
        send_test_delay_response(delay.clone(), &mut client, true).await;
        assert_eq!(rust_get_connection_delay_sample(), (2_u64 << 32) | 1400, "equal values can still be fresh samples");
        delay.from_client = true;
        send_test_delay_response(delay, &mut client, true).await;
        assert_eq!(rust_get_connection_delay_sample(), (2_u64 << 32) | 1400);
    });
    CONNECTION_DELAY_SAMPLE.store(previous_sample, Ordering::SeqCst);
    CONNECTION_DELAY_MS.store(previous_delay, Ordering::SeqCst);
    CONNECTION_TARGET_BITRATE_KB.store(previous_bitrate, Ordering::SeqCst);
}

#[test]
fn signature_diagnostics_record_only_kind_and_presence() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(value: *const c_char) {
        if let Some(value) = cstr_to_string(value) { EVENTS.lock().unwrap().push(value); }
    }
    struct Restore(Option<EventCallback>);
    impl Drop for Restore { fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; } }
    let _restore = Restore(EVENT_CALLBACK.lock().unwrap().replace(capture));
    EVENTS.lock().unwrap().clear();
    let mut signed = RendezvousMessage::new();
    signed.set_punch_hole_response(hbb_common::rendezvous_proto::PunchHoleResponse {
        pk: b"TEST_PRIVATE_SIGNATURE".to_vec().into(),
        other_failure: "TEST_PRIVATE_RESPONSE".into(), ..Default::default()
    });
    log_peer_signature_response("control", &signed.union);
    let mut unsigned = RendezvousMessage::new();
    unsigned.set_relay_response(hbb_common::rendezvous_proto::RelayResponse::default());
    log_peer_signature_response("file", &unsigned.union);
    let log = EVENTS.lock().unwrap().join("\n");
    assert!(log.contains("context=control response=punch_hole_response signature_present=true"));
    assert!(log.contains("context=file response=relay_response signature_present=false"));
    assert!(!log.contains("TEST_PRIVATE_SIGNATURE"));
    assert!(!log.contains("TEST_PRIVATE_RESPONSE"));
}

#[test]
fn unsigned_file_only_session_reports_specific_error_without_sending_login() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(value: *const c_char) {
        if let Some(value) = cstr_to_string(value) { EVENTS.lock().unwrap().push(value); }
    }
    struct Restore(Option<EventCallback>);
    impl Drop for Restore { fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; } }
    let _restore = Restore(EVENT_CALLBACK.lock().unwrap().replace(capture));
    EVENTS.lock().unwrap().clear();
    let session_id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    FILE_ONLY_SESSION.store(true, Ordering::SeqCst);
    INSECURE_SESSION_REASON.store(INSECURE_NONE, Ordering::SeqCst);
    runtime().block_on(async {
        let rendezvous = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let rv_addr = rendezvous.local_addr().unwrap();
        let relay_addr = relay.local_addr().unwrap();
        let rendezvous_task = tokio::spawn(async move {
            let (socket, address) = rendezvous.accept().await.unwrap();
            let mut stream = Stream::from(socket, address);
            assert!(stream.next_timeout(1000).await.unwrap().is_ok());
            let mut response = RendezvousMessage::new();
            response.set_relay_response(hbb_common::rendezvous_proto::RelayResponse {
                relay_server: relay_addr.to_string(), uuid: "test-uuid".into(), ..Default::default()
            });
            stream.send(&response).await.unwrap();
        });
        let relay_task = tokio::spawn(async move {
            let (socket, address) = relay.accept().await.unwrap();
            let mut stream = Stream::from(socket, address);
            let create = stream.next_timeout(1000).await.unwrap().unwrap();
            assert!(matches!(RendezvousMessage::parse_from_bytes(&create).unwrap().union,
                Some(rendezvous_message::Union::RequestRelay(_))));
            assert!(!matches!(stream.next_timeout(500).await, Some(Ok(_))),
                "unsigned file session sent handshake or login data");
        });
        let config = ConnectionConfig {
            public_server: false, peer: "test-file-peer".into(), password: "private-file-password".into(),
            rendezvous_addr: rv_addr.to_string(), relay_override: String::new(), key: String::new(),
            client_hwid: Vec::new(), client_id: "test".into(), os_password: String::new(),
        };
        let (_sender, receiver) = mpsc::channel();
        tokio::time::timeout(Duration::from_secs(3), run_file_session(session_id, config, receiver)).await.unwrap();
        rendezvous_task.await.unwrap();
        relay_task.await.unwrap();
    });
    let log = EVENTS.lock().unwrap().join("\n");
    assert!(log.contains("context=file response=relay_response signature_present=false"));
    assert!(log.contains("file-only session security_signature_missing"));
    assert!(!log.contains("private-file-password"));
    assert!(REMOTE_DIRECTORY_RESULT.lock().unwrap().contains("文件连接缺少远端身份签名"));
    FILE_ONLY_SESSION.store(false, Ordering::SeqCst);
}

#[test]
fn invalid_identity_never_downgrades_or_sends_public_key() {
    runtime().block_on(async {
        let (rs_pk, rs_sk) = sign::gen_keypair();
        let (peer_pk, peer_sk) = sign::gen_keypair();
        let key = base64::encode(&rs_pk.0, Variant::Original);
        let signed = signed_identity("test-peer", peer_pk.0, &rs_sk);
        for scenario in 0..7 {
            let (mut client, mut peer) = stream_pair().await;
            let mut server_signed = signed.clone();
            let mut server_key = key.clone();
            match scenario {
                0 => server_key = "invalid-key".into(),
                1 => server_signed[0] ^= 1,
                2 => server_signed = signed_identity("wrong-peer", peer_pk.0, &rs_sk),
                3 => peer.send(&PeerMessage::new()).await.unwrap(),
                4 => peer.send_raw(vec![0xff]).await.unwrap(),
                5 | 6 => {
                    let mut id = signed_identity(
                        if scenario == 5 {
                            "wrong-peer"
                        } else {
                            "test-peer"
                        },
                        peer_pk.0,
                        &peer_sk,
                    );
                    if scenario == 6 {
                        id[0] ^= 1;
                    }
                    let mut message = PeerMessage::new();
                    message.set_signed_id(SignedId {
                        id: id.into(),
                        ..Default::default()
                    });
                    peer.send(&message).await.unwrap();
                }
                _ => unreachable!(),
            }
            assert!(
                secure_peer_connection(
                    "test-peer",
                    &server_signed,
                    &server_key,
                    &mut client,
                    INSECURE_NONE
                )
                .await
                .is_err(),
                "scenario {scenario}"
            );
            assert!(!client.is_secured());
            // A failed identity check must not emit a compatibility/downgrade message.
            assert!(
                peer.next_timeout(30).await.is_none(),
                "scenario {scenario} sent data"
            );
        }
    });
}

#[test]
fn invalid_server_key_downgrades_only_after_explicit_one_time_approval() {
    runtime().block_on(async {
        let (mut client, mut peer) = stream_pair().await;
        secure_peer_connection("test-peer", &[], "invalid-key", &mut client, INSECURE_SERVER_KEY)
            .await
            .unwrap();
        assert!(!client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        let message = PeerMessage::parse_from_bytes(&response).unwrap();
        assert!(message.union.is_none());

        let (configured_pk, _) = sign::gen_keypair();
        let (_, actual_sk) = sign::gen_keypair();
        let configured_key = base64::encode(&configured_pk.0, Variant::Original);
        let (peer_pk, _) = sign::gen_keypair();
        let signed = signed_identity("test-peer", peer_pk.0, &actual_sk);
        let (mut client, mut peer) = stream_pair().await;
        secure_peer_connection("test-peer", &signed, &configured_key, &mut client, INSECURE_SERVER_KEY)
            .await
            .unwrap();
        assert!(!client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        let message = PeerMessage::parse_from_bytes(&response).unwrap();
        assert!(message.union.is_none());
    });
}
