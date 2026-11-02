"""Ferry's package for the tests, and bin/ferry, a script without .py, loaded by its path as `bin_ferry`.

A test changes a name where it is defined: `mock.patch.object(store, "notify", …)` would miss, since store reaches it as
notices.notify; `owner(name)` finds that module for the tests that patch a list of names."""
import importlib
import importlib.machinery
import importlib.util
import inspect
import os
import pkgutil
import sys

LINUX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, LINUX)
import ferry  # noqa: E402

MODULES = [importlib.import_module("ferry." + m.name) for m in pkgutil.iter_modules(ferry.__path__)]
globals().update({m.__name__.split(".")[1]: m for m in MODULES})

_path = os.path.join(LINUX, "bin", "ferry")
_loader = importlib.machinery.SourceFileLoader("ferry_cmd", _path)
_spec = importlib.util.spec_from_loader("ferry_cmd", _loader)
bin_ferry = sys.modules.get("ferry_cmd") or importlib.util.module_from_spec(_spec)
if "ferry_cmd" not in sys.modules:
    sys.modules["ferry_cmd"] = bin_ferry
    _loader.exec_module(bin_ferry)


def owner(name):
    """The module that defines name (not one that only imports it)."""
    for m in MODULES + [bin_ferry]:
        if name in vars(m) and not inspect.ismodule(vars(m)[name]):
            return m
    raise AttributeError(name)
