"""Who opened a connection to the local server: the user its socket belongs to, from the kernel's table of TCP sockets.

The server listens on 127.0.0.1, where tailscale serve reaches it, and everything else about who is asking is in
headers (Tailscale-User-Login, Host) that any local process could make up. Tailscale won't publish a Unix socket
without root or sudo, so the port stays, and a connection is taken only from tailscaled (root) or this user's own
processes, which can read Ferry's state anyway. Another user of the same computer gets the connection closed."""
import os
import socket
import struct

TABLE = "/proc/net/tcp"     # IPv4 only: the server listens on 127.0.0.1
ESTABLISHED = "01"


def hex_address(host, port):
    """An address as the table writes it: the IPv4 address as the kernel's 32-bit number in this machine's byte order,
    the port in ordinary hex."""
    number = struct.unpack("=I", socket.inet_aton(host))[0]
    return f"{number:08X}:{port:04X}"


def uid_of(client, server, table=None):
    """The uid owning the client's end of the connection client → server ((host, port) pairs), or None when the table
    has no such connection (or can't be read: then nobody is trusted)."""
    mine, theirs = hex_address(*client), hex_address(*server)
    try:
        with open(table or TABLE) as f:
            next(f, None)   # the header
            for line in f:
                fields = line.split()
                if len(fields) > 7 and fields[1] == mine and fields[2] == theirs and fields[3] == ESTABLISHED:
                    return int(fields[7])
    except (OSError, ValueError):
        pass
    return None


def trusted(client, server, table=None, me=None):
    """Whether a connection may be answered: its client is root's (tailscaled) or this user's."""
    uid = uid_of(client, server, table)
    return uid is not None and uid in (0, os.getuid() if me is None else me)
