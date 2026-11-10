//! Content-free input diagnostics. Never include a key identity, text payload,
//! Unicode value or scan code: even numeric positions can reconstruct passwords.
use hbb_common::message_proto::{message, ControlKey, Message};

pub fn trace_summary(stage: &str, msg: &Message) -> Option<String> {
    match &msg.union {
        Some(message::Union::MouseEvent(event)) if event.mask & 7 != 0 => Some(format!(
            "input-trace: stage={stage} type=mouse mask={} x={} y={} modifiers=[{}]",
            event.mask, event.x, event.y, modifier_summary(&event.modifiers)
        )),
        Some(message::Union::KeyEvent(event)) => Some(format!(
            "input-trace: stage={stage} type=key key=redacted down={} press={} mode={} modifiers=[{}]",
            event.down, event.press, event.mode.value(), modifier_summary(&event.modifiers)
        )),
        _ => None,
    }
}

fn modifier_summary(modifiers: &[protobuf::EnumOrUnknown<ControlKey>]) -> String {
    modifiers
        .iter()
        .filter_map(|modifier| match modifier.enum_value().ok()? {
            ControlKey::Control | ControlKey::RControl => Some("ctrl"),
            ControlKey::Shift | ControlKey::RShift => Some("shift"),
            ControlKey::Alt | ControlKey::RAlt => Some("alt"),
            ControlKey::Meta | ControlKey::RWin => Some("meta"),
            ControlKey::CapsLock => Some("caps"),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join(",")
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::message_proto::{key_event, KeyEvent, KeyboardMode, MouseEvent};

    #[test]
    fn all_key_payloads_have_identical_content_free_diagnostics() {
        let payloads = [
            key_event::Union::Chr(11),
            key_event::Union::Chr(53),
            key_event::Union::Unicode(0x4e2d),
            key_event::Union::Seq("synthetic-password-do-not-log".to_owned()),
            key_event::Union::Win2winHotkey(0x415a1234),
            key_event::Union::ControlKey(ControlKey::Numpad5.into()),
            key_event::Union::ControlKey(protobuf::EnumOrUnknown::from_i32(12345)),
        ];
        for payload in payloads {
            let mut msg = Message::new();
            msg.set_key_event(KeyEvent {
                down: true,
                mode: KeyboardMode::Map.into(),
                union: Some(payload),
                modifiers: vec![ControlKey::Shift.into()],
                ..Default::default()
            });
            let before = msg.clone();
            for stage in ["queue", "network_send", "network_sent"] {
                assert_eq!(trace_summary(stage, &msg).unwrap(), format!(
                    "input-trace: stage={stage} type=key key=redacted down=true press=false mode=1 modifiers=[shift]"));
            }
            assert_eq!(
                msg, before,
                "redaction must never change the transmitted key event"
            );
        }
    }

    #[test]
    fn release_and_combination_state_remain_available_without_key_codes() {
        let mut msg = Message::new();
        msg.set_key_event(KeyEvent {
            down: false,
            press: true,
            modifiers: vec![
                ControlKey::Control.into(),
                ControlKey::Alt.into(),
                ControlKey::Meta.into(),
                ControlKey::Numpad9.into(),
            ],
            ..Default::default()
        });
        assert_eq!(trace_summary("network_sent", &msg).unwrap(),
            "input-trace: stage=network_sent type=key key=redacted down=false press=true mode=0 modifiers=[ctrl,alt,meta]");
    }

    #[test]
    fn mouse_buttons_are_diagnosable_but_moves_and_unrelated_messages_are_not_logged() {
        let mut msg = Message::new();
        msg.set_mouse_event(MouseEvent {
            mask: 9,
            x: 10,
            y: 20,
            ..Default::default()
        });
        assert_eq!(
            trace_summary("queue", &msg).unwrap(),
            "input-trace: stage=queue type=mouse mask=9 x=10 y=20 modifiers=[]"
        );
        msg.set_mouse_event(MouseEvent {
            mask: 0,
            ..Default::default()
        });
        assert!(trace_summary("queue", &msg).is_none());
        assert!(trace_summary("queue", &Message::new()).is_none());
    }
}
