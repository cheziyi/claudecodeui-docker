# syntax=docker/dockerfile:1

# CloudCLI UI (siteboon/claudecodeui) + Claude Code in one ready-to-code image.
#
# The full (non-slim) Debian image already ships git, curl, gcc/make and
# python3, which native npm modules and most coding sessions need anyway.
FROM node:22-bookworm

# "latest" keeps local builds simple; CI passes exact versions so every
# published tag maps to a known pair of upstream releases.
ARG CLOUDCLI_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest

# Developer tooling plus the GitHub CLI from its official apt repository.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        fd-find \
        gh \
        git \
        git-lfs \
        gosu \
        htop \
        jq \
        less \
        nano \
        openssh-client \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        sudo \
        tini \
        tree \
        tzdata \
        unzip \
        vim \
        wget \
        zip; \
    ln -s /usr/bin/fdfind /usr/local/bin/fd; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    npm install -g \
        "@cloudcli-ai/cloudcli@${CLOUDCLI_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    # Configuration comes from the container environment; an empty .env stops
    # the server logging "No .env file found" on every start.
    touch "$(npm root -g)/@cloudcli-ai/cloudcli/.env"; \
    cloudcli version; \
    claude --version

# Run as the image's existing "node" user (uid/gid 1000, remapped at start via
# PUID/PGID), with passwordless sudo so sessions can apt-get install extras.
RUN set -eux; \
    echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node; \
    chmod 0440 /etc/sudoers.d/node; \
    install -d -o node -g node /workspace /home/node/.claude /home/node/.cloudcli /home/node/.npm-global

COPY --chmod=0755 entrypoint.sh /usr/local/bin/cloudcli-entrypoint.sh

ENV HOST=0.0.0.0 \
    SERVER_PORT=3001 \
    WORKSPACES_ROOT=/workspace \
    # The image is rebuilt with new releases; an in-container self-update
    # could not write to the root-owned global install anyway.
    DISABLE_AUTOUPDATER=1 \
    # User-level `npm install -g` lands in the persisted home volume.
    NPM_CONFIG_PREFIX=/home/node/.npm-global \
    PATH=/home/node/.npm-global/bin:/home/node/.local/bin:$PATH \
    SHELL=/bin/bash \
    LANG=C.UTF-8

WORKDIR /workspace
EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${SERVER_PORT}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/cloudcli-entrypoint.sh"]
CMD ["cloudcli", "start"]
