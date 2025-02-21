from base64 import b64encode, b64decode
from nacl import encoding, public
import sys

def encrypt(public_key: str, secret_value: str) -> str:
  """Encrypt a Unicode string using the public key."""
  public_key_bytes = b64decode(public_key)
  public_key = public.PublicKey(public_key_bytes, encoding.RawEncoder())
  sealed_box = public.SealedBox(public_key)
  encrypted = sealed_box.encrypt(secret_value.encode("utf-8"))
  return b64encode(encrypted).decode("utf-8")

encrypt(sys.argv[1], sys.argv[2])