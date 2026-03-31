#!/bin/bash
# Git credential helper that generates a fresh GitHub App installation token on demand.
# Called by git automatically whenever credentials are needed.
if [ "$1" != "get" ]; then exit 0; fi

TOKEN=$(python3.11 /app/ghpat.py)

echo "protocol=https"
echo "host=github.com"
echo "username=x-access-token"
echo "password=${TOKEN}"
