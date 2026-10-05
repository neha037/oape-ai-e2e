FROM registry.access.redhat.com/ubi9/go-toolset

USER 0

RUN dnf install -y \
        git \
        make \
        jq \
        openssl \
        python3 \
        python3-pyyaml && \
    dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && \
    dnf install -y gh && \
    dnf clean all

WORKDIR /app

RUN go install golang.org/x/tools/cmd/goimports@v0.33.0 && \
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/v2.1.6/install.sh | sh -s -- -b /usr/local/bin v2.1.6

RUN dnf module reset -y nodejs && \
    dnf module enable -y nodejs:20 && \
    dnf install -y nodejs npm && \
    npm install -g @anthropic-ai/claude-code@1.0.16 && \
    dnf clean all

COPY scripts/ci-monitor/ /app/scripts/ci-monitor/
COPY scripts/pr-agent/ /app/scripts/pr-agent/
COPY plugins /plugins
COPY deploy/config/ /config/

RUN git config --global user.name "openshift-app-platform-shift-bot" && \
    git config --global user.email "267347085+openshift-app-platform-shift-bot@users.noreply.github.com"

RUN chmod -R g=u /opt/app-root/src /config

USER 1001
