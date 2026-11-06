use super::*;
use hbb_common::rendezvous_proto::{ConfigUpdate, IceCandidate, OnlineResponse, PunchHoleResponse};

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
fn secondary_frames_use_their_own_geometry_and_stop_on_close() {
    use hbb_common::message_proto::EncodedVideoFrame;
    static CALLS: AtomicI32 = AtomicI32::new(0);
    static WIDTH: AtomicI32 = AtomicI32::new(0);
    static CODEC: AtomicI32 = AtomicI32::new(0);
    static DISPLAY: AtomicI32 = AtomicI32::new(-1);
    extern "C" fn receive(_data: *const c_uchar, _length: i32, width: i32, _height: i32,
                          _key: i32, _pts: i64, display: i32, codec: i32) {
        DISPLAY.store(display, Ordering::SeqCst);
        WIDTH.store(width, Ordering::SeqCst);
        CODEC.store(codec, Ordering::SeqCst);
        CALLS.fetch_add(1, Ordering::SeqCst);
        // Simulate closing the secondary surface while a batch is in flight.
        SECONDARY_DISPLAY.store(-1, Ordering::SeqCst);
    }
    CALLS.store(0, Ordering::SeqCst);
    *DISPLAY_INFOS.lock().unwrap() = vec![(0, 0, 1920, 1080, false), (-1280, 0, 1280, 720, false)];
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = Some(receive);
    SECONDARY_DISPLAY.store(1, Ordering::SeqCst);
    let item = EncodedVideoFrame { data: vec![1, 2, 3].into(), key: true, pts: 1, ..Default::default() };
    let frames = EncodedVideoFrames { frames: vec![item.clone(), item], ..Default::default() };
    assert_eq!(forward_frame_for_destination(frames, b'V',
        multi_display_routing::FrameDestination::Secondary(1)), 1);
    assert_eq!(CALLS.load(Ordering::SeqCst), 1);
    assert_eq!(WIDTH.load(Ordering::SeqCst), 1280);
    assert_eq!(DISPLAY.load(Ordering::SeqCst), 1);
    assert_eq!(CODEC.load(Ordering::SeqCst), i32::from(b'V'));
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = None;
    DISPLAY_INFOS.lock().unwrap().clear();
}

#[test]
fn secondary_subscription_rejects_unsupported_or_unready_sessions() {
    extern "C" fn callback(_: *const c_uchar, _: i32, _: i32, _: i32, _: i32, _: i64, _: i32, _: i32) {}
    CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
    FILE_ONLY_SESSION.store(false, Ordering::SeqCst);
    *CURRENT_DISPLAY.lock().unwrap() = 0;
    *DISPLAY_INFOS.lock().unwrap() = vec![(0, 0, 800, 600, false), (800, 0, 1024, 768, false)];
    PEER_SUPPORTS_MULTI_DISPLAY_FRAMES.store(false, Ordering::SeqCst);
    assert_eq!(rust_set_secondary_display(1), -2);
    PEER_SUPPORTS_MULTI_DISPLAY_FRAMES.store(true, Ordering::SeqCst);
    PEER_IS_WAYLAND.store(true, Ordering::SeqCst);
    assert_eq!(rust_set_secondary_display(1), -2);
    PEER_IS_WAYLAND.store(false, Ordering::SeqCst);
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = None;
    assert_eq!(rust_set_secondary_display(1), -3);
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = Some(callback);
    assert_eq!(rust_set_secondary_display(0), -4);
    assert_eq!(rust_set_secondary_display(2), -4);
    assert_eq!(SECONDARY_DISPLAY.load(Ordering::SeqCst), -1);
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = None;
    reset_display_state();
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
}

#[test]
fn secondary_subscription_preserves_primary_and_restores_single_capture() {
    extern "C" fn callback(_: *const c_uchar, _: i32, _: i32, _: i32, _: i32, _: i64, _: i32, _: i32) {}
    fn capture(cmd: QueuedPeerCommand) -> Vec<i32> {
        match cmd {
            QueuedPeerCommand::Message { message, .. } => match message.union {
                Some(message::Union::Misc(misc)) => match misc.union {
                    Some(misc::Union::CaptureDisplays(displays)) => displays.set,
                    _ => panic!("expected capture displays"),
                },
                _ => panic!("expected misc"),
            },
            _ => panic!("expected message"),
        }
    }
    let (sender, mut receiver) = tokio_mpsc::unbounded_channel();
    let session = SESSION_ID.load(Ordering::SeqCst);
    *PEER_MESSAGE_SENDER.lock().unwrap() = Some((session, sender));
    CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
    PEER_SUPPORTS_MULTI_DISPLAY_FRAMES.store(true, Ordering::SeqCst);
    PEER_IS_WAYLAND.store(false, Ordering::SeqCst);
    FILE_ONLY_SESSION.store(false, Ordering::SeqCst);
    *CURRENT_DISPLAY.lock().unwrap() = 0;
    *DISPLAY_INFOS.lock().unwrap() = vec![(0, 0, 800, 600, false), (800, 0, 800, 600, false), (1600, 0, 800, 600, false)];
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = Some(callback);
    assert_eq!(rust_set_secondary_display(1), 0);
    assert_eq!(capture(receiver.try_recv().unwrap()), vec![0, 1]);
    assert_eq!(rust_switch_display(2), 0);
    let _switch = receiver.try_recv().unwrap();
    assert_eq!(capture(receiver.try_recv().unwrap()), vec![2, 1]);
    assert_eq!(rust_set_secondary_display(-1), 0);
    assert_eq!(capture(receiver.try_recv().unwrap()), vec![2]);
    assert_eq!(SECONDARY_DISPLAY.load(Ordering::SeqCst), -1);
    *SECONDARY_FRAME_CALLBACK.lock().unwrap() = None;
    *PEER_MESSAGE_SENDER.lock().unwrap() = None;
    reset_display_state();
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
}

#[test]
fn secondary_pointer_uses_its_own_origin_and_rejects_stale_events() {
    let (sender, mut receiver) = tokio_mpsc::unbounded_channel();
    let session = SESSION_ID.load(Ordering::SeqCst);
    *PEER_MESSAGE_SENDER.lock().unwrap() = Some((session, sender));
    CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
    FILE_ONLY_SESSION.store(false, Ordering::SeqCst);
    *CURRENT_DISPLAY.lock().unwrap() = 0;
    *DISPLAY_INFOS.lock().unwrap() = vec![(0, 0, 1920, 1080, false), (-1280, 120, 1280, 720, false)];
    SECONDARY_DISPLAY.store(1, Ordering::SeqCst);
    assert_eq!(rust_send_secondary_mouse_event(1, 5000.0, -5.0, 1, 0), 0);
    let QueuedPeerCommand::Message { message, .. } = receiver.try_recv().unwrap() else { panic!("expected mouse"); };
    let Some(message::Union::MouseEvent(mouse)) = message.union else { panic!("expected mouse event"); };
    assert_eq!((mouse.x, mouse.y, mouse.mask), (-1, 120, 9));
    assert_eq!(*CURRENT_DISPLAY.lock().unwrap(), 0);
    assert_eq!(rust_send_secondary_mouse_event(0, 10.0, 10.0, 1, 0), -1);
    assert_eq!(rust_send_secondary_mouse_event(1, f64::NAN, 10.0, 1, 0), -1);
    assert_eq!(rust_send_secondary_wheel(1, 20.0, 30.0, 0.0, -2.0, 0), 0);
    let QueuedPeerCommand::Message { message: first, .. } = receiver.try_recv().unwrap() else { panic!("expected move"); };
    let QueuedPeerCommand::Message { message: second, .. } = receiver.try_recv().unwrap() else { panic!("expected wheel"); };
    let Some(message::Union::MouseEvent(moved)) = first.union else { panic!("expected move event"); };
    let Some(message::Union::MouseEvent(wheel)) = second.union else { panic!("expected wheel event"); };
    assert_eq!((moved.x, moved.y, moved.mask), (-1260, 150, 0));
    assert_eq!((wheel.x, wheel.y, wheel.mask), (0, -2, 3));
    SECONDARY_DISPLAY.store(-1, Ordering::SeqCst);
    assert_eq!(rust_send_secondary_mouse_event(1, 10.0, 10.0, 1, 0), -1);
    assert!(receiver.try_recv().is_err());
    *PEER_MESSAGE_SENDER.lock().unwrap() = None;
    reset_display_state();
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
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
fn domain_ports_are_direct_but_custom_ids_and_invalid_endpoints_remain_distinct() {
    for peer in ["example.org:21118", "localhost:32001", "NAS.local:1", "xn--example-9d0b.com:65535"] {
        assert_eq!(direct_peer_endpoint(peer).unwrap(), Some(peer.to_string()));
    }
    for peer in ["example.org", "Custom.ID", "123456789"] {
        assert_eq!(direct_peer_endpoint(peer).unwrap(), None);
    }
    for peer in ["example.org:0", "example.org:65536", "example.org:abc", "example.org:-1",
        "-bad.test:1", "bad-.test:1", "bad..test:1", "http://example.org:1", "999.1.2.3:1", "[bad]:1"] {
        assert!(direct_peer_endpoint(peer).is_err(), "{peer}");
    }
    assert_eq!(direct_peer_endpoint("[::1]:21118").unwrap(), Some("[::1]:21118".to_string()));
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
        rust_connect(invalid.as_ptr(), null, null, null, null, null, null, 0, 0, 0, 0, 0, null, 0),
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
fn adaptive_direct_timeout_uses_punch_latency_nat_and_bounded_fallback() {
    assert_eq!(
        adaptive_direct_timeout(true, NatType::ASYMMETRIC, NatType::ASYMMETRIC, true, 0, 3_000),
        LOCAL_DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::SYMMETRIC, NatType::ASYMMETRIC, true, 0, 3_000),
        LOCAL_DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::ASYMMETRIC, NatType::ASYMMETRIC, true, 0, 3_000),
        ADAPTIVE_DIRECT_MAX_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::UNKNOWN_NAT, NatType::UNKNOWN_NAT, true, 0, 250),
        DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::UNKNOWN_NAT, NatType::UNKNOWN_NAT, false, 2, 250),
        DIRECT_ONLY_CONNECT_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::ASYMMETRIC, NatType::SYMMETRIC, true, 0, 3_000),
        LOCAL_DIRECT_CONNECT_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::ASYMMETRIC, NatType::ASYMMETRIC, true, 1, 3_000),
        ADAPTIVE_DIRECT_RETRY_MAX_TIMEOUT
    );
    assert_eq!(
        adaptive_direct_timeout(false, NatType::UNKNOWN_NAT, NatType::UNKNOWN_NAT, false, 0, u64::MAX),
        ADAPTIVE_DIRECT_ONLY_MAX_TIMEOUT
    );
}

#[test]
fn relay_standby_requires_authenticated_pairing_and_an_active_direct_candidate() {
    assert!(should_prepare_relay_standby(true, true, true, false, true));
    for (authenticated, paired, available, forced, direct) in [
        (false, true, true, false, true), (true, false, true, false, true),
        (true, true, false, false, true), (true, true, true, true, true),
        (true, true, true, false, false),
    ] {
        assert!(!should_prepare_relay_standby(authenticated, paired, available, forced, direct));
    }
}

#[test]
fn standby_is_cancelled_on_direct_success_and_retained_only_for_fallback() {
    struct DropProbe(Arc<AtomicBool>);
    impl Drop for DropProbe { fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); } }
    runtime().block_on(async {
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = cancelled.clone();
        let direct = async { tokio::time::sleep(Duration::from_millis(25)).await; Ok::<_, ()>(7) };
        let standby = async move {
            let _guard = DropProbe(flag);
            std::future::pending::<Option<i32>>().await
        };
        let (result, standby) = direct_with_standby(direct, standby).await;
        assert_eq!(result, Ok(7));
        assert_eq!(standby, None);
        assert!(cancelled.load(Ordering::SeqCst));

        let dropped = Arc::new(AtomicBool::new(false));
        let flag = dropped.clone();
        let direct = async { tokio::time::sleep(Duration::from_millis(25)).await; Ok::<_, ()>(8) };
        let standby = async move { Some(DropProbe(flag)) };
        let (result, standby) = direct_with_standby(direct, standby).await;
        assert_eq!(result, Ok(8));
        assert!(standby.is_none());
        assert!(dropped.load(Ordering::SeqCst), "ready standby must close when direct wins");

        let direct = async { Err::<i32, _>("direct_failed") };
        let standby = async { tokio::time::sleep(Duration::from_millis(15)).await; Some(9) };
        let (result, standby) = direct_with_standby(direct, standby).await;
        assert_eq!(result, Err("direct_failed"));
        assert_eq!(standby, Some(9));

        let direct_dropped = Arc::new(AtomicBool::new(false));
        let standby_dropped = Arc::new(AtomicBool::new(false));
        let first = direct_dropped.clone();
        let second = standby_dropped.clone();
        let direct = async move { let _guard = DropProbe(first); std::future::pending::<Result<i32, ()>>().await };
        let standby = async move { let _guard = DropProbe(second); std::future::pending::<Option<i32>>().await };
        let epoch = AtomicU64::new(1);
        let cancel = async { tokio::time::sleep(Duration::from_millis(75)).await; epoch.store(2, Ordering::SeqCst); };
        let (result, ()) = tokio::join!(await_connection_attempt(1, &epoch, Duration::from_secs(1),
            direct_with_standby(direct, standby)), cancel);
        assert!(matches!(result, Err(ConnectionAttemptError::Cancelled)));
        assert!(direct_dropped.load(Ordering::SeqCst));
        assert!(standby_dropped.load(Ordering::SeqCst));
    });
}

#[test]
fn relay_preconnect_sends_no_pairing_until_selected_and_expires_safely() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap().to_string();
        let prepared = prepare_relay_transport(&endpoint, true).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut peer = Stream::from(socket, addr);
        assert!(tokio::time::timeout(Duration::from_millis(40), peer.next()).await.is_err(),
            "standby must not send a request before the direct path fails");
        let joined = create_relay_with_standby(Some(prepared), "TEST_PEER", "TEST_UUID", &endpoint,
            "TEST_PUBLIC_KEY", true).await.unwrap();
        let bytes = peer.next_timeout(1_000).await.unwrap().unwrap();
        let request = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
        assert_eq!(request.request_relay().id, "TEST_PEER");
        assert_eq!(request.request_relay().uuid, "TEST_UUID");
        assert_eq!(request.request_relay().licence_key, "TEST_PUBLIC_KEY");
        drop(joined);

        let mut expired = prepare_relay_transport(&endpoint, true).await.unwrap();
        let (socket, addr) = listener.accept().await.unwrap();
        let mut old_peer = Stream::from(socket, addr);
        expired.ready_at = Instant::now() - PREPARED_RELAY_MAX_IDLE - Duration::from_millis(1);
        let (joined, accepted) = tokio::join!(create_relay_with_standby(Some(expired), "TEST_PEER",
            "TEST_FRESH_UUID", &endpoint, "TEST_PUBLIC_KEY", true), listener.accept());
        let joined = joined.unwrap();
        let (socket, addr) = accepted.unwrap();
        let mut fresh_peer = Stream::from(socket, addr);
        assert!(matches!(tokio::time::timeout(Duration::from_secs(1), old_peer.next()).await,
            Ok(None) | Ok(Some(Err(_)))));
        let bytes = fresh_peer.next_timeout(1_000).await.unwrap().unwrap();
        let request = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
        assert_eq!(request.request_relay().uuid, "TEST_FRESH_UUID");
        drop(joined);
    });
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
fn game_transport_preference_is_bounded_and_never_bypasses_security() {
    assert_eq!(udp_probe_budget(GameTransportPolicy::Automatic), Duration::from_millis(300));
    assert_eq!(udp_probe_budget(GameTransportPolicy::UdpPreferred), Duration::from_millis(800));
    assert_eq!(udp_probe_budget(GameTransportPolicy::TcpFallback), Duration::from_millis(300));
    assert_eq!(GameTransportPolicy::from_wire(1, false), GameTransportPolicy::UdpPreferred);
    assert_eq!(GameTransportPolicy::from_wire(2, false), GameTransportPolicy::TcpFallback);
    assert_eq!(GameTransportPolicy::from_wire(1, true), GameTransportPolicy::Automatic);
    assert_eq!(GameTransportPolicy::from_wire(999, false), GameTransportPolicy::Automatic);
    assert_eq!(game_candidate_delay_ms(GameTransportPolicy::UdpPreferred, true, false), 350);
    assert_eq!(game_candidate_delay_ms(GameTransportPolicy::UdpPreferred, false, false), 0);
    assert_eq!(game_candidate_delay_ms(GameTransportPolicy::UdpPreferred, true, true), 0);
    assert_eq!(game_candidate_delay_ms(GameTransportPolicy::Automatic, true, false), 0);
    assert!(should_retry_game_udp_as_tcp(GameTransportPolicy::UdpPreferred, false, true, INSECURE_NONE));
    for reason in [INSECURE_SERVER_KEY, INSECURE_MISSING_SIGNATURE, INSECURE_DIRECT_ENDPOINT] {
        assert!(!should_retry_game_udp_as_tcp(GameTransportPolicy::UdpPreferred, false, true, reason));
    }
    assert!(!should_retry_game_udp_as_tcp(GameTransportPolicy::UdpPreferred, true, true, INSECURE_NONE));
    assert!(!should_retry_game_udp_as_tcp(GameTransportPolicy::UdpPreferred, false, false, INSECURE_NONE));
    assert!(!should_retry_game_udp_as_tcp(GameTransportPolicy::TcpFallback, false, true, INSECURE_NONE));
}

#[test]
fn game_udp_probe_accepts_a_slow_real_server_reply_without_inventing_a_port() {
    runtime().block_on(async {
        let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let address = server.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let mut buf = [0_u8; 1500];
            let (_, peer) = server.recv_from(&mut buf).await.unwrap();
            tokio::time::sleep(Duration::from_millis(450)).await;
            let mut response = RendezvousMessage::new();
            response.set_test_nat_response(hbb_common::rendezvous_proto::TestNatResponse {
                port: i32::from(peer.port()), ..Default::default()
            });
            server.send_to(&response.write_to_bytes().unwrap(), peer).await.unwrap();
        });
        let result = prepare_udp_punch_socket(&address.to_string(), false,
            udp_probe_budget(GameTransportPolicy::UdpPreferred)).await;
        assert!(result.is_some(), "game probe must accept a real delayed mapping");
        task.await.unwrap();
    });
}

#[test]
fn game_udp_preference_does_not_block_a_real_tcp_fallback() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        socket.connect(target.local_addr().unwrap()).await.unwrap();
        let started = Instant::now();
        let selected = connect_direct_transports(Some(listener.local_addr().unwrap()),
            "127.0.0.1:0".parse().unwrap(), 1500, Some(Arc::new(socket)), None, None, 1,
            GameTransportPolicy::UdpPreferred).await.expect("TCP fallback must remain available");
        assert_eq!(selected.transport, TRANSPORT_TCP);
        assert!(started.elapsed() >= Duration::from_millis(GAME_UDP_PREFERENCE_MS));
    });
}

#[test]
fn game_udp_preference_selects_a_working_kcp_peer_before_tcp() {
    runtime().block_on(async {
        let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        client.connect(server.local_addr().unwrap()).await.unwrap();
        let peer = tokio::spawn(async move {
            let mut buf = [0_u8; 1500];
            let (size, address) = server.recv_from(&mut buf).await.unwrap();
            let transaction = punch_transaction(&buf[..size], &PUNCH_PROBE).expect("UDP probe");
            server.connect(address).await.unwrap();
            server.send(&punch_packet(&PUNCH_ACK, transaction)).await.unwrap();
            let mut endpoint = kcp_sys::endpoint::KcpEndpoint::new();
            endpoint.run().await;
            let input = endpoint.input_sender();
            let mut output = endpoint.output_receiver().unwrap();
            let accept = endpoint.accept();
            tokio::pin!(accept);
            loop {
                tokio::select! {
                    accepted = &mut accept => {
                        assert!(accepted.is_ok());
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        break;
                    }
                    packet = server.recv(&mut buf) => {
                        let size = packet.unwrap();
                        if size >= std::mem::size_of::<kcp_sys::packet_def::KcpPacketHeader>() {
                            input.send(hbb_common::bytes::BytesMut::from(&buf[..size]).into()).await.unwrap();
                        }
                    }
                    Some(packet) = output.recv() => { server.send(&packet.inner()).await.unwrap(); }
                }
            }
        });
        let selected = connect_direct_transports(Some(tcp.local_addr().unwrap()),
            "127.0.0.1:0".parse().unwrap(), 1500, Some(Arc::new(client)), None, None, 1,
            GameTransportPolicy::UdpPreferred).await.expect("UDP/KCP should connect");
        assert_eq!(selected.transport, TRANSPORT_UDP_KCP);
        peer.abort();
    });
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

async fn check_direct_listener(host: &str, file_session: bool, domain: bool) {
    let listener = match tokio::net::TcpListener::bind(host).await {
        Ok(listener) => listener,
        Err(error) if host.starts_with('[') => {
            eprintln!("IPv6 loopback unavailable: {error}");
            return;
        }
        Err(error) => panic!("loopback bind failed: {error}"),
    };
    let address = listener.local_addr().unwrap();
    let endpoint = if domain { format!("localhost:{}", address.port()) } else { address.to_string() };
    let mut client = if file_session {
        let config = ConnectionConfig {
            public_server: false,
            peer: endpoint.clone(),
            password: String::new(),
            // These must never be resolved/contacted for a literal peer.
            rendezvous_addr: "invalid-rendezvous.invalid:1".into(),
            relay_override: "invalid-relay.invalid:1".into(),
            key: "not-a-server-key".into(),
            client_hwid: Vec::new(),
            client_id: "test".into(),
            os_password: String::new(),
        };
        let previous_approval = INSECURE_SESSION_REASON.swap(INSECURE_NONE, Ordering::SeqCst);
        assert_eq!(connect_file_stream(&config).await.err().as_deref(),
            Some("direct endpoint requires unencrypted approval"));
        INSECURE_SESSION_REASON.store(INSECURE_DIRECT_ENDPOINT, Ordering::SeqCst);
        let stream = connect_file_stream(&config).await.unwrap();
        INSECURE_SESSION_REASON.store(previous_approval, Ordering::SeqCst);
        stream
    } else {
        connect_direct_endpoint(direct_peer_endpoint(&endpoint).unwrap().unwrap()).await.unwrap()
    };
    let (socket, address) = listener.accept().await.unwrap();
    let mut peer = Stream::from(socket, address);
    assert!(!client.is_secured()); // Direct IP requires explicit session approval.
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
            check_direct_listener(host, false, false).await;
            check_direct_listener(host, true, false).await;
            check_direct_listener(host, false, true).await;
            check_direct_listener(host, true, true).await;
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
fn punch_waits_for_response_after_heartbeat_and_ice_without_disclosing_values() {
    static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    extern "C" fn capture(message: *const c_char) {
        if !message.is_null() {
            let value = unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned();
            EVENTS.lock().unwrap().push(value);
        }
    }
    struct RestoreCallback(Option<EventCallback>);
    impl Drop for RestoreCallback {
        fn drop(&mut self) { *EVENT_CALLBACK.lock().unwrap() = self.0; }
    }
    EVENTS.lock().unwrap().clear();
    let previous = EVENT_CALLBACK.lock().unwrap().replace(capture);
    let _restore = RestoreCallback(previous);
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = connect_tcp(listener.local_addr().unwrap(), 1000).await.unwrap();
        let (socket, address) = listener.accept().await.unwrap();
        let responder = tokio::spawn(async move {
            let mut peer = Stream::from(socket, address);
            let request = RendezvousMessage::parse_from_bytes(&peer.next().await.unwrap().unwrap()).unwrap();
            assert_eq!(request.punch_hole_request().token, "TEST_TOKEN_DO_NOT_LOG");
            peer.send_raw(Vec::new()).await.unwrap();
            let mut candidate = RendezvousMessage::new();
            candidate.set_ice_candidate(IceCandidate {
                id: "TEST_PEER_DO_NOT_LOG".into(),
                session_key: "TEST_SESSION_KEY_DO_NOT_LOG".into(),
                candidate: "TEST_CANDIDATE_DO_NOT_LOG".into(),
                ..Default::default()
            });
            peer.send(&candidate).await.unwrap();
            let mut reply = RendezvousMessage::new();
            reply.set_punch_hole_response(PunchHoleResponse {
                other_failure: "TEST_RAW_RESPONSE_DO_NOT_LOG TEST_PASSWORD_DO_NOT_LOG".into(),
                ..Default::default()
            });
            peer.send(&reply).await.unwrap();
            let mut unknown = RendezvousMessage::new();
            unknown.special_fields.mut_unknown_fields().add_length_delimited(99, b"TEST_RAW_UNKNOWN_DO_NOT_LOG".to_vec());
            peer.send(&unknown).await.unwrap();
        });
        let mut request = punch_hole_request("TEST_PEER_DO_NOT_LOG", "TEST_KEY_DO_NOT_LOG",
            ConnType::DEFAULT_CONN, false, NatType::UNKNOWN_NAT, 0, Vec::new(), String::new());
        request.mut_punch_hole_request().token = "TEST_TOKEN_DO_NOT_LOG".into();
        let response = send_punch_request(&mut client, &request, false).await.unwrap().unwrap();
        let Some(rendezvous_message::Union::PunchHoleResponse(reply)) = response.union else {
            panic!("expected punch response after side-band messages");
        };
        assert_eq!(reply.other_failure, "TEST_RAW_RESPONSE_DO_NOT_LOG TEST_PASSWORD_DO_NOT_LOG", "server refusals must remain intact for safe classification");
        let unknown = next_punch_response(&mut client, 1000, false).await.unwrap().unwrap();
        assert!(unknown.union.is_none());
        responder.await.unwrap();
    });
    let events = EVENTS.lock().unwrap();
    let diagnostic: Vec<&str> = events.iter().map(String::as_str).filter(|s| s.starts_with("rv_diag ")).collect();
    assert!(diagnostic.iter().any(|s| s.contains("phase=punch kind=heartbeat action=skip")));
    assert!(diagnostic.iter().any(|s| s.contains("phase=punch kind=ice_candidate action=ignore_unsupported_trickle")));
    assert!(diagnostic.iter().any(|s| s.contains("phase=punch kind=punch_hole_response action=deliver")));
    assert!(diagnostic.iter().any(|s| s.contains("phase=punch kind=none action=deliver unknown_fields=true")));
    for event in events.iter() {
        for secret in ["TEST_TOKEN_DO_NOT_LOG", "TEST_KEY_DO_NOT_LOG", "TEST_PEER_DO_NOT_LOG",
            "TEST_SESSION_KEY_DO_NOT_LOG", "TEST_CANDIDATE_DO_NOT_LOG", "TEST_RAW_RESPONSE_DO_NOT_LOG",
            "TEST_RAW_UNKNOWN_DO_NOT_LOG", "TEST_PASSWORD_DO_NOT_LOG"] {
            assert!(!event.contains(secret), "diagnostics exposed a remote value");
        }
    }
}

#[test]
fn rendezvous_diagnostics_use_fixed_stage_labels() {
    for (phase, expected) in [
        (RendezvousPhase::Punch, "punch"), (RendezvousPhase::FilePunch, "file_punch"),
        (RendezvousPhase::Relay, "relay"), (RendezvousPhase::Online, "online"),
        (RendezvousPhase::Nat, "nat"), (RendezvousPhase::Generic, "generic"),
    ] {
        assert_eq!(phase.as_str(), expected);
    }
}

#[test]
fn punch_sideband_preserves_the_existing_encrypted_stream() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = connect_tcp(listener.local_addr().unwrap(), 1000).await.unwrap();
        let (socket, address) = listener.accept().await.unwrap();
        let key = secretbox::Key([42u8; 32]);
        client.set_key(key.clone());
        let responder = tokio::spawn(async move {
            let mut peer = Stream::from(socket, address);
            peer.set_key(key);
            let mut ice = RendezvousMessage::new();
            ice.set_ice_candidate(IceCandidate::new());
            peer.send(&ice).await.unwrap();
            let mut response = RendezvousMessage::new();
            response.set_punch_hole_response(PunchHoleResponse::new());
            peer.send(&response).await.unwrap();
        });
        let response = next_punch_response(&mut client, 1000, false).await.unwrap().unwrap();
        assert!(client.is_secured(), "side-band handling must never downgrade encryption");
        assert!(matches!(response.union, Some(rendezvous_message::Union::PunchHoleResponse(_))));
        responder.await.unwrap();
    });
}

#[test]
fn unknown_rendezvous_payload_is_not_silently_ignored() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = connect_tcp(listener.local_addr().unwrap(), 1000).await.unwrap();
        let (socket, address) = listener.accept().await.unwrap();
        let responder = tokio::spawn(async move {
            let mut peer = Stream::from(socket, address);
            let mut unknown = RendezvousMessage::new();
            unknown.special_fields.mut_unknown_fields().add_length_delimited(99, b"TEST_PRIVATE_RESPONSE".to_vec());
            peer.send(&unknown).await.unwrap();
        });
        let message = next_punch_response(&mut client, 1000, false).await.unwrap().unwrap();
        assert!(message.union.is_none());
        assert!(message.special_fields().unknown_fields().iter().next().is_some());
        responder.await.unwrap();
    });
}

#[test]
fn trickle_candidates_do_not_extend_punch_deadline_or_allow_unbounded_floods() {
    runtime().block_on(async {
        for flood in [false, true] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut client = connect_tcp(listener.local_addr().unwrap(), 1000).await.unwrap();
            let (socket, address) = listener.accept().await.unwrap();
            let sender = tokio::spawn(async move {
                let mut peer = Stream::from(socket, address);
                let mut message = RendezvousMessage::new();
                message.set_ice_candidate(IceCandidate::new());
                loop {
                    if peer.send(&message).await.is_err() { break; }
                    if !flood { tokio::time::sleep(Duration::from_millis(5)).await; }
                }
            });
            let result = tokio::time::timeout(Duration::from_secs(2),
                next_punch_response(&mut client, if flood { 1000 } else { 40 }, false)).await.unwrap();
            sender.abort();
            let _ = sender.await;
            if flood { assert!(matches!(result, Err(-5))); }
            else { assert!(matches!(result, Ok(None))); }
        }
    });
}

#[test]
fn rendezvous_eof_is_not_a_timeout_and_never_retries_a_dead_socket() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = connect_tcp(listener.local_addr().unwrap(), 1000).await.unwrap();
        let (socket, address) = listener.accept().await.unwrap();
        let responder = tokio::spawn(async move {
            let mut peer = Stream::from(socket, address);
            assert!(peer.next().await.is_some());
            // Close without replying, as in the user's second attempt.
        });
        let request = punch_hole_request("test", "", ConnType::DEFAULT_CONN, false,
            NatType::UNKNOWN_NAT, 0, Vec::new(), String::new());
        assert!(send_punch_request(&mut client, &request, false).await.is_err());
        responder.await.unwrap();
    });
}

#[test]
fn unencrypted_server_messages_do_not_authorize_token_or_ice_disclosure() {
    runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = connect_tcp(listener.local_addr().unwrap(), 1000).await.unwrap();
        let (socket, address) = listener.accept().await.unwrap();
        let mut peer = Stream::from(socket, address);
        let mut message = RendezvousMessage::new();
        message.set_configure_update(ConfigUpdate::new());
        peer.send(&message).await.unwrap();
        assert!(secure_rendezvous_connection(&mut client, RS_PUB_KEY, RendezvousHandshakeContext::Account).await.is_err());
        assert!(!client.is_secured());
        assert!(tokio::time::timeout(Duration::from_millis(40), peer.next()).await.is_err());
    });
}

#[test]
fn online_queries_exclude_ip_literals_and_reject_truncated_bitmaps() {
    runtime().block_on(async {
        assert!(query_peer_online_states(
            vec!["127.0.0.1".into(), "[::1]:21118".into()],
            "invalid-rendezvous.invalid:1".into(),
            "test".into(), 1, Instant::now()
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
                2, Instant::now(),
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

#[test]
fn online_query_does_not_probe_neighboring_websocket_port() {
    runtime().block_on(async {
        let (aux_port, websocket_listener) = loop {
            let aux = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = aux.local_addr().unwrap().port();
            if let Some(websocket_port) = port.checked_add(2) {
                if let Ok(websocket) = tokio::net::TcpListener::bind(("127.0.0.1", websocket_port)).await {
                    drop(aux);
                    break (port, websocket);
                }
            }
        };
        let result = query_peer_online_states(
            vec!["123456789".into()],
            format!("127.0.0.1:{aux_port}"),
            "test".into(),
            3,
            Instant::now(),
        )
        .await;
        assert!(result.is_err(), "closed auxiliary port must fail safely");
        assert!(
            tokio::time::timeout(Duration::from_millis(200), websocket_listener.accept())
                .await
                .is_err(),
            "online status must not connect to a neighboring WebSocket port"
        );
    });
}
