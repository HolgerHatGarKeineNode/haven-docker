"""Terminal hangup fixture for tests/haven-backup.bats.

pty-hangup.py <mode> <statedir> <outfile> <command> [args...]

Runs <command> as the session leader of a fresh pty (signals reset to their
defaults first), reads its output until the scripted docker mock touches
<statedir>/started (the held one-shot has begun), then:

  hangup  closes the master side: the kernel sends SIGHUP to the session
          leader, and every later write to the terminal fails with EIO
  kill    sends SIGHUP with the master left open (the control: the same
          signal on a terminal that still works)

Writes what the command printed to <outfile> and one line to stdout:
"exit <n>" or "signal <n>". Exit status 2 when the one-shot never started or
the command did not end within 40 s (it is killed then).
"""
import os
import pty
import select
import signal
import sys
import time


def drain(fd, buf, timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    if r:
        try:
            buf += os.read(fd, 65536)
        except OSError:
            pass
    return buf


def main():
    mode, state, outf = sys.argv[1], sys.argv[2], sys.argv[3]
    cmd = sys.argv[4:]
    if mode not in ("hangup", "kill") or not cmd:
        sys.stderr.write(__doc__)
        return 2
    pid, fd = pty.fork()
    if pid == 0:
        for s in (signal.SIGPIPE, signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
            signal.signal(s, signal.SIG_DFL)
        os.execv(cmd[0], cmd)
    buf = b""
    started = os.path.join(state, "started")
    deadline = time.time() + 15
    while time.time() < deadline and not os.path.exists(started):
        buf = drain(fd, buf, 0.05)
    if not os.path.exists(started):
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        open(outf, "wb").write(buf)
        print("one-shot never started")
        return 2
    # the relay stop and the first lines are through; let the output settle
    end = time.time() + 0.3
    while time.time() < end:
        buf = drain(fd, buf, 0.05)
    if mode == "hangup":
        os.close(fd)
    else:
        os.kill(pid, signal.SIGHUP)
    st = None
    end = time.time() + 40
    while time.time() < end:
        if mode == "kill":
            buf = drain(fd, buf, 0.05)
        p, st = os.waitpid(pid, os.WNOHANG)
        if p:
            break
        time.sleep(0.05)
    else:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        open(outf, "wb").write(buf)
        print("still running after 40 s")
        return 2
    if mode == "kill":
        buf = drain(fd, buf, 0.2)
    open(outf, "wb").write(buf)
    if os.WIFSIGNALED(st):
        print("signal %d" % os.WTERMSIG(st))
    else:
        print("exit %d" % os.WEXITSTATUS(st))
    return 0


if __name__ == "__main__":
    sys.exit(main())
