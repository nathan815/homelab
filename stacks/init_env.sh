#!/bin/bash

# Copy .env.defaults to .env in each subdirectory
find . -name .env.defaults -exec sh -c 'cp "$1" "${1%.example}"' _ {} \;
