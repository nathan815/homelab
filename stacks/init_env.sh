#!/bin/bash
# Generate .env files from templates for all stacks
# This script copies .env.defaults or .env.example to .env (git-ignored)
# You should then edit each .env file to add actual secrets/passwords

set -e

STACKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUND=0

echo "Initializing environment files..."

# Look for .env.defaults first, then .env.example
for template in $(find "$STACKS_DIR" -maxdepth 2 \( -name ".env.defaults" -o -name ".env.example" \)); do
    stack_dir=$(dirname "$template")
    stack_name=$(basename "$stack_dir")
    env_file="$stack_dir/.env"

    if [ ! -f "$env_file" ]; then
        cp "$template" "$env_file"
        chmod 600 "$env_file"
        echo "✓ Created $stack_name/.env"
        ((FOUND++))
    fi
done

if [ $FOUND -eq 0 ]; then
    echo "ℹ No .env files needed (no templates found)"
else
    echo "✓ Created $FOUND .env files"
    echo ""
    echo "⚠ Next steps:"
    echo "  1. Edit each .env file to add secrets/passwords"
    echo "  2. Run: ./init_data.sh"
    echo "  3. Deploy services: cd SERVICE && docker-compose up -d"
fi
