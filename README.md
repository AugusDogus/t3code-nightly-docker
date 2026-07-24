# T3 Code Nightly Docker

An amd64 image that layers each exact T3 Code nightly onto the maintained
[`traktuner/docker-t3-code`](https://github.com/traktuner/docker-t3-code) runtime.
The upstream image already handles provider installation and configuration,
authentication homes, Git safe directories, health checks, signal handling,
optional sandbox integration, and container-specific lifecycle behavior.

This repository deliberately adds only two things:

- an exact T3 nightly package
- automation that publishes immutable nightly image tags after smoke tests

## Included Software

The upstream Debian Bookworm image includes:

- Claude Code, Codex CLI, OpenCode, Cursor Agent, and Grok
- Node.js, npm, pnpm, Yarn, Bun, Python, and uv
- Git, Git LFS, GitHub CLI, OpenSSH, ripgrep, fd, jq, SQLite, database clients,
  and native build tools

See the [upstream documentation](https://github.com/traktuner/docker-t3-code)
for its full provider, MCP, sandbox, Xcode, and issue-worker capabilities.

## Tags

```text
ghcr.io/augusdogus/t3code-nightly:<exact T3 nightly version>
ghcr.io/augusdogus/t3code-nightly:nightly
```

Use an exact version for deliberate upgrades and rollback. Use `nightly` only
after automating state backups and accepting unattended database migrations.

The upstream base is pinned by digest in `Dockerfile`. Dependabot proposes base
updates for review instead of silently changing the runtime beneath an existing
nightly image.

## Unraid Setup

Create SSD-backed cache or exclusive shares:

```text
/mnt/user/appdata/t3code
/mnt/user/dev
```

Make both paths writable by Unraid's `nobody:users` identity, UID 99 and GID 100.
Copy `.env.example` to `.env`, select an exact image tag, and start the stack:

```bash
docker compose up -d
```

The Compose file enables Claude, Codex, and OpenCode. Cursor and Grok remain
installed but disabled by default. Provider runtime updates and the upstream
custom auth proxy are disabled so the image remains immutable and T3's native
pairing remains authoritative.

## Tailscale

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
| `/data` | T3 state, worktrees, provider authentication, SSH and Git configuration, and caches |
| `/workspace` | Project repositories and project dependencies |

Back up `/mnt/user/appdata/t3code` before every nightly upgrade. Back up or push
important repository work separately.

## Provider Authentication

Credentials are written beneath `/data` and survive image replacement.

```bash
docker exec -it t3code t3-auth codex login
docker exec -it t3code t3-auth claude login
docker exec -it t3code t3-auth gh login
docker exec -it t3code t3-auth gh setup-git
docker exec -it t3code t3-doctor
```

## Automated Builds

The workflow checks npm's `t3` nightly dist-tag every six hours. If the exact
GHCR tag does not exist, it:

1. Builds the thin derived image for amd64.
2. Verifies the exact T3 version and every bundled provider CLI.
3. Starts the server and probes its environment endpoint.
4. Publishes the exact version and moving `nightly` tags with provenance and an
   SBOM.

For a deliberate Unraid upgrade:

1. Finish active agent and terminal work.
2. Stop the container.
3. Back up the `/data` host path.
4. Change `T3CODE_IMAGE_TAG` to the new exact nightly.
5. Pull and recreate the container.
6. Verify projects, threads, and provider authentication.

Rollback may require restoring both the previous exact image tag and the state
backup if the newer nightly applied a database migration.

## Local Build

```bash
T3_VERSION="$(npm view t3 dist-tags.nightly)"
docker build --build-arg "T3_VERSION=$T3_VERSION" -t "t3code-nightly:$T3_VERSION" .
scripts/smoke.sh "t3code-nightly:$T3_VERSION" "$T3_VERSION"
```

## Security Boundary

Coding agents execute arbitrary commands inside this container. They can modify
the mounted workspace and read provider credentials under `/data`. Do not mount
the Unraid root filesystem, all of `/mnt/user`, host devices, or
`/var/run/docker.sock`.

Docker shares the Unraid host kernel. Use a VM when hostile-code isolation is
more important than low overhead and elastic resource use.
