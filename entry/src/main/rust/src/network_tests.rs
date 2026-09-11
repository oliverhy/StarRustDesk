use super::*;
use hbb_common::rendezvous_proto::{ConfigUpdate, OnlineResponse};

#[test]
fn multi_display_frames_only_reach_the_selected_surface() {
    assert!(should_forward_video_display(1, 1, true));
    assert!(!should_forward_video_display(0, 1, true));
    assert!(!should_forward_video_display(2, 1, true));
}

#[test]
fn legacy_peers_without_display_tags_keep_video_compatible() {
    assert!(should_forward_video_display(0, 2, false));
}

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
        assert_eq!(
            direct_peer_addr(input).unwrap_or_else(|error| panic!("literal {input:?}: {error}")),
            Some(
                expected
                    .parse::<SocketAddr>()
                    .unwrap_or_else(|error| panic!("expected {expected:?}: {error}"))
            ),
            "{input}"
        );
    }
    for id in ["123456789", "test-peer", "custom.id"] {
        assert_eq!(direct_peer_addr(id).unwrap(), None);
    }
}

#[test]
fn malformed_literals_never_become_rendezvous_ids() {
    for input in [
        "",
        "192.0.2.8:0",
        "[::1]:0",
        "[::1]:65536",
        "192.0.2.8:65536",
        "192.0.2.8:abc",
        "[::1",
        "[::1]:",
        "[not-an-ip]",
        "999.1.2.3",
        "1.2.3",
        "::gg",
        "2001:db8::21118",
    ] {
        assert!(direct_peer_addr(input).is_err(), "{input}");
    }
}

#[test]
fn retry_guard_endpoint_forms_never_select_id_rendezvous() {
    // Matches the service/page exclusion guard, not just valid IP parsing.
    for endpoint in [
        "192.0.2.8",
        "192.0.2.8:21118",
        "999.1.2.3",
        "192.0.2.8:0",
        "::1",
        "[::1]",
        "[::1]:21118",
        "[fe80::1%3]:21118",
        "fe80::1%wlan0",
        "[::ffff:192.0.2.8]:21118",
        "[bad]",
        "bad:port",
        "[::1",
        "1.2.3",
    ] {
        assert!(
            !matches!(direct_peer_addr(endpoint), Ok(None)),
            "routed endpoint {endpoint:?} as an ID"
        );
    }
    for id in ["123456789", "test-peer", "custom.id"] {
        assert!(
            matches!(direct_peer_addr(id), Ok(None)),
            "blocked ID {id:?}"
        );
    }
    let invalid = CString::new("192.0.2.8:0").unwrap();
    let null = std::ptr::null();
    assert_eq!(
        rust_connect(invalid.as_ptr(), null, null, null, null, null, null, 0, 0),
        -23
    );
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
            let message = punch_hole_request(
                "test-peer",
                &public_key,
                conn_type,
                force_relay,
                NatType::ASYMMETRIC,
                40000,
                vec![1, 2, 3],
                "webrtc://offer".to_string(),
            );
            let bytes = message.write_to_bytes().unwrap();
            let parsed = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
            let Some(rendezvous_message::Union::PunchHoleRequest(request)) = parsed.union else {
                panic!("expected PunchHoleRequest")
            };
            assert_eq!(request.licence_key, RS_PUB_KEY);
            assert!(request.token.is_empty());
            assert_eq!(request.id, "test-peer");
            assert_eq!(request.conn_type.enum_value().unwrap(), conn_type);
            assert_eq!(request.force_relay, force_relay);
            assert_eq!(request.nat_type.enum_value().unwrap(), NatType::ASYMMETRIC);
            assert_eq!(request.version, RUSTDESK_PROTOCOL_VERSION);
            assert_eq!(request.udp_port, 40000);
            assert_eq!(request.socket_addr_v6.as_ref(), &[1, 2, 3]);
            assert_eq!(request.webrtc_sdp_offer, "webrtc://offer");
        }
    }
}

#[test]
fn official_public_server_candidates_do_not_override_custom_configuration() {
    let public = rendezvous_candidates("");
    assert!(!public.is_empty());
    assert!(public.iter().all(|server| server.ends_with(":21116")));
    assert!(public.contains(&"rs-ny.rustdesk.com:21116".to_string()));
    assert_eq!(
        rendezvous_candidates("private.example:32116"),
        vec!["private.example:32116".to_string()]
    );
}

#[test]
fn websocket_fallbacks_match_rustdesk_rendezvous_and_relay_routes() {
    assert_eq!(
        websocket_fallback_candidates("192.0.2.8:21116", EndpointRole::Rendezvous),
        vec!["ws://192.0.2.8:21118"]
    );
    assert_eq!(
        websocket_fallback_candidates("[2001:db8::8]:21117", EndpointRole::Relay),
        vec!["ws://[2001:db8::8]:21119"]
    );
    assert_eq!(
        websocket_fallback_candidates("example.com:21116", EndpointRole::Rendezvous),
        vec![
            "wss://example.com/ws/id",
            "ws://example.com:21118/ws/id",
            "ws://example.com/ws/id",
        ]
    );
    assert_eq!(
        websocket_fallback_candidates("example.com:21117", EndpointRole::Relay),
        vec![
            "wss://example.com/ws/relay",
            "ws://example.com:21119/ws/relay",
            "ws://example.com/ws/relay",
        ]
    );
    assert!(
        websocket_fallback_candidates("wss://example.com/ws/id", EndpointRole::Rendezvous)
            .is_empty()
    );
}

#[test]
fn udp_punch_probe_is_transaction_bound_and_rejects_other_packets() {
    let transaction = 0x8877_6655_4433_2211;
    let probe = punch_packet(&PUNCH_PROBE, transaction);
    let ack = punch_packet(&PUNCH_ACK, transaction);
    assert_eq!(punch_transaction(&probe, &PUNCH_PROBE), Some(transaction));
    assert_eq!(punch_transaction(&ack, &PUNCH_ACK), Some(transaction));
    assert_eq!(punch_transaction(&probe, &PUNCH_ACK), None);
    assert_eq!(
        punch_transaction(&ack[..PUNCH_PACKET_LEN - 1], &PUNCH_ACK),
        None
    );
}

#[test]
fn rendezvous_refusals_are_logged_as_safe_categories() {
    assert_eq!(classify_rendezvous_refusal(""), "none");
    assert_eq!(
        classify_rendezvous_refusal("Please update client"),
        "client_version"
    );
    assert_eq!(classify_rendezvous_refusal("too frequent"), "rate_limit");
    assert_eq!(
        classify_rendezvous_refusal("invalid licence key"),
        "server_key"
    );
    assert_eq!(classify_rendezvous_refusal("internal detail"), "other");
}

#[test]
fn official_direct_timeout_preserves_relay_fallback_responsiveness() {
    assert_eq!(
        official_direct_timeout(true, NatType::ASYMMETRIC, NatType::ASYMMETRIC, true, 0),
        LOCAL_DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        official_direct_timeout(false, NatType::SYMMETRIC, NatType::ASYMMETRIC, true, 0),
        LOCAL_DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        official_direct_timeout(false, NatType::ASYMMETRIC, NatType::ASYMMETRIC, true, 0),
        DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        official_direct_timeout(false, NatType::UNKNOWN_NAT, NatType::UNKNOWN_NAT, true, 0),
        DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        official_direct_timeout(false, NatType::UNKNOWN_NAT, NatType::UNKNOWN_NAT, false, 2),
        DIRECT_ONLY_CONNECT_TIMEOUT
    );
    assert_eq!(
        official_direct_timeout(false, NatType::ASYMMETRIC, NatType::ASYMMETRIC, true, 1),
        LOCAL_DIRECT_CONNECT_TIMEOUT
    );
}

#[test]
fn peer_route_history_learns_failures_without_storing_plain_peer_ids() {
    let now = 10_000;
    let peer = "123456789";
    let key = peer_route_history_key(peer);
    assert_ne!(key, peer);
    assert_eq!(key.len(), 24);

    let mut history = BTreeMap::new();
    assert_eq!(apply_peer_direct_failure(&mut history, key.clone(), now), 1);
    assert_eq!(
        apply_peer_direct_failure(&mut history, key.clone(), now + 1),
        2
    );
    assert_eq!(recent_direct_failures(history.get(&key), now + 2), 2);

    let relay = apply_peer_route_success(&mut history, key.clone(), 2, TRANSPORT_TCP, now + 3);
    assert_eq!(relay.direct_failures, 2);
    assert_eq!(recent_direct_failures(history.get(&key), now + 4), 2);

    let direct = apply_peer_route_success(&mut history, key.clone(), 1, TRANSPORT_UDP_KCP, now + 5);
    assert_eq!(direct.direct_failures, 0);
    assert_eq!(direct.direct_failure_ms, 0);
    assert_eq!(recent_direct_failures(history.get(&key), now + 6), 0);
}

#[test]
fn peer_route_history_expires_and_stays_bounded() {
    let now = PEER_ROUTE_HISTORY_TTL_MS + 1_000;
    let stale = PeerRouteRecord {
        direct_failures: 2,
        direct_failure_ms: 1,
        updated_ms: 1,
        ..Default::default()
    };
    assert_eq!(recent_direct_failures(Some(&stale), now), 0);

    let mut history = BTreeMap::new();
    history.insert("stale".to_string(), stale);
    for index in 0..(PEER_ROUTE_HISTORY_MAX_ENTRIES + 5) {
        history.insert(
            format!("peer-{index:03}"),
            PeerRouteRecord {
                updated_ms: now + index as u64,
                ..Default::default()
            },
        );
    }
    prune_peer_route_history(
        &mut history,
        now + PEER_ROUTE_HISTORY_MAX_ENTRIES as u64 + 5,
    );
    assert_eq!(history.len(), PEER_ROUTE_HISTORY_MAX_ENTRIES);
    assert!(!history.contains_key("stale"));
    assert!(!history.contains_key("peer-000"));
    assert!(history.contains_key("peer-132"));
}

#[test]
fn official_quality_monitor_uses_peer_delay_and_target_bitrate() {
    let mut peer_probe = TestDelay::new();
    peer_probe.from_client = false;
    peer_probe.last_delay = 86;
    peer_probe.target_bitrate = 2048;
    assert_eq!(test_delay_quality_values(&peer_probe), Some((86, 2048)));

    peer_probe.last_delay = u32::MAX;
    peer_probe.target_bitrate = u32::MAX;
    assert_eq!(
        test_delay_quality_values(&peer_probe),
        Some((i32::MAX, i32::MAX))
    );

    peer_probe.from_client = true;
    assert_eq!(test_delay_quality_values(&peer_probe), None);
}

#[test]
fn extended_transports_never_block_the_custom_or_forced_relay_fast_path() {
    assert_eq!(
        transport_preparation_policy(false, false),
        TransportPreparationPolicy {
            udp_kcp: true,
            ipv6_kcp: true,
            webrtc: false,
        }
    );
    assert_eq!(
        transport_preparation_policy(true, false),
        TransportPreparationPolicy {
            udp_kcp: true,
            ipv6_kcp: true,
            webrtc: true,
        }
    );
    assert_eq!(
        transport_preparation_policy(true, true),
        TransportPreparationPolicy {
            udp_kcp: false,
            ipv6_kcp: false,
            webrtc: false,
        }
    );
    assert_eq!(UDP_NAT_TEST_TIMEOUT, Duration::from_millis(300));
    assert_eq!(IPV6_PREPARATION_TIMEOUT, 300);
    assert_eq!(WEBRTC_OFFER_TIMEOUT, 500);
    assert_eq!(PUNCH_REPLY_TIMEOUTS, [1_500, 2_500, 4_000]);
}

#[test]
fn public_bootstrap_and_online_port_match_upstream_without_overriding_custom_servers() {
    assert_eq!(default_rendezvous_addr(""), "rs-ny.rustdesk.com:21116");
    assert_eq!(default_rendezvous_addr("  "), default_rendezvous_addr(""));
    assert_eq!(online_query_addr(""), "rs-ny.rustdesk.com:21115");
    for (input, connection, online) in [
        (
            "private.example",
            "private.example:21116",
            "private.example:21115",
        ),
        (
            " private.example:32116 ",
            "private.example:32116",
            "private.example:32115",
        ),
        ("192.0.2.8:32116", "192.0.2.8:32116", "192.0.2.8:32115"),
        ("2001:db8::8", "[2001:db8::8]:21116", "[2001:db8::8]:21115"),
        (
            "[2001:db8::8]:32116",
            "[2001:db8::8]:32116",
            "[2001:db8::8]:32115",
        ),
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
            peer: address.to_string(),
            password: String::new(),
            // These must never be resolved/contacted for a literal peer.
            rendezvous_addr: "invalid-rendezvous.invalid:1".into(),
            relay_override: "invalid-relay.invalid:1".into(),
            key: "not-a-server-key".into(),
            client_hwid: Vec::new(),
            client_id: "test".into(),
        };
        connect_file_stream(&config).await.unwrap()
    } else {
        connect_ip_literal(address).await.unwrap()
    };
    let (socket, address) = listener.accept().await.unwrap();
    let mut peer = Stream::from(socket, address);
    assert!(!client.is_secured()); // Explicit IP protocol, not a signed-ID downgrade.
    assert!(
        peer.next_timeout(30).await.is_none(),
        "unexpected rendezvous or handshake data"
    );
    let mut challenge = PeerMessage::new();
    challenge.set_hash(Hash {
        salt: "test-salt".into(),
        challenge: "test-challenge".into(),
        ..Default::default()
    });
    peer.send(&challenge).await.unwrap();
    let received = client.next_timeout(1000).await.unwrap().unwrap();
    assert!(matches!(
        PeerMessage::parse_from_bytes(&received).unwrap().union,
        Some(message::Union::Hash(_))
    ));
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
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }
    runtime().block_on(async {
        let current = AtomicU64::new(2);
        let polled = AtomicBool::new(false);
        assert_eq!(
            await_connection_attempt(1, &current, Duration::from_secs(1), async {
                polled.store(true, Ordering::SeqCst);
            })
            .await,
            Err(ConnectionAttemptError::Cancelled)
        );
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
                if cancel {
                    current.store(2, Ordering::SeqCst);
                }
            };
            let limit = if cancel {
                Duration::from_secs(1)
            } else {
                Duration::from_millis(30)
            };
            let (result, ()) = tokio::join!(
                await_connection_attempt(1, &current, limit, attempt),
                change
            );
            assert_eq!(
                result,
                Err(if cancel {
                    ConnectionAttemptError::Cancelled
                } else {
                    ConnectionAttemptError::Deadline
                })
            );
            assert!(dropped.load(Ordering::SeqCst));
        }
        assert_eq!(
            await_connection_attempt(2, &current, Duration::from_secs(1), async { 7 }).await,
            Ok(7)
        );
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
                if peer.send(&message).await.is_err() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        });
        let result =
            tokio::time::timeout(Duration::from_secs(1), next_rendezvous(&mut client, 40)).await;
        writer.abort();
        let _ = writer.await;
        assert!(result.unwrap().is_none());
    });
}

#[test]
fn online_queries_exclude_ip_literals_and_reject_truncated_bitmaps() {
    runtime().block_on(async {
        assert!(query_peer_online_states(
            vec!["127.0.0.1".into(), "[::1]:21118".into()],
            "invalid-rendezvous.invalid:1".into(),
            "test".into()
        )
        .await
        .unwrap()
        .is_empty());
        for truncated in [false, true] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (socket, address) = listener.accept().await.unwrap();
                let mut peer = Stream::from(socket, address);
                let bytes = peer.next_timeout(1000).await.unwrap().unwrap();
                let request = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
                let Some(rendezvous_message::Union::OnlineRequest(request)) = request.union else {
                    panic!("expected OnlineRequest")
                };
                assert_eq!(request.peers, vec!["123456789", "987654321"]);
                let mut response = RendezvousMessage::new();
                response.set_online_response(OnlineResponse {
                    states: (if truncated { vec![] } else { vec![0x80] }).into(),
                    ..Default::default()
                });
                peer.send(&response).await.unwrap();
            });
            let result = query_peer_online_states(
                vec![
                    "127.0.0.1".into(),
                    "123456789".into(),
                    "[::1]:21118".into(),
                    "987654321".into(),
                ],
                address.to_string(),
                "test".into(),
            )
            .await;
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
