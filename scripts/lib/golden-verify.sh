#!/bin/bash
# Compatibility shim (terminology stage 2, 2026-08-12): this script is now
# checkpoint-verify.sh (and --bake is spelled --capture there; both accepted).
# The shim keeps every existing invocation working for one epoch; stage 5
# removes it.
exec "$(dirname "$0")/checkpoint-verify.sh" "$@"
