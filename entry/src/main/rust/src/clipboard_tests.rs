use super::*;

fn clipboard_content(msg: PeerMessage) -> Vec<u8> {
    let Some(message::Union::Clipboard(item)) = msg.union else {
        panic!("expected a clipboard message");
    };
    assert_eq!(item.format.enum_value(), Ok(ClipboardFormat::Text));
    if item.compress { hbb_common::compress::decompress(&item.content) }
    else { item.content.to_vec() }
}

#[test]
fn repeated_text_is_queued_again_after_a_remote_change_or_explicit_retry() {
    let mut queued = Vec::new();
    for _ in 0..2 {
        assert_eq!(enqueue_clipboard_text("example", |msg| {
            queued.push(clipboard_content(msg));
            0
        }), 0);
    }
    assert_eq!(queued, vec![b"example".to_vec(), b"example".to_vec()]);
}

#[test]
fn failure_does_not_poison_the_next_enqueue() {
    assert_eq!(enqueue_clipboard_text("retry", |_| -3), -3);
    assert_eq!(enqueue_clipboard_text("retry", |msg| {
        assert_eq!(clipboard_content(msg), b"retry");
        0
    }), 0);
}

#[test]
fn unicode_and_compressed_text_round_trip_and_empty_is_not_queued() {
    let sample = "合成测试示例".repeat(120);
    assert_eq!(enqueue_clipboard_text(&sample, |msg| {
        assert_eq!(clipboard_content(msg), sample.as_bytes());
        0
    }), 0);
    assert_eq!(enqueue_clipboard_text("", |_| panic!("empty clipboard was queued")), 0);
}
