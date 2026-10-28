#!/bin/bash
# Initialize persistent data directories for services
# Runtime data lives under $APPDATA_DIR/<stack> (default /opt/appdata), outside
# the stack folders, so the stack folder can be replaced or re-cloned (issue #9).
# Moving existing ./data into it: docs/appdata-migration.md

set -e

APPDATA_DIR="${APPDATA_DIR:-/opt/appdata}"
CREATED=0

echo "Initializing data directories in $APPDATA_DIR..."

# Create directories as needed
declare -a DIRS=(
    "adguardhome/work"
    "adguardhome/config"
    "container-mgmt/dockge"
)

for dir in "${DIRS[@]}"; do
    full_path="$APPDATA_DIR/$dir"
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
