#!/usr/bin/env bash
# What CI checks on Linux, runnable here the same way (Fedora: dnf install ShellCheck python3-cryptography):
#   - every shell script: bash -n and shellcheck (warnings and errors; style notes are left alone)
#   - every Python file parses, and the Linux server's and app's tests pass
#   - linux/release.sh builds a release whose files match its SHA256SUMS, and the tarball's VERSION is the release's
#     (it replaces linux/build, as release.sh always does: don't run this before a release's files are uploaded)
# The relay's phpunit is a job of its own in ci.yml (PHP and Composer), and swift test needs a Mac.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Shell scripts by their shebang too, since some have no .sh (linux/tests/fake-tailscale)
mapfile -t scripts < <(git ls-files | while read -r f; do
  [[ -f $f ]] || continue
  if [[ $f == *.sh ]] || head -n1 "$f" | grep -qE '^#!.*\b(ba)?sh\b'; then echo "$f"; fi
done)
echo "Shell: ${#scripts[@]} scripts"
for f in "${scripts[@]}"; do bash -n "$f"; done
shellcheck -S warning "${scripts[@]}"

echo "Python: syntax"
git ls-files '*.py' linux/bin/ferry | python3 -c '
import ast, sys
for path in sys.stdin.read().split():
    ast.parse(open(path, encoding="utf-8").read(), path)
'

echo "Python: the Linux tests"
# No __pycache__ left behind in the checkout
(cd linux && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests)

echo "Release: linux/release.sh --beta 0"
linux/release.sh --beta 0
(cd linux/build && sha256sum -c SHA256SUMS)
[[ $(tar -xOzf linux/build/ferry-linux.tar.gz ferry/ferry/config.py | sed -n 's/^VERSION = "\(.*\)"$/\1/p') == *-beta.0 ]]
rm -rf linux/build
