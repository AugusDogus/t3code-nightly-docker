# syntax=docker/dockerfile:1.7

# Dependabot proposes updates to the official runtime and tool images.
ARG BASE_IMAGE=node:26.5.0-bookworm-slim@sha256:2d49d876e96237d76de412761cf05dbfe5aee325cc4406a4d41d5824c5bb8beb
FROM oven/bun:1.3.14-slim@sha256:621f249399228db47cf34611ee662585e77e015250ed29d5d0932b2d3282f0b0 AS bun
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="T3 Code Nightly"
LABEL org.opencontainers.image.description="T3 Code with persistent, user-controlled server and provider updates"
LABEL org.opencontainers.image.source="https://github.com/AugusDogus/t3code-nightly-docker"
LABEL org.opencontainers.image.licenses="MIT"

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates curl dumb-init git git-lfs openssh-client \
      python3 python3-venv python3-pip build-essential cmake pkg-config \
      jq ripgrep fd-find sqlite3 rsync unzip zip procps lsof less file \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && useradd --uid 99 --gid 100 --home-dir /data/home --no-create-home --shell /bin/bash t3 \
    && mkdir -p /data/home /workspace \
    && chown -R 99:100 /data /workspace

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=uv /uv /uvx /usr/local/bin/
ARG PNPM_VERSION=11.11.0
ARG YARN_VERSION=1.22.22
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx \
    && npm install -g --no-audit --no-fund "pnpm@${PNPM_VERSION}" "yarn@${YARN_VERSION}" \
    && npm cache clean --force

# Require the platform package directly: npm must fail if it is not published yet.
ARG T3_VERSION
RUN test -n "${T3_VERSION}" \
    && NPM_CONFIG_CACHE=/tmp/t3-npm-cache npm install -g \
      --prefix /opt/t3-install \
      --no-audit \
      --no-fund \
      --dangerously-allow-all-scripts \
      "@t3code/t3-linux-x64@${T3_VERSION}" \
    && mv /opt/t3-install/lib/node_modules/@t3code/t3-linux-x64 /opt/t3-seed \
    && /opt/t3-seed/t3 --version \
    && rm -rf /opt/t3-install /tmp/t3-npm-cache

ARG CODEX_VERSION=0.160.1
ARG CLAUDE_VERSION=2.1.291
ARG OPENCODE_VERSION=1.18.34
RUN NPM_CONFIG_CACHE=/tmp/t3-npm-cache npm install -g \
      --prefix /opt/t3-provider-seed \
      --no-audit --no-fund --dangerously-allow-all-scripts \
      "@openai/codex@${CODEX_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
      "opencode-ai@${OPENCODE_VERSION}" \
    && /opt/t3-provider-seed/bin/codex --version \
    && /opt/t3-provider-seed/bin/claude --version \
    && /opt/t3-provider-seed/bin/opencode --version \
    && rm -rf /tmp/t3-npm-cache

COPY scripts/runtime.py scripts/settings.py scripts/entrypoint.sh scripts/healthcheck.sh scripts/t3 /opt/t3-container/
RUN chmod +x /opt/t3-container/entrypoint.sh /opt/t3-container/healthcheck.sh /opt/t3-container/t3 \
    && ln -sf /opt/t3-container/t3 /usr/local/bin/t3 \
    && ln -s /opt/t3-container/t3 /opt/t3-provider-seed/bin/t3 \
    && for provider in codex claude opencode; do \
         ln -sf "/data/providers/bin/$provider" "/usr/local/bin/$provider"; \
       done

# Updates happen through T3's UI, never automatically on container startup.
LABEL org.opencontainers.image.version="${T3_VERSION}"
ENV HOME=/data/home \
    T3CODE_HOME=/data/t3 \
    CODEX_HOME=/data/codex \
    XDG_CONFIG_HOME=/data/home/.config \
    XDG_DATA_HOME=/data/home/.local/share \
    XDG_CACHE_HOME=/data/home/.cache \
    T3_WORKDIR=/workspace \
    T3_ENABLE_PROVIDER_UPDATE_CHECKS=1 \
    NPM_CONFIG_PREFIX=/data/providers \
    npm_config_prefix=/data/providers \
    NPM_CONFIG_CACHE=/data/npm-cache \
    T3_IMAGE_T3_VERSION=${T3_VERSION} \
    PATH=/data/providers/bin:/data/home/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

USER t3
WORKDIR /workspace
EXPOSE 3773
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 CMD ["/opt/t3-container/healthcheck.sh"]
ENTRYPOINT ["/usr/bin/dumb-init", "--single-child", "--", "/opt/t3-container/entrypoint.sh"]
CMD []
