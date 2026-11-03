"""An upload's body within its limits (docs/protocol.md › api/upload): sizes read strictly, the 4 GiB limit counted from
what arrives, and the free space looked at as a chunked upload grows. Run from linux/:

    python3 -m unittest discover -s tests -p test_upload.py
"""
import collections
import io
import os
import tempfile
import unittest
from unittest import mock

from load import api, bodies, config


def chunked(*parts, end=b"0\r\n\r\n"):
    """A chunked body of these chunks (bytes), or of size lines given as they are (str)."""
    out = b""
    for p in parts:
        out += p.encode() if isinstance(p, str) else b"%x\r\n%s\r\n" % (len(p), p)
    return out + end


def read(body, headers, limit=100, step=4):
    return b"".join(bodies.pieces(io.BytesIO(body), headers, limit, step))


class Sizes(unittest.TestCase):
    CHUNKED = {"Transfer-Encoding": "chunked"}

    def test_a_chunked_body(self):
        self.assertEqual(read(chunked(b"hello ", b"world"), self.CHUNKED), b"hello world")

    def test_chunk_extensions_and_trailers(self):
        body = b"5;name=x\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n"
        self.assertEqual(read(body, self.CHUNKED), b"hello")

    def test_a_negative_chunk_doesnt_take_back_from_the_limit(self):
        # int("-5", 16) == -5: the total went down and the limit never came
        body = chunked(b"x" * 60, "-50\r\n", b"y" * 60)
        with self.assertRaises(ValueError):
            read(body, self.CHUNKED)

    def test_signs_spaces_and_underscores_are_no_size(self):
        for line in ("+5\r\n", "0x5\r\n", "5_0\r\n", " \r\n", "123456789\r\n"):
            with self.subTest(line=line), self.assertRaises(ValueError):
                read(chunked(line + "hello\r\n"), self.CHUNKED)

    def test_the_limit_counts_every_chunk(self):
        with self.assertRaises(bodies.TooBig):
            read(chunked(b"x" * 60, b"y" * 60), self.CHUNKED)

    def test_a_chunk_over_the_limit_isnt_read(self):
        f = io.BytesIO(b"ffffffff\r\n" + b"x" * 10)
        with self.assertRaises(bodies.TooBig):
            list(bodies.pieces(f, self.CHUNKED, 100, 4))
        self.assertEqual(f.tell(), len(b"ffffffff\r\n"))

    def test_a_chunk_out_of_step(self):
        with self.assertRaises(ValueError):
            read(b"3\r\nhelloworld\r\n0\r\n\r\n", self.CHUNKED)

    def test_a_connection_that_ends_early(self):
        for body in (b"5\r\nhel", b"5\r\nhello\r\n"):
            with self.subTest(body=body), self.assertRaises(OSError):
                read(body, self.CHUNKED)

    def test_content_length(self):
        self.assertEqual(read(b"hello world", {"Content-Length": "5"}), b"hello")
        self.assertEqual(read(b"", {}), b"")
        with self.assertRaises(bodies.TooBig):
            read(b"x" * 101, {"Content-Length": "101"})

    def test_a_negative_content_length_is_no_length(self):
        # rfile.read(-1) reads to the end of the connection, past any limit
        for v in ("-1", "+5", "5 5", "0x10", "1e3"):
            with self.subTest(v=v), self.assertRaises(ValueError):
                bodies.length({"Content-Length": v})

    def test_a_bad_content_length_closes_the_connection(self):
        self.assertTrue(bodies.unread({"Content-Length": "-1"}))
        self.assertTrue(bodies.unread(self.CHUNKED))
        self.assertFalse(bodies.unread({"Content-Length": "0"}))
        self.assertFalse(bodies.unread({}))


class Upload(unittest.TestCase):
    """The handler's upload(): which answer each limit gives, and that nothing is left behind."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dest = tmp.name
        for name, value in (("downloads", lambda: self.dest), ("MAX_FILE", 1000), ("FREE_CHECK", 100),
                            ("MIN_FREE", 500)):
            p = mock.patch.object(config, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.free = 10 ** 6
        p = mock.patch.object(api.shutil, "disk_usage", lambda d: collections.namedtuple("U", "free")(self.free))
        p.start()
        self.addCleanup(p.stop)

    def upload(self, body, headers, shrink=0):
        """upload() of this body; shrink takes that many bytes off the free space for each one written."""
        app = mock.Mock()
        app.tailnet.device.return_value = "iPhone"
        cls = api.handler(app)
        h = cls.__new__(cls)
        h.headers, h.consumed, h.answers = headers, False, []
        rfile = io.BytesIO(body)
        if shrink:
            real = rfile.read

            def read(n=-1):
                got = real(n)
                self.free -= shrink * len(got)
                return got
            rfile.read = read
        h.rfile = rfile
        h.send = lambda code, body=b"", *a, **k: h.answers.append((code, body))
        h.upload({"name": "photo.jpg"})
        return h.answers[0][0], os.listdir(self.dest), app

    def test_a_chunked_upload_is_saved(self):
        code, files, app = self.upload(chunked(b"x" * 300, b"y" * 300), {"Transfer-Encoding": "chunked"})
        self.assertEqual((code, files), (200, ["photo.jpg"]))
        self.assertEqual(app.received_file.call_args.args[1], 600)

    def test_a_chunked_upload_over_the_limit(self):
        body = chunked(*[b"x" * 300] * 4)
        self.assertEqual(self.upload(body, {"Transfer-Encoding": "chunked"})[:2], (413, []))

    def test_negative_chunks_dont_get_past_the_limit(self):
        body = chunked(*[b"x" * 300, "-12c\r\n"] * 4)
        code, files, app = self.upload(body, {"Transfer-Encoding": "chunked"})
        self.assertEqual((code, files), (400, []))
        app.received_file.assert_not_called()

    def test_a_chunked_upload_stops_when_the_disk_fills(self):
        # No Content-Length to check at the start: the free space is looked at again every FREE_CHECK bytes
        self.free = 1000
        code, files, app = self.upload(chunked(*[b"x" * 100] * 9), {"Transfer-Encoding": "chunked"}, shrink=1)
        self.assertEqual((code, files), (507, []))
        app.received_file.assert_not_called()

    def test_a_content_length_over_the_limit(self):
        self.assertEqual(self.upload(b"x" * 1001, {"Content-Length": "1001"})[:2], (413, []))

    def test_a_content_length_that_wouldnt_fit(self):
        self.free = 900
        self.assertEqual(self.upload(b"x" * 600, {"Content-Length": "600"})[:2], (507, []))


if __name__ == "__main__":
    unittest.main()
