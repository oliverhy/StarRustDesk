use hbb_common::{
    anyhow,
    bytes::{Bytes, BytesMut},
    bytes_codec::BytesCodec,
    config,
    tcp::{DynTcpStream, FramedStream},
    tokio::{self, net::UdpSocket, sync::mpsc, sync::oneshot},
    tokio_util, ResultType, Stream,
};
use kcp_sys::{
    endpoint::{ConnId, KcpEndpoint},
    packet_def::{KcpPacket, KcpPacketHeader},
    stream,
};
use std::{net::SocketAddr, sync::Arc};

/// Owns the KCP endpoint tasks for as long as the framed RustDesk stream is alive.
pub struct KcpStream {
    endpoint: KcpEndpoint,
    conn_id: ConnId,
    stop_sender: Option<oneshot::Sender<()>>,
}

impl KcpStream {
    fn create_framed(stream: stream::KcpStream, local_addr: Option<SocketAddr>) -> Stream {
        Stream::Tcp(FramedStream(
            tokio_util::codec::Framed::new(DynTcpStream(Box::new(stream)), BytesCodec::new()),
            local_addr.unwrap_or(config::Config::get_any_listen_addr(true)),
            None,
            0,
        ))
    }

    pub async fn connect(
        udp_socket: Arc<UdpSocket>,
        timeout: std::time::Duration,
    ) -> ResultType<(Self, Stream)> {
        let mut endpoint = KcpEndpoint::new();
        endpoint.run().await;
        let input = endpoint.input_sender();
        let output = endpoint
            .output_receiver()
            .ok_or_else(|| anyhow::anyhow!("Failed to get KCP output receiver"))?;
        let (stop_sender, stop_receiver) = oneshot::channel();
        Self::kcp_io(udp_socket.clone(), input, output, stop_receiver);

        let conn_id = endpoint.connect(timeout, 0, 0, Bytes::new()).await?;
        let stream = stream::KcpStream::new(&endpoint, conn_id)
            .ok_or_else(|| anyhow::anyhow!("Failed to create KCP stream"))?;
        Ok((
            Self {
                endpoint,
                conn_id,
                stop_sender: Some(stop_sender),
            },
            Self::create_framed(stream, udp_socket.local_addr().ok()),
        ))
    }

    fn kcp_io(
        udp_socket: Arc<UdpSocket>,
        input: mpsc::Sender<KcpPacket>,
        mut output: mpsc::Receiver<KcpPacket>,
        mut stop_receiver: oneshot::Receiver<()>,
    ) {
        tokio::spawn(async move {
            let mut buf = vec![0_u8; 1500];
            loop {
                tokio::select! {
                    _ = &mut stop_receiver => break,
                    Some(data) = output.recv() => {
                        if udp_socket.send(&data.inner()).await.is_err() {
                            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                        }
                    }
                    result = udp_socket.recv_from(&mut buf) => {
                        match result {
                            Ok((size, _)) if size >= std::mem::size_of::<KcpPacketHeader>() => {
                                if input.send(BytesMut::from(&buf[..size]).into()).await.is_err() {
                                    break;
                                }
                            }
                            Ok(_) => {}
                            Err(_) => tokio::time::sleep(std::time::Duration::from_millis(10)).await,
                        }
                    }
                    else => break,
                }
            }
        });
    }
}

impl Drop for KcpStream {
    fn drop(&mut self) {
        let _ = (&self.endpoint, self.conn_id);
        if let Some(sender) = self.stop_sender.take() {
            let _ = sender.send(());
        }
    }
}
