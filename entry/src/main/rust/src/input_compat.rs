//! Per-session input compatibility. Do not change the normal OS Map tables for KVMs.
use hbb_common::message_proto::{key_event, ControlKey, KeyEvent, KeyboardMode};

pub fn is_one_kvm(username: &str, displays: &[String]) -> bool {
    username.trim().eq_ignore_ascii_case("one-kvm")
        && displays.iter().any(|name| name.eq_ignore_ascii_case("KVM Display"))
}

pub fn auto_map_keyboard(platform: &str, one_kvm: bool) -> bool {
    let p = platform.to_ascii_lowercase();
    !one_kvm && (p.contains("mac") || p.contains("darwin") || p.contains("osx"))
}

pub fn control_key_event(code: i32, action: i32, modifiers: i32, mode: i32,
    platform: &str, one_kvm: bool) -> KeyEvent {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Legacy.into(),
        modifiers: super::modifier_mask_to_controls(modifiers & !super::modifier_bit_for_key_code(code)),
        ..Default::default()
    };
    match super::key_code_to_control(code) {
        Some(control) => event.set_control_key(control),
        None => event.union = Some(key_event::Union::Chr(code.max(0) as u32)),
    }
    let mac_map = (mode == 1 || mode == 0) && auto_map_keyboard(platform, one_kvm);
    if mode == 1 || mac_map {
        let mapped = mapped_modifier(code, platform).or_else(|| {
            // Physical navigation/function keys must share the modifier path on
            // macOS. Self-contained toolbar press shortcuts remain Legacy so
            // the receiver applies their explicit modifier list atomically.
            if !mac_map || action == 2 { return None; }
            let hid = match code {
                8 => 0x2a, 9 => 0x2b, 13 => 0x28, 27 => 0x29, 32 => 0x2c,
                33 => 0x4b, 34 => 0x4e, 35 => 0x4d, 36 => 0x4a,
                37 => 0x50, 38 => 0x52, 39 => 0x4f, 40 => 0x51,
                45 => 0x49, 46 => 0x4c, 112..=123 => 0x3a + (code - 112) as u32,
                _ => return None,
            };
            super::map_usb_hid_to_peer_code(hid, platform)
        });
        if let Some(mapped) = mapped {
            event.mode = KeyboardMode::Map.into();
            event.union = Some(key_event::Union::Chr(mapped));
        }
    }
    event
}

pub fn mapped_modifier(code: i32, platform: &str) -> Option<u32> {
    // Windows scan code, Xorg keycode, Android keycode, macOS virtual keycode.
    let codes = match code {
        16 => [0x2a, 50, 59, 56], 161 => [0x36, 62, 60, 60],
        17 => [0x1d, 37, 113, 59], 163 => [0xe01d, 105, 114, 62],
        18 => [0x38, 64, 57, 58], 165 => [0xe038, 108, 58, 61],
        91 => [0xe05b, 133, 117, 55], 92 => [0xe05c, 134, 118, 54],
        20 => [0x3a, 66, 115, 57],
        _ => return None,
    };
    let p = platform.to_ascii_lowercase();
    Some(codes[if p.contains("linux") { 1 } else if p.contains("android") { 2 }
        else if p.contains("mac") || p.contains("darwin") || p.contains("osx") { 3 } else { 0 }])
}

pub fn legacy_physical_key(hid: u32, action: i32, modifiers: i32) -> Option<KeyEvent> {
    let mut event = KeyEvent {
        down: action == 0,
        press: action == 2,
        mode: KeyboardMode::Legacy.into(),
        modifiers: super::modifier_mask_to_controls(modifiers),
        ..Default::default()
    };
    // Use characters, NOT OS scan codes. Preserve modifiers for shortcuts and USB HID.
    let ch = match hid {
        0x04..=0x1d => Some(b'a' as u32 + hid - 4),
        0x1e..=0x26 => Some(b'1' as u32 + hid - 0x1e),
        0x27 => Some(b'0' as u32),
        0x2c => Some(b' ' as u32),
        0x2d..=0x38 => Some(b"-=[]\\#;'`,./"[(hid - 0x2d) as usize] as u32),
        _ => None,
    };
    if let Some(ch) = ch {
        // Unicode disambiguates punctuation from legacy VK/control codes in KVM adapters.
        event.union = Some(if hid >= 0x2d {
            key_event::Union::Unicode(ch)
        } else {
            key_event::Union::Chr(ch)
        });
        return Some(event);
    }
    let control = match hid {
        0x28 => ControlKey::Return, 0x29 => ControlKey::Escape,
        0x2a => ControlKey::Backspace, 0x2b => ControlKey::Tab,
        0x39 => ControlKey::CapsLock,
        0x3a => ControlKey::F1, 0x3b => ControlKey::F2, 0x3c => ControlKey::F3,
        0x3d => ControlKey::F4, 0x3e => ControlKey::F5, 0x3f => ControlKey::F6,
        0x40 => ControlKey::F7, 0x41 => ControlKey::F8, 0x42 => ControlKey::F9,
        0x43 => ControlKey::F10, 0x44 => ControlKey::F11, 0x45 => ControlKey::F12,
        0x49 => ControlKey::Insert, 0x4a => ControlKey::Home, 0x4b => ControlKey::PageUp,
        0x4c => ControlKey::Delete, 0x4d => ControlKey::End, 0x4e => ControlKey::PageDown,
        0x4f => ControlKey::RightArrow, 0x50 => ControlKey::LeftArrow,
        0x51 => ControlKey::DownArrow, 0x52 => ControlKey::UpArrow,
        _ => return None,
    };
    event.union = Some(key_event::Union::ControlKey(control.into()));
    Some(event)
}

// Soft-keyboard shortcuts supply VK-style key identities, while Legacy Chr is
// a Unicode character. Do not pass these identities through as uppercase text,
// and do not feed lowercase characters back through the control-key VK table.
pub fn printable_shortcut_key(key_code: i32, modifiers: i32) -> Option<KeyEvent> {
    let shift = modifiers & 2 != 0;
    let ch = match key_code {
        65..=90 => if shift { key_code as u32 } else { (key_code + 32) as u32 },
        48..=57 => if shift { b")!@#$%^&*("[(key_code - 48) as usize] as u32 }
            else { key_code as u32 },
        186 => (if shift { ':' } else { ';' }) as u32,
        187 => (if shift { '+' } else { '=' }) as u32,
        188 => (if shift { '<' } else { ',' }) as u32,
        189 => (if shift { '_' } else { '-' }) as u32,
        190 => (if shift { '>' } else { '.' }) as u32,
        191 => (if shift { '?' } else { '/' }) as u32,
        192 => (if shift { '~' } else { '`' }) as u32,
        219 => (if shift { '{' } else { '[' }) as u32,
        220 => (if shift { '|' } else { '\\' }) as u32,
        221 => (if shift { '}' } else { ']' }) as u32,
        222 => (if shift { '"' } else { '\'' }) as u32,
        _ => return None,
    };
    Some(KeyEvent {
        press: true,
        mode: KeyboardMode::Legacy.into(),
        modifiers: super::modifier_mask_to_controls(modifiers),
        union: Some(key_event::Union::Chr(ch)),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn printable_hotkeys_do_not_invent_shift_or_alias_function_keys() {
        for code in 65..=90 {
            for mask in [1, 4, 8, 1 | 4, 1 | 8] {
                let event = printable_shortcut_key(code, mask).unwrap();
                assert_eq!(event.union, Some(key_event::Union::Chr((code + 32) as u32)));
                assert_eq!(event.modifiers, super::super::modifier_mask_to_controls(mask));
                assert!(!event.modifiers.contains(&ControlKey::Shift.into()));
                assert!(event.press);
                assert!(!event.down);
                assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Legacy);
            }
        }
        assert_eq!(printable_shortcut_key(81, 1).unwrap().chr(), 'q' as u32);
        assert_eq!(super::super::key_code_to_control(113), Some(ControlKey::F2));
        assert!(printable_shortcut_key(113, 1).is_none());
        assert!(printable_shortcut_key(46, 1).is_none());
    }

    #[test]
    fn printable_shortcuts_preserve_explicit_shift_and_punctuation() {
        for mask in [2, 3, 6, 10, 15] {
            for code in 65..=90 {
                let event = printable_shortcut_key(code, mask).unwrap();
                assert_eq!(event.chr(), code as u32);
                assert_eq!(event.modifiers, super::super::modifier_mask_to_controls(mask));
            }
        }
        for code in 48..=57 {
            assert_eq!(printable_shortcut_key(code, 1).unwrap().chr(), code as u32);
            assert_eq!(printable_shortcut_key(code, 3).unwrap().chr(), b")!@#$%^&*("[(code - 48) as usize] as u32);
        }
        for (code, normal, shifted) in [(186, ';', ':'), (187, '=', '+'),
            (188, ',', '<'), (189, '-', '_'), (190, '.', '>'), (191, '/', '?'),
            (192, '`', '~'), (219, '[', '{'), (220, '\\', '|'), (221, ']', '}'), (222, '\'', '"')] {
            assert_eq!(printable_shortcut_key(code, 1).unwrap().chr(), normal as u32);
            assert_eq!(printable_shortcut_key(code, 3).unwrap().chr(), shifted as u32);
        }
    }

    #[test]
    fn kvm_detection_is_narrow() {
        assert!(is_one_kvm("one-kvm", &["KVM Display".into()]));
        assert!(!is_one_kvm("someone", &["KVM Display".into()]));
        assert!(!is_one_kvm("one-kvm", &["Display 1".into()]));
    }
    #[test]
    fn d_is_character_not_windows_space_scan_code() {
        let event = legacy_physical_key(7, 0, 3).unwrap();
        assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Legacy);
        assert!(matches!(event.union, Some(key_event::Union::Chr(100))));
        assert_eq!(event.modifiers.len(), 2);
        assert!(event.down);
        assert!(!legacy_physical_key(7, 1, 0).unwrap().down);
    }
    #[test]
    fn punctuation_and_controls_do_not_alias() {
        assert!(matches!(legacy_physical_key(0x2f, 0, 0).unwrap().union,
            Some(key_event::Union::Unicode(91))));
        assert!(matches!(legacy_physical_key(0x28, 0, 0).unwrap().union,
            Some(key_event::Union::ControlKey(_))));
        assert!(legacy_physical_key(0xffff, 0, 0).is_none());
    }
    #[test]
    fn explicit_map_modifiers_follow_target_platform() {
        assert_eq!(mapped_modifier(16, "Windows"), Some(0x2a));
        assert_eq!(mapped_modifier(163, "Linux"), Some(105));
        assert_eq!(mapped_modifier(91, "Mac OS"), Some(55));
        assert_eq!(mapped_modifier(20, "Android"), Some(115));
        assert_eq!(mapped_modifier(13, "Windows"), None);
    }

    #[test]
    fn mac_auto_modifiers_and_letter_use_the_same_map_protocol() {
        for platform in ["Mac OS", "macOS", "Darwin", "OSX"] {
            assert!(auto_map_keyboard(platform, false));
            for (key, mapped, mask) in [(17, 59, 1), (163, 62, 1), (16, 56, 2),
                (161, 60, 2), (18, 58, 4), (165, 61, 4), (91, 55, 8), (92, 54, 8)] {
                for action in [0, 1] {
                    let event = control_key_event(key, action, mask, 0, platform, false);
                    assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Map);
                    assert_eq!(event.chr(), mapped);
                    assert_eq!(event.down, action == 0);
                    assert!(!event.press);
                    assert!(event.modifiers.is_empty(), "do not echo a modifier into its own flags");
                }
            }
            assert_eq!(super::super::map_usb_hid_to_peer_code(0x14, platform), Some(12));
            assert_eq!(super::super::map_usb_hid_to_peer_code(0x04, platform), Some(0));
        }
    }

    #[test]
    fn mac_navigation_and_function_keys_keep_raw_modifier_context() {
        for mode in [0, 1] {
            for (key, mapped) in [(38, 126), (40, 125), (37, 123), (39, 124), (114, 99),
                (33, 116), (34, 121), (36, 115), (35, 119), (13, 36), (46, 117)] {
                for action in [0, 1] {
                    let event = control_key_event(key, action, 3, mode, "Mac OS", false);
                    assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Map);
                    assert_eq!(event.chr(), mapped);
                    assert_eq!(event.modifiers.len(), 2);
                    assert_eq!(event.down, action == 0);
                }
            }
        }
    }

    #[test]
    fn mac_explicit_legacy_and_self_contained_shortcuts_remain_compatible() {
        let legacy = control_key_event(91, 0, 8, 2, "Mac OS", false);
        assert_eq!(legacy.mode.enum_value().unwrap(), KeyboardMode::Legacy);
        assert_eq!(legacy.control_key(), ControlKey::Meta);
        let shortcut = control_key_event(38, 2, 1, 0, "Mac OS", false);
        assert_eq!(shortcut.mode.enum_value().unwrap(), KeyboardMode::Legacy);
        assert!(shortcut.press);
        assert_eq!(shortcut.control_key(), ControlKey::UpArrow);
        assert_eq!(shortcut.modifiers, super::super::modifier_mask_to_controls(1));
    }

    #[test]
    fn other_targets_and_auto_kvm_do_not_change_keyboard_policy() {
        for platform in ["Windows", "Linux", "Android", "", "Mac OS"] {
            let kvm = platform == "Mac OS";
            assert!(!auto_map_keyboard(platform, kvm));
            let event = control_key_event(17, 0, 3, 0, platform, kvm);
            assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Legacy);
            assert_eq!(event.control_key(), ControlKey::Control);
            assert_eq!(event.modifiers, super::super::modifier_mask_to_controls(2));
        }
        for platform in ["Windows", "Linux", "Android", "Mac OS"] {
            let event = control_key_event(163, 0, 1, 1, platform, false);
            assert_eq!(event.mode.enum_value().unwrap(), KeyboardMode::Map);
            assert_eq!(event.chr(), mapped_modifier(163, platform).unwrap());
        }
    }
}
