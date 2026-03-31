#!/bin/bash
# Git credential helper that reads a GitHub App installation token
# from a shared volume (written by the ghtoken-sidecar container).
if [ "$1" != "get" ]; then exit 0; fi

TOKEN=$(cat /shared/gh-token 2>/dev/null)

echo "protocol=https"
echo "host=github.com"
echo "username=x-access-token"
echo "password=${TOKEN}"
