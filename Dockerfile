# syntax=docker/dockerfile:1

# CloudCLI UI (siteboon/claudecodeui) + Claude Code in one ready-to-code image.
#
# Plain Debian plus fnm and uv: users manage their own Node.js and Python
# versions, which live in the persisted home volume and survive image updates.
FROM debian:trixie-slim

# Node.js major that runs the CloudCLI server itself, separate from any
# versions users install with fnm. Pinned to the current LTS so a new major
# (and its native-module ABI) is adopted deliberately.
ARG NODE_MAJOR=26
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Developer tooling plus the GitHub CLI and Docker from their official apt
# repositories. python3 and build-essential are also what node-gyp needs for
# native modules. Docker's daemon only runs when the user opts in with DIND=1
# on a privileged container; otherwise the CLI talks to a host socket the user
# chooses to mount, or to nothing (see the README).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    install -d -m 0755 /etc/apt/keyrings; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bind9-dnsutils \
        build-essential \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin \
        fd-find \
        file \
        gh \
        git \
        git-lfs \
        gosu \
        htop \
        iproute2 \
        iptables \
        iputils-ping \
        jq \
        less \
        lsof \
        nano \
        netcat-openbsd \
        openssh-client \
        pkg-config \
        procps \
        python3 \
        ripgrep \
        rsync \
        strace \
        sudo \
        tini \
        tree \
        tzdata \
        unzip \
        vim \
        wget \
        xz-utils \
        zip; \
    ln -s /usr/bin/fdfind /usr/local/bin/fd; \
    rm -rf /var/lib/apt/lists/*

# fnm (Node.js versions) and uv (Python versions, packages and tools). CI
# passes the newest releases within upstream.env's ranges; "latest" keeps local
# builds simple. uv is checked against the sha256 file it publishes with each
# release; fnm publishes none.
ARG FNM_VERSION=latest
ARG UV_VERSION=latest
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) fnm_asset=fnm-linux.zip; uv_asset=uv-x86_64-unknown-linux-gnu ;; \
        arm64) fnm_asset=fnm-arm64.zip; uv_asset=uv-aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    release() { if [ "$2" = latest ]; then echo "https://github.com/$1/releases/latest/download"; else echo "https://github.com/$1/releases/download/$2"; fi; }; \
    fnm_tag="$FNM_VERSION"; [ "$fnm_tag" = latest ] || fnm_tag="v${FNM_VERSION#v}"; \
    cd /tmp; \
    curl -fsSL -o fnm.zip "$(release Schniz/fnm "$fnm_tag")/$fnm_asset"; \
    unzip -q fnm.zip -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/fnm; \
    uv_url="$(release astral-sh/uv "$UV_VERSION")/$uv_asset.tar.gz"; \
    curl -fsSL -o "$uv_asset.tar.gz" "$uv_url"; \
    curl -fsSL "$uv_url.sha256" | sha256sum -c -; \
    tar -xzf "$uv_asset.tar.gz" --strip-components=1 -C /usr/local/bin "$uv_asset/uv" "$uv_asset/uvx"; \
    rm fnm.zip "$uv_asset.tar.gz"; \
    fnm --version; \
    uv --version

# The server's own Node.js, installed with fnm into a root-owned location.
RUN set -eux; \
    fnm --fnm-dir /opt/fnm install "$NODE_MAJOR"; \
    fnm --fnm-dir /opt/fnm default "$NODE_MAJOR"; \
    ln -s "$(readlink -f /opt/fnm/aliases/default)" /opt/node; \
    /opt/node/bin/node --version

# "latest" keeps local builds simple; CI passes exact versions so every
# published tag maps to a known pair of upstream releases. Declared here, not
# at the top, so a version bump only invalidates the layers from here on.
ARG CLOUDCLI_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest

# npm 11+ skips dependency install scripts unless allowed. These five build
# native modules or place the claude binary; --strict-allow-scripts fails the
# build if an upstream release adds another, instead of shipping it broken.
RUN set -eux; \
    export PATH="/opt/node/bin:$PATH"; \
    npm install -g \
        --allow-scripts=@anthropic-ai/claude-code,@cloudcli-ai/cloudcli,bcrypt,better-sqlite3,node-pty \
        --strict-allow-scripts \
        "@cloudcli-ai/cloudcli@${CLOUDCLI_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    cloudcli_dir="$(npm root -g)/@cloudcli-ai/cloudcli"; \
    # Configuration comes from the container environment; an empty .env stops
    # the server logging "No .env file found" on every start.
    touch "$cloudcli_dir/.env"; \
    # Always run the server on this Node, whatever `node` a user's PATH picks.
    printf '#!/bin/sh\nexec /opt/node/bin/node %s "$@"\n' "$(readlink -f /opt/node/bin/cloudcli)" \
        > /usr/local/bin/cloudcli; \
    chmod 0755 /usr/local/bin/cloudcli; \
    # claude is a native binary; expose it without the server's Node on PATH.
    ln -s "$(readlink -f /opt/node/bin/claude)" /usr/local/bin/claude; \
    # Fail the build if a native module did not build for this platform.
    (cd "$cloudcli_dir" && /opt/node/bin/node -e 'for (const m of ["node-pty", "better-sqlite3", "bcrypt"]) require(m)'); \
    /usr/local/bin/cloudcli version; \
    /usr/local/bin/claude --version; \
    # Global npm installs with this Node go to the persisted home volume.
    install -d /opt/node/etc; \
    echo 'prefix=/home/dev/.npm-global' > /opt/node/etc/npmrc

# Interactive shells: enable `fnm use` and switch versions on cd (.nvmrc,
# .node-version), plus shell completions.
RUN set -eux; \
    { \
        echo; \
        echo '# fnm: per-project Node.js versions'; \
        echo 'eval "$(fnm env --use-on-cd --version-file-strategy=recursive --shell bash)"'; \
        echo 'eval "$(fnm completions --shell bash)"'; \
        echo 'eval "$(uv generate-shell-completion bash)"'; \
    } >> /etc/bash.bashrc

# Runtime user "dev" (uid/gid 1000, remapped at start via PUID/PGID), with
# passwordless sudo so sessions can apt-get install extras.
RUN set -eux; \
    groupadd -g 1000 dev; \
    useradd -m -u 1000 -g 1000 -s /bin/bash dev; \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev; \
    chmod 0440 /etc/sudoers.d/dev; \
    install -d -o dev -g dev /workspaces /home/dev/.claude /home/dev/.cloudcli /home/dev/.npm-global

COPY --chmod=0755 entrypoint.sh /usr/local/bin/cloudcli-entrypoint.sh
# Managed CLAUDE.md: tells every Claude Code session about fnm, uv and what
# persists. Image-owned, so it updates with the image. The directory is made
# first: COPY --chmod would also apply 0644 to the parent it creates, leaving
# it unsearchable for "dev".
RUN install -d -m 0755 /etc/claude-code
COPY --chmod=0644 etc/claude-code/CLAUDE.md /etc/claude-code/CLAUDE.md

# PATH order: the user's fnm default Node, user-installed tools (uv tool,
# pipx, npm -g), the system, then the server's Node as a fallback `node`.
ENV HOST=0.0.0.0 \
    SERVER_PORT=3001 \
    WORKSPACES_ROOT=/workspaces \
    # The image is rebuilt with new releases; an in-container self-update
    # could not write to the root-owned install anyway.
    DISABLE_AUTOUPDATER=1 \
    # Projects (/workspaces) and uv's cache (home volume) are on different
    # filesystems, so hardlinking always fails; copy without warning.
    UV_LINK_MODE=copy \
    PATH=/home/dev/.local/share/fnm/aliases/default/bin:/home/dev/.local/bin:/home/dev/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/node/bin \
    SHELL=/bin/bash \
    LANG=C.UTF-8

# Login shells (`bash -l`, `sudo -iu dev`, Claude Code's shell snapshot) get
# PATH from /etc/profile, which Debian hard-codes; give them the one above.
RUN set -eux; \
    sed -i 's|^  PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"$|  PATH="'"$PATH"'"|' /etc/profile; \
    grep -qF "PATH=\"$PATH\"" /etc/profile

WORKDIR /workspaces
EXPOSE 3001

# A script rather than an inline command so the Podman unit can reuse it:
# Podman ignores HEALTHCHECK in OCI-format images, which is what CI publishes.
RUN set -eux; \
    printf '#!/bin/sh\nexec curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT:-3001}/health"\n' \
        > /usr/local/bin/cloudcli-healthcheck; \
    chmod 0755 /usr/local/bin/cloudcli-healthcheck

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/cloudcli-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/cloudcli-entrypoint.sh"]
# Absolute path: ~/.npm-global/bin and the user's fnm Node come first on PATH,
# so a user-installed cloudcli must not replace the image's pinned server.
CMD ["/usr/local/bin/cloudcli", "start"]
