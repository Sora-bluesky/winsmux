use super::io::IoError;
use crate::contract::InstanceId;
use sha2::{Digest, Sha256};
use std::ffi::c_void;
use std::ptr::{null, null_mut};
use std::sync::Mutex;
use windows_sys::Win32::Security::Cryptography::{
    BCryptCloseAlgorithmProvider, BCryptDestroyKey, BCryptExportKey, BCryptFinalizeKeyPair,
    BCryptGenRandom, BCryptGenerateKeyPair, BCryptImportKeyPair, BCryptOpenAlgorithmProvider,
    BCryptSignHash, BCryptVerifySignature, BCRYPT_ALG_HANDLE, BCRYPT_ECCPUBLIC_BLOB,
    BCRYPT_ECDSA_P256_ALGORITHM, BCRYPT_ECDSA_PUBLIC_P256_MAGIC, BCRYPT_KEY_HANDLE,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG,
};

pub(crate) const AUTH_MAGIC: &[u8; 8] = b"WSMXAUTH";
pub(crate) const AUTH_VERSION: u32 = 1;
pub(crate) const AUTH_REQUEST_BYTES: usize = 44;
pub(crate) const AUTH_RESPONSE_BYTES: usize = 148;
pub(crate) const PUBLIC_KEY_BYTES: usize = 72;
pub(crate) const SIGNATURE_BYTES: usize = 64;
const CHALLENGE_BYTES: usize = 32;
const TRANSCRIPT_DOMAIN: &[u8] = b"winsmux.workspace.server-proof.v1\0";

struct CngKey {
    algorithm: BCRYPT_ALG_HANDLE,
    key: BCRYPT_KEY_HANDLE,
}

// CNG key handles can be used from another thread. ServerKey serializes every
// operation on the private handle through its mutex.
unsafe impl Send for CngKey {}

impl Drop for CngKey {
    fn drop(&mut self) {
        unsafe {
            if !self.key.is_null() {
                BCryptDestroyKey(self.key);
            }
            if !self.algorithm.is_null() {
                BCryptCloseAlgorithmProvider(self.algorithm, 0);
            }
        }
    }
}

pub(crate) struct ServerKey {
    cng: Mutex<CngKey>,
    public_blob: [u8; PUBLIC_KEY_BYTES],
    fingerprint: String,
}

impl ServerKey {
    pub(crate) fn generate() -> Result<Self, IoError> {
        #[cfg(debug_assertions)]
        if std::env::var_os("WINSMUX_TASK862_FAIL_CNG").is_some() {
            return Err(IoError::Failed);
        }
        let mut algorithm = null_mut();
        if !nt_success(unsafe {
            BCryptOpenAlgorithmProvider(&mut algorithm, BCRYPT_ECDSA_P256_ALGORITHM, null(), 0)
        }) || algorithm.is_null()
        {
            return Err(IoError::Failed);
        }
        let mut cng = CngKey {
            algorithm,
            key: null_mut(),
        };
        if !nt_success(unsafe { BCryptGenerateKeyPair(cng.algorithm, &mut cng.key, 256, 0) })
            || cng.key.is_null()
            || !nt_success(unsafe { BCryptFinalizeKeyPair(cng.key, 0) })
        {
            return Err(IoError::Failed);
        }

        let public_blob = export_public_blob(cng.key)?;
        validate_public_blob(&public_blob)?;
        let fingerprint = fingerprint(&public_blob);
        Ok(Self {
            cng: Mutex::new(cng),
            public_blob,
            fingerprint,
        })
    }

    pub(crate) fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    pub(crate) fn response(
        &self,
        instance_id: &InstanceId,
        pipe_name: &str,
        challenge: &[u8; CHALLENGE_BYTES],
        client_pid: u32,
        host_pid: u32,
    ) -> Result<[u8; AUTH_RESPONSE_BYTES], IoError> {
        let digest = transcript_hash(instance_id, pipe_name, challenge, client_pid, host_pid)?;
        let cng = self.cng.lock().map_err(|_| IoError::Failed)?;
        let mut signature = [0u8; SIGNATURE_BYTES];
        let mut written = 0u32;
        if !nt_success(unsafe {
            BCryptSignHash(
                cng.key,
                null::<c_void>(),
                digest.as_ptr(),
                digest.len() as u32,
                signature.as_mut_ptr(),
                signature.len() as u32,
                &mut written,
                0,
            )
        }) || written as usize != signature.len()
        {
            return Err(IoError::Failed);
        }

        let mut response = [0u8; AUTH_RESPONSE_BYTES];
        response[..AUTH_MAGIC.len()].copy_from_slice(AUTH_MAGIC);
        response[8..12].copy_from_slice(&AUTH_VERSION.to_le_bytes());
        response[12..84].copy_from_slice(&self.public_blob);
        response[84..].copy_from_slice(&signature);
        Ok(response)
    }
}

pub(crate) fn random_challenge() -> Result<[u8; CHALLENGE_BYTES], IoError> {
    let mut challenge = [0u8; CHALLENGE_BYTES];
    if !nt_success(unsafe {
        BCryptGenRandom(
            null_mut(),
            challenge.as_mut_ptr(),
            challenge.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    }) {
        return Err(IoError::Failed);
    }
    Ok(challenge)
}

pub(crate) fn encode_request(challenge: &[u8; CHALLENGE_BYTES]) -> [u8; AUTH_REQUEST_BYTES] {
    let mut request = [0u8; AUTH_REQUEST_BYTES];
    request[..AUTH_MAGIC.len()].copy_from_slice(AUTH_MAGIC);
    request[8..12].copy_from_slice(&AUTH_VERSION.to_le_bytes());
    request[12..].copy_from_slice(challenge);
    request
}

pub(crate) fn parse_request(body: &[u8]) -> Result<[u8; CHALLENGE_BYTES], IoError> {
    if body.len() != AUTH_REQUEST_BYTES
        || &body[..AUTH_MAGIC.len()] != AUTH_MAGIC
        || u32::from_le_bytes(body[8..12].try_into().map_err(|_| IoError::Protocol)?)
            != AUTH_VERSION
    {
        return Err(IoError::Protocol);
    }
    body[12..].try_into().map_err(|_| IoError::Protocol)
}

pub(crate) fn verify_response(
    body: &[u8],
    expected_fingerprint: &str,
    instance_id: &InstanceId,
    pipe_name: &str,
    challenge: &[u8; CHALLENGE_BYTES],
    client_pid: u32,
    host_pid: u32,
) -> Result<(), IoError> {
    if body.len() != AUTH_RESPONSE_BYTES
        || &body[..AUTH_MAGIC.len()] != AUTH_MAGIC
        || u32::from_le_bytes(body[8..12].try_into().map_err(|_| IoError::Protocol)?)
            != AUTH_VERSION
    {
        return Err(IoError::Protocol);
    }
    let public_blob: &[u8; PUBLIC_KEY_BYTES] =
        body[12..84].try_into().map_err(|_| IoError::Protocol)?;
    validate_public_blob(public_blob)?;
    if fingerprint(public_blob) != expected_fingerprint {
        return Err(IoError::Protocol);
    }
    let signature: &[u8; SIGNATURE_BYTES] = body[84..].try_into().map_err(|_| IoError::Protocol)?;
    let digest = transcript_hash(instance_id, pipe_name, challenge, client_pid, host_pid)?;
    verify_signature(public_blob, &digest, signature)
}

fn export_public_blob(key: BCRYPT_KEY_HANDLE) -> Result<[u8; PUBLIC_KEY_BYTES], IoError> {
    let mut required = 0u32;
    if !nt_success(unsafe {
        BCryptExportKey(
            key,
            null_mut(),
            BCRYPT_ECCPUBLIC_BLOB,
            null_mut(),
            0,
            &mut required,
            0,
        )
    }) || required as usize != PUBLIC_KEY_BYTES
    {
        return Err(IoError::Failed);
    }
    let mut output = [0u8; PUBLIC_KEY_BYTES];
    let mut written = 0u32;
    if !nt_success(unsafe {
        BCryptExportKey(
            key,
            null_mut(),
            BCRYPT_ECCPUBLIC_BLOB,
            output.as_mut_ptr(),
            output.len() as u32,
            &mut written,
            0,
        )
    }) || written as usize != output.len()
    {
        return Err(IoError::Failed);
    }
    Ok(output)
}

fn verify_signature(
    public_blob: &[u8; PUBLIC_KEY_BYTES],
    digest: &[u8; 32],
    signature: &[u8; SIGNATURE_BYTES],
) -> Result<(), IoError> {
    let mut algorithm = null_mut();
    if !nt_success(unsafe {
        BCryptOpenAlgorithmProvider(&mut algorithm, BCRYPT_ECDSA_P256_ALGORITHM, null(), 0)
    }) || algorithm.is_null()
    {
        return Err(IoError::Failed);
    }
    let mut cng = CngKey {
        algorithm,
        key: null_mut(),
    };
    if !nt_success(unsafe {
        BCryptImportKeyPair(
            cng.algorithm,
            null_mut(),
            BCRYPT_ECCPUBLIC_BLOB,
            &mut cng.key,
            public_blob.as_ptr(),
            public_blob.len() as u32,
            0,
        )
    }) || cng.key.is_null()
    {
        return Err(IoError::Protocol);
    }
    if !nt_success(unsafe {
        BCryptVerifySignature(
            cng.key,
            null::<c_void>(),
            digest.as_ptr(),
            digest.len() as u32,
            signature.as_ptr(),
            signature.len() as u32,
            0,
        )
    }) {
        return Err(IoError::Protocol);
    }
    Ok(())
}

fn validate_public_blob(blob: &[u8; PUBLIC_KEY_BYTES]) -> Result<(), IoError> {
    let magic = u32::from_le_bytes(blob[..4].try_into().map_err(|_| IoError::Protocol)?);
    let coordinate_bytes =
        u32::from_le_bytes(blob[4..8].try_into().map_err(|_| IoError::Protocol)?);
    if magic != BCRYPT_ECDSA_PUBLIC_P256_MAGIC || coordinate_bytes != 32 {
        return Err(IoError::Protocol);
    }
    Ok(())
}

fn transcript_hash(
    instance_id: &InstanceId,
    pipe_name: &str,
    challenge: &[u8; CHALLENGE_BYTES],
    client_pid: u32,
    host_pid: u32,
) -> Result<[u8; 32], IoError> {
    if client_pid == 0 || host_pid == 0 {
        return Err(IoError::Protocol);
    }
    let instance = uuid::Uuid::parse_str(instance_id.as_str()).map_err(|_| IoError::Protocol)?;
    let pipe = pipe_name.as_bytes();
    let pipe_len = u32::try_from(pipe.len()).map_err(|_| IoError::Protocol)?;
    let mut transcript = Vec::with_capacity(
        TRANSCRIPT_DOMAIN.len() + 4 + 16 + 4 + pipe.len() + CHALLENGE_BYTES + 4 + 4,
    );
    transcript.extend_from_slice(TRANSCRIPT_DOMAIN);
    transcript.extend_from_slice(&AUTH_VERSION.to_le_bytes());
    transcript.extend_from_slice(instance.as_bytes());
    transcript.extend_from_slice(&pipe_len.to_le_bytes());
    transcript.extend_from_slice(pipe);
    transcript.extend_from_slice(challenge);
    transcript.extend_from_slice(&client_pid.to_le_bytes());
    transcript.extend_from_slice(&host_pid.to_le_bytes());
    Ok(Sha256::digest(&transcript).into())
}

fn fingerprint(public_blob: &[u8]) -> String {
    Sha256::digest(public_blob)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn nt_success(status: i32) -> bool {
    status >= 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn instance() -> InstanceId {
        InstanceId::new("10000000-0000-4000-8000-000000000001").expect("instance")
    }

    #[test]
    fn cng_proof_is_bound_to_every_transcript_field() {
        let key = ServerKey::generate().expect("server key");
        let challenge = [0x5au8; CHALLENGE_BYTES];
        let pipe = format!(
            r"\\.\pipe\winsmux-workspace-v1-{}-{}",
            "1".repeat(64),
            key.fingerprint()
        );
        let response = key
            .response(&instance(), &pipe, &challenge, 101, 202)
            .expect("server response");
        verify_response(
            &response,
            key.fingerprint(),
            &instance(),
            &pipe,
            &challenge,
            101,
            202,
        )
        .expect("valid proof");
        assert_eq!(
            verify_response(&response, &"0".repeat(64), &instance(), &pipe, &challenge, 101, 202),
            Err(IoError::Protocol),
            "a different server key cannot claim the original discovery fingerprint",
        );
        let stale = InstanceId::new("40000000-0000-4000-8000-000000000001").unwrap();
        assert_eq!(
            verify_response(&response, key.fingerprint(), &stale, &pipe, &challenge, 101, 202),
            Err(IoError::Protocol),
            "a prior generation cannot reuse the signed proof",
        );
        assert_eq!(
            verify_response(&response, key.fingerprint(), &instance(), &pipe, &challenge, 101, 203),
            Err(IoError::Protocol),
            "the observed host process is part of the signed proof",
        );

        let mut changed = response;
        changed[147] ^= 1;
        assert_eq!(
            verify_response(
                &changed,
                key.fingerprint(),
                &instance(),
                &pipe,
                &challenge,
                101,
                202,
            ),
            Err(IoError::Protocol)
        );
        assert_eq!(
            verify_response(
                &response,
                key.fingerprint(),
                &instance(),
                &pipe,
                &[0x5bu8; CHALLENGE_BYTES],
                101,
                202,
            ),
            Err(IoError::Protocol)
        );
        assert_eq!(
            verify_response(
                &response,
                key.fingerprint(),
                &instance(),
                &pipe,
                &challenge,
                102,
                202,
            ),
            Err(IoError::Protocol)
        );
        assert_eq!(
            verify_response(
                &response,
                key.fingerprint(),
                &instance(),
                &format!("{pipe}x"),
                &challenge,
                101,
                202,
            ),
            Err(IoError::Protocol)
        );
    }

    #[test]
    fn authentication_request_rejects_wrong_length_magic_and_version() {
        let challenge = [7u8; CHALLENGE_BYTES];
        let request = encode_request(&challenge);
        assert_eq!(parse_request(&request), Ok(challenge));
        assert_eq!(parse_request(&request[..43]), Err(IoError::Protocol));
        let mut changed = request;
        changed[0] ^= 1;
        assert_eq!(parse_request(&changed), Err(IoError::Protocol));
        let mut changed = request;
        changed[8..12].copy_from_slice(&2u32.to_le_bytes());
        assert_eq!(parse_request(&changed), Err(IoError::Protocol));
    }
}
