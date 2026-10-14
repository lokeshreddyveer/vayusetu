#!/bin/bash
set -euo pipefail
exec /usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/renew_ios.py" "$@"
