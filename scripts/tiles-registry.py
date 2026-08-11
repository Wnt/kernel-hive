#!/usr/bin/env python3
"""Compatibility shim (terminology stage 2, 2026-08-12).

This generator is now ``scripts/stations-registry.py``. The shim keeps
existing invocations and in-flight agent briefs working for one epoch;
stage 5 removes it.
"""

import os
import sys

os.execv(
    sys.executable,
    [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "stations-registry.py")] + sys.argv[1:],
)
