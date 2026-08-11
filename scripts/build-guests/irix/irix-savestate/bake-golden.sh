#!/bin/bash
# Compatibility shim (terminology stage 2, 2026-08-12): this script is now
# capture-checkpoint.sh. The shim keeps every muscle-memory invocation and
# in-flight agent brief working for one epoch; stage 5 removes it.
exec "$(dirname "$0")/capture-checkpoint.sh" "$@"
