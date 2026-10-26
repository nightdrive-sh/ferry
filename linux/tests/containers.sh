#!/usr/bin/env bash
# The distribution matrix, on the Mac with OrbStack. In each fresh Linux machine, a Nightdrive computer's Ferry is set up
# (its state and its service), then Ferry is installed as a user does (curl … | bash, the release served from this Mac),
# and tests/in-container.sh checks that it runs and kept the old state, goes through the whole API with curl
# (tests/api.sh) and installs again as an update. Then tests/client.sh runs the iPhone app's client (FerryKit's
# HTTPBackend) against the same server. Each distribution's result is printed at the end, its output kept in
# build/containers/<distro>.log.
#
#   linux/tests/containers.sh [--keep] [ubuntu] [debian] [fedora] [arch]   (all four by default)
#
# Machines are made from scratch as ferry-test-<distro> and deleted afterwards (--keep: left for a look, orb -m …,
# and for tests/client.sh or tests/api.sh again).
set -uo pipefail
cd "$(dirname "$0")/.."

image() {   # (macOS's bash 3.2 has no associative arrays)
  case $1 in ubuntu) echo ubuntu:noble ;; debian) echo debian:trixie ;; fedora) echo fedora ;; arch) echo arch ;; esac
}
keep=0 distros=()
for a in "$@"; do
  case $a in
    --keep) keep=1 ;;
    ubuntu|debian|fedora|arch) distros+=("$a") ;;
    *) echo "Unknown: $a" >&2; exit 2 ;;
  esac
done
(( ${#distros[@]} )) || distros=(ubuntu debian fedora arch)

./release.sh || exit 1
# The client's tests, built once before the machines (a build that fails stops here, not after the first install)
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  swift build --package-path ../FerryKit --build-tests >/dev/null || { echo "FerryKit's tests don't build" >&2; exit 1; }
logs=$PWD/build/containers
mkdir -p "$logs"
fixture=$(mktemp -d "$PWD/build/fixture.XXXX")
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$fixture/vapid.pem"
port=47299
python3 -m http.server "$port" --bind 127.0.0.1 --directory build >/dev/null 2>&1 &
server=$!
disown "$server"   # (no "Terminated" when it is stopped at the end)
trap 'kill $server 2>/dev/null; rm -rf "$fixture"' EXIT

plain() { sed $'s/\x1b\\[[0-9;]*m//g' "$1"; }   # a log without its colours
results=() failed=0
for d in "${distros[@]}"; do
  m=ferry-test-$d log=$logs/$d.log
  orb delete -f "$m" >/dev/null 2>&1 || true
  echo "Making $m ($(image "$d"))" | tee "$log"
  if ! orb create "$(image "$d")" "$m" >>"$log" 2>&1; then
    results+=("$(printf '%-7s FAILED: the machine (%s) could not be made' "$d" "$(image "$d")")") failed=1
    continue
  fi
  # host.orb.internal is the Mac from inside a machine; the Mac's files are at the same paths there
  orb -m "$m" env RELEASE="http://host.orb.internal:$port" FIXTURE="$fixture" TESTS="$PWD/tests" \
    bash "$PWD/tests/in-container.sh" 2>&1 | tee -a "$log"
  installed=${PIPESTATUS[0]}
  os=$(plain "$log" | sed -n 's/^== //p' | head -1)
  if (( installed )); then
    step=$(plain "$log" | sed -n 's/^== //p' | tail -1)
    why=$(grep -m1 "FAILED:" "$log" | sed 's/^ *FAILED: //')
    results+=("$(printf '%-7s FAILED in "%s": %s (%s)' "$d" "$step" "${why:-see the log}" "${os:-?}")") failed=1
  else
    printf '\n\033[1m== The iPhone app'"'"'s client\033[0m\n' | tee -a "$log"
    tests/client.sh "$m" 2>&1 | tee -a "$log"
    if (( PIPESTATUS[0] )); then
      results+=("$(printf '%-7s FAILED in the iPhone app'"'"'s client tests (%s)' "$d" "$os")") failed=1
    else
      counts=$(grep -c '^  ok: ' "$log")
      clients=$(plain "$log" | sed -n 's/.*Test run with \([0-9]*\) tests.*passed.*/\1/p' | tail -1)
      results+=("$(printf '%-7s PASS  %s: install, %s checks with curl, update, %s client tests' "$d" "$os" "$counts" \
        "${clients:-?}")")
    fi
  fi
  (( keep )) || orb delete -f "$m" >/dev/null
done

printf '\n\033[1mResults\033[0m (logs in %s)\n' "$logs"
printf '  %s\n' "${results[@]}"
exit "$failed"
