#!/bin/bash
# Periodically generates a fresh GitHub App installation token
# and writes it to a shared volume for the main container to read.
TOKEN_FILE="/shared/gh-token"
REFRESH_INTERVAL=1800 # 30 minutes

while true; do
    TOKEN=$(python3.11 /opt/ghtoken/ghpat.py 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "$(date): Token refreshed successfully"
    else
        echo "$(date): Failed to refresh token"
    fi
    sleep "$REFRESH_INTERVAL"
done
