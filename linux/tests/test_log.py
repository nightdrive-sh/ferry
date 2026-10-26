"""What the server writes to the journal: the requests, never what they carry (a file's name is in the query). Run from
linux/:

    python3 -m unittest discover -s tests -p test_log.py
"""
import contextlib
import io
import unittest

from load import ferry


class RequestLines(unittest.TestCase):
    def logged(self, fmt, *args):
        cls = ferry.handler(None)
        h = cls.__new__(cls)
        h.headers = None
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            h.log_message(fmt, *args)
        return out.getvalue()

    def test_an_uploads_name_isnt_logged(self):
        line = self.logged('"%s" %s %s', "POST /ferry/api/upload?name=Lasku%20%26%20kuitti.pdf&type=application/pdf"
                           "&clip=1 HTTP/1.1", "200", "-")
        self.assertIn("POST /ferry/api/upload HTTP/1.1", line)
        self.assertIn("200", line)
        self.assertNotIn("Lasku", line)
        self.assertNotIn("?", line)

    def test_an_error_names_no_query_either(self):   # BaseHTTPRequestHandler's own, with the request line in it
        line = self.logged("code %d, message %s", 400, "Bad request syntax ('GET /ferry/api/upload?name=Salainen.pdf')")
        self.assertNotIn("Salainen", line)
        self.assertIn("code 400", line)

    def test_a_plain_request(self):
        self.assertIn("GET /ferry/api/items HTTP/1.1", self.logged('"%s" %s %s', "GET /ferry/api/items HTTP/1.1", "200", "-"))


if __name__ == "__main__":
    unittest.main()
