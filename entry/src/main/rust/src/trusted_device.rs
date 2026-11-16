//! RustDesk trusted-device V2 client state. The platform store contains only a
//! 32-byte credential under a scope derived from verified identities. Neither
//! credentials nor the scope are diagnostic data.
use hbb_common::message_proto::{LoginRequest, LoginResponse};
use hbb_common::sha2::{Digest, Sha256};

pub const TOKEN_SIZE: usize = 32;
pub type Scope = [u8; 32];
pub type Token = [u8; TOKEN_SIZE];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum TrustMode { Disabled, Legacy, V2 }

pub enum LoadResult { Missing, Present(Token), Unavailable }
pub enum SaveResult { NotRequested, Saved, Failed, Unsolicited }

pub trait CredentialStore: Send + Sync {
    fn load(&self, scope: &Scope) -> LoadResult;
    fn save(&self, scope: &Scope, token: &Token) -> bool;
}

/// Frame each field before hashing so no two field combinations alias. The
/// caller must supply a peer signing key verified on the current E2EE stream.
pub fn scope(peer: &str, server: &str, server_key: &str, peer_key: &[u8; 32]) -> Scope {
    let mut hash = Sha256::new();
    hash.update(b"starrustdesk.trusted-device.v2\0");
    for field in [peer.as_bytes(), server.as_bytes(), server_key.as_bytes(), peer_key.as_slice()] {
        hash.update((field.len() as u64).to_be_bytes());
        hash.update(field);
    }
    hash.finalize().into()
}

pub struct Session {
    pub session_id: u64,
    scope: Option<Scope>,
    token: Option<Token>,
    pub store_unavailable: bool,
    pub offered_v2: bool,
    pub mode: TrustMode,
    pub requested_v2: bool,
    pub awaiting_2fa: bool,
    pub notice: i32,
}

impl Session {
    pub fn unavailable(session_id: u64, verified: bool) -> Self {
        Self { session_id, scope: None, token: None, store_unavailable: verified,
            offered_v2: false, mode: TrustMode::Disabled, requested_v2: false, awaiting_2fa: false,
            notice: 0 }
    }

    pub fn new(session_id: u64, scope: Option<Scope>, store: &dyn CredentialStore) -> Self {
        let mut session = Self { session_id, scope, token: None, store_unavailable: false,
            offered_v2: false, mode: TrustMode::Disabled, requested_v2: false, awaiting_2fa: false, notice: 0 };
        if let Some(scope) = session.scope.as_ref() {
            match store.load(scope) {
                LoadResult::Missing => session.offered_v2 = true,
                LoadResult::Present(token) => { session.token = Some(token); session.offered_v2 = true; }
                LoadResult::Unavailable => session.store_unavailable = true,
            }
        }
        session
    }

    /// Passwordless attempts must not transmit a credential. A missing or
    /// insecurely obtained peer identity never advertises V2 or sends hwid.
    pub fn apply_login(&mut self, request: &mut LoginRequest) {
        self.mode = TrustMode::Disabled;
        self.requested_v2 = false;
        self.awaiting_2fa = false;
        request.trusted_device_v2_token.clear();
        request.trusted_device_v2_supported = false;
        if self.scope.is_none() { request.hwid.clear(); return; }
        request.trusted_device_v2_supported = self.offered_v2;
        if self.offered_v2 && !request.password.is_empty() {
            if let Some(token) = self.token { request.trusted_device_v2_token = token.to_vec().into(); }
        }
    }

    pub fn challenge(&mut self, response: &LoginResponse) -> TrustMode {
        self.requested_v2 = false;
        self.awaiting_2fa = true;
        self.mode = if self.scope.is_none() { TrustMode::Disabled }
            else if response.trusted_device_v2_supported {
                if self.offered_v2 { TrustMode::V2 } else { TrustMode::Disabled }
            }
            else if response.enable_trusted_devices { TrustMode::Legacy }
            else { TrustMode::Disabled };
        if self.store_unavailable && self.mode == TrustMode::Disabled { self.notice = 3; }
        self.mode
    }

    pub fn mark_submitted(&mut self, requested: bool) {
        self.requested_v2 = requested && self.mode == TrustMode::V2;
        self.awaiting_2fa = false;
    }

    /// Never accept a credential that was not explicitly requested in this
    /// session, including unsolicited legacy-to-V2 migration responses.
    pub fn finish(&mut self, response: &LoginResponse, store: &dyn CredentialStore) -> SaveResult {
        let requested = std::mem::replace(&mut self.requested_v2, false);
        self.awaiting_2fa = false;
        let mode = std::mem::replace(&mut self.mode, TrustMode::Disabled);
        let result = if !requested {
            return if response.trusted_device_v2_token.is_empty() { SaveResult::NotRequested }
                else { SaveResult::Unsolicited };
        } else if mode != TrustMode::V2 || !response.trusted_device_v2_supported {
            SaveResult::Failed
        } else if let (Some(scope), Ok(token)) = (self.scope.as_ref(), <Token>::try_from(response.trusted_device_v2_token.as_ref())) {
            if store.save(scope, &token) { SaveResult::Saved } else { SaveResult::Failed }
        } else { SaveResult::Failed };
        self.notice = if matches!(result, SaveResult::Saved) { 1 } else { 2 };
        result
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(token) = self.token.as_mut() { token.fill(0); }
    }
}

pub struct PlatformStore;

#[cfg(target_env = "ohos")]
extern "C" {
    fn srd_trusted_asset_load(scope: *const u8, scope_len: usize, token: *mut u8, token_len: usize) -> i32;
    fn srd_trusted_asset_save(scope: *const u8, scope_len: usize, token: *const u8, token_len: usize) -> i32;
}

impl CredentialStore for PlatformStore {
    fn load(&self, scope: &Scope) -> LoadResult {
        #[cfg(target_env = "ohos")]
        {
            let mut token = [0_u8; TOKEN_SIZE];
            let result = unsafe { srd_trusted_asset_load(scope.as_ptr(), scope.len(), token.as_mut_ptr(), token.len()) };
            match result { 0 => LoadResult::Present(token), 1 => LoadResult::Missing, _ => LoadResult::Unavailable }
        }
        #[cfg(not(target_env = "ohos"))]
        { let _ = scope; LoadResult::Unavailable }
    }

    fn save(&self, scope: &Scope, token: &Token) -> bool {
        #[cfg(target_env = "ohos")]
        { unsafe { srd_trusted_asset_save(scope.as_ptr(), scope.len(), token.as_ptr(), token.len()) == 0 } }
        #[cfg(not(target_env = "ohos"))]
        { let _ = (scope, token); false }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct MemoryStore { items: Mutex<HashMap<Scope, Token>>, fail: bool }
    impl CredentialStore for MemoryStore {
        fn load(&self, scope: &Scope) -> LoadResult {
            if self.fail { return LoadResult::Unavailable; }
            self.items.lock().unwrap().get(scope).copied().map(LoadResult::Present).unwrap_or(LoadResult::Missing)
        }
        fn save(&self, scope: &Scope, token: &Token) -> bool {
            if self.fail { return false; }
            self.items.lock().unwrap().insert(*scope, *token); true
        }
    }
    fn scope_for(peer: &str) -> Scope { scope(peer, "test-server", "test-key", &[7; 32]) }
    fn request() -> LoginRequest { LoginRequest { password: vec![1, 2].into(), hwid: vec![3].into(), ..Default::default() } }
    fn response(v2: bool, legacy: bool, token: &[u8]) -> LoginResponse {
        LoginResponse { trusted_device_v2_supported: v2, enable_trusted_devices: legacy,
            trusted_device_v2_token: token.to_vec().into(), ..Default::default() }
    }

    #[test]
    fn verified_identity_and_server_scope_prevent_cross_peer_or_key_reuse() {
        let a = scope("ab", "c", "key", &[1; 32]);
        for other in [scope("a", "bc", "key", &[1; 32]), scope("ab", "c", "other", &[1; 32]),
            scope("ab", "c", "key", &[2; 32])] { assert_ne!(a, other); }
        let store = MemoryStore::default(); assert!(store.save(&a, &[9; 32]));
        let mut different = Session::new(2, Some(scope_for("another")), &store);
        let mut req = request(); different.apply_login(&mut req);
        assert!(req.trusted_device_v2_supported && req.trusted_device_v2_token.is_empty());
    }

    #[test]
    fn new_v2_enrollment_requires_explicit_choice_and_reconnects_with_stored_token() {
        let store = MemoryStore::default(); let scope = scope_for("peer-a");
        let mut session = Session::new(1, Some(scope), &store);
        let mut req = request(); session.apply_login(&mut req);
        assert!(req.trusted_device_v2_supported && req.trusted_device_v2_token.is_empty());
        assert!(session.challenge(&response(true, false, &[])) == TrustMode::V2);
        session.mark_submitted(true);
        assert!(matches!(session.finish(&response(true, false, &[5; 32]), &store), SaveResult::Saved));
        let mut next = Session::new(2, Some(scope), &store);
        let mut req = request(); next.apply_login(&mut req);
        assert_eq!(req.trusted_device_v2_token.as_ref(), &[5; 32]);
    }

    #[test]
    fn unverified_and_passwordless_sessions_never_send_trust_material() {
        let store = MemoryStore::default(); let scope = scope_for("peer"); assert!(store.save(&scope, &[8; 32]));
        let mut session = Session::new(1, None, &store); let mut req = request(); session.apply_login(&mut req);
        assert!(req.hwid.is_empty() && !req.trusted_device_v2_supported && req.trusted_device_v2_token.is_empty());
        let mut session = Session::new(2, Some(scope), &store); let mut req = request(); req.password.clear();
        session.apply_login(&mut req); assert!(req.trusted_device_v2_token.is_empty());
    }

    #[test]
    fn old_peers_keep_explicit_legacy_support_but_v2_takes_precedence() {
        let store = MemoryStore::default(); let mut session = Session::new(1, Some(scope_for("peer")), &store);
        assert!(session.challenge(&response(false, true, &[])) == TrustMode::Legacy);
        session.mark_submitted(true); assert!(!session.requested_v2);
        assert!(session.challenge(&response(true, true, &[])) == TrustMode::V2);
        let mut unverified = Session::new(2, None, &store);
        assert!(unverified.challenge(&response(false, true, &[])) == TrustMode::Disabled);
    }

    #[test]
    fn unavailable_store_and_unsolicited_or_invalid_tokens_fail_closed() {
        let bad = MemoryStore { fail: true, ..Default::default() };
        let mut s = Session::new(1, Some(scope_for("peer")), &bad);
        assert!(!s.offered_v2 && s.store_unavailable);
        assert!(s.challenge(&response(true, false, &[])) == TrustMode::Disabled);
        assert!(s.challenge(&response(true, true, &[])) == TrustMode::Disabled);
        let store = MemoryStore::default(); let scope = scope_for("peer"); let mut s = Session::new(2, Some(scope), &store);
        assert!(matches!(s.finish(&response(true, false, &[4; 32]), &store), SaveResult::Unsolicited));
        s.challenge(&response(true, false, &[])); s.mark_submitted(true);
        assert!(matches!(s.finish(&response(true, false, &[4; 31]), &store), SaveResult::Failed));
        s.challenge(&response(true, false, &[])); s.mark_submitted(true); assert!(matches!(s.finish(&response(false, false, &[4; 32]), &store), SaveResult::Failed));
        s.challenge(&response(true, false, &[])); s.mark_submitted(true); assert!(matches!(s.finish(&response(true, false, &[4; 32]), &bad), SaveResult::Failed));
        assert!(matches!(store.load(&scope), LoadResult::Missing));
    }
}
