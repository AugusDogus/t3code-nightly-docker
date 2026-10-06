# T3 Code Nightly Docker

An amd64 image built on the official Node.js image with Debian 12. It installs
upstream's prebuilt T3 Code nightly and provider CLIs, with persistent data and
updates controlled through T3's app. It does not depend on another T3 Docker image.

This repository adds:

- a tested initial T3 nightly and provider installation
- persistent installations that can be updated from T3's own UI
- the native T3 service launcher for update, restart, and reconnect

Published images use T3's nightly channel. The release workflow accepts only
nightly T3 versions; stable releases are not currently built or tested here.
Codex, Claude, and OpenCode use their own versions and update controls.

## Included Software

The image includes:

- Claude Code, Codex CLI, and OpenCode
- Node.js, npm, pnpm, Yarn, Bun, Python, and uv
- Git, Git LFS, GitHub CLI, OpenSSH, ripgrep, fd, jq, SQLite, rsync, and native
  build tools (GCC, Make, CMake, and pkg-config)

Node.js, Bun, and uv come from versioned, digest-pinned official images. GitHub
CLI comes from its official apt repository; system packages come from Debian.
The container runs as UID 99, GID 100, and uses `dumb-init` for signal handling.

## Tags

```text
ghcr.io/augusdogus/t3code-nightly:<T3-version>-<repository-commit>
ghcr.io/augusdogus/t3code-nightly:nightly
```

Exact image tags include the full repository commit so container fixes can ship
independently of T3 releases. Copy an exact tag from the Actions build summary,
or use `nightly` for the latest tested container build.
The image selects the initial T3 version for a fresh `/data` directory.
After initialization, T3's UI controls the active version. Restarting or replacing
the container preserves that selection and your provider installations. Pulling
an older image does not downgrade an existing installation.

The base and tool images are pinned by digest in `Dockerfile`. Dependabot proposes
updates for review instead of silently changing the container runtime.

## Unraid Setup

The current Unraid installation runs as a directly managed Docker container
named `t3code`, with `/mnt/cache/appdata/t3code` mounted at `/data` and
`/mnt/cache/dev` mounted at `/workspace`. It uses T3 Connect for remote access.
It is not managed by Compose or an Unraid Docker template.

The Unraid deployment uses a separate `cliproxyapi` container on the private
`t3-backend` Docker network. T3 has two configured profiles, Codex and Claude,
pointing to `http://cliproxyapi:8317`. Codex uses the `/v1` Responses API;
Claude uses the Anthropic API. Account pooling and authentication belong to
CLIProxyAPI, and T3 reads pooled quotas through its CLIProxyAPI usage source.
The proxy has no published host ports and runs independently of the desktop
and MacBook installations.

Each independent proxy must obtain its own OAuth sessions through fresh logins.
Never copy provider access or refresh tokens from another running proxy: a refresh
on one machine can invalidate the other machine's credentials. Alternatively,
multiple T3 installations can use one shared proxy, which alone owns those tokens.

The Unraid proxy is currently stopped with automatic restart disabled. Its copied
account credentials have been removed, and T3's provider profiles and quota source
are disabled pending independent authorization.

Proxy configuration and account credentials persist in
`/mnt/cache/appdata/cliproxyapi`. Its client and management keys are separate;
T3 stores its management key and Claude token in its native secret store.
The proxy runs the official `eceasy/cli-proxy-api:v8.0.16` image, pinned by digest
in the deployed container. It is updated separately from T3 and the provider CLIs.

The previous Unraid settings, profiles, and conversations were archived under
`/mnt/cache/appdata/t3code-backups/20261006T181212Z-cliproxy-reset/data` before
starting fresh. T3 Connect identity and existing client authorizations were
retained. `/mnt/cache/dev` was not reset. Automatic project creation from
`/workspace` is disabled on this deployment.

The following Compose instructions are for a new installation. Do not start a
second container against the existing data directory. When replacing the current
container, preserve its mounts, environment overrides, UID/GID, and port mapping.

Create SSD-backed cache or exclusive shares:

```text
/mnt/user/appdata/t3code
/mnt/user/dev
```

Make both paths writable by Unraid's `nobody:users` identity, UID 99 and GID 100.
Copy `.env.example` to `.env`, optionally select an exact image tag, and start the stack:

```bash
docker compose up -d
```

Fresh installations enable Claude, Codex, and OpenCode with persistent binary and
authentication paths. Manage providers and additional profiles in T3's settings.
Startup preserves existing settings, profiles, and credentials, and never
updates installed packages. T3 handles pairing and update controls directly.

## Updates from T3

Connect the nightly desktop app or a compatible mobile app to this server. When
the connected client offers **Update server**, click it and keep the client
open while the download completes, the server restarts, and the connection returns.
The server follows the nightly release channel. Update notices and checks are
provided by T3's client; the container does not install updates unattended. The
container's bundled browser UI does not provide the desktop's nightly banner.

In **Settings → Providers**, enable update checks and use **Update all** or an
individual provider's update action. Codex, Claude, and OpenCode are installed in
the writable `/data/providers` prefix, so updates survive container replacement.
The initial versions are pinned by build arguments in `Dockerfile`.

Server updates can interrupt running agents and terminals. T3's optional
**Continue threads after restarts** setting controls supported thread recovery.
Back up `/data` before significant upgrades. The native launcher snapshots SQLite
for failed-update recovery; this does not replace a backup of the full data volume.

This container adapts the upstream internal service launcher, protocol 3, without
systemd or a Docker socket. The launcher stays in the image while updated server
versions are installed beneath `/data/t3/runtime`. If a future release requires a
new launcher protocol, update the container image first. Do not run
`t3 service install` inside the container or use startup `npm update` jobs.

The launcher replaces the T3 server process inside the running container. It does
not pull or replace Docker images. Debian packages, bundled development tools,
the launcher, and container startup scripts are updated by pulling a new image
and recreating the container through Docker or Unraid.

To migrate from the earlier immutable image: stop the container, back up `/data`,
then recreate it with this image and the same writable mounts. On first start it
seeds the managed runtime and providers while retaining T3 state and provider
authentication. Existing package copies in `/data/npm-global` are left intact but
are no longer used for T3, Codex, Claude, or OpenCode.

When moving from this repository's earlier third-party base, keep the same
`/data` and `/workspace` mounts. Personal and work profiles, selected runtime,
provider installations, and T3 Connect authorization are preserved. The old
`/config/t3code.toml`, provider provisioning environment variables, `t3-auth`,
`t3-doctor`, and bundled proxy/MCP/sandbox helpers are no longer provided.
Cursor and Grok are not bundled. The existing host, port, and project-bootstrap
environment variable names remain accepted for container replacement.

When upgrading a V1 installation, T3 copies `userdata/state.sqlite` to
`userdata/statev2.sqlite` and migrates the copy. Existing threads and conversation
messages are imported; the original database remains available for recovery.
Live provider sessions and some older activity/checkpoint history are not
carried over. See the [upstream migration notes](https://github.com/pingdotgg/t3code/blob/main/docs/user/thread-migration.md).

## Remote Access

### T3 Connect

The current installation uses T3 Connect. Its authorization persists under
`/data`, and T3 starts its tunnel when the server starts. Check its status with:

```bash
docker exec t3code t3 connect status
```

For a new installation, run `docker exec -it t3code t3 connect --headless` and
follow the authorization prompts. Connect from the desktop or mobile app using
T3 Connect. No Tailscale Serve route is required for this method.

### Tailscale (alternative)

The container maps T3 only to host loopback. With the native Unraid Tailscale
plugin, publish it privately over the existing Tailnet:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:3773
tailscale serve status
```

Open `https://googolplex.<tailnet>.ts.net/` and use the pairing token from:

```bash
docker logs t3code
```

Do not enable Tailscale Funnel and do not publish port 3773 on all host
interfaces.

## Persistence

| Container path | Contents |
| --- | --- |
| `/data` | T3 state and installed runtimes, provider installations and authentication, worktrees, SSH and Git configuration, and caches |
| `/workspace` | Project repositories and project dependencies |

Stop the container and back up the actual host directory mounted at `/data`
before significant upgrades. On the current installation this is
`/mnt/cache/appdata/t3code`; recovery copies are kept separately under
`/mnt/cache/appdata/t3code-backups`. Back up or push important repository work
separately.

## Provider Authentication

Credentials are written beneath `/data` and survive image replacement.

```bash
docker exec -it t3code codex login --device-auth
docker exec -it -e HOME=/data/claude-home t3code claude auth login
docker exec -it t3code opencode auth login
docker exec -it t3code gh auth login
docker exec -it t3code gh auth setup-git
```

These commands use the default profile paths. For an additional profile, use the
home directory configured for that profile in T3, such as `/data/claude-work`.

## Automated Builds

The workflow tests pull requests and publishes container changes merged to
`main`. It also supports manual runs; only `main` publishes images. There is no
scheduled nightly rebuild. Each build uses the tested `T3_VERSION` in `Dockerfile`
as the initial version, unless a manual run specifies another exact version.
This avoids depending on partially published nightlies for container changes.
If the exact image tag does not exist, it:

1. Builds the image for amd64.
2. Tests bootstrap state preservation and validates provider update destinations.
3. Starts an older nightly as UID 99, updates it through T3's native API, verifies
   authenticated reconnection, then recreates the container with the same data
   and verifies database/runtime recovery after a deliberately failed update.
4. Replaces the previous base image and verifies that personal/work profiles,
   provider homes, environment identity, and an existing credential survive.
5. Publishes the version-plus-commit and moving `nightly` tags with provenance and an
   SBOM.

Dependabot checks the pinned base and tool images weekly. Merging an image update
builds a new container with its OS and bundled tool updates. T3 and provider
updates within an existing installation remain controlled through the app.

For an Unraid container image refresh:

1. Finish active agent and terminal work.
2. Stop the container.
3. Back up the `/data` host path.
4. Select the desired exact image tag. For Compose, set `T3CODE_IMAGE_TAG`.
5. Pull and recreate the container using its existing mounts and settings.
6. Verify projects, threads, and provider authentication.

The selected T3 runtime and provider versions remain in `/data`. To roll back an
already committed update, restore the matching data backup and compatible image.
Keep the stopped previous container until the replacement is verified. Never run
both containers against the same `/data` directory.

## Local Build

```bash
T3_VERSION="$(sed -n 's/^ARG T3_VERSION=//p' Dockerfile)"
docker build --build-arg "T3_VERSION=$T3_VERSION" -t "t3code-nightly:$T3_VERSION" .
scripts/smoke.sh "t3code-nightly:$T3_VERSION" "$T3_VERSION"
```

To also exercise a real native update from an older release:

```bash
UPDATE_FROM_VERSION=0.0.46-nightly.20261005.2676 \
  scripts/smoke.sh "t3code-nightly:$T3_VERSION" "$T3_VERSION"
```

Set `CONTAINER_ENGINE=podman` when testing with Podman. Smoke tests use disposable
volumes and do not access your live `/data` or provider credentials.
Set `MIGRATE_FROM_IMAGE` to the previous image and `UPDATE_FROM_VERSION` to its
initial T3 version to also test replacement of that image.

## Security Boundary

Coding agents execute arbitrary commands inside this container. They can modify
the mounted workspace and read provider credentials under `/data`. Do not mount
the Unraid root filesystem, all of `/mnt/user`, host devices, or
`/var/run/docker.sock`.

Docker shares the Unraid host kernel. Use a VM when hostile-code isolation is
more important than low overhead and elastic resource use.
