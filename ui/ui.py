#!/usr/bin/env python3
"""Touchscreen UI for the drone machine.

Runs full screen on the Pi's touchscreen and talks OSC to the engine. Four pages:
  MIX    a fader and mute for each layer
  LAYER  every setting for one layer
  FX     effects, drift, weather and volume
  PLAY   an XY pad (filter / feedback) over a live view of the notes, a root-note
         keyboard, and freeze / hold / mutate / scale / record

    python3 ui.py                         # full screen, engine on this Pi
    python3 ui.py --window 800x480        # in a window, for trying it on a desktop
    python3 ui.py --swap-xy --flip-x      # if touches land in the wrong place
"""
import argparse
import math
import os
import threading
import time

import pygame
from pythonosc.dispatcher import Dispatcher
from pythonosc.osc_server import ThreadingOSCUDPServer
from pythonosc.udp_client import SimpleUDPClient

LAYERS = [
    ("sub", (124, 108, 240)),
    ("pad", (46, 196, 182)),
    ("glass", (142, 202, 230)),
    ("bells", (244, 162, 97)),
    ("texture", (231, 111, 138)),
]
LAYER_COLORS = dict(LAYERS)
LAYER_PARAMS = ["level", "density", "rate", "tone", "space"]
FX_COLUMNS = [
    ["drive", "crush", "filter", "drift", "weather", "volume"],
    ["delay", "time", "feedback", "reverb", "size"],
]
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

BG = (13, 15, 20)
PANEL = (28, 32, 46)
PANEL_HI = (44, 50, 70)
TEXT = (220, 224, 235)
TEXT_DIM = (120, 128, 150)
ACCENT = (240, 240, 255)
FX_COLOR = (170, 180, 210)
RED = (235, 70, 80)


def dim(color, amount=0.35):
    return tuple(int(c * amount) for c in color)


class Engine:
    """OSC link to the engine plus a mirror of its state."""

    def __init__(self, host, port, listen_port):
        self.client = SimpleUDPClient(host, port)
        self.listen_port = listen_port
        self.p, self.eff, self.mute, self.notes = {}, {}, {}, {}
        self.meters = [0.0] * len(LAYERS)
        self.info = {"root": 38, "root_name": "--", "scale_name": "--", "hold": 0, "freeze": 0, "rec": 0}
        self.dragging = set()   # keys being touched right now: ignore echoes for these
        self.last_heard = 0.0

        d = Dispatcher()
        d.map("/state/p", self._on_p)
        d.map("/state/eff", self._on_eff)
        d.map("/state/mute", lambda _, name, v: self.mute.__setitem__(name, bool(v)))
        d.map("/state/meters", self._on_meters)
        d.map("/state/notes", lambda _, name, *notes: self.notes.__setitem__(name, notes))
        d.map("/state/info", self._on_info)
        server = ThreadingOSCUDPServer(("0.0.0.0", listen_port), d)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        threading.Thread(target=self._hello_loop, daemon=True).start()

    def _heard(self):
        self.last_heard = time.time()

    def _on_p(self, _, key, value):
        if key not in self.dragging:
            self.p[key] = value

    def _on_eff(self, _, *pairs):
        self.eff.update(zip(pairs[0::2], pairs[1::2]))

    def _on_meters(self, _, *values):
        self.meters = list(values)
        self._heard()

    def _on_info(self, _, root, root_name, scale, scale_name, hold, freeze, rec):
        self.info = {"root": root, "root_name": root_name, "scale_name": scale_name,
                     "hold": hold, "freeze": freeze, "rec": rec}

    def _hello_loop(self):
        # Keep saying hello so the UI reconnects by itself if the engine restarts.
        while True:
            if not self.connected:
                self.send("/ui/hello", self.listen_port)
            time.sleep(1)

    @property
    def connected(self):
        return time.time() - self.last_heard < 2

    def send(self, address, *args):
        self.client.send_message(address, list(args))

    def set(self, key, value):
        value = min(1.0, max(0.0, value))
        self.p[key] = value
        self.send(f"/p/{key}", value)


# ---------------------------------------------------------------- widgets

class Widget:
    def __init__(self, rect):
        self.rect = pygame.Rect(rect)

    def draw(self, ui):
        pass

    def down(self, ui, pos):
        pass

    def drag(self, ui, pos):
        pass

    def up(self, ui, pos):
        pass


class Slider(Widget):
    def __init__(self, rect, key, label, color, vertical=False):
        super().__init__(rect)
        self.key, self.label, self.color, self.vertical = key, label, color, vertical

    def _value_at(self, pos):
        r = self.rect
        if self.vertical:
            return 1 - (pos[1] - r.y) / r.h
        return (pos[0] - r.x) / r.w

    def down(self, ui, pos):
        ui.engine.dragging.add(self.key)
        ui.engine.set(self.key, self._value_at(pos))

    drag = down

    def up(self, ui, pos):
        ui.engine.dragging.discard(self.key)

    def draw(self, ui):
        r, s = self.rect, ui.screen
        value = ui.engine.p.get(self.key, 0)
        live = ui.engine.eff.get(self.key, value)
        radius = max(4, min(r.w, r.h) // 6)
        pygame.draw.rect(s, PANEL, r, border_radius=radius)
        if self.vertical:
            fill = pygame.Rect(r.x, r.bottom - r.h * value, r.w, r.h * value)
            ghost = r.bottom - r.h * live
            pygame.draw.rect(s, dim(self.color, 0.55), fill, border_radius=radius)
            pygame.draw.line(s, ACCENT, (r.x + 4, ghost), (r.right - 5, ghost), 2)
            ui.text(self.label, r.centerx, r.bottom - ui.small_h, TEXT, ui.font_small, center=True)
        else:
            fill = pygame.Rect(r.x, r.y, r.w * value, r.h)
            ghost = r.x + r.w * live
            pygame.draw.rect(s, dim(self.color, 0.55), fill, border_radius=radius)
            pygame.draw.line(s, ACCENT, (ghost, r.y + 4), (ghost, r.bottom - 5), 2)
            ui.text(self.label, r.x + ui.pad, r.centery, TEXT, ui.font, vcenter=True)
            ui.text(f"{round(value * 100)}", r.right - ui.pad, r.centery, TEXT_DIM, ui.font, right=True, vcenter=True)


class Button(Widget):
    """kind: 'press' fires on touch, 'momentary' is on while touched."""

    def __init__(self, rect, label, color, on_down, on_up=None, is_lit=None, small=False):
        super().__init__(rect)
        self.label, self.color = label, color
        self.on_down, self.on_up, self.is_lit = on_down, on_up, is_lit or (lambda: False)
        self.small = small
        self.pressed = False

    def down(self, ui, pos):
        self.pressed = True
        self.on_down()

    def up(self, ui, pos):
        self.pressed = False
        if self.on_up:
            self.on_up()

    def draw(self, ui):
        lit = self.is_lit() or self.pressed
        label = self.label() if callable(self.label) else self.label
        pygame.draw.rect(ui.screen, self.color if lit else PANEL, self.rect, border_radius=8)
        if not lit:
            pygame.draw.rect(ui.screen, dim(self.color, 0.7), self.rect, width=2, border_radius=8)
        font = ui.font_small if self.small else ui.font
        ui.text(label, self.rect.centerx, self.rect.centery, BG if lit else TEXT, font, center=True, vcenter=True)


class Meter(Widget):
    def __init__(self, rect, index, color):
        super().__init__(rect)
        self.index, self.color = index, color

    def draw(self, ui):
        r = self.rect
        level = min(1.0, ui.engine.meters[self.index] * 3) if self.index < len(ui.engine.meters) else 0
        pygame.draw.rect(ui.screen, PANEL, r, border_radius=3)
        h = r.h * level
        pygame.draw.rect(ui.screen, self.color, (r.x, r.bottom - h, r.w, h), border_radius=3)


class XYPad(Widget):
    """X = filter, Y = feedback, drawn over a live view of every playing note."""

    def __init__(self, rect, x_key="filter", y_key="feedback"):
        super().__init__(rect)
        self.x_key, self.y_key = x_key, y_key
        self.overlay = pygame.Surface(self.rect.size, pygame.SRCALPHA)

    def _set(self, ui, pos):
        r = self.rect
        ui.engine.set(self.x_key, (pos[0] - r.x) / r.w)
        ui.engine.set(self.y_key, 1 - (pos[1] - r.y) / r.h)

    def down(self, ui, pos):
        ui.engine.dragging.update((self.x_key, self.y_key))
        self._set(ui, pos)

    drag = _set

    def up(self, ui, pos):
        ui.engine.dragging.difference_update((self.x_key, self.y_key))

    def draw(self, ui):
        r, e, t = self.rect, ui.engine, time.time()
        pygame.draw.rect(ui.screen, (18, 21, 30), r, border_radius=10)

        # Each playing note is a glowing orb: height = pitch, size = how loud its layer is.
        self.overlay.fill((0, 0, 0, 0))
        for i, (name, color) in enumerate(LAYERS):
            meter = e.meters[i] if i < len(e.meters) else 0
            if e.mute.get(name):
                continue
            notes = e.notes.get(name, ())
            if name == "texture":
                notes = [60 + 24 * math.sin(t * 0.3 + k) for k in range(3)] if meter > 0.005 else []
            for n, pitch in enumerate(notes):
                seed = (hash((name, int(pitch))) % 1000) / 1000
                x = r.w * (0.08 + 0.84 * ((seed + 0.03 * t * (1 + i * 0.2)) % 1))
                y = r.h * (1 - (pitch - 24) / 76)
                size = r.h * (0.012 + min(0.05, meter * 0.25))
                for ring, alpha in ((2.4, 35), (1.5, 70), (0.8, 210)):
                    pygame.draw.circle(self.overlay, (*color, alpha), (x, y), size * ring)
        ui.screen.blit(self.overlay, r.topleft)

        # Crosshair at the set position, small dot where the weather has pushed it.
        x = r.x + r.w * e.p.get(self.x_key, 0)
        y = r.y + r.h * (1 - e.p.get(self.y_key, 0))
        gx = r.x + r.w * e.eff.get(self.x_key, 0)
        gy = r.y + r.h * (1 - e.eff.get(self.y_key, 0))
        pygame.draw.line(ui.screen, (60, 66, 90), (x, r.y), (x, r.bottom))
        pygame.draw.line(ui.screen, (60, 66, 90), (r.x, y), (r.right, y))
        pygame.draw.circle(ui.screen, ACCENT, (x, y), max(8, r.h // 18), 2)
        pygame.draw.circle(ui.screen, ACCENT, (gx, gy), 3)
        ui.text(f"x: {self.x_key}", r.right - ui.pad, r.bottom - ui.pad, TEXT_DIM, ui.font_small, right=True, bottom=True)
        ui.text(f"y: {self.y_key}", r.x + ui.pad, r.y + ui.pad, TEXT_DIM, ui.font_small)


# ---------------------------------------------------------------- app

class UI:
    PAGES = ["MIX", "LAYER", "FX", "PLAY"]

    def __init__(self, screen, engine, touch_transform=None):
        self.screen, self.engine = screen, engine
        self.touch_transform = touch_transform or (lambda pos: pos)
        self.W, self.H = screen.get_size()
        self.pad = max(4, int(min(self.W, self.H) * 0.015))
        self.font = pygame.font.Font(None, max(18, int(self.H * 0.065)))
        self.font_small = pygame.font.Font(None, max(15, int(self.H * 0.05)))
        self.small_h = self.font_small.get_height()
        self.page = "PLAY"
        self.layer = "pad"
        self.captured = None
        self.build()

    def text(self, s, x, y, color, font, center=False, right=False, vcenter=False, bottom=False):
        img = font.render(str(s), True, color)
        rect = img.get_rect()
        rect.x = x - rect.w // 2 if center else x - rect.w if right else x
        rect.y = y - rect.h // 2 if vcenter else y - rect.h if bottom else y
        self.screen.blit(img, rect)

    def goto(self, page, layer=None):
        self.page = page
        if layer:
            self.layer = layer
        self.build()

    # Layouts are computed from the screen size, so any resolution works.
    def build(self):
        W, H, p = self.W, self.H, self.pad
        tab_h = max(36, int(H * 0.14))
        self.area = pygame.Rect(p, p, W - 2 * p, H - tab_h - 2 * p)
        self.widgets = self._tabs(tab_h) + getattr(self, "_page_" + self.page.lower())(self.area)

    def _tabs(self, tab_h):
        W, H, p = self.W, self.H, self.pad
        tab_w = int(W * 0.6 / len(self.PAGES))
        tabs = []
        for i, name in enumerate(self.PAGES):
            rect = (p + i * tab_w, H - tab_h, tab_w - p, tab_h - p)
            tabs.append(Button(rect, name, ACCENT, lambda n=name: self.goto(n), is_lit=lambda n=name: self.page == n))
        self.status_rect = pygame.Rect(p + len(self.PAGES) * tab_w, H - tab_h, W - 2 * p - len(self.PAGES) * tab_w, tab_h - p)
        return tabs

    def _page_mix(self, a):
        p, col_w = self.pad, a.w / len(LAYERS)
        head_h, foot_h = int(a.h * 0.16), int(a.h * 0.15)
        widgets = []
        for i, (name, color) in enumerate(LAYERS):
            x = int(a.x + i * col_w)
            w = int(col_w - p)
            widgets.append(Button((x, a.y, w, head_h), name, color,
                                  lambda n=name: self.goto("LAYER", n), small=True))
            body = pygame.Rect(x, a.y + head_h + p, w, a.h - head_h - foot_h - 2 * p)
            meter_w = max(6, w // 7)
            widgets.append(Slider((body.x, body.y, body.w - meter_w - p, body.h), f"{name}_level", "", color, vertical=True))
            widgets.append(Meter((body.right - meter_w, body.y, meter_w, body.h), i, color))
            widgets.append(Button((x, a.bottom - foot_h, w, foot_h), "mute", RED,
                                  lambda n=name: self.engine.send("/mute", n, int(not self.engine.mute.get(n))),
                                  is_lit=lambda n=name: self.engine.mute.get(n, False), small=True))
        return widgets

    def _page_layer(self, a):
        p = self.pad
        head_h = int(a.h * 0.16)
        cells = len(LAYERS) + 1
        cell_w = a.w / cells
        widgets = []
        for i, (name, color) in enumerate(LAYERS):
            widgets.append(Button((int(a.x + i * cell_w), a.y, int(cell_w - p), head_h), name, color,
                                  lambda n=name: self.goto("LAYER", n),
                                  is_lit=lambda n=name: self.layer == n, small=True))
        widgets.append(Button((int(a.x + len(LAYERS) * cell_w), a.y, int(cell_w - p), head_h), "mute", RED,
                              lambda: self.engine.send("/mute", self.layer, int(not self.engine.mute.get(self.layer))),
                              is_lit=lambda: self.engine.mute.get(self.layer, False), small=True))
        color = LAYER_COLORS[self.layer]
        row_h = (a.h - head_h - p) / len(LAYER_PARAMS)
        for i, param in enumerate(LAYER_PARAMS):
            y = int(a.y + head_h + p + i * row_h)
            widgets.append(Slider((a.x, y, a.w, int(row_h - p)), f"{self.layer}_{param}", param, color))
        return widgets

    def _page_fx(self, a):
        p = self.pad
        col_w = a.w / len(FX_COLUMNS)
        rows = max(len(c) for c in FX_COLUMNS)
        row_h = a.h / rows
        widgets = []
        for c, column in enumerate(FX_COLUMNS):
            for r, key in enumerate(column):
                rect = (int(a.x + c * col_w), int(a.y + r * row_h), int(col_w - p), int(row_h - p))
                widgets.append(Slider(rect, key, key, FX_COLOR))
        return widgets

    def _page_play(self, a):
        p, e = self.pad, self.engine
        left_w = int(a.w * 0.68)
        keys_h = int(a.h * 0.17)
        widgets = [XYPad((a.x, a.y, left_w, a.h - keys_h - p))]
        key_w = left_w / 12
        for i, name in enumerate(NOTE_NAMES):
            color = (90, 96, 120) if "#" in name else (200, 205, 220)
            widgets.append(Button((int(a.x + i * key_w), a.bottom - keys_h, int(key_w - 2), keys_h), name, color,
                                  lambda i=i: e.send("/root", 36 + i),
                                  is_lit=lambda i=i: e.info["root"] % 12 == i, small=True))
        bx, bw = a.x + left_w + p, a.w - left_w - p
        bh = a.h / 5
        buttons = [
            ("FREEZE", (120, 200, 255), lambda: e.send("/freeze", 1), lambda: e.send("/freeze", 0), lambda: e.info["freeze"]),
            ("HOLD", (180, 160, 255), lambda: e.send("/hold", int(not e.info["hold"])), None, lambda: e.info["hold"]),
            ("MUTATE", (46, 196, 182), lambda: e.send("/mutate", 1), None, None),
            (lambda: e.info["scale_name"], (244, 162, 97), lambda: e.send("/scale/next", 1), None, None),
            ("REC", RED, lambda: e.send("/record", int(not e.info["rec"])), None, lambda: e.info["rec"]),
        ]
        for i, (label, color, on_down, on_up, lit) in enumerate(buttons):
            widgets.append(Button((bx, int(a.y + i * bh), bw, int(bh - p)), label, color, on_down, on_up, lit))
        return widgets

    # ---------------------------------------------------------------- loop

    def draw(self):
        self.screen.fill(BG)
        for w in self.widgets:
            w.draw(self)
        r, e = self.status_rect, self.engine
        if e.connected:
            status = f"{e.info['root_name']}  {e.info['scale_name']}"
            self.text(status, r.right - self.pad, r.centery, TEXT, self.font, right=True, vcenter=True)
            if e.info["rec"] and int(time.time() * 2) % 2:
                pygame.draw.circle(self.screen, RED, (r.x + r.h // 2, r.centery), r.h // 5)
        else:
            self.text("waiting for engine...", r.right - self.pad, r.centery, RED, self.font_small, right=True, vcenter=True)

    def handle(self, event):
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            pos = self.touch_transform(event.pos)
            for w in reversed(self.widgets):
                if w.rect.collidepoint(pos):
                    self.captured = w
                    w.down(self, pos)
                    break
        elif event.type == pygame.MOUSEMOTION and self.captured:
            self.captured.drag(self, self._clamp(self.touch_transform(event.pos)))
        elif event.type == pygame.MOUSEBUTTONUP and event.button == 1 and self.captured:
            self.captured.up(self, self._clamp(self.touch_transform(event.pos)))
            self.captured = None

    def _clamp(self, pos):
        r = self.captured.rect
        return min(max(pos[0], r.x), r.right), min(max(pos[1], r.y), r.bottom)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", default="127.0.0.1", help="host running the engine")
    parser.add_argument("--port", type=int, default=57120, help="engine OSC port")
    parser.add_argument("--listen", type=int, default=57130, help="port this UI listens on for engine state")
    parser.add_argument("--window", metavar="WxH", help="run in a window instead of full screen, e.g. 800x480")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--swap-xy", action="store_true", help="touch axes are swapped (rotated screen)")
    parser.add_argument("--flip-x", action="store_true", help="touch is mirrored left/right")
    parser.add_argument("--flip-y", action="store_true", help="touch is mirrored top/bottom")
    args = parser.parse_args()

    pygame.display.init()   # not pygame.init(): that would also open the sound card
    pygame.font.init()
    if args.window:
        w, h = (int(v) for v in args.window.lower().split("x"))
        screen = pygame.display.set_mode((w, h))
    else:
        screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
        pygame.mouse.set_visible(False)
    pygame.display.set_caption("Drone Machine")
    W, H = screen.get_size()

    def transform(pos):
        x, y = pos
        if args.swap_xy:
            x, y = y * W / H, x * H / W
        if args.flip_x:
            x = W - 1 - x
        if args.flip_y:
            y = H - 1 - y
        return int(x), int(y)

    engine = Engine(args.engine, args.port, args.listen)
    ui = UI(screen, engine, transform)
    clock = pygame.time.Clock()
    while True:
        for event in pygame.event.get():
            if event.type == pygame.QUIT or (event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE):
                pygame.quit()
                return
            if event.type == pygame.KEYDOWN and event.key == pygame.K_s:
                pygame.image.save(screen, os.path.expanduser(f"~/drone-ui-{ui.page.lower()}.png"))
            ui.handle(event)
        ui.draw()
        pygame.display.flip()
        clock.tick(args.fps)


if __name__ == "__main__":
    main()
