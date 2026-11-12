"""Keystroke fixture for tests/haven-prompt.bats.

pty-keys.py <cols> <lines> <keys.json> <donefile> <outfile> <command> [args...]

Runs <command> in a fresh pty of <cols> x <lines>, writes the chunks of the
JSON list in <keys.json> to it one after the other (0.15 s apart, so the
prompt's 0.1 s read polls see them as separate keys; a chunk is one key or one
bracketed paste) once <donefile>.ready exists, and keeps reading until <donefile> exists (the command
writes it when it is finished) or 30 s passed. Everything the command wrote
to the terminal goes to <outfile> (for tests/term-emu.py). Prints "done" or
"timeout"; exit status 2 on a timeout.
"""
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def main():
    cols, lines = int(sys.argv[1]), int(sys.argv[2])
    keys = json.load(open(sys.argv[3], encoding="utf-8"))
    done, outf = sys.argv[4], sys.argv[5]
    cmd = sys.argv[6:]
    pid, fd = pty.fork()
    if pid == 0:
        for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGPIPE):
            signal.signal(s, signal.SIG_DFL)
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", lines, cols, 0, 0))
    buf = b""

    def drain(timeout):
        nonlocal buf
        r, _, _ = select.select([fd], [], [], timeout)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                pass

    deadline = time.time() + 30
    # let the command reach its first read: it touches <donefile>.ready right
    # before it opens the prompt (whose input flush runs first), then a margin
    while time.time() < deadline and not os.path.exists(done + ".ready"):
        drain(0.05)
    t0 = time.time()
    while time.time() - t0 < 0.4:
        drain(0.05)
    for k in keys:
        os.write(fd, k.encode("utf-8"))
        t0 = time.time()
        while time.time() - t0 < 0.15:
            drain(0.03)
    state = "timeout"
    while time.time() < deadline:
        if os.path.exists(done):
            state = "done"
            break
        drain(0.05)
    t0 = time.time()
    while time.time() - t0 < 0.2:
        drain(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    open(outf, "wb").write(buf)
    print(state)
    sys.exit(0 if state == "done" else 2)


if __name__ == "__main__":
    main()
