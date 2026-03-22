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
COPY server/*.py server/agent.py server/config.json server/homepage.html ./
COPY team-repos.csv /

# Copy plugins directory
# server.py resolves: Path(__file__).parent.parent / "plugins" / "oape"
# With __file__=/app/server.py, parent.parent=/, so it expects /plugins/oape
COPY plugins /plugins

USER 1001

EXPOSE 8000

RUN git config --global user.name "openshift-app-platform-shift-bot"
RUN git config --global user.email "267347085+openshift-app-platform-shift-bot@users.noreply.github.com"

CMD gh auth setup-git && uvicorn server:app --host 0.0.0.0 --port 8000
