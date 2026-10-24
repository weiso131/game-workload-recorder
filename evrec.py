#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0
"""Record / replay keyboard+mouse evdev events aligned to a game launch.

libinput record/replay rebases time on the first event, which loses the gap
between launching the game and the first input; replaying title-screen input
then needs that gap. Here every event keeps its CLOCK_MONOTONIC timestamp and
replay re-anchors them to the moment the game is launched again.
"""

import argparse
import fcntl
import gzip
import json
import os
import select
import signal
import struct
import sys
import time

import libevdev

EVIOCSCLOCKID = 0x400445A0  # _IOW('E', 0xa0, int)

DEFAULT_DEVICES = ["Logitech USB Keyboard", "USB GAMING MOUSE", "USB GAMING MOUSE  Keyboard"]


def find_event_nodes(names):
    nodes = {}
    name = None
    with open("/proc/bus/input/devices") as f:
        for line in f:
            if line.startswith("N: Name="):
                name = line[len("N: Name="):].strip().strip('"').strip()
            elif line.startswith("H: Handlers=") and name in names:
                ev = [h for h in line.split("=", 1)[1].split() if h.startswith("event")]
                if ev:
                    nodes[name] = "/dev/input/" + ev[0]
    missing = [n for n in names if n not in nodes]
    if missing:
        sys.exit(f"input device not found: {missing}")
    return [(n, nodes[n]) for n in names]


def describe(dev):
    caps = {}
    for t, codes in dev.evbits.items():
        # Recorded key repeats (value 2) are replayed as-is; EV_REP on the
        # uinput device would make the kernel add a second set of repeats.
        if t in (libevdev.EV_SYN, libevdev.EV_REP):
            continue
        caps[t.name] = [c.name for c in codes]
    absinfo = {}
    for c in caps.get("EV_ABS", []):
        a = dev.absinfo[libevdev.evbit(c)]
        absinfo[c] = [a.minimum, a.maximum, a.fuzz, a.flat, a.resolution]
    return {"name": dev.name, "id": dev.id, "caps": caps, "absinfo": absinfo}


def record(args):
    devs = []
    for name, node in find_event_nodes(args.device or DEFAULT_DEVICES):
        fd = open(node, "rb")
        os.set_blocking(fd.fileno(), False)
        fcntl.ioctl(fd, EVIOCSCLOCKID, struct.pack("i", time.CLOCK_MONOTONIC))
        d = libevdev.Device(fd)
        devs.append(d)

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "devices.json"), "w") as f:
        json.dump([describe(d) for d in devs], f, indent=1)

    stop = False

    def on_signal(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    deadline = time.monotonic() + args.duration if args.duration else None
    by_fd = {d.fd.fileno(): (i, d) for i, d in enumerate(devs)}
    n = 0
    with gzip.open(os.path.join(args.out, "events.tsv.gz"), "wt") as out:
        if args.ready:
            with open(args.ready, "w") as f:
                f.write(str(os.getpid()))
        while not stop:
            timeout = 0.5
            if deadline is not None:
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                timeout = min(timeout, left)
            try:
                ready, _, _ = select.select(list(by_fd), [], [], timeout)
            except InterruptedError:
                continue
            for fd in ready:
                idx, d = by_fd[fd]
                try:
                    evs = list(d.events())
                except libevdev.EventsDroppedException:
                    evs = list(d.sync())
                for e in evs:
                    ns = e.sec * 1_000_000_000 + e.usec * 1000
                    out.write(f"{ns}\t{idx}\t{e.type.value}\t{e.code.value}\t{e.value}\n")
                    n += 1
    print(f"recorded {n} events", file=sys.stderr)

    if args.owner:
        uid, gid = (int(x) for x in args.owner.split(":"))
        for p in (args.out, *(os.path.join(args.out, f) for f in os.listdir(args.out))):
            os.chown(p, uid, gid)


def make_uinput(desc):
    d = libevdev.Device()
    d.name = desc["name"]
    d.id = desc["id"]
    for t, codes in desc["caps"].items():
        if t == "EV_REP":
            continue
        for c in codes:
            code = libevdev.evbit(c)
            if t == "EV_ABS":
                mn, mx, fuzz, flat, res = desc["absinfo"][c]
                d.enable(code, libevdev.InputAbsInfo(minimum=mn, maximum=mx, fuzz=fuzz,
                                                     flat=flat, resolution=res))
            else:
                d.enable(code)
    return d.create_uinput_device()


def replay(args):
    with open(os.path.join(args.dir, "devices.json")) as f:
        uinputs = [make_uinput(d) for d in json.load(f)]
    with open(os.path.join(args.dir, "meta.json")) as f:
        meta = json.load(f)
    t0_rec = meta["launch_monotonic_ns"]

    # uinput devices need a moment before the compositor starts listening.
    time.sleep(1)
    if args.ready:
        with open(args.ready, "w") as f:
            f.write(str(os.getpid()))
    while not os.path.exists(args.launched):
        time.sleep(0.01)
    with open(args.launched) as f:
        t0 = int(f.read())

    # Streamed rather than sorted: a 30 min recording is millions of events, and
    # file order is read order, which is chronological to within one select() pass.
    codes = {}
    pending = [None] * len(uinputs)
    syn = (libevdev.EV_SYN.value, libevdev.EV_SYN.SYN_REPORT.value)
    with gzip.open(os.path.join(args.dir, "events.tsv.gz"), "rt") as f:
        for line in f:
            ns, idx, t, c, v = (int(x) for x in line.split("\t"))
            code = codes.get((t, c))
            if code is None:
                code = codes[(t, c)] = libevdev.evbit(t, c)
            if pending[idx] is None:
                pending[idx] = (ns - t0_rec, [])
            pending[idx][1].append(libevdev.InputEvent(code, v))
            if (t, c) != syn:
                continue
            off, evs = pending[idx]
            pending[idx] = None
            if off < 0:
                continue
            delay = t0 + off - time.clock_gettime_ns(time.CLOCK_MONOTONIC)
            if delay > 0:
                time.sleep(delay / 1e9)
            uinputs[idx].send_events(evs)

    # Hold until the recorded duration so every replay covers the same window.
    left = t0 + meta["duration_s"] * 1_000_000_000 - time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    if left > 0:
        time.sleep(left / 1e9)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record")
    r.add_argument("out")
    r.add_argument("--device", action="append", help="device name (repeatable)")
    r.add_argument("--duration", type=int, default=0, help="seconds, 0 = until SIGINT")
    r.add_argument("--ready", help="write our pid here once recording has started")
    r.add_argument("--owner", help="uid:gid to chown the output to")

    s = sub.add_parser("replay")
    s.add_argument("dir")
    s.add_argument("--ready", help="write our pid here once uinput devices exist")
    s.add_argument("--launched", required=True,
                   help="file the caller writes the launch CLOCK_MONOTONIC ns into")

    args = p.parse_args()
    {"record": record, "replay": replay}[args.cmd](args)


if __name__ == "__main__":
    main()
