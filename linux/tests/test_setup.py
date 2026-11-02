"""What stands between Ferry and the owner's devices, as the window and `ferry list --json` say it. Run from linux/:

    python3 -m unittest discover -s tests -p test_setup.py
"""
import unittest

from load import bin_ferry, config, tailnet

RUNNING = {"BackendState": "Running", "CertDomains": ["pc.tail0.ts.net"],
           "Self": {"DNSName": "pc.tail0.ts.net.", "UserID": 1}}


def step(st=RUNNING, have=True, running=True, served=True):
    s = tailnet.setup_step(st, have_tailscale=have, running=running, served=served)
    return s and s["step"]


class SetupStep(unittest.TestCase):
    def test_nothing_in_the_way(self):
        self.assertIsNone(step())

    def test_tailscale_missing_links_its_download(self):
        s = tailnet.setup_step({}, have_tailscale=False, running=True, served=False)
        self.assertEqual(s["step"], "tailscale-missing")
        self.assertEqual(s["link"], config.TAILSCALE_DOWNLOAD)

    def test_tailscale_not_running(self):
        s = tailnet.setup_step({}, have_tailscale=True, running=True, served=False)
        self.assertEqual(s["step"], "tailscale-off")
        self.assertIn("systemctl", s["command"])

    def test_logged_out_gives_the_login_link_when_tailscale_has_one(self):
        st = {"BackendState": "NeedsLogin", "AuthURL": "https://login.tailscale.com/a/abc"}
        s = tailnet.setup_step(st, have_tailscale=True, running=True, served=False)
        self.assertEqual(s["step"], "logged-out")
        self.assertEqual(s["link"], "https://login.tailscale.com/a/abc")
        self.assertEqual(s["command"], "sudo tailscale up")

    def test_logged_out_without_a_link(self):
        s = tailnet.setup_step({"BackendState": "NeedsLogin"}, have_tailscale=True, running=True, served=False)
        self.assertNotIn("link", s)

    def test_waiting_for_the_admin_to_approve_the_machine(self):
        self.assertEqual(step({"BackendState": "NeedsMachineAuth"}, served=False), "needs-approval")

    def test_tailscale_turned_off(self):
        s = tailnet.setup_step({"BackendState": "Stopped"}, have_tailscale=True, running=True, served=False)
        self.assertEqual(s["step"], "tailscale-stopped")
        self.assertEqual(s["action"], "tailscale-up")

    def test_ferry_stopped_while_tailscale_is_fine(self):
        # Tailscale is fine and Ferry isn't running: turning Ferry on is the one thing to do
        s = tailnet.setup_step(RUNNING, have_tailscale=True, running=False, served=True)
        self.assertEqual(s["step"], "stopped")
        self.assertEqual(s["action"], "enable")

    def test_tailscale_s_problem_comes_first_when_both(self):
        self.assertEqual(step({"BackendState": "Stopped"}, running=False, served=False), "tailscale-stopped")

    def test_https_certificates_off(self):
        st = dict(RUNNING, CertDomains=None)
        s = tailnet.setup_step(st, have_tailscale=True, running=True, served=False)
        self.assertEqual(s["step"], "https-off")
        self.assertEqual(s["link"], config.TAILSCALE_DNS)

    def test_published_with_certificates_unknown_is_fine(self):
        # Serve already works: whatever CertDomains says, nothing is in the way
        self.assertIsNone(step(dict(RUNNING, CertDomains=None), served=True))

    def test_not_published(self):
        self.assertEqual(step(served=False), "not-published")


class PublishProblem(unittest.TestCase):
    def test_operator_rights_missing(self):
        out = "Access denied: serve config denied\n\nUse 'sudo tailscale serve ...' or 'tailscale set --operator=$USER'"
        s = tailnet.publish_problem(out, user="jari")
        self.assertEqual(s["step"], "operator")
        self.assertEqual(s["command"], "sudo tailscale set --operator=jari")
        self.assertEqual(s["action"], "operator")

    def test_tailscale_s_own_words_and_link(self):
        out = "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n  https://login.tailscale.com/f/serve?node=n1\n"
        s = tailnet.publish_problem(out, user="jari")
        self.assertEqual(s["step"], "problem")
        self.assertEqual(s["link"], "https://login.tailscale.com/f/serve?node=n1")
        self.assertEqual(s["text"], "Serve is not enabled on your tailnet.")

    def test_nothing_said(self):
        self.assertEqual(tailnet.publish_problem("", user="jari")["text"], "tailscale serve failed")


class Publish(unittest.TestCase):
    def setUp(self):
        self.serve = tailnet.serve

    def tearDown(self):
        tailnet.serve = self.serve

    def test_published(self):
        tailnet.serve = lambda on, raw=False: ""
        self.assertIsNone(tailnet.publish())

    def test_refused(self):
        tailnet.serve = lambda on, raw=False: "Access denied: serve config denied"
        self.assertEqual(tailnet.publish()["step"], "operator")

    def test_serve_says_why_in_a_terminal(self):
        tailnet.serve = self.serve
        self.assertIn("--operator", tailnet.serve_message("Access denied: serve config denied"))
        self.assertEqual(tailnet.serve_message("line one\nline two"), "line two")


if __name__ == "__main__":
    unittest.main()


class WarmCertificate(unittest.TestCase):
    """Ferry asks its own https address once it is published, so that tailscale serve fetches the tailnet's
    certificate then, not while the phone's first try waits (36 s for a new machine name in a VM, longer than it waits)."""
    URL = "https://pc.tail0.ts.net/ferry/"

    def warm(self, url=URL, served=True, fails=False):
        asked = []

        def get(u):
            asked.append(u)
            if fails:
                raise OSError("timed out")
        return bin_ferry.warm_certificate(own=lambda: url, served=lambda: served, get=get), asked

    def test_asks_its_own_address(self):
        self.assertEqual(self.warm(), (self.URL, [self.URL + "api/ping"]))

    def test_not_before_it_is_published(self):
        self.assertEqual(self.warm(served=False), ("", []))
        self.assertEqual(self.warm(url=""), ("", []))

    def test_tries_again_after_a_failure(self):   # "" means not warmed: the loop asks again
        self.assertEqual(self.warm(fails=True)[0], "")
