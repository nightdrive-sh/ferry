"""Ferry's package (linux/ferry/) for the tests.

A test changes a name where it is defined: `mock.patch.object(store, "notify", …)` would miss, since store reaches it as
notices.notify; `owner(name)` finds that module for the tests that patch a list of names."""
import importlib
import inspect
import os
import pkgutil
import sys

LINUX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, LINUX)
import ferry  # noqa: E402

MODULES = [importlib.import_module("ferry." + m.name) for m in pkgutil.iter_modules(ferry.__path__)]
globals().update({m.__name__.split(".")[1]: m for m in MODULES})


def owner(name):
    """The module that defines name (not one that only imports it)."""
    for m in MODULES:
        if name in vars(m) and not inspect.ismodule(vars(m)[name]):
            return m
    raise AttributeError(name)

# The Mac, where these tests also run, has no /proc/net/tcp to say whose a connection is: the tests that talk to a real
# server there take every connection as their own (test_peers checks the real thing on Linux)
if not os.path.exists(peers.TABLE):
    peers.trusted = lambda client, server, table=None, me=None: True
