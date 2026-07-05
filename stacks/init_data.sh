#!/bin/bash
# Initialize persistent data directories for services
# This creates the mount points that docker-compose volumes bind to
# Prevents permission issues and ensures data survives container restarts

set -e

STACKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATED=0

echo "Initializing data directories..."

# Create directories as needed
declare -a DIRS=(
    "adguardhome/data/work"
    "adguardhome/data/config"
    "dockge/data"
)

for dir in "${DIRS[@]}"; do
    full_path="$STACKS_DIR/$dir"
    if [ ! -d "$full_path" ]; then
        mkdir -p "$full_path"
        echo "✓ Created $dir"
        ((CREATED++))
    fi
done

if [ $CREATED -eq 0 ]; then
    echo "ℹ All data directories already exist"
else
    echo "✓ Created $CREATED directories"
fi

echo ""
echo "Data directories initialized. Ready to deploy services."
