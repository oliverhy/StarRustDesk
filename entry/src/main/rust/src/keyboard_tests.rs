use super::{
    ctrl_alt_del_event, key_code_to_control, map_usb_hid_to_peer_code, modifier_bit_for_key_code,
};
use hbb_common::message_proto::{key_event, ControlKey, KeyboardMode};

#[test]
fn linux_uses_xorg_codes_instead_of_windows_scan_codes() {
    assert_eq!(map_usb_hid_to_peer_code(0x14, "Linux"), Some(24)); // Q
    assert_eq!(map_usb_hid_to_peer_code(0x1A, "Linux"), Some(25)); // W
    assert_eq!(map_usb_hid_to_peer_code(0x04, "Linux"), Some(38)); // A
    assert_eq!(map_usb_hid_to_peer_code(0x1E, "Linux"), Some(10)); // 1
}

#[test]
fn windows_keeps_set_one_scan_codes() {
    assert_eq!(map_usb_hid_to_peer_code(0x14, "Windows"), Some(0x10));
    assert_eq!(map_usb_hid_to_peer_code(0x1A, "Windows"), Some(0x11));
    assert_eq!(map_usb_hid_to_peer_code(0x04, "Windows"), Some(0x1E));
    assert_eq!(map_usb_hid_to_peer_code(0x1E, "Windows"), Some(0x02));
}

#[test]
fn android_and_macos_use_native_target_codes() {
    assert_eq!(map_usb_hid_to_peer_code(0x14, "Android"), Some(45));
    assert_eq!(map_usb_hid_to_peer_code(0x1A, "Android"), Some(51));
    assert_eq!(map_usb_hid_to_peer_code(0x04, "macOS"), Some(0));
    assert_eq!(map_usb_hid_to_peer_code(0x14, "Mac OS"), Some(12));
}

#[test]
fn punctuation_and_unknown_platform_are_stable() {
    assert_eq!(map_usb_hid_to_peer_code(0x36, "Linux"), Some(59)); // comma
    assert_eq!(map_usb_hid_to_peer_code(0x38, "Windows"), Some(0x35)); // slash
    assert_eq!(map_usb_hid_to_peer_code(0x35, "Android"), Some(68)); // grave
    assert_eq!(map_usb_hid_to_peer_code(0x04, ""), Some(0x1E));
    assert_eq!(map_usb_hid_to_peer_code(0xFF, "Linux"), None);
}

#[test]
fn right_side_modifiers_follow_rustdesk_protocol_controls() {
    assert_eq!(key_code_to_control(161), Some(ControlKey::RShift));
    assert_eq!(key_code_to_control(163), Some(ControlKey::RControl));
    assert_eq!(key_code_to_control(165), Some(ControlKey::RAlt));
    assert_eq!(key_code_to_control(92), Some(ControlKey::RWin));
}

#[test]
fn function_keys_follow_rustdesk_protocol_controls() {
    assert_eq!(key_code_to_control(112), Some(ControlKey::F1));
    assert_eq!(key_code_to_control(114), Some(ControlKey::F3));
    assert_eq!(key_code_to_control(123), Some(ControlKey::F12));
}

#[test]
fn mobile_keyboard_helper_keys_follow_rustdesk_protocol_controls() {
    assert_eq!(key_code_to_control(33), Some(ControlKey::PageUp));
    assert_eq!(key_code_to_control(34), Some(ControlKey::PageDown));
    assert_eq!(key_code_to_control(35), Some(ControlKey::End));
    assert_eq!(key_code_to_control(36), Some(ControlKey::Home));
    assert_eq!(key_code_to_control(45), Some(ControlKey::Insert));
    assert_eq!(key_code_to_control(46), Some(ControlKey::Delete));
    assert_eq!(key_code_to_control(44), Some(ControlKey::Snapshot));
    assert_eq!(key_code_to_control(93), Some(ControlKey::Apps));
}

#[test]
fn both_sides_share_the_same_aggregate_modifier_bit() {
    assert_eq!(
        modifier_bit_for_key_code(16),
        modifier_bit_for_key_code(161)
    );
    assert_eq!(
        modifier_bit_for_key_code(17),
        modifier_bit_for_key_code(163)
    );
    assert_eq!(
        modifier_bit_for_key_code(18),
        modifier_bit_for_key_code(165)
    );
    assert_eq!(modifier_bit_for_key_code(91), modifier_bit_for_key_code(92));
}

#[test]
fn windows_ctrl_alt_del_uses_secure_attention_control() {
    let event = ctrl_alt_del_event("Windows");
    assert_eq!(event.mode, KeyboardMode::Legacy.into());
    assert!(event.down);
    assert!(!event.press);
    assert!(event.modifiers.is_empty());
    assert_eq!(
        event.union,
        Some(key_event::Union::ControlKey(ControlKey::CtrlAltDel.into()))
    );
}

#[test]
fn linux_ctrl_alt_del_uses_delete_with_ctrl_and_alt() {
    let event = ctrl_alt_del_event("Linux");
    assert!(!event.down);
    assert!(event.press);
    assert_eq!(
        event.union,
        Some(key_event::Union::ControlKey(ControlKey::Delete.into()))
    );
    assert!(event.modifiers.contains(&ControlKey::Control.into()));
    assert!(event.modifiers.contains(&ControlKey::Alt.into()));
}
