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
        assert!(secure_rendezvous_connection(&mut client, &key).await.is_err());
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
        secure_rendezvous_connection(&mut client, &key).await.unwrap();
        assert!(client.is_secured());
        let response = server.next_timeout(1000).await.unwrap().unwrap();
        assert!(matches!(RendezvousMessage::parse_from_bytes(&response).unwrap().union,
            Some(rendezvous_message::Union::KeyExchange(_))));
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
fn secure_handshake_valid_and_unsigned_compatibility() {
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
        secure_peer_connection("test-peer", &signed, &key, &mut client, false)
            .await
            .unwrap();
        assert!(client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        assert!(matches!(
            PeerMessage::parse_from_bytes(&response).unwrap().union,
            Some(message::Union::PublicKey(_))
        ));

        let (mut client, mut peer) = stream_pair().await;
        secure_peer_connection("test-peer", &[], &key, &mut client, false)
            .await
            .unwrap();
        assert!(!client.is_secured());
        assert!(peer.next_timeout(1000).await.is_some());
    });
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
                    false
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
        secure_peer_connection("test-peer", &[], "invalid-key", &mut client, true)
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
        secure_peer_connection("test-peer", &signed, &configured_key, &mut client, true)
            .await
            .unwrap();
        assert!(!client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        let message = PeerMessage::parse_from_bytes(&response).unwrap();
        assert!(message.union.is_none());
    });
}
