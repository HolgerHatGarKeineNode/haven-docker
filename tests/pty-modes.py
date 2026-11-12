"""Terminal-mode sampler for tests/e2e-tui.sh (section 31).

pty-modes.py <tty> <outfile> <stopfile> [max_seconds]

Reads the local modes of <tty> (a tmux pane's terminal, opened without
becoming its controlling terminal) with termios.tcgetattr in a tight loop
until <stopfile> exists or max_seconds (default 120) have passed, then writes
one line to <outfile>:

  samples=<n> echo=<samples with ECHO set> icanon=<samples with ICANON set>

The line goes to <outfile>.tmp first and is renamed, so a reader never sees a
half-written file. Exit status 2 when <tty> cannot be opened or read.
"""
import os
import sys
import termios
import time


def main():
    tty, out, stop = sys.argv[1], sys.argv[2], sys.argv[3]
    limit = float(sys.argv[4]) if len(sys.argv) > 4 else 120.0
    try:
        fd = os.open(tty, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
        print("cannot open %s: %s" % (tty, e), file=sys.stderr)
        return 2
    samples = echo = icanon = 0
    deadline = time.monotonic() + limit
    try:
        while not os.path.exists(stop) and time.monotonic() < deadline:
            lflag = termios.tcgetattr(fd)[3]
            samples += 1
            if lflag & termios.ECHO:
                echo += 1
            if lflag & termios.ICANON:
                icanon += 1
            time.sleep(0.0005)
    except termios.error as e:
        print("cannot read the modes of %s: %s" % (tty, e), file=sys.stderr)
        return 2
    finally:
        os.close(fd)
    with open(out + ".tmp", "w") as f:
        f.write("samples=%d echo=%d icanon=%d\n" % (samples, echo, icanon))
    os.replace(out + ".tmp", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
