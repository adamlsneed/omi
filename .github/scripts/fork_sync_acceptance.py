"""Explicit November 9 sync acceptance; changed blobs receive normal checks."""
import hashlib
import json
from pathlib import Path

ACCEPTANCE = json.loads(Path(__file__).with_suffix('.json').read_text())


def accepted_entry(kind: str, path: str, source: bytes) -> dict:
    entry = ACCEPTANCE.get(kind, {}).get(path, {})
    digest = hashlib.sha1(b'blob ' + str(len(source)).encode() + b'\0' + source).hexdigest()
    return entry if entry.get('blob') == digest else {}
