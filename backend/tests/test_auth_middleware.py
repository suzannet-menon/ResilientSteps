import base64
import json
import unittest
from unittest.mock import patch, MagicMock

import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

from app.services.auth_middleware import _decode_token, require_auth, optional_auth


def int_to_base64url(val: int) -> str:
    """Helper to convert an integer to a base64url-encoded string."""
    size = (val.bit_length() + 7) // 8
    b = val.to_bytes(size, byteorder="big")
    return base64.urlsafe_b64encode(b).decode("utf-8").rstrip("=")


class AuthMiddlewareTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        # Generate dynamic EC keypair for ES256 tests
        cls.private_key = ec.generate_private_key(ec.SECP256R1())
        public_key = cls.private_key.public_key()
        numbers = public_key.public_numbers()
        cls.x_str = int_to_base64url(numbers.x)
        cls.y_str = int_to_base64url(numbers.y)
        cls.kid = "test-key-id-123"
        cls.jwk = {
            "kty": "EC",
            "crv": "P-256",
            "x": cls.x_str,
            "y": cls.y_str,
            "kid": cls.kid,
            "alg": "ES256",
            "key_ops": ["verify"],
        }
        cls.jwks = {"keys": [cls.jwk]}
        cls.jwks_str = json.dumps(cls.jwks)

    def test_es256_verification_with_static_jwks(self):
        token_payload = {
            "sub": "user-123",
            "exp": 9999999999,
        }
        token = jwt.encode(
            token_payload,
            self.private_key,
            algorithm="ES256",
            headers={"kid": self.kid},
        )

        with patch("app.services.auth_middleware.SUPABASE_JWKS", self.jwks_str):
            payload = _decode_token(token)
            self.assertIsNotNone(payload)
            self.assertEqual(payload["sub"], "user-123")

    def test_es256_verification_expired_token(self):
        token_payload = {
            "sub": "user-123",
            "exp": 1,  # expired
        }
        token = jwt.encode(
            token_payload,
            self.private_key,
            algorithm="ES256",
            headers={"kid": self.kid},
        )

        with patch("app.services.auth_middleware.SUPABASE_JWKS", self.jwks_str):
            payload = _decode_token(token)
            self.assertIsNone(payload)

    def test_es256_verification_invalid_signature(self):
        token_payload = {
            "sub": "user-123",
            "exp": 9999999999,
        }
        token = jwt.encode(
            token_payload,
            self.private_key,
            algorithm="ES256",
            headers={"kid": self.kid},
        )
        # Corrupt the token signature
        corrupted_token = token[:-5] + "aaaaa"

        with patch("app.services.auth_middleware.SUPABASE_JWKS", self.jwks_str):
            payload = _decode_token(corrupted_token)
            self.assertIsNone(payload)

    def test_es256_verification_missing_kid(self):
        token_payload = {
            "sub": "user-123",
            "exp": 9999999999,
        }
        token = jwt.encode(
            token_payload,
            self.private_key,
            algorithm="ES256",
        )

        with patch("app.services.auth_middleware.SUPABASE_JWKS", self.jwks_str):
            payload = _decode_token(token)
            self.assertIsNone(payload)

    def test_hs256_verification(self):
        token_payload = {
            "sub": "user-456",
            "exp": 9999999999,
        }
        secret = "test-symmetric-secret-key-that-is-long"
        token = jwt.encode(
            token_payload,
            secret,
            algorithm="HS256",
        )

        with patch("app.services.auth_middleware.SUPABASE_JWT_SECRET", secret):
            payload = _decode_token(token)
            self.assertIsNotNone(payload)
            self.assertEqual(payload["sub"], "user-456")

    def test_hs256_verification_accepts_supabase_aud_claim(self):
        # Regression: real Supabase access tokens always carry aud=.
        # PyJWT raises InvalidAudienceError when the token has an aud claim
        # and decode() is called without an audience, which used to 401 the
        # entire hosted app. The middleware must verify the signature only.
        token_payload = {
            "sub": "user-456",
            "exp": 9999999999,
            "aud": "authenticated",
            "email": "e2e@example.com",
            "role": "authenticated",
        }
        secret = "test-symmetric-secret-key-that-is-long"
        token = jwt.encode(token_payload, secret, algorithm="HS256")

        with patch("app.services.auth_middleware.SUPABASE_JWT_SECRET", secret):
            payload = _decode_token(token)
            self.assertIsNotNone(payload)
            self.assertEqual(payload["sub"], "user-456")

    @patch("app.services.auth_middleware._decode_token")
    async def test_require_auth_success(self, mock_decode):
        mock_decode.return_value = {"sub": "user-789"}
        mock_request = MagicMock()
        mock_request.headers = {"authorization": "Bearer dummy-token"}

        user_id = await require_auth(mock_request)
        self.assertEqual(user_id, "user-789")

    @patch("app.services.auth_middleware._decode_token")
    async def test_require_auth_missing_token(self, mock_decode):
        mock_request = MagicMock()
        mock_request.headers = {}

        with self.assertRaises(HTTPException) as ctx:
            await require_auth(mock_request)
        self.assertEqual(ctx.exception.status_code, 401)

    @patch("app.services.auth_middleware._decode_token")
    async def test_require_auth_invalid_token(self, mock_decode):
        mock_decode.return_value = None
        mock_request = MagicMock()
        mock_request.headers = {"authorization": "Bearer dummy-token"}

        with self.assertRaises(HTTPException) as ctx:
            await require_auth(mock_request)
        self.assertEqual(ctx.exception.status_code, 401)

    @patch("app.services.auth_middleware._decode_token")
    async def test_optional_auth_success(self, mock_decode):
        mock_decode.return_value = {"sub": "user-789"}
        mock_request = MagicMock()
        mock_request.headers = {"authorization": "Bearer dummy-token"}

        user_id = await optional_auth(mock_request)
        self.assertEqual(user_id, "user-789")

    @patch("app.services.auth_middleware._decode_token")
    async def test_optional_auth_missing_token(self, mock_decode):
        mock_request = MagicMock()
        mock_request.headers = {}

        user_id = await optional_auth(mock_request)
        self.assertIsNone(user_id)
