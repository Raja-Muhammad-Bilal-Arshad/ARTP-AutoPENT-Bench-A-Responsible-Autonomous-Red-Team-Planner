#!/usr/bin/env bash
# launcher that forwards args to harness/harness.py
python3 "$(dirname "$0")/harness/harness.py" "$@"
