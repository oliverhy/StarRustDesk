"""PIN transcript and exact certificate verification for our private loopback Sunshine process."""
from datetime import datetime, timedelta, timezone
from contextlib import closing
from hashlib import sha256
from hmac import compare_digest
import http.client
import os
from pathlib import Path
import re
import secrets
import ssl
from tempfile import mkstemp
from urllib.parse import urlencode, urlsplit
import uuid
import xml.etree.ElementTree as ET

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.x509.oid import NameOID

HOST = "Sesame-Physical-LAN-Only"
TILE = "Sesame Physical Screen"
HTTP, HTTPS = 47989, 47984


def fail(code):
    raise RuntimeError(code)


def bounded_hex(root, key, size=None, cap=10000):
    data = root.findtext(key, "")
    if not data or len(data) > cap or len(data) % 2 or not re.fullmatch(r"[0-9A-Fa-f]+", data):
        fail("fixture_pair_field_invalid")
    out = bytes.fromhex(data)
    if size is not None and len(out) != size:
        fail("fixture_pair_field_length")
    return out


def aes(k, body, encrypt=True):
    if len(k) != 16 or len(body) % 16:
        fail("fixture_pair_block_length")
    c = Cipher(algorithms.AES(k), modes.ECB())
    op = c.encryptor() if encrypt else c.decryptor()
    return op.update(body) + op.finalize()


def identity():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    label = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Sesame Ephemeral Fixture")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(label).issuer_name(label).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=20))
            .not_valid_after(now + timedelta(hours=2)).sign(key, hashes.SHA256()))
    return cert, key


def temporary_chain(ctx, cert, key):
    # ssl.load_cert_chain reads files. Keep this one test identity under the
    # local user's temp ACL only, and remove both files immediately after load.
    payloads = (cert.public_bytes(serialization.Encoding.PEM),
                key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))
    names = []
    try:
        for data in payloads:
            fid, name = mkstemp(prefix="sesame-fixture-tls-", suffix=".pem")
            names.append(Path(name))
            with os.fdopen(fid, "wb") as output:
                output.write(data)
        ctx.load_cert_chain(str(names[0]), str(names[1]))
    finally:
        for name in names:
            name.unlink(missing_ok=True)


class Pair:
    def __init__(self):
        self.unique = secrets.token_hex(8)
        self.cert, self.key = identity()
        self.pin = None
        self.tls = None
        self.version = None
        self.gfe = None
        self.codec = None
        self.appid = None

    def request(self, path, args=None, timeout=6, secure=False):
        if path not in ("serverinfo", "pair", "applist", "launch", "cancel"):
            fail("fixture_control_path_rejected")
        q = {"uniqueid": self.unique, "uuid": str(uuid.uuid4())}
        if args:
            q.update(args)
        conn_cls = http.client.HTTPSConnection if secure else http.client.HTTPConnection
        kw = {"context": self.tls} if secure else {}
        if secure and (self.pin is None or self.tls is None):
            fail("fixture_tls_before_pin")
        with closing(conn_cls("127.0.0.1", HTTPS if secure else HTTP, timeout=timeout, **kw)) as sock:
            if secure:
                sock.connect()
                got = sock.sock.getpeercert(binary_form=True)
                if not got or not compare_digest(self.pin, sha256(got).digest()):
                    fail("fixture_tls_pin_mismatch")
            sock.request("GET", "/" + path + "?" + urlencode(q))
            response = sock.getresponse()
            data = response.read(128001)
            if response.status != 200 or len(data) > 128000 or b"<!DOCTYPE" in data.upper():
                fail("fixture_control_response_rejected")
            root = ET.fromstring(data)
            if root.tag != "root" or root.get("status_code") != "200":
                fail("fixture_control_status_failed")
            return root

    def paired(self, pin):
        info = self.request("serverinfo")
        version = info.findtext("appversion", "")
        if info.findtext("hostname") != HOST or not re.fullmatch(r"7\.\d{1,4}\.\d{1,5}\.-?\d{1,5}", version):
            fail("fixture_owned_host_unconfirmed")
        if not re.fullmatch(r"[0-9]{4}", pin):
            fail("fixture_ephemeral_pin_unconfirmed")
        salt = secrets.token_bytes(16)
        mk = sha256(salt + pin.encode("ascii")).digest()[:16]
        bind = {"devicename": "Sesame Windows Companion", "updateState": "1"}
        hello = self.request("pair", dict(bind, phrase="getservercert", salt=salt.hex(),
                            clientcert=self.cert.public_bytes(serialization.Encoding.PEM).hex()), timeout=12)
        if hello.findtext("paired") != "1":
            fail("fixture_pair_cert_rejected")
        raw = bounded_hex(hello, "plaincert")
        server = x509.load_pem_x509_certificate(raw)
        pub = server.public_key()
        if not isinstance(pub, rsa.RSAPublicKey) or pub.key_size != 2048:
            fail("fixture_pair_certificate_type")
        challenge = secrets.token_bytes(16)
        reply = self.request("pair", dict(bind, clientchallenge=aes(mk, challenge).hex()))
        if reply.findtext("paired") != "1":
            fail("fixture_pair_challenge_rejected")
        transcript = aes(mk, bounded_hex(reply, "challengeresponse", size=48), encrypt=False)
        secret = secrets.token_bytes(16)
        reply = self.request("pair", dict(bind, serverchallengeresp=aes(mk, sha256(
                             transcript[32:] + self.cert.signature + secret).digest()).hex()))
        if reply.findtext("paired") != "1":
            fail("fixture_pair_server_proof_rejected")
        proof = bounded_hex(reply, "pairingsecret", size=272)
        pub.verify(proof[16:], proof[:16], padding.PKCS1v15(), hashes.SHA256())
        if not compare_digest(sha256(challenge + server.signature + proof[:16]).digest(), transcript[:32]):
            fail("fixture_pair_pin_proof_failed")
        reply = self.request("pair", dict(bind, clientpairingsecret=(secret + self.key.sign(
                             secret, padding.PKCS1v15(), hashes.SHA256())).hex()))
        if reply.findtext("paired") != "1":
            fail("fixture_pair_client_proof_rejected")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        # The test certificate is associated by the authenticated PIN. The
        # exact DER pin, not a hostname or globally installed root, is checked.
        ctx.check_hostname = False
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(cadata=raw.decode("ascii"))
        temporary_chain(ctx, self.cert, self.key)
        self.pin = server.fingerprint(hashes.SHA256())
        self.tls = ctx
        if self.request("pair", dict(bind, phrase="pairchallenge"), secure=True).findtext("paired") != "1":
            fail("fixture_pair_tls_challenge_rejected")
        check = self.request("serverinfo", secure=True)
        if check.findtext("hostname") != HOST or check.findtext("appversion") != version:
            fail("fixture_tls_host_identity_changed")
        self.version = version
        gfe = check.findtext("GfeVersion", "")
        self.gfe = gfe if re.fullmatch(r"\d{1,4}(?:\.\d{1,6}){1,3}", gfe or "") else ""
        codec = check.findtext("ServerCodecModeSupport", "1")
        self.codec = int(codec) if re.fullmatch(r"\d{1,9}", codec) else 1
        apps = self.request("applist", secure=True).findall("App")
        if len(apps) != 1 or apps[0].findtext("AppTitle") != TILE:
            fail("unexpected_desktop_tile")
        appid = apps[0].findtext("ID", "")
        if not re.fullmatch(r"\d{1,10}", appid):
            fail("fixture_app_id_rejected")
        self.appid = appid
