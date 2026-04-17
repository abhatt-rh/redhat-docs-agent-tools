#!/bin/bash
# SCRIPT_MARKER_E5F6
set -euo pipefail
echo "Building RHIVOS image..."
aib build manifest.yml rhivos-image
