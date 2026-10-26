"""bin/ferry as a module for the tests: it is a script without .py, so it is loaded by its path."""
import importlib.machinery
import importlib.util
import os
import sys

_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "ferry")
_loader = importlib.machinery.SourceFileLoader("ferry", _path)
_spec = importlib.util.spec_from_loader("ferry", _loader)
ferry = sys.modules.get("ferry") or importlib.util.module_from_spec(_spec)
if "ferry" not in sys.modules:
    sys.modules["ferry"] = ferry
    _loader.exec_module(ferry)
