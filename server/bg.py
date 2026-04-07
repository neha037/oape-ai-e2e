"""Background task to update GH_TOKEN env var periodically."""

import os
from pathlib import Path
import threading
import time

GH_TOKEN_PATH = "/shared/gh-token"
GH_TOKEN_REFRESH_INTERVAL = 30  # seconds


def _refresh_gh_token() -> None:
    """Background thread: read GH token from shared volume and set env var."""
    while True:
        try:
            token = Path(GH_TOKEN_PATH).read_text().strip()
            if token:
                os.environ["GH_TOKEN"] = token
                print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}: GH_TOKEN refreshed")
        except FileNotFoundError:
            print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}: {GH_TOKEN_PATH} not found, retrying...")
        except OSError as exc:
            print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}: Failed to read GH token: {exc}")
        time.sleep(GH_TOKEN_REFRESH_INTERVAL)


threading.Thread(target=_refresh_gh_token, daemon=True).start()
