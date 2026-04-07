FROM registry.access.redhat.com/ubi9/go-toolset

# Install system dependencies required by operator tooling
USER 0
RUN dnf install -y \
        git \
        make && \
    # Install GitHub CLI
    dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && \
    dnf install -y gh && \
    dnf install -y python3.11 && \
    dnf install -y python3.11-pip && \
    dnf clean all

WORKDIR /app

# Install Python dependencies
COPY server/requirements.txt .
RUN python3.11 -m pip install --no-cache-dir -r requirements.txt

# Copy server code and config
COPY server/server.py server/agent.py server/bg.py server/homepage.html ./

# Copy git credential helper (reads token from sidecar's shared volume)
COPY server/gh-credential-helper.sh /bin/gh-credential-helper

# Copy GitHub App token generator and refresh loop (used by sidecar entrypoint)
COPY server/ghpat.py /opt/ghtoken/ghpat.py
COPY server/token-refresh.sh /opt/ghtoken/token-refresh.sh
RUN chmod +x /opt/ghtoken/token-refresh.sh

# copy default config, users willing to customize should mount at runtime.
COPY deploy/config /config

# Copy plugins directory
# server.py resolves: Path(__file__).parent.parent / "plugins" / "oape"
# With __file__=/app/server.py, parent.parent=/, so it expects /plugins/oape
COPY plugins /plugins

# Configure git globally while still root, and ensure the home directory is
# writable for arbitrary UIDs (OpenShift runs containers as random UID).
RUN git config --global user.name "openshift-app-platform-shift-bot" && \
    git config --global user.email "267347085+openshift-app-platform-shift-bot@users.noreply.github.com"

RUN chmod +x /bin/gh-credential-helper && \
    chmod -R g=u /opt/app-root/src

RUN git config --global credential.helper '/bin/gh-credential-helper'

USER 1001

EXPOSE 8000

CMD uvicorn server:app --host 0.0.0.0 --port 8000
