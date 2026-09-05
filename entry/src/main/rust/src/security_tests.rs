use super::*;
use hbb_common::message_proto::SignedId;

async fn stream_pair() -> (Stream, Stream) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let client = tokio::net::TcpStream::connect(addr).await.unwrap();
    let (server, peer) = listener.accept().await.unwrap();
    (Stream::from(client, addr), Stream::from(server, peer))
}

fn signed_identity(id: &str, pk: [u8; 32], signer: &sign::SecretKey) -> Vec<u8> {
    let payload = IdPk { id: id.into(), pk: pk.to_vec().into(), ..Default::default() };
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
        secure_peer_connection("test-peer", &signed, &key, &mut client).await.unwrap();
        assert!(client.is_secured());
        let response = peer.next_timeout(1000).await.unwrap().unwrap();
        assert!(matches!(PeerMessage::parse_from_bytes(&response).unwrap().union,
            Some(message::Union::PublicKey(_))));

        let (mut client, mut peer) = stream_pair().await;
        secure_peer_connection("test-peer", &[], &key, &mut client).await.unwrap();
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
                    let mut id = signed_identity(if scenario == 5 { "wrong-peer" } else { "test-peer" },
                        peer_pk.0, &peer_sk);
                    if scenario == 6 { id[0] ^= 1; }
                    let mut message = PeerMessage::new();
                    message.set_signed_id(SignedId { id: id.into(), ..Default::default() });
                    peer.send(&message).await.unwrap();
                }
                _ => unreachable!(),
            }
            assert!(secure_peer_connection("test-peer", &server_signed, &server_key, &mut client).await.is_err(),
                "scenario {scenario}");
            assert!(!client.is_secured());
            // A failed identity check must not emit a compatibility/downgrade message.
            assert!(peer.next_timeout(30).await.is_none(), "scenario {scenario} sent data");
        }
    });
}
