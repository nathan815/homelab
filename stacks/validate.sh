#!/bin/bash

SCRIPT_DIR=$(dirname "$0")

echo "Validating stacks config..."

set -e

sh $SCRIPT_DIR/nginx-proxy/validate.sh
