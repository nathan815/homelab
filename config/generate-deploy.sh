#!/bin/bash
# Wrapper script to generate Kamal deploy.yml
# Usage: ./config/generate-deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Python dependencies..."
pip3 install -q pyyaml 2>/dev/null || true

echo "Generating config/deploy.yml from docker-compose files..."
python3 "$SCRIPT_DIR/generate-deploy.py"

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo ""
    echo "✅ Generation successful!"
    echo ""
    echo "To deploy:"
    echo "  kamal deploy"
    echo ""
    echo "To deploy a specific role:"
    echo "  kamal deploy -r plex"
fi

exit $exit_code
