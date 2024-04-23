#!/bin/bash

# Copy .env.example to .env in each subdirectory
find . -name .env.example -exec sh -c 'cp "$1" "${1%.example}"' _ {} \;
