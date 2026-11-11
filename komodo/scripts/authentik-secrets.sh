#!/bin/sh
# Generate the Komodo secret variables for the authentik stack and print them to
# stdout only (nothing is written to disk). Paste them into Komodo
# (Settings -> Variables), marking each as secret. Generate once: changing
# AUTHENTIK_SECRET_KEY later invalidates sessions and stored secrets, and the
# Postgres password only applies on first start.
set -eu

cat <<OUT
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')
AUTHENTIK_PG_PASS=$(openssl rand -base64 36 | tr -d '\n=+/')
OUT
