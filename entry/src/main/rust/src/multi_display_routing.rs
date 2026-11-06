//! Display-tagged video routing. The caller must opt in to a secondary stream
//! only after it has established an independent decoder and presentation surface.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameDestination {
    Primary(i32),
    Secondary(i32),
    Drop,
}

/// Only advertise an extension after the peer can label separate video streams.
/// This is a protocol gate, not a guarantee that a device has a free decoder.
pub fn supports_secondary(connected: bool, file_only: bool, tagged_frames: bool, wayland: bool) -> bool {
    connected && !file_only && tagged_frames && !wayland
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DisplaySelection {
    pub primary: i32,
    pub secondary: i32,
}

impl DisplaySelection {
    /// A peer without tagged frames must never receive a multi-screen request.
    pub fn checked(primary: i32, secondary: i32, display_count: usize,
                   peer_tags_frames: bool) -> Option<Self> {
        if !peer_tags_frames || primary == secondary || primary < 0 || secondary < 0 ||
            primary as usize >= display_count || secondary as usize >= display_count {
            return None;
        }
        Some(Self { primary, secondary })
    }

    pub fn capture_set(self) -> Vec<i32> { vec![self.primary, self.secondary] }
}

pub fn frame_destination(frame_display: i32, primary_display: i32,
                         secondary_display: Option<i32>, peer_tags_frames: bool) -> FrameDestination {
    // Older peers do not identify the source display; routing their frames to
    // a second decoder would make two independent screens impossible to tell apart.
    if !peer_tags_frames {
        return FrameDestination::Primary(primary_display);
    }
    let frame_display = frame_display.max(0);
    if frame_display == primary_display {
        return FrameDestination::Primary(primary_display);
    }
    if secondary_display == Some(frame_display) && frame_display != primary_display {
        return FrameDestination::Secondary(frame_display);
    }
    FrameDestination::Drop
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_screen_matches_existing_selection_and_discards_stale_frames() {
        assert_eq!(frame_destination(2, 2, None, true), FrameDestination::Primary(2));
        assert_eq!(frame_destination(1, 2, None, true), FrameDestination::Drop);
        assert_eq!(frame_destination(-1, 0, None, true), FrameDestination::Primary(0));
    }

    #[test]
    fn routes_only_the_two_explicit_screens() {
        assert_eq!(frame_destination(1, 1, Some(3), true), FrameDestination::Primary(1));
        assert_eq!(frame_destination(3, 1, Some(3), true), FrameDestination::Secondary(3));
        assert_eq!(frame_destination(2, 1, Some(3), true), FrameDestination::Drop);
        assert_eq!(frame_destination(1, 1, Some(1), true), FrameDestination::Primary(1));
    }

    #[test]
    fn untagged_legacy_peer_is_never_routed_to_secondary() {
        assert_eq!(frame_destination(3, 1, Some(3), false), FrameDestination::Primary(1));
        assert_eq!(frame_destination(0, 2, None, false), FrameDestination::Primary(2));
    }

    #[test]
    fn capture_set_requires_distinct_known_displays_and_tagged_frames() {
        let selection = DisplaySelection::checked(2, 0, 3, true).unwrap();
        assert_eq!(selection.capture_set(), vec![2, 0]);
        assert_eq!(DisplaySelection::checked(0, 1, 2, false), None);
        assert_eq!(DisplaySelection::checked(0, 0, 2, true), None);
        assert_eq!(DisplaySelection::checked(0, 2, 2, true), None);
        assert_eq!(DisplaySelection::checked(-1, 0, 2, true), None);
        assert_eq!(DisplaySelection::checked(0, 1, 0, true), None);
    }

    #[test]
    fn secondary_capability_fails_closed_without_a_compatible_active_session() {
        assert!(supports_secondary(true, false, true, false));
        assert!(!supports_secondary(false, false, true, false));
        assert!(!supports_secondary(true, true, true, false));
        assert!(!supports_secondary(true, false, false, false));
        assert!(!supports_secondary(true, false, true, true));
    }
}
