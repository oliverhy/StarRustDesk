// Peer-provided close text is untrusted. Export only fixed reason classes to the UI.
pub fn classify_peer_close_reason(reason: &str) -> &'static str {
    match reason.trim() {
        "Remote desktop is offline" => "offline",
        "Connection closed manually by the peer" => "manual",
        "Wrong Password" | "No Password Access" | "Permission denied"
        | "Connection not allowed" | "Connection is not allowed"
        | "Too many wrong password attempts" => "rejected",
        _ => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::classify_peer_close_reason as classify;

    #[test]
    fn only_explicit_offline_is_recoverable() {
        assert_eq!(classify("Remote desktop is offline"), "offline");
        assert_eq!(classify(" Remote desktop is offline\r\n"), "offline");
        for reason in ["", "Restarting remote device", "Connection closed", "Remote desktop is offline password=secret"] {
            assert_eq!(classify(reason), "other");
        }
    }

    #[test]
    fn manual_close_and_auth_denial_are_terminal() {
        assert_eq!(classify("Connection closed manually by the peer"), "manual");
        for reason in ["Wrong Password", "No Password Access", "Permission denied", "Connection not allowed",
            "Connection is not allowed", "Too many wrong password attempts"] {
            assert_eq!(classify(reason), "rejected");
        }
    }
}
