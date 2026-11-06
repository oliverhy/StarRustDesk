use hbb_common::message_proto::ImageQuality;

#[derive(Clone, Copy, Debug)]
pub(crate) struct PerformanceConfig {
    pub fps: i32,
    pub quality: ImageQuality,
    // Percentage, not kbps. RustDesk's wire format stores this in the high bits.
    pub custom_quality: i32,
}

impl PerformanceConfig {
    pub const DEFAULT: Self = Self { fps: 45, quality: ImageQuality::Low, custom_quality: 0 };

    pub fn from_preset(preset: &str) -> Self {
        let (fps, quality) = match preset {
            "stable" => (30, ImageQuality::Balanced),
            "high_fps" => (60, ImageQuality::Balanced),
            "silky" => (60, ImageQuality::Low),
            "best" => (30, ImageQuality::Best),
            _ => {
                let parts: Vec<&str> = preset.split(':').collect();
                if parts.len() == 3 && parts[0] == "custom"
                    && (1..=4).contains(&parts[1].len()) && (1..=3).contains(&parts[2].len())
                    && parts[1].bytes().all(|v| v.is_ascii_digit())
                    && parts[2].bytes().all(|v| v.is_ascii_digit()) {
                    if let (Ok(quality), Ok(fps)) = (parts[1].parse::<i32>(), parts[2].parse::<i32>()) {
                        return Self { fps: fps.clamp(5, 120), quality: ImageQuality::NotSet,
                            custom_quality: quality.clamp(10, 2000) };
                    }
                }
                return Self::DEFAULT;
            }
        };
        Self { fps, quality, custom_quality: 0 }
    }

    pub fn effective(self, background: bool, public_relay: bool) -> Self {
        if background {
            return Self { fps: 2, ..Self::DEFAULT };
        }
        if public_relay && self.custom_quality > 0 {
            // Match upstream LoginConfigHandler::get_option_message.
            return Self { fps: self.fps.min(30),
                custom_quality: if self.custom_quality > 100 { 50 } else { self.custom_quality }, ..self };
        }
        self
    }

    // A temporary stream policy, not a new saved image-quality preset.
    // Keep the user's original settings untouched when game mode is left.
    pub fn for_session(self, game: bool, game_fps: i32, background: bool, public_relay: bool) -> Self {
        self.for_session_with_priority(game, game_fps, false, background, public_relay)
    }

    // Priority is an explicit request, not a guarantee of the peer's output.
    // Preserve a custom choice; otherwise offer a bounded 60 FPS / 100% target.
    // The existing public-relay and background policies always remain in force.
    pub fn for_session_with_priority(self, game: bool, game_fps: i32, priority: bool,
        background: bool, public_relay: bool) -> Self {
        let selected = if priority && self.custom_quality > 0 {
            self
        } else if priority {
            Self { fps: self.fps.max(60), quality: ImageQuality::NotSet, custom_quality: 100 }
        } else if game {
            Self { fps: game_fps.clamp(20, 60), quality: ImageQuality::Low, custom_quality: 0 }
        } else {
            self
        };
        let selected = if game && !priority && public_relay { Self { fps: selected.fps.min(30), ..selected } } else { selected };
        selected.effective(background, public_relay)
    }

    pub fn wire_quality(self) -> i32 { self.custom_quality << 8 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_and_invalid_inputs() {
        assert_eq!(PerformanceConfig::from_preset("best").quality, ImageQuality::Best);
        for (name, fps) in [("stable", 30), ("high_fps", 60), ("smooth", 45), ("silky", 60)] {
            let p = PerformanceConfig::from_preset(name);
            assert_eq!(p.fps, fps);
            assert_eq!(p.wire_quality(), 0);
        }
        for invalid in ["custom", "custom:NaN:60", "custom:-1:30", "custom:100:60:1", "custom:999999:30", "custom::30"] {
            assert_eq!(PerformanceConfig::from_preset(invalid).quality, ImageQuality::Low);
        }
    }

    #[test]
    fn custom_protocol_and_limits() {
        let p = PerformanceConfig::from_preset("custom:2000:120");
        assert_eq!(p.quality, ImageQuality::NotSet);
        assert_eq!(p.wire_quality(), 2000 << 8);
        assert_eq!(p.fps, 120);
        let min = PerformanceConfig::from_preset("custom:0:0");
        assert_eq!((min.custom_quality, min.fps), (10, 5));
        let max = PerformanceConfig::from_preset("custom:9999:999");
        assert_eq!((max.custom_quality, max.fps), (2000, 120));
    }

    #[test]
    fn public_relay_and_background_do_not_destroy_saved_quality() {
        let p = PerformanceConfig::from_preset("custom:500:60");
        let relay = p.effective(false, true);
        assert_eq!((relay.custom_quality, relay.fps), (50, 30));
        let bg = p.effective(true, false);
        assert_eq!((bg.custom_quality, bg.fps, bg.quality), (0, 2, ImageQuality::Low));
        let restored = p.effective(false, false);
        assert_eq!((restored.custom_quality, restored.fps), (500, 60));
        let low = PerformanceConfig::from_preset("custom:80:20").effective(false, true);
        assert_eq!((low.custom_quality, low.fps), (80, 20));
    }

    #[test]
    fn game_mode_is_temporary_bounded_and_respects_background_and_public_relay() {
        let saved = PerformanceConfig::from_preset("custom:500:90");
        let game = saved.for_session(true, 60, false, false);
        assert_eq!((game.fps, game.quality, game.custom_quality), (60, ImageQuality::Low, 0));
        assert_eq!(saved.for_session(true, 10, false, false).fps, 20);
        assert_eq!(saved.for_session(true, 90, false, false).fps, 60);
        assert_eq!(saved.for_session(true, 60, false, true).fps, 30);
        assert_eq!(saved.for_session(true, 60, true, false).fps, 2);
        let restored = saved.for_session(false, 30, false, false);
        assert_eq!((restored.fps, restored.custom_quality), (90, 500));
    }

    #[test]
    fn high_performance_is_opt_in_preserves_custom_and_never_bypasses_safety_caps() {
        let custom = PerformanceConfig::from_preset("custom:500:90");
        let priority = custom.for_session_with_priority(true, 20, true, false, false);
        assert_eq!((priority.fps, priority.custom_quality), (90, 500));
        let relay = custom.for_session_with_priority(true, 20, true, false, true);
        assert_eq!((relay.fps, relay.custom_quality), (30, 50));
        let background = custom.for_session_with_priority(true, 20, true, true, false);
        assert_eq!((background.fps, background.custom_quality), (2, 0));
        let standard = PerformanceConfig::from_preset("smooth");
        let requested = standard.for_session_with_priority(false, 60, true, false, false);
        assert_eq!((requested.fps, requested.custom_quality), (60, 100));
        let restored = standard.for_session_with_priority(false, 60, false, false, false);
        assert_eq!((restored.fps, restored.custom_quality), (45, 0));
    }

    #[test]
    fn live_game_mode_waits_for_auth_and_restores_the_original_wire_options() {
        use crate::{message, misc, QueuedPeerCommand, CONNECTION_ACTIVE, CONNECTION_ROUTE,
            FILE_ONLY_SESSION, BACKGROUND_VIDEO_MODE, USING_PUBLIC_SERVER, GAME_MODE,
            GAME_FPS_CAP, HIGH_PERFORMANCE_PRIORITY, PERFORMANCE_CONFIG, PEER_MESSAGE_SENDER, SESSION_ID};
        use std::sync::atomic::Ordering;
        let old_active = CONNECTION_ACTIVE.swap(true, Ordering::SeqCst);
        let old_route = CONNECTION_ROUTE.swap(1, Ordering::SeqCst);
        let old_file = FILE_ONLY_SESSION.swap(false, Ordering::SeqCst);
        let old_background = BACKGROUND_VIDEO_MODE.swap(false, Ordering::SeqCst);
        let old_public = USING_PUBLIC_SERVER.swap(false, Ordering::SeqCst);
        let old_mode = GAME_MODE.swap(false, Ordering::SeqCst);
        let old_fps = GAME_FPS_CAP.swap(60, Ordering::SeqCst);
        let old_priority = HIGH_PERFORMANCE_PRIORITY.swap(false, Ordering::SeqCst);
        let old_config = *PERFORMANCE_CONFIG.lock().unwrap();
        *PERFORMANCE_CONFIG.lock().unwrap() = PerformanceConfig::from_preset("custom:500:90");
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let old_sender = PEER_MESSAGE_SENDER.lock().unwrap().replace((SESSION_ID.load(Ordering::SeqCst), sender));

        // A connected socket is not proof that peer login has completed.
        assert_eq!(crate::rust_set_game_mode(1, 0), 0);
        assert!(receiver.try_recv().is_err());
        assert_eq!(crate::rust_set_game_mode(1, 1), 0);
        let option = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => match message.union {
                Some(message::Union::Misc(m)) => match m.union {
                    Some(misc::Union::Option(option)) => option,
                    _ => panic!("expected option"),
                },
                _ => panic!("expected misc"),
            },
            _ => panic!("expected message"),
        };
        assert_eq!(option.image_quality.enum_value(), Ok(ImageQuality::Low));
        assert_eq!(option.custom_fps, 60);
        assert_eq!(option.custom_image_quality, 0);
        assert!(option.supported_decoding.is_none(), "codec/recording preferences stay intact");
        let fps = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => message.misc().auto_adjust_fps(),
            _ => panic!("expected fps message"),
        };
        assert_eq!(fps, 60);
        assert_eq!(crate::rust_set_game_fps(40, 1), 0);
        let fps_only = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => message.misc().option().clone(),
            _ => panic!("expected fps-only option"),
        };
        assert_eq!(fps_only.image_quality.enum_value(), Ok(ImageQuality::NotSet));
        assert_eq!((fps_only.custom_image_quality, fps_only.custom_fps), (0, 40));
        assert!(fps_only.supported_decoding.is_none());
        let fps = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => message.misc().auto_adjust_fps(),
            _ => panic!("expected fps message"),
        };
        assert_eq!(fps, 40);
        assert_eq!(crate::rust_set_high_performance(1, 1), 0);
        let priority = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => message.misc().option().clone(),
            _ => panic!("expected priority option"),
        };
        assert_eq!((priority.custom_fps, priority.custom_image_quality), (90, 500 << 8));
        assert_eq!(crate::rust_get_requested_performance_fps(), 90);
        assert_eq!(crate::rust_get_requested_bitrate_percent(), 500);
        let _ = receiver.try_recv().unwrap(); // corresponding FPS hint
        USING_PUBLIC_SERVER.store(true, Ordering::SeqCst);
        CONNECTION_ROUTE.store(2, Ordering::SeqCst);
        assert_eq!((crate::rust_get_requested_performance_fps(), crate::rust_get_requested_bitrate_percent()), (30, 50));
        USING_PUBLIC_SERVER.store(false, Ordering::SeqCst);
        CONNECTION_ROUTE.store(1, Ordering::SeqCst);
        assert_eq!(crate::rust_set_high_performance(0, 1), 0);
        let game_again = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => message.misc().option().clone(),
            _ => panic!("expected restored game option"),
        };
        assert_eq!((game_again.custom_fps, game_again.custom_image_quality), (40, 0));
        let _ = receiver.try_recv().unwrap();
        assert_eq!(crate::rust_set_game_mode(0, 1), 0);
        let restored = match receiver.try_recv().unwrap() {
            QueuedPeerCommand::Message { message, .. } => message.misc().option().clone(),
            _ => panic!("expected option message"),
        };
        assert_eq!((restored.custom_fps, restored.custom_image_quality), (90, 500 << 8));
        assert_eq!(crate::rust_set_game_fps(30, 1), -3);

        *PEER_MESSAGE_SENDER.lock().unwrap() = old_sender;
        *PERFORMANCE_CONFIG.lock().unwrap() = old_config;
        CONNECTION_ACTIVE.store(old_active, Ordering::SeqCst);
        CONNECTION_ROUTE.store(old_route, Ordering::SeqCst);
        FILE_ONLY_SESSION.store(old_file, Ordering::SeqCst);
        BACKGROUND_VIDEO_MODE.store(old_background, Ordering::SeqCst);
        USING_PUBLIC_SERVER.store(old_public, Ordering::SeqCst);
        GAME_MODE.store(old_mode, Ordering::SeqCst);
        GAME_FPS_CAP.store(old_fps, Ordering::SeqCst);
        HIGH_PERFORMANCE_PRIORITY.store(old_priority, Ordering::SeqCst);
    }
}
