"""Telling the phones this computer is back: the silent "awake" push when Ferry starts and when the computer wakes from
sleep, so an iPhone app with a send waiting for it sends it from the background (docs/protocol.md › Sends that wait).

A wake is seen without asking the desktop or logind: CLOCK_MONOTONIC stops while the computer sleeps and CLOCK_BOOTTIME
doesn't, so the gap between them grows by the time slept. The push waits for the network: right after a wake neither
Wi-Fi nor Tailscale is up yet, and the phone, told too soon, would find nobody to send to."""
import sys
import time

from . import push, tailnet

EVERY = 10        # seconds between looks at the clocks
SLEPT = 30        # seconds of sleep that count as a wake (a laptop's lid, not a hiccup)
READY_FOR = 300   # seconds after a start or a wake the push is tried before it gives up (no network all that time)
TRY_EVERY = 15    # seconds between those tries


def slept_gap():
    """Seconds this computer has slept since it started."""
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)


def ready(st=None):
    """Whether this computer can be reached on the tailnet: Tailscale running and Ferry published there."""
    st = st if st is not None else tailnet.tailscale_status()
    return st.get("BackendState") == "Running" and bool(tailnet.url(st)) and tailnet.serving()


def announce(is_ready=ready, send=push.wake, clock=time.monotonic, sleep=time.sleep):
    """push.wake() once the computer is reachable, trying for READY_FOR seconds. Whether it went (None: no app to
    tell)."""
    end = clock() + READY_FOR
    while True:
        try:
            if is_ready():
                went = send()
                if went is None or went:
                    return went
        except Exception as e:   # one bad try mustn't end the thread that tells the phones
            print(f"the awake push failed: {e!r}", file=sys.stderr, flush=True)
        if clock() >= end:
            return False
        sleep(TRY_EVERY)


def run(gap=slept_gap, sleep=time.sleep, tell=announce):
    """The server's thread: tells the phones once at start, then after every wake."""
    tell()
    last = gap()
    while True:
        sleep(EVERY)
        now = gap()
        if now - last >= SLEPT:
            tell()
        last = now
