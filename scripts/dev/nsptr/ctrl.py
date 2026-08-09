#!/usr/bin/env python3
"""The closed-loop pointer controller (PoC).

MEASURED plant (all numbers from this tile, framebuffer-checked):
  * one injected relative event produces ONE atomic cursor jump, 10-22 ms later;
  * the axes are independent, and one event carries both;
  * in the warm state a controller operates in, displacement = 10 * d for
    d >= 5, saturating at 630 px (the NeXT KMS delta register is 6-bit signed);
  * below that the plant is quantised hard: d = 1 -> 0 px, 2 -> 2 px,
    3 -> 12 px, 4 -> ~26 px. There is nothing between 2 px and 12 px, so the
    last mile is walked in 2 px steps;
  * gain is history dependent (a cold plant gives ~17.5 on its first event),
    which is exactly why this is a closed loop: the gain is re-estimated from
    the displacement each step actually produced.
"""
import time

PRED0 = {2: 2.0, 3: 12.0, 4: 26.0}
MAXSTEP_DEFAULT = 10
DMAX = 63


class Loop:
    def __init__(self, qmp, agent, tol=1, max_steps=10, cap_ms=40.0, confirm_ms=3.0):
        self.q = qmp
        self.a = agent
        self.tol = tol
        self.max_steps = max_steps
        self.cap = cap_ms / 1000.0
        self.confirm = confirm_ms / 1000.0
        self.pred = dict(PRED0)
        self.g = 10.0

    def disp(self, d):
        return self.pred[d] if d in self.pred else self.g * d

    def pick(self, err, pos=None, lim=None):
        ae = abs(err)
        s = 1 if err > 0 else -1
        best, bestcost = 0, ae
        for d in list(self.pred) + list(range(5, DMAX + 1)):
            land = self.disp(d)
            if pos is not None and not (0 <= pos + s * land <= lim):
                continue  # never command a step that would slam an edge
            c = abs(ae - land)
            if c < bestcost - 1e-9:
                best, bestcost = d, c
        return s * best

    def settle(self, p0):
        """One event makes one atomic jump: wait for it, then confirm briefly."""
        t0 = time.perf_counter()
        last = p0
        while True:
            p = self.a.pos()
            now = time.perf_counter()
            if p != last:
                last = p
                tc = time.perf_counter()
                while time.perf_counter() - tc < self.confirm:
                    p2 = self.a.pos()
                    if p2 != last:
                        last, tc = p2, time.perf_counter()
                return last
            if now - t0 >= self.cap:
                return last

    def learn(self, d, moved, clamped):
        # The sub-5 rungs are FIXED. They are quantised plant constants
        # (2 / 12 / 26 px), and adapting them on +-3 px of measurement noise
        # made the loop chase its own estimate instead of the target.
        # A clamped axis moved less than the plant would have moved it. Learning
        # from that poisons the gain for every later step -- the failure that
        # put two edge targets 98 and 402 px out in the first sweep.
        if clamped:
            return
        ad, am = abs(d), abs(moved)
        if ad not in self.pred and am:
            self.g = 0.5 * self.g + 0.5 * (am / ad)

    def goto(self, tx, ty, budget_ms=250.0):
        t0 = time.perf_counter()
        p = self.a.pos()
        trace = [p]
        for _ in range(self.max_steps):
            ex, ey = tx - p[0], ty - p[1]
            if abs(ex) <= self.tol and abs(ey) <= self.tol:
                break
            if (time.perf_counter() - t0) * 1000 > budget_ms - 40:
                break
            dx = self.pick(ex, p[0], 1119) if abs(ex) > self.tol else 0
            dy = self.pick(ey, p[1], 831) if abs(ey) > self.tol else 0
            if dx == 0 and dy == 0:
                break
            self.q.rel(dx, dy)
            n = self.settle(p)
            if dx:
                self.learn(dx, n[0] - p[0], n[0] in (0, 1119))
            if dy:
                self.learn(dy, n[1] - p[1], n[1] in (0, 831))
            p = n
            trace.append(p)
        # A jump can still be in flight when the loop exits, and a stale exit
        # read is indistinguishable from success. Confirm, and if it moved,
        # spend one more correction on it.
        time.sleep(0.014)
        p = self.a.pos()
        if p != trace[-1]:
            trace.append(p)
            ex, ey = tx - p[0], ty - p[1]
            if abs(ex) > self.tol or abs(ey) > self.tol:
                dx = self.pick(ex, p[0], 1119) if abs(ex) > self.tol else 0
                dy = self.pick(ey, p[1], 831) if abs(ey) > self.tol else 0
                if dx or dy:
                    self.q.rel(dx, dy)
                    p = self.settle(p)
                    trace.append(p)
        return p, trace, (time.perf_counter() - t0) * 1000
