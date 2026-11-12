#!/usr/bin/env python3
"""A small cursor-aware terminal emulator for the TUI geometry tests.

Reads the byte stream of one or more render passes on stdin and replays it on
a COLS x LINES grid: CUP (ESC[r;cH, ESC[H), clear (ESC[2J), SGR and private
modes (ignored), printable characters (East Asian Wide/Fullwidth take two
cells). A character that would start or extend past column COLS is recorded
as an overflow instead of wrapping, so "nothing is written beyond COLS" is a
count.

    python3 -I tests/term-emu.py COLS LINES frame

prints a report of the frame geometry, one fact per line:
    overflow <n>                      characters written beyond COLS
    end <row> <col>                   last non-blank cell of each frame row
    last <row> <char>                 the character in that cell
    first <row> <char>                first cell of each frame row
    junction <┬> <title │> <┼> <┴>    columns of the four divider glyphs
    title <row-1 text>                row 1 as drawn (wide glyphs once)

    python3 -I tests/term-emu.py COLS LINES dump

prints the grid, one row per line (a wide glyph once, its second cell left out).

The input may also be a `tmux capture-pane -p -N` text with CRLF line ends: the
rows are then replayed from column 0 one under the other.
"""
import re
import sys
import unicodedata

WIDE = "\x00"  # second cell of a wide glyph


def width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def replay(data, cols, lines):
    grid = [[" "] * cols for _ in range(lines)]
    overflow = []
    r = c = 0
    i = 0
    csi = re.compile(r"\x1b\[([?>]?)([0-9;]*)([@-~])")
    while i < len(data):
        ch = data[i]
        if ch == "\x1b":
            m = csi.match(data, i)
            if m:
                priv, args, fin = m.groups()
                i = m.end()
                if not priv and fin in ("H", "f"):
                    parts = [int(p) if p else 1 for p in (args.split(";") if args else [])]
                    r = (parts[0] if len(parts) > 0 else 1) - 1
                    c = (parts[1] if len(parts) > 1 else 1) - 1
                elif not priv and fin == "J" and args in ("2", "3"):
                    grid = [[" "] * cols for _ in range(lines)]
                # SGR, cursor visibility, alternate screen: no effect on cells
                continue
            # other escapes (ESC 7/8, charset): skip the escape and one byte
            i += 2
            continue
        i += 1
        if ch == "\r":
            c = 0
            continue
        if ch == "\n":
            r += 1
            continue
        if ord(ch) < 32:
            continue
        w = width(ch)
        if w == 0:
            continue
        if r < 0 or r >= lines or c < 0 or c + w > cols:
            overflow.append((r, c, ch))
            c += w
            continue
        grid[r][c] = ch
        if w == 2:
            grid[r][c + 1] = WIDE
        c += w
    return grid, overflow


def row_text(row):
    return "".join(x for x in row if x != WIDE)


def main():
    cols, lines, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    grid, overflow = replay(data, cols, lines)
    if mode == "dump":
        for row in grid:
            print(row_text(row))
        return
    print("overflow %d" % len(overflow))
    for o in overflow[:5]:
        print("overflow-at %d %d %r" % o)
    for n in range(lines - 1):  # frame rows: top border .. bottom border
        row = grid[n]
        last = max((k for k, x in enumerate(row) if x not in (" ", WIDE)), default=-1)
        print("end %d %d" % (n, last))
        print("last %d %s" % (n, row[last] if last >= 0 else ""))
        print("first %d %s" % (n, row[0]))

    def col_of(row, glyph):
        for k, x in enumerate(grid[row][1:-1], start=1):
            if x == glyph:
                return k
        return -1

    print("junction %d %d %d %d" % (col_of(0, "┬"), col_of(1, "│"), col_of(2, "┼"), col_of(lines - 2, "┴")))
    print("title %s" % row_text(grid[1]))


if __name__ == "__main__":
    main()
