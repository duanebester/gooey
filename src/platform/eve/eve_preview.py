#!/usr/bin/env python3
"""Render a Gooey EVE dump to PNG, for checking display lists without hardware.

Build an app with `-Dlinux-backend=eve`, run it on the simulated chip, and
render its last frame:

    GOOEY_EVE_SIMULATE=/tmp/eve.bin ./counter  # writes RAM_G + RAM_DL per swap
    python3 src/platform/eve/eve_preview.py /tmp/eve.bin out.png [--stats]

This models the BT81x commands Gooey's EVE renderer emits (RECTS, LINE_STRIP,
POINTS, L8/RGB565/ARGB4 BITMAPS with BITMAP_TRANSFORM_A/E scaling and
NEAREST/BILINEAR filtering, scissor, stencil, color mask) from the BT81x
Programming Guide. It is an approximation: antialiasing and rounding differ
from the chip, and it shares the renderer's reading of the guide, so it cannot
catch a misreading of the guide. The panel is the final check.
Needs numpy and Pillow.
"""

import struct
import sys

import numpy as np
from PIL import Image

RAM_G_SIZE = 1024 * 1024
RAM_DL_SIZE = 8192
WIDTH, HEIGHT = 1024, 600

L8, RGB565, ARGB4 = 3, 7, 6
BITMAPS, POINTS, LINES, LINE_STRIP, RECTS = 1, 2, 3, 4, 9
NAMES = {0: "DISPLAY", 1: "BITMAP_SOURCE", 2: "CLEAR_COLOR_RGB", 4: "COLOR_RGB",
         5: "BITMAP_HANDLE", 7: "BITMAP_LAYOUT", 8: "BITMAP_SIZE", 10: "STENCIL_FUNC",
         12: "STENCIL_OP", 13: "POINT_SIZE", 14: "LINE_WIDTH", 16: "COLOR_A", 27: "SCISSOR_XY",
         28: "SCISSOR_SIZE", 31: "BEGIN",
         32: "COLOR_MASK", 33: "END", 38: "CLEAR", 39: "VERTEX_FORMAT", 40: "BITMAP_LAYOUT_H",
         41: "BITMAP_SIZE_H", 43: "VERTEX_TRANSLATE_X", 44: "VERTEX_TRANSLATE_Y",
         21: "BITMAP_TRANSFORM_A", 25: "BITMAP_TRANSFORM_E"}


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class Handle:
    def __init__(self):
        self.source = 0
        self.format = L8
        self.stride = 0
        self.layout_height = 0
        self.width = 0
        self.height = 0
        self.bilinear = False


class Renderer:
    def __init__(self, ram_g):
        self.ram_g = ram_g
        self.rgb = np.zeros((HEIGHT, WIDTH, 3), np.float32)
        self.stencil = np.zeros((HEIGHT, WIDTH), np.uint8)
        self.handles = [Handle() for _ in range(32)]
        self.clear_rgb = (0, 0, 0)
        self.color = (255, 255, 255)
        self.alpha = 255
        self.line_width = 16
        self.point_size = 16
        self.frac = 4
        self.translate = [0.0, 0.0]
        # BITMAP_TRANSFORM_A and _E: texels per pixel.
        self.transform = [1.0, 1.0]
        self.scissor = (0, 0, 2048, 2048)
        self.handle = 0
        self.cell = 0
        self.mask = True
        self.stencil_func = (7, 0, 255)
        self.stencil_op = (1, 1)
        self.primitive = None
        self.pending = []
        self.counts = {}

    # -- coverage helpers -------------------------------------------------
    def box(self, x0, y0, x1, y1):
        sx, sy, sw, sh = self.scissor
        left = max(int(np.floor(x0)), sx, 0)
        top = max(int(np.floor(y0)), sy, 0)
        right = min(int(np.ceil(x1)), sx + sw, WIDTH)
        bottom = min(int(np.ceil(y1)), sy + sh, HEIGHT)
        if right <= left or bottom <= top:
            return None
        ys, xs = np.mgrid[top:bottom, left:right].astype(np.float32)
        return (top, bottom, left, right, xs + 0.5, ys + 0.5)

    def blend(self, region, coverage, rgb):
        top, bottom, left, right = region[:4]
        alpha = coverage * (self.alpha / 255.0)
        stencil = self.stencil[top:bottom, left:right]
        func, ref, smask = self.stencil_func
        a, b = ref & smask, stencil & smask
        passes = {0: np.zeros_like(b, bool), 1: a < b, 2: a <= b, 3: a > b, 4: a >= b,
                  5: a == b, 6: a != b, 7: np.ones_like(b, bool)}[func]
        drawn = coverage > 0
        fail_op, pass_op = self.stencil_op
        for which, op in ((passes & drawn, pass_op), (~passes & drawn, fail_op)):
            if op == 0:
                stencil[which] = 0
            elif op == 2:
                stencil[which] = ref
            elif op == 3:
                stencil[which] = np.minimum(stencil[which].astype(int) + 1, 255)
            elif op == 4:
                stencil[which] = np.maximum(stencil[which].astype(int) - 1, 0)
            elif op == 5:
                stencil[which] = ~stencil[which]
        if not self.mask:
            return
        alpha = np.where(passes, alpha, 0)[..., None]
        target = self.rgb[top:bottom, left:right]
        target[:] = rgb * alpha + target * (1 - alpha)

    def color_array(self):
        return np.array(self.color, np.float32)

    # -- primitives --------------------------------------------------------
    def rect(self, a, b):
        r = self.line_width / 16.0
        x0, x1 = sorted((a[0], b[0]))
        y0, y1 = sorted((a[1], b[1]))
        region = self.box(x0 - r - 1, y0 - r - 1, x1 + r + 1, y1 + r + 1)
        if region is None:
            return
        xs, ys = region[4], region[5]
        cx, cy, hx, hy = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
        dx = np.maximum(np.abs(xs - cx) - hx, 0)
        dy = np.maximum(np.abs(ys - cy) - hy, 0)
        sdf = np.sqrt(dx * dx + dy * dy) - r
        self.blend(region, np.clip(0.5 - sdf, 0, 1), self.color_array())

    def segment(self, a, b):
        r = max(self.line_width / 16.0, 0.5)
        region = self.box(min(a[0], b[0]) - r - 1, min(a[1], b[1]) - r - 1,
                          max(a[0], b[0]) + r + 1, max(a[1], b[1]) + r + 1)
        if region is None:
            return
        xs, ys = region[4], region[5]
        vx, vy = b[0] - a[0], b[1] - a[1]
        length2 = vx * vx + vy * vy or 1e-9
        t = np.clip(((xs - a[0]) * vx + (ys - a[1]) * vy) / length2, 0, 1)
        sdf = np.hypot(xs - (a[0] + t * vx), ys - (a[1] + t * vy)) - r
        self.blend(region, np.clip(0.5 - sdf, 0, 1), self.color_array())

    def point(self, p):
        r = self.point_size / 16.0
        region = self.box(p[0] - r - 1, p[1] - r - 1, p[0] + r + 1, p[1] + r + 1)
        if region is None:
            return
        sdf = np.hypot(region[4] - p[0], region[5] - p[1]) - r
        self.blend(region, np.clip(0.5 - sdf, 0, 1), self.color_array())

    def bitmap(self, p, handle_index, cell):
        h = self.handles[handle_index]
        x, y = int(round(p[0])), int(round(p[1]))
        region = self.box(x, y, x + h.width, y + h.height)
        if region is None or h.stride == 0:
            return
        top, bottom, left, right = region[:4]
        # Texel coordinates of each pixel centre under the transform.
        u = (np.arange(left, right) - x + 0.5) * self.transform[0]
        v = (np.arange(top, bottom) - y + 0.5) * self.transform[1]
        if h.bilinear:
            u0, v0 = np.floor(u - 0.5), np.floor(v - 0.5)
            fu, fv = (u - 0.5 - u0)[None, :, None], (v - 0.5 - v0)[:, None, None]
            corners = [self.texels(h, cell, v0 + dy, u0 + dx) for dy in (0, 1) for dx in (0, 1)]
            top_row = corners[0] * (1 - fu) + corners[1] * fu
            low_row = corners[2] * (1 - fu) + corners[3] * fu
            rgba = top_row * (1 - fv) + low_row * fv
        else:
            rgba = self.texels(h, cell, np.floor(v), np.floor(u))
        rgb = rgba[..., :3] if h.format != L8 else self.color_array()
        if h.format != L8:
            rgb = rgb * self.color_array() / 255
        self.blend(region, rgba[..., 3], rgb)

    def texels(self, h, cell, ty, tx):
        """RGBA of texel rows `ty` by columns `tx`: rgb 0..255, alpha 0..1;
        texels outside the bitmap are transparent (BORDER)."""
        ty = ty.astype(np.int64)[:, None]
        tx = tx.astype(np.int64)[None, :]
        bpp = {L8: 1, RGB565: 2, ARGB4: 2}[h.format]
        valid = (ty >= 0) & (tx >= 0) & (ty < h.layout_height) & (tx * bpp < h.stride)
        base = h.source + cell * h.stride * h.layout_height
        offsets = base + ty * h.stride + tx * bpp
        offsets = np.clip(np.where(valid, offsets, 0), 0, RAM_G_SIZE - bpp)
        out = np.zeros(valid.shape + (4,), np.float32)
        if h.format == L8:
            out[..., 3] = np.where(valid, self.ram_g[offsets] / 255.0, 0)
            return out
        low = self.ram_g[offsets].astype(np.uint32)
        value = low | (self.ram_g[offsets + 1].astype(np.uint32) << 8)
        if h.format == RGB565:
            rgb = np.stack([(value >> 11) * 255 / 31, ((value >> 5) & 63) * 255 / 63,
                            (value & 31) * 255 / 31], -1)
            alpha = valid.astype(np.float32)
        else:
            rgb = np.stack([((value >> 8) & 15) * 17, ((value >> 4) & 15) * 17,
                            (value & 15) * 17], -1)
            alpha = np.where(valid, (value >> 12) * 17 / 255.0, 0)
        out[..., :3] = rgb
        out[..., 3] = alpha
        return out

    # -- command decoding --------------------------------------------------
    def vertex(self, point, handle=None, cell=None):
        prim = self.primitive
        if prim == BITMAPS:
            handle = self.handle if handle is None else handle
            self.bitmap(point, handle, self.cell if cell is None else cell)
        elif prim == POINTS:
            self.point(point)
        elif prim == RECTS:
            self.pending.append(point)
            if len(self.pending) == 2:
                self.rect(*self.pending)
                self.pending = []
        elif prim == LINES:
            self.pending.append(point)
            if len(self.pending) == 2:
                self.segment(*self.pending)
                self.pending = []
        elif prim == LINE_STRIP:
            if self.pending:
                self.segment(self.pending[-1], point)
            self.pending = [point]

    def run(self, words):
        for word in words:
            if word >> 30 == 1:
                scale = 1 << self.frac
                self.vertex((signed((word >> 15) & 0x7FFF, 15) / scale + self.translate[0],
                             signed(word & 0x7FFF, 15) / scale + self.translate[1]))
                continue
            if word >> 30 == 2:
                x = ((word >> 21) & 511) + self.translate[0]
                y = ((word >> 12) & 511) + self.translate[1]
                self.vertex((x, y), (word >> 7) & 31, word & 127)
                continue
            op = word >> 24
            self.counts[NAMES.get(op, op)] = self.counts.get(NAMES.get(op, op), 0) + 1
            h = self.handles[self.handle]
            if op == 0:
                return
            elif op == 1:
                h.source = word & 0xFFFFFF
            elif op == 2:
                self.clear_rgb = ((word >> 16) & 255, (word >> 8) & 255, word & 255)
            elif op == 4:
                self.color = ((word >> 16) & 255, (word >> 8) & 255, word & 255)
            elif op == 5:
                self.handle = word & 31
            elif op == 6:
                self.cell = word & 127
            elif op == 7:
                h.format = (word >> 19) & 31
                h.stride = (h.stride & ~1023) | ((word >> 9) & 1023)
                h.layout_height = (h.layout_height & ~511) | (word & 511)
            elif op == 8:
                h.bilinear = bool(word & (1 << 20))
                h.width = (h.width & ~511) | ((word >> 9) & 511)
                h.height = (h.height & ~511) | (word & 511)
            elif op == 10:
                self.stencil_func = ((word >> 16) & 15, (word >> 8) & 255, word & 255)
            elif op == 12:
                self.stencil_op = ((word >> 3) & 7, word & 7)
            elif op == 13:
                self.point_size = word & 0x1FFF
            elif op == 14:
                self.line_width = word & 0xFFF
            elif op == 16:
                self.alpha = word & 255
            elif op == 27:
                self.scissor = ((word >> 11) & 2047, word & 2047, self.scissor[2], self.scissor[3])
            elif op == 28:
                self.scissor = (self.scissor[0], self.scissor[1], (word >> 12) & 4095, word & 4095)
            elif op == 31:
                self.primitive = word & 15
                self.pending = []
            elif op == 32:
                self.mask = bool(word & 0xE)
            elif op == 33:
                self.primitive = None
                self.pending = []
            elif op == 38:
                region = self.box(0, 0, WIDTH, HEIGHT)
                if region and word & 4:
                    self.rgb[region[0]:region[1], region[2]:region[3]] = self.clear_rgb
                if region and word & 2:
                    self.stencil[region[0]:region[1], region[2]:region[3]] = 0
            elif op == 39:
                self.frac = word & 7
            elif op in (21, 25):
                # 8.8 fixed point unless bit 17 selects 1.15.
                scale = 1 << 15 if word & (1 << 17) else 256
                self.transform[0 if op == 21 else 1] = signed(word & 0x1FFFF, 17) / scale
            elif op in (43, 44):
                self.translate[op - 43] = signed(word & 0x1FFFF, 17) / 16.0
            elif op == 40:
                h.stride = (h.stride & 1023) | (((word >> 2) & 3) << 10)
                h.layout_height = (h.layout_height & 511) | ((word & 3) << 9)
            elif op == 41:
                h.width = (h.width & 511) | (((word >> 2) & 3) << 9)
                h.height = (h.height & 511) | ((word & 3) << 9)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    data = open(argv[1], "rb").read()
    if len(data) != RAM_G_SIZE + RAM_DL_SIZE:
        print("expected %d bytes (RAM_G + RAM_DL), got %d" % (RAM_G_SIZE + RAM_DL_SIZE, len(data)))
        return 1
    ram_g = np.frombuffer(data[:RAM_G_SIZE], np.uint8)
    words = struct.unpack("<2048I", data[RAM_G_SIZE:])
    length = next((i + 1 for i, w in enumerate(words) if w == 0), 2048)
    renderer = Renderer(ram_g)
    renderer.run(words)
    Image.fromarray(np.clip(renderer.rgb, 0, 255).astype(np.uint8)).save(argv[2])
    if "--stats" in argv:
        print("display list: %d of 2048 words" % length)
        for name, count in sorted(renderer.counts.items(), key=lambda kv: -kv[1]):
            print("  %-16s %d" % (name, count))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
