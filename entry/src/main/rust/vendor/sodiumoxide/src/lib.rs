pub mod base64 {
    use ::base64::Engine;

    #[derive(Clone, Copy)]
    pub enum Variant {
        Original,
    }

    pub fn encode<T: AsRef<[u8]>>(data: T, _variant: Variant) -> String {
        ::base64::engine::general_purpose::STANDARD.encode(data)
    }

    pub fn decode<T: AsRef<[u8]>>(data: T, _variant: Variant) -> Result<Vec<u8>, ()> {
        ::base64::engine::general_purpose::STANDARD.decode(data).map_err(|_| ())
    }
}

pub mod utils {
    pub fn memcmp(a: &[u8], b: &[u8]) -> bool {
        if a.len() != b.len() {
            return false;
        }
        let mut diff = 0u8;
        for (x, y) in a.iter().zip(b.iter()) {
            diff |= x ^ y;
        }
        diff == 0
    }
}

pub mod crypto {
    pub mod secretbox {
        use crypto_secretbox::{aead::{Aead, KeyInit}, Key as CryptoKey, Nonce as CryptoNonce, XSalsa20Poly1305};
        use rand::RngCore;

        pub const KEYBYTES: usize = 32;
        pub const NONCEBYTES: usize = 24;
        pub const MACBYTES: usize = 16;

        #[derive(Clone)]
        pub struct KeyBytes(pub [u8; KEYBYTES]);
        pub use KeyBytes as Key;

        #[derive(Clone)]
        pub struct Nonce(pub [u8; NONCEBYTES]);

        pub fn gen_key() -> Key {
            let mut bytes = [0u8; KEYBYTES];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            Key(bytes)
        }

        pub fn gen_nonce() -> Nonce {
            let mut bytes = [0u8; NONCEBYTES];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            Nonce(bytes)
        }

        pub fn seal(data: &[u8], nonce: &Nonce, key: &Key) -> Vec<u8> {
            let cipher = XSalsa20Poly1305::new(CryptoKey::from_slice(&key.0));
            cipher.encrypt(CryptoNonce::from_slice(&nonce.0), data).unwrap_or_default()
        }

        pub fn open(data: &[u8], nonce: &Nonce, key: &Key) -> Result<Vec<u8>, ()> {
            let cipher = XSalsa20Poly1305::new(CryptoKey::from_slice(&key.0));
            cipher.decrypt(CryptoNonce::from_slice(&nonce.0), data).map_err(|_| ())
        }
    }

    pub mod box_ {
        use crypto_box::{aead::Aead, PublicKey as CryptoPublicKey, SalsaBox, SecretKey as CryptoSecretKey};
        use rand::RngCore;

        pub const PUBLICKEYBYTES: usize = 32;
        pub const SECRETKEYBYTES: usize = 32;
        pub const NONCEBYTES: usize = 24;

        #[derive(Clone)]
        pub struct PublicKey(pub [u8; PUBLICKEYBYTES]);
        #[derive(Clone)]
        pub struct SecretKey(pub [u8; SECRETKEYBYTES]);
        #[derive(Clone)]
        pub struct Nonce(pub [u8; NONCEBYTES]);

        pub fn gen_keypair() -> (PublicKey, SecretKey) {
            let mut bytes = [0u8; SECRETKEYBYTES];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            let secret = CryptoSecretKey::from(bytes);
            (PublicKey(*secret.public_key().as_bytes()), SecretKey(bytes))
        }

        pub fn seal(data: &[u8], nonce: &Nonce, public: &PublicKey, secret: &SecretKey) -> Vec<u8> {
            let public = CryptoPublicKey::from(public.0);
            let secret = CryptoSecretKey::from(secret.0);
            SalsaBox::new(&public, &secret)
                .encrypt(crypto_box::Nonce::from_slice(&nonce.0), data)
                .unwrap_or_default()
        }

        pub fn open(data: &[u8], nonce: &Nonce, public: &PublicKey, secret: &SecretKey) -> Result<Vec<u8>, ()> {
            let public = CryptoPublicKey::from(public.0);
            let secret = CryptoSecretKey::from(secret.0);
            SalsaBox::new(&public, &secret)
                .decrypt(crypto_box::Nonce::from_slice(&nonce.0), data)
                .map_err(|_| ())
        }
    }

    pub mod sign {
        use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
        use rand::RngCore;

        pub const PUBLICKEYBYTES: usize = 32;
        pub const SECRETKEYBYTES: usize = 64;
        pub const SIGNATUREBYTES: usize = 64;

        #[derive(Clone)]
        pub struct PublicKey(pub [u8; PUBLICKEYBYTES]);
        #[derive(Clone)]
        pub struct SecretKey(pub [u8; SECRETKEYBYTES]);

        pub fn gen_keypair() -> (PublicKey, SecretKey) {
            let mut seed = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut seed);
            let signing = SigningKey::from_bytes(&seed);
            let public = signing.verifying_key().to_bytes();
            let mut secret = [0u8; SECRETKEYBYTES];
            secret[..32].copy_from_slice(&seed);
            secret[32..].copy_from_slice(&public);
            (PublicKey(public), SecretKey(secret))
        }

        pub fn sign(data: &[u8], secret: &SecretKey) -> Vec<u8> {
            let seed: [u8; 32] = secret.0[..32].try_into().unwrap();
            let signature = SigningKey::from_bytes(&seed).sign(data);
            let mut signed = signature.to_bytes().to_vec();
            signed.extend_from_slice(data);
            signed
        }

        pub fn verify(signed: &[u8], public: &PublicKey) -> Result<Vec<u8>, ()> {
            if signed.len() < SIGNATUREBYTES {
                return Err(());
            }
            let key = VerifyingKey::from_bytes(&public.0).map_err(|_| ())?;
            let signature = Signature::from_slice(&signed[..SIGNATUREBYTES]).map_err(|_| ())?;
            let message = &signed[SIGNATUREBYTES..];
            key.verify_strict(message, &signature).map_err(|_| ())?;
            Ok(message.to_vec())
        }
    }
}

pub fn init() -> Result<(), ()> {
    Ok(())
}
