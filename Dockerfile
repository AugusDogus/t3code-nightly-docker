# syntax=docker/dockerfile:1.7

# Pin the audited amd64 upstream image. Dependabot proposes digest updates so
# upstream lifecycle and compatibility fixes remain deliberate and reviewable.
ARG BASE_IMAGE=ghcr.io/traktuner/docker-t3-code:latest@sha256:e07846ae6e85c73f43549e29eeda52e04d0a2baabcfad0c10c34b2057da99639
FROM ${BASE_IMAGE}

ARG T3_VERSION
ARG CODEX_VERSION=0.160.1
ARG CLAUDE_VERSION=2.1.291
ARG OPENCODE_VERSION=1.18.34

LABEL org.opencontainers.image.title="T3 Code Nightly"
LABEL org.opencontainers.image.description="T3 Code with persistent, user-controlled server and provider updates"
LABEL org.opencontainers.image.source="https://github.com/AugusDogus/t3code-nightly-docker"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${T3_VERSION}"

USER root
# Require the platform package directly: npm must fail if it is not published yet.
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

COPY scripts/runtime.py scripts/entrypoint.sh scripts/t3 /opt/t3-container/
RUN chmod +x /opt/t3-container/entrypoint.sh /opt/t3-container/t3 \
    && ln -sf /opt/t3-container/t3 /usr/local/bin/t3 \
    && ln -s /opt/t3-container/t3 /opt/t3-provider-seed/bin/t3 \
    && for provider in codex claude opencode; do \
         ln -sf "/data/providers/bin/$provider" "/usr/local/bin/$provider"; \
       done

# Updates happen through T3's UI, never automatically on container startup.
ENV T3_AUTO_UPDATE=0 \
    T3_UPDATE_T3=0 \
    T3_ENABLE_PROVIDER_UPDATE_CHECKS=1 \
    T3_CODEX_BINARY_PATH=/data/providers/bin/codex \
    T3_CLAUDE_BINARY_PATH=/data/providers/bin/claude \
    T3_OPENCODE_BINARY_PATH=/data/providers/bin/opencode \
    NPM_CONFIG_PREFIX=/data/providers \
    npm_config_prefix=/data/providers \
    T3_IMAGE_T3_VERSION=${T3_VERSION} \
    PATH=/data/providers/bin:/usr/local/bin:/data/home/.local/bin:/data/home/.grok/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

USER t3
ENTRYPOINT ["/usr/bin/dumb-init", "--single-child", "--", "/opt/t3-container/entrypoint.sh"]
