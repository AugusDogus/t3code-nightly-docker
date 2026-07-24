# syntax=docker/dockerfile:1.7

# Pin the audited amd64 upstream image. Dependabot proposes digest updates so
# upstream lifecycle and compatibility fixes remain deliberate and reviewable.
ARG BASE_IMAGE=ghcr.io/traktuner/docker-t3-code:latest@sha256:e07846ae6e85c73f43549e29eeda52e04d0a2baabcfad0c10c34b2057da99639
FROM ${BASE_IMAGE}

ARG T3_VERSION

LABEL org.opencontainers.image.title="T3 Code Nightly"
LABEL org.opencontainers.image.description="Exact T3 Code nightly layered onto traktuner/docker-t3-code"
LABEL org.opencontainers.image.source="https://github.com/AugusDogus/t3code-nightly-docker"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${T3_VERSION}"

USER root
RUN test -n "${T3_VERSION}" \
    && NPM_CONFIG_CACHE=/tmp/t3-npm-cache npm install -g \
      --prefix /usr/local \
      --no-audit \
      --no-fund \
      --dangerously-allow-all-scripts \
      "t3@${T3_VERSION}" \
    && rm -rf /tmp/t3-npm-cache

# The upstream runtime can persist self-updated packages under /data. Put the
# image-pinned nightly first and disable runtime mutation by default.
ENV T3_AUTO_UPDATE=0 \
    T3_UPDATE_T3=0 \
    T3_IMAGE_T3_VERSION=${T3_VERSION} \
    PATH=/usr/local/bin:/data/npm-global/bin:/data/home/.local/bin:/data/home/.grok/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

USER t3
