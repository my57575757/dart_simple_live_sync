import struct
import zlib

S = 512
O = 2

PURPLE = (0x91, 0x46, 0xFF)
WHITE = (255, 255, 255)

buf = bytearray(S * S * 4)


def put(x, y, c, a):
    if x < 0 or x >= S or y < 0 or y >= S:
        return
    i = (y * S + x) * 4
    ia = a / 255.0
    buf[i] = int(c[0] * ia + buf[i] * (1 - ia))
    buf[i + 1] = int(c[1] * ia + buf[i + 1] * (1 - ia))
    buf[i + 2] = int(c[2] * ia + buf[i + 2] * (1 - ia))
    buf[i + 3] = max(buf[i + 3], a)


def rounded_rect(x0, y0, x1, y1, r, c, a=255):
    for y in range(y0, y1):
        for x in range(x0, x1):
            cx = cy = 0
            if x < x0 + r and y < y0 + r:
                cx, cy = x0 + r, y0 + r
            elif x >= x1 - r and y < y0 + r:
                cx, cy = x1 - r - 1, y0 + r
            elif x < x0 + r and y >= y1 - r:
                cx, cy = x0 + r, y1 - r - 1
            elif x >= x1 - r and y >= y1 - r:
                cx, cy = x1 - r - 1, y1 - r - 1
            else:
                put(x, y, c, a)
                continue
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                put(x, y, c, a)


def polygon(pts, c, a=255):
    ys = [p[1] for p in pts]
    y0, y1 = min(ys), max(ys) + 1
    n = len(pts)
    for y in range(y0, y1):
        xs = []
        for i in range(n):
            ax, ay = pts[i]
            bx, by_ = pts[(i + 1) % n]
            if ay == by_:
                continue
            if min(ay, by_) <= y < max(ay, by_):
                xs.append(ax + (y - ay) * (bx - ax) / (by_ - ay))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            for x in range(int(xs[i]), int(xs[i + 1]) + 1):
                put(x, y, c, a)


# 紫色圆角底
rounded_rect(32, 32, S - 32, S - 32, 96, PURPLE)

# 白色气泡主体
rounded_rect(112, 112, 400, 352, 24, WHITE)
# 左下尾巴
polygon([(160, 352), (240, 352), (160, 432)], WHITE)

# 两只紫色眼睛
rounded_rect(192, 176, 224, 288, 16, PURPLE)
rounded_rect(288, 176, 320, 288, 16, PURPLE)

# 降采样到 256
N = S // O
out = bytearray(N * N * 4)
for y in range(N):
    for x in range(N):
        r = g = b = a = 0
        for dy in range(O):
            for dx in range(O):
                i = ((y * O + dy) * S + x * O + dx) * 4
                r += buf[i]
                g += buf[i + 1]
                b += buf[i + 2]
                a += buf[i + 3]
        j = (y * N + x) * 4
        n = O * O
        out[j] = r // n
        out[j + 1] = g // n
        out[j + 2] = b // n
        out[j + 3] = a // n

raw = bytearray()
for y in range(N):
    raw.append(0)
    raw.extend(out[y * N * 4:(y + 1) * N * 4])


def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")

import sys

for path in sys.argv[1:]:
    with open(path, "wb") as f:
        f.write(png)
    print("wrote", path)
