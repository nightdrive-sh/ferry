"""A request's body read within its limits: with a Content-Length, or chunked (docs/protocol.md › api/upload).

Sizes are read strictly. int() takes "-5", " +5" and "5_0": a negative chunk size, subtracted from the running total,
let an upload past MAX_FILE, and a negative Content-Length made rfile.read() read to the end of the connection. Here a
size is digits only (hex for a chunk), and the limit counts the bytes the body is made of, so no size line gets more
than limit bytes out."""
import re

DIGITS = re.compile(rb"[0-9]{1,15}")
HEX = re.compile(rb"[0-9a-fA-F]{1,8}")   # 8 hex digits: a chunk under 4 GiB, and no sign
LINE = 1024                             # bytes of a chunk's size line or a trailer


class TooBig(ValueError):
    """The body is over its limit: 413."""


class NoSpace(OSError):
    """The disk would have less than MIN_FREE left: 507."""


def chunked(headers):
    return "chunked" in (headers.get("Transfer-Encoding") or "").lower()


def length(headers):
    """The Content-Length, 0 without one. ValueError for anything but digits."""
    v = (headers.get("Content-Length") or "").strip().encode()
    if not v:
        return 0
    if not DIGITS.fullmatch(v):
        raise ValueError("bad Content-Length")
    return int(v)


def unread(headers):
    """The request has a body (any Content-Length but 0, even a bad one, or chunked), so answering without reading it
    has to close the connection."""
    return chunked(headers) or (headers.get("Content-Length") or "0").strip() != "0"


def chunk_size(line):
    """A chunk's size from its line (extensions after ';' left out). ValueError for a size that isn't hex digits."""
    v = line.split(b";")[0].strip()
    if not HEX.fullmatch(v):
        raise ValueError("bad chunk size")
    return int(v, 16)


def read(rfile, n, step):
    """n bytes in pieces of at most step. OSError if the connection closes first."""
    while n > 0:
        piece = rfile.read(min(step, n))
        if not piece:
            raise OSError("connection closed")
        n -= len(piece)
        yield piece


def pieces(rfile, headers, limit, step):
    """The body in pieces of at most step bytes: TooBig past limit (before reading what would be over it), ValueError
    for a malformed chunked body, OSError when the connection closes before its end."""
    if not chunked(headers):
        n = length(headers)
        if n > limit:
            raise TooBig("too big")
        yield from read(rfile, n, step)
        return
    total = 0
    while True:
        line = rfile.readline(LINE)
        if not line:
            raise OSError("connection closed")
        size = chunk_size(line)
        if size == 0:
            while rfile.readline(LINE).strip():   # the trailers, up to the empty line
                pass
            return
        total += size
        if total > limit:
            raise TooBig("too big")
        yield from read(rfile, size, step)
        if rfile.readline(LINE).strip():   # the CRLF after a chunk: anything else is a body out of step
            raise ValueError("bad chunk end")
