use super::*;
use hbb_common::rendezvous_proto::{ConfigUpdate, OnlineResponse};

#[test]
fn ip_literals_use_direct_listener_and_preserve_explicit_ports() {
    for (input, expected) in [
        ("192.0.2.8", "192.0.2.8:21118"),
        (" 192.0.2.8:32100 ", "192.0.2.8:32100"),
        ("::1", "[::1]:21118"),
        ("[::1]", "[::1]:21118"),
        ("[2001:db8::1]:32100", "[2001:db8::1]:32100"),
        ("2001:db8::2111", "[2001:db8::2111]:21118"),
        ("[::ffff:192.0.2.8]:65535", "[::ffff:192.0.2.8]:65535"),
    ] {
        assert_eq!(direct_peer_addr(input).unwrap_or_else(|error| panic!("literal {input:?}: {error}")),
            Some(expected.parse::<SocketAddr>().unwrap_or_else(|error| panic!("expected {expected:?}: {error}"))), "{input}");
    }
    for id in ["123456789", "test-peer", "custom.id"] {
        assert_eq!(direct_peer_addr(id).unwrap(), None);
    }
}

#[test]
fn malformed_literals_never_become_rendezvous_ids() {
    for input in ["", "192.0.2.8:0", "[::1]:0", "[::1]:65536", "192.0.2.8:65536",
        "192.0.2.8:abc", "[::1", "[::1]:", "[not-an-ip]", "999.1.2.3", "1.2.3", "::gg",
        "2001:db8::21118"] {
        assert!(direct_peer_addr(input).is_err(), "{input}");
    }
}

#[test]
fn retry_guard_endpoint_forms_never_select_id_rendezvous() {
    // Matches the service/page exclusion guard, not just valid IP parsing.
    for endpoint in ["192.0.2.8", "192.0.2.8:21118", "999.1.2.3", "192.0.2.8:0",
        "::1", "[::1]", "[::1]:21118", "[fe80::1%3]:21118", "fe80::1%wlan0",
        "[::ffff:192.0.2.8]:21118", "[bad]", "bad:port", "[::1", "1.2.3"] {
        assert!(!matches!(direct_peer_addr(endpoint), Ok(None)), "routed endpoint {endpoint:?} as an ID");
    }
    for id in ["123456789", "test-peer", "custom.id"] {
        assert!(matches!(direct_peer_addr(id), Ok(None)), "blocked ID {id:?}");
    }
    let invalid = CString::new("192.0.2.8:0").unwrap();
    let null = std::ptr::null();
    assert_eq!(rust_connect(invalid.as_ptr(), null, null, null, null, null, null, 0), -23);
}

#[test]
fn public_access_key_and_peer_password_are_separate() {
    let public_key = default_server_key("", "");
    assert_eq!(public_key, RS_PUB_KEY);
    assert!(get_rs_pk(&public_key).is_some());
    assert_eq!(default_server_key("  ", ""), RS_PUB_KEY);
    assert_eq!(default_server_key("private.example", ""), "");
    for server in ["", "private.example", "192.0.2.8:21116"] {
        for key in ["explicit-custom-key", "invalid-key", RS_PUB_KEY] {
            assert_eq!(default_server_key(server, key), key);
        }
    }
    for conn_type in [ConnType::DEFAULT_CONN, ConnType::FILE_TRANSFER] {
        for force_relay in [false, true] {
            let message = punch_hole_request("test-peer", &public_key, conn_type, force_relay);
            let bytes = message.write_to_bytes().unwrap();
            let parsed = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
            let Some(rendezvous_message::Union::PunchHoleRequest(request)) = parsed.union else { panic!("expected PunchHoleRequest") };
            assert_eq!(request.licence_key, RS_PUB_KEY);
            assert!(request.token.is_empty());
            assert_eq!(request.id, "test-peer");
            assert_eq!(request.conn_type.enum_value().unwrap(), conn_type);
            assert_eq!(request.force_relay, force_relay);
        }
    }
}

#[test]
fn public_bootstrap_and_online_port_match_upstream_without_overriding_custom_servers() {
    assert_eq!(default_rendezvous_addr(""), "rs-ny.rustdesk.com:21116");
    assert_eq!(default_rendezvous_addr("  "), default_rendezvous_addr(""));
    assert_eq!(online_query_addr(""), "rs-ny.rustdesk.com:21115");
    for (input, connection, online) in [
        ("private.example", "private.example:21116", "private.example:21115"),
        (" private.example:32116 ", "private.example:32116", "private.example:32115"),
        ("192.0.2.8:32116", "192.0.2.8:32116", "192.0.2.8:32115"),
        ("2001:db8::8", "[2001:db8::8]:21116", "[2001:db8::8]:21115"),
        ("[2001:db8::8]:32116", "[2001:db8::8]:32116", "[2001:db8::8]:32115"),
        // Even this explicit legacy hostname is user configuration, not a default.
        ("rustdesk.com", "rustdesk.com:21116", "rustdesk.com:21115"),
    ] {
        assert_eq!(default_rendezvous_addr(input), connection);
        assert_eq!(online_query_addr(input), online);
    }
}

async fn check_direct_listener(host: &str, file_session: bool) {
    let listener = match tokio::net::TcpListener::bind(host).await {
        Ok(listener) => listener,
        Err(error) if host.starts_with('[') => {
            eprintln!("IPv6 loopback unavailable: {error}");
            return;
        }
        Err(error) => panic!("loopback bind failed: {error}"),
    };
    let address = listener.local_addr().unwrap();
    let mut client = if file_session {
        let config = ConnectionConfig {
            peer: address.to_string(), password: String::new(),
            // These must never be resolved/contacted for a literal peer.
            rendezvous_addr: "invalid-rendezvous.invalid:1".into(),
            relay_override: "invalid-relay.invalid:1".into(),
            key: "not-a-server-key".into(), client_hwid: Vec::new(), client_id: "test".into(),
        };
        connect_file_stream(&config).await.unwrap()
    } else {
        connect_ip_literal(address).await.unwrap()
    };
    let (socket, address) = listener.accept().await.unwrap();
    let mut peer = Stream::from(socket, address);
    assert!(!client.is_secured()); // Explicit IP protocol, not a signed-ID downgrade.
    assert!(peer.next_timeout(30).await.is_none(), "unexpected rendezvous or handshake data");
    let mut challenge = PeerMessage::new();
    challenge.set_hash(Hash { salt: "test-salt".into(), challenge: "test-challenge".into(), ..Default::default() });
    peer.send(&challenge).await.unwrap();
    let received = client.next_timeout(1000).await.unwrap().unwrap();
    assert!(matches!(PeerMessage::parse_from_bytes(&received).unwrap().union, Some(message::Union::Hash(_))));
}

#[test]
fn direct_ipv4_ipv6_and_file_sessions_preserve_login_challenge() {
    runtime().block_on(async {
        for host in ["127.0.0.1:0", "[::1]:0"] {
            check_direct_listener(host, false).await;
            check_direct_listener(host, true).await;
        }
    });
}

#[test]
fn connection_deadline_and_cancellation_drop_inflight_attempt() {
    struct DropMarker<'a>(&'a AtomicBool);
    impl Drop for DropMarker<'_> {
        fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); }
    }
    runtime().block_on(async {
        let current = AtomicU64::new(2);
        let polled = AtomicBool::new(false);
        assert_eq!(await_connection_attempt(1, &current, Duration::from_secs(1), async {
            polled.store(true, Ordering::SeqCst);
        }).await, Err(ConnectionAttemptError::Cancelled));
        assert!(!polled.load(Ordering::SeqCst));
        for cancel in [false, true] {
            let current = AtomicU64::new(1);
            let dropped = AtomicBool::new(false);
            let attempt = async {
                let _marker = DropMarker(&dropped);
                std::future::pending::<()>().await;
            };
            let change = async {
                tokio::time::sleep(Duration::from_millis(10)).await;
                if cancel { current.store(2, Ordering::SeqCst); }
            };
            let limit = if cancel { Duration::from_secs(1) } else { Duration::from_millis(30) };
            let (result, ()) = tokio::join!(await_connection_attempt(1, &current, limit, attempt), change);
            assert_eq!(result, Err(if cancel { ConnectionAttemptError::Cancelled } else { ConnectionAttemptError::Deadline }));
            assert!(dropped.load(Ordering::SeqCst));
        }
        assert_eq!(await_connection_attempt(2, &current, Duration::from_secs(1), async { 7 }).await, Ok(7));
    });
    assert_eq!(CONNECTION_DEADLINE, Duration::from_secs(28));
    assert_eq!(SERVER_CONNECT_TIMEOUT, 8_000);
    assert_eq!(ONLINE_QUERY_DEADLINE, Duration::from_secs(10));
}

#[test]
fn skipped_rendezvous_messages_do_not_restart_read_deadline() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut client = connect_tcp(address, 1000).await.unwrap();
        let (socket, address) = listener.accept().await.unwrap();
        let writer = tokio::spawn(async move {
            let mut peer = Stream::from(socket, address);
            let mut message = RendezvousMessage::new();
            message.set_configure_update(ConfigUpdate::new());
            loop {
                if peer.send(&message).await.is_err() { break; }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        });
        let result = tokio::time::timeout(Duration::from_secs(1), next_rendezvous(&mut client, 40)).await;
        writer.abort();
        let _ = writer.await;
        assert!(result.unwrap().is_none());
    });
}

#[test]
fn online_queries_exclude_ip_literals_and_reject_truncated_bitmaps() {
    runtime().block_on(async {
        assert!(query_peer_online_states(vec!["127.0.0.1".into(), "[::1]:21118".into()],
            "invalid-rendezvous.invalid:1".into(), "test".into()).await.unwrap().is_empty());
        for truncated in [false, true] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (socket, address) = listener.accept().await.unwrap();
                let mut peer = Stream::from(socket, address);
                let bytes = peer.next_timeout(1000).await.unwrap().unwrap();
                let request = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
                let Some(rendezvous_message::Union::OnlineRequest(request)) = request.union else { panic!("expected OnlineRequest") };
                assert_eq!(request.peers, vec!["123456789", "987654321"]);
                let mut response = RendezvousMessage::new();
                response.set_online_response(OnlineResponse {
                    states: (if truncated { vec![] } else { vec![0x80] }).into(),
                    ..Default::default()
                });
                peer.send(&response).await.unwrap();
            });
            let result = query_peer_online_states(vec!["127.0.0.1".into(), "123456789".into(),
                "[::1]:21118".into(), "987654321".into()], address.to_string(), "test".into()).await;
            server.await.unwrap();
            if truncated {
                assert!(result.err().unwrap().contains("truncated"));
            } else {
                let states = result.unwrap();
                assert_eq!(states.len(), 2);
                assert!(states[0].online);
                assert!(!states[1].online);
            }
        }
    });
}
