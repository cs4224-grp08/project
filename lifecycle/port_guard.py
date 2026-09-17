import argparse
import fcntl
import os
import signal
import socket
import sys
import threading
from pathlib import Path


def reserve(lock_path, port):
    lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for family, address in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
            if family == socket.AF_INET6 and not socket.has_ipv6:
                continue
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                if family == socket.AF_INET6:
                    probe.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                probe.bind((address, port))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("lock", type=Path)
    parser.add_argument("port", type=int)
    parser.add_argument("ready", type=Path)
    args = parser.parse_args()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    try:
        descriptor = reserve(args.lock, args.port)
    except OSError as error:
        print(f"Cannot reserve port {args.port}: {error}. Check for another job or listener.", file=sys.stderr)
        return 1
    try:
        args.ready.write_text(f"{os.getpid()}\n")
        stop.wait()
    finally:
        args.ready.unlink(missing_ok=True)
        os.close(descriptor)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
