#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""A Maven repository that demands HTTP Basic auth, for compatibility tests.

Serves ``GET`` and ``HEAD`` from a directory and stores ``PUT`` bodies
in it, on 127.0.0.1 at a port the system picks. Every request must
carry the expected credentials; any other request answers 401 with a
``WWW-Authenticate`` challenge, so a request that succeeds proves the
client sent what its settings supplied.

A ``.sha1``, ``.md5``, ``.sha256`` or ``.sha512`` request for a file
that exists but has no stored checksum answers with one computed on
the fly: Maven 4 refuses an artifact it cannot verify, and a seeded
file comes without checksum files.

Each request appends one line to the request log: the method, the
path, ``auth=ok``, ``auth=bad`` or ``auth=none``, and the response
status. The log never records the credentials themselves.

Usage: auth_repo.py <root> <port-file> <request-log>

The expected credentials come from ``AUTH_USER`` and
``AUTH_PASSWORD`` in the environment, not the command line, where
other processes could read them.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import final
from urllib.parse import unquote, urlsplit

CHECKSUMS = {
    ".sha1": "sha1",
    ".md5": "md5",
    ".sha256": "sha256",
    ".sha512": "sha512",
}


def basic_authorization(user: str, password: str) -> str:
    """Return the Authorization header value for ``user``/``password``."""
    token = base64.b64encode(f"{user}:{password}".encode()).decode("ascii")
    return f"Basic {token}"


@final
class AuthRepo(ThreadingHTTPServer):
    """A threaded server holding the root, credentials and request log."""

    daemon_threads = True

    def __init__(self, root: Path, log: Path, authorization: str) -> None:
        """Listen on 127.0.0.1 at a free port and open the request log."""
        super().__init__(("127.0.0.1", 0), Handler)
        self.root: Path = root.resolve()
        self.authorization: bytes = authorization.encode()
        self._log = log.open("a", encoding="utf-8")
        self._lock = threading.Lock()

    @property
    def port(self) -> int:
        """Port the server listens on."""
        return int(self.server_address[1])

    def record(self, line: str) -> None:
        """Append one line to the request log, whole, from any thread."""
        with self._lock:
            _ = self._log.write(f"{line}\n")
            self._log.flush()

    def locate(self, request_path: str) -> Path | None:
        """Map a request path onto ``root``; None if it escapes it."""
        path = unquote(urlsplit(request_path).path).lstrip("/")
        target = (self.root / path).resolve()
        if target == self.root or self.root in target.parents:
            return target
        return None


@final
class Handler(BaseHTTPRequestHandler):
    """Serve, store and log requests for an ``AuthRepo``."""

    # HTTP/1.0, the default, never answers "Expect: 100-continue", so
    # Maven would wait out its timeout (3 seconds) before every PUT.
    protocol_version = "HTTP/1.1"

    @property
    def repo(self) -> AuthRepo:
        """The server this handler answers for."""
        assert isinstance(self.server, AuthRepo)
        return self.server

    def do_GET(self) -> None:
        """Serve a file, or a checksum computed from one."""
        self._serve(send_body=True)

    def do_HEAD(self) -> None:
        """Answer as GET would, without the body."""
        self._serve(send_body=False)

    def do_PUT(self) -> None:
        """Store the request body at the request path."""
        length = self.headers.get("Content-Length")
        if length is None or not length.isdigit():
            # The unread body would be taken for the next request.
            self.close_connection = True
            self._reply(411, self._auth())
            return
        # Read the body before refusing anything, so the connection
        # stays in step for the client however the request ends.
        body = self.rfile.read(int(length))
        auth = self._auth()
        if auth != "ok":
            self._reply(401, auth)
            return
        target = self.repo.locate(self.path)
        if target is None or target == self.repo.root:
            self._reply(403, auth)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(f".{target.name}.partial")
        _ = partial.write_bytes(body)
        _ = partial.replace(target)
        self._reply(201, auth)

    def _auth(self) -> str:
        """Classify the request's credentials as ok, bad or none."""
        header = self.headers.get("Authorization")
        if header is None:
            return "none"
        if hmac.compare_digest(header.encode(), self.repo.authorization):
            return "ok"
        return "bad"

    def _serve(self, *, send_body: bool) -> None:
        auth = self._auth()
        if auth != "ok":
            self._reply(401, auth)
            return
        body = self._content()
        if body is None:
            self._reply(404, auth)
        else:
            self._reply(200, auth, body, send_body=send_body)

    def _content(self) -> bytes | None:
        """The stored file, else a checksum of an existing file."""
        target = self.repo.locate(self.path)
        if target is None:
            return None
        if target.is_file():
            return target.read_bytes()
        algorithm = CHECKSUMS.get(target.suffix)
        source = target.with_suffix("")
        if algorithm is None or not source.is_file():
            return None
        digest = hashlib.new(algorithm, source.read_bytes()).hexdigest()
        return digest.encode("ascii")

    def _reply(
        self,
        status: int,
        auth: str,
        body: bytes = b"",
        *,
        send_body: bool = True,
    ) -> None:
        self.repo.record(f"{self.command} {self.path} auth={auth} status={status}")
        self.send_response(status)
        if status == 401:
            self.send_header("WWW-Authenticate", 'Basic realm="auth-repo"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body and body:
            _ = self.wfile.write(body)


def main(argv: list[str]) -> int:
    """Serve until killed, writing the port to the port file once ready."""
    if len(argv) != 4:
        print(f"usage: {argv[0]} <root> <port-file> <request-log>", file=sys.stderr)
        return 64
    root, port_file, log = (Path(arg) for arg in argv[1:])
    authorization = basic_authorization(
        os.environ["AUTH_USER"], os.environ["AUTH_PASSWORD"]
    )
    root.mkdir(parents=True, exist_ok=True)
    server = AuthRepo(root, log, authorization)
    # Rename into place so a reader never sees a partly written port.
    partial = port_file.with_name(f"{port_file.name}.partial")
    _ = partial.write_text(f"{server.port}\n", encoding="utf-8")
    _ = partial.replace(port_file)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
