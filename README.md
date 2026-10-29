# claudecodeui-docker

A ready-to-code Docker image with [CloudCLI UI](https://github.com/siteboon/claudecodeui)
(formerly Claude Code UI) and [Claude Code](https://docs.claude.com/en/docs/claude-code)
installed. Start the container, open the browser, log in to Claude, and start coding:
from your desktop, or from your phone.

```
ghcr.io/cheziyi/claudecodeui:1
```

Built for `linux/amd64` and `linux/arm64`. Releases are versioned on their own
(see [Versions and tags](#versions-and-tags)), and the newest release is rebuilt
daily when CloudCLI, Claude Code, fnm or uv ships a new version.

## Quick start

```sh
mkdir -p ~/claudecodeui && cd ~/claudecodeui
curl -O https://raw.githubusercontent.com/cheziyi/claudecodeui-docker/main/compose.yaml
grep -qs '^PUID=' .env || printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> .env
docker compose up -d
```

Or without Compose:

```sh
docker run -d --name claudecodeui -p 3001:3001 \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  -v ~/claudecodeui/workspaces:/workspaces \
  -v claudecodeui-home:/home/dev \
  ghcr.io/cheziyi/claudecodeui:1
```

Either way, projects go in `~/claudecodeui/workspaces` and everything else in
the `claudecodeui-home` volume, so you can switch between Compose and
`docker run` without losing anything.

### Podman

[`podman/`](podman/) has a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
unit, the Podman equivalent of `compose.yaml`. systemd runs the container,
restarts it on failure and starts it at boot. Tested with Podman 4.9.

```sh
mkdir -p ~/.config/containers/systemd ~/claudecodeui/workspaces
cp podman/claudecodeui.container podman/claudecodeui-home.volume ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start claudecodeui
loginctl enable-linger "$USER"   # keep it running after you log out
```

Projects go in `~/claudecodeui/workspaces`, as with Docker, but Podman keeps its
volumes apart from Docker's, so it starts with a fresh home volume. To pick up
new builds, run `podman auto-update`, or have it run daily with
`systemctl --user enable --now podman-auto-update.timer`.

Without systemd, the equivalent one-off command is:

```sh
mkdir -p ~/claudecodeui/workspaces
podman run -d --name claudecodeui -p 3001:3001 \
  --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
  --sysctl net.ipv4.ping_group_range="1000 1000" \
  -v ~/claudecodeui/workspaces:/workspaces:z \
  -v claudecodeui-home:/home/dev \
  ghcr.io/cheziyi/claudecodeui:1
```

Under rootless Podman, `--userns keep-id` maps your host user to the
container's `dev` user, so files in the workspace stay owned by you. There's no
need for `PUID`/`PGID`. The `--sysctl` lets `dev` use `ping`, which Podman
otherwise allows only for root.

Then:

1. Open <http://localhost:3001> and create the UI's admin account. The first
   visitor gets to create it, so do this right away.
2. Sign in to Claude: open the **Shell** tab, run `claude`, and follow the login
   link. Or set `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or
   `ANTHROPIC_API_KEY` instead (see `compose.yaml`, or the Podman unit for
   keeping it in a Podman secret).
3. Create a project under `/workspaces`, or clone one there from the shell, then
   start a chat.

Claude Code's tools are disabled by default in the UI. Enable the ones you want
under the gear icon in the sidebar.

## What's inside

- CloudCLI UI and Claude Code, at the versions recorded in the image labels
- Debian 13 (trixie) with `build-essential`, `pkg-config` and Python 3
- [fnm](https://github.com/Schniz/fnm) for Node.js versions and
  [uv](https://docs.astral.sh/uv/) for Python versions, packages and tools.
  Node.js 26 (LTS) is available out of the box.
- `git`, `git-lfs`, `gh` (GitHub CLI), `openssh-client`
- Docker with the Compose and Buildx plugins: a daemon inside the container,
  or the host's Docker, if you enable either (see [Docker](#docker))
- `ripgrep`, `fd`, `jq`, `tree`, `htop`, `vim`, `nano`, `curl`, `wget`, `rsync`, `zip`/`unzip`
- For debugging: `ip`/`ss`, `ping`, `dig`, `nc`, `lsof`, `strace`
- Passwordless `sudo`, so you (or Claude) can `sudo apt-get install` anything else
- `tini` as the init process, plus a `/health` healthcheck

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PUID` / `PGID` | `1000` | uid/gid the server runs as. Set them to your host user's so files in `/workspaces` belong to you. |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | – | Sets `git config --global user.name` / `user.email` at startup. |
| `CLAUDE_CODE_OAUTH_TOKEN` | – | Claude subscription token from `claude setup-token`. Lets you skip the interactive login. |
| `ANTHROPIC_API_KEY` | – | Use API billing instead of a subscription. |
| `SERVER_PORT` | `3001` | Port the UI listens on inside the container. |
| `WORKSPACES_ROOT` | `/workspaces` | The UI only opens projects under this path. |
| `TZ` | `Etc/UTC` | Container time zone. |
| `DIND` | – | `1` runs a Docker daemon inside the container. Needs `--privileged`; see [Docker](#docker). |

The CloudCLI server's other settings (for example `API_KEY` and `JWT_SECRET`)
can be passed as environment variables too. See the
[CloudCLI docs](https://cloudcli.ai/docs).

### Volumes

| Path | Holds |
|---|---|
| `/workspaces` | Your projects. Bind-mount a host directory here. |
| `/home/dev` | Claude Code login, settings, MCP servers and session history (`~/.claude`, `~/.claude.json`), the UI's account database (`~/.cloudcli`), git/gh/ssh config, and the languages and tools you install (below). Keep it on a named volume so it survives image updates. |
| `/var/lib/docker` | Only with `DIND=1`: the inner Docker's images, containers and volumes. Keep it on a named volume. |

### Node.js and Python versions

Install whatever versions your projects need. They go into the home volume,
so they survive image updates:

```sh
fnm install 24 && fnm default 24   # your default `node`
uv python install 3.12             # Python versions for uv projects/venvs
uv tool install ruff               # CLI tools, on PATH in ~/.local/bin
npm install -g pnpm                # global npm packages
```

In the shell, fnm switches versions automatically when you `cd` into a project
with an `.nvmrc` or `.node-version` file. Claude Code's commands use your
`fnm default`.

Claude Code is told all of this through a system-wide
[`/etc/claude-code/CLAUDE.md`](etc/claude-code/CLAUDE.md), so sessions use fnm
and uv without having to work it out. It ships with the image; put your own
instructions in `~/.claude/CLAUDE.md` or a project's `CLAUDE.md` instead.

On first start, the container copies the image's Node.js 26 into the home
volume as your fnm default, so it stays the default when you install other
versions. While you keep that default, an image update with a different
Node.js moves it to a copy of the new one and deletes the old copy (unless
another `fnm alias` uses it); once you change it with `fnm default` (or
remove it with `fnm unalias default`), the container leaves it alone. The UI
server runs on the image's own copy, so switching versions can't break it.

Anything installed with `sudo apt-get install` goes into the image's system
directories and is gone after an update. To keep system packages, build your own
image on top of this one:

```dockerfile
FROM ghcr.io/cheziyi/claudecodeui:1
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
```

### Docker

Docker is installed but off by default. To let the container (and Claude)
build and run containers, pick one of two ways.

**Docker inside the container (recommended).** The container runs its own
Docker daemon. The agent's containers, images and build cache stay inside it,
apart from your own, and paths and ports work as they would on a normal
machine: `docker run -v "$PWD:/src"` mounts the project you're in, and a
published port is on `localhost` here. It needs a privileged container and a
volume for Docker's data, and a longer stop timeout so the inner Docker can
stop its own containers (each gets 10 seconds) before it's killed. In
`compose.yaml`, uncomment `DIND`, `privileged`, `stop_grace_period` and the
`docker` volume. With `docker run`, add:

```sh
--privileged --stop-timeout 30 -e DIND=1 -v claudecodeui-docker:/var/lib/docker
```

With the Quadlet unit, add the `dind.conf` drop-in, which sets all of that:

```sh
mkdir -p ~/.config/containers/systemd/claudecodeui.container.d
cp podman/optional/dind.conf ~/.config/containers/systemd/claudecodeui.container.d/
systemctl --user daemon-reload && systemctl --user restart claudecodeui
```

It also starts the container as root, which the daemon needs; the UI still
runs as `dev`, mapped to your host user. To turn it off again, delete the file
and run the last line.

Drop-ins need Podman 5.0 or newer. On Podman 4, copy the drop-in's settings
into the `[Container]` section of `claudecodeui.container` instead, replacing
its `User=` line.

A privileged container can reach the host's devices and kernel settings, so
it's not a security boundary against an agent that wants out. Under rootless
Podman it's still confined to your host user. The daemon's images and build
cache grow in the `claudecodeui-docker` volume; `docker system prune` from
inside the container frees them. Its log is in `/var/log/dockerd.log`.

Files that inner containers write to `/workspaces` belong to whichever user
they run as. Under rootless Podman, only `dev` maps to your host user, so a
file an inner container writes as root shows up on the host owned by one of
your subordinate uids. Run them with `--user "$(id -u):$(id -g)"`, or fix
ownership afterwards from the container's shell with
`sudo chown -R dev:dev /workspaces/myapp`.

**The host's Docker.** Mount its socket instead. Uncomment the socket line in
`compose.yaml`, or add this to `docker run`:

```sh
-v /var/run/docker.sock:/var/run/docker.sock
```

**This gives the agent root on the host.** Anything that can talk to the
Docker socket can start a privileged container with the host's filesystem
mounted. Only do it on a machine you'd let the agent administer.

On start, the container adds `dev` to the group that owns the socket, so
`docker` works without `sudo`. Where that's not enough, e.g. Docker Desktop's
socket belongs to `root:root` (never joined) or isn't writable by its group,
`sudo docker` works. A container started with `--user` can't change groups
itself; pass the socket's gid with `--group-add "$(stat -c %g /var/run/docker.sock)"`.

The containers it starts are the host's siblings, not children of this one:

- Bind-mount paths are resolved on the host, where `/workspaces/myapp` is
  `~/claudecodeui/workspaces/myapp` (or wherever you mounted it). From inside
  the container, `docker run -v "$PWD:/src"` mounts the wrong directory, or an
  empty new one. Use host paths or named volumes. `docker build .` is fine:
  the CLI uploads the build context.
- Published ports open on the host, not in this container, so reach them via
  the host's address rather than `localhost`.

With rootless Podman, mount your Podman socket instead, with the
`podman-socket.conf` drop-in:

```sh
systemctl --user enable --now podman.socket
mkdir -p ~/.config/containers/systemd/claudecodeui.container.d
cp podman/optional/podman-socket.conf ~/.config/containers/systemd/claudecodeui.container.d/
systemctl --user daemon-reload && systemctl --user restart claudecodeui
```

Only containers belonging to your host user are reachable that way, not the
whole system. Use one drop-in or the other, not both.

### GitHub access

From the UI's shell, run `gh auth login` once. The token is stored in the home
volume, and on the next start the container configures `git` to use it for
`https://` remotes. For SSH remotes, put a key in `~/.ssh` instead.

### Shell access from the host

The UI has a built-in shell. To open one from the host, use `-u dev` so files
you create aren't owned by root:

```sh
docker exec -it -u dev claudecodeui bash
```

### Running as a fixed user

If you'd rather not start the container as root (for example under rootless
Docker or Kubernetes), run it with `--user <uid>:<gid>`. The entrypoint then
skips the `PUID`/`PGID` remapping and uses `/home/dev` as the home directory
whatever the uid, so make sure both volumes are writable by that uid.

## Updating

```sh
docker compose pull && docker compose up -d
```

Your login, sessions and projects live in the volumes, so updating doesn't lose
them. Claude Code's built-in auto-updater is turned off because the image is the
update mechanism.

### Versions and tags

The image has its own [semantic version](https://semver.org), separate from
CloudCLI's and Claude Code's. It describes this packaging: paths, volumes,
environment variables, the user, the tools that come with it.

- **Major** (`2.0.0`): a breaking change for existing setups, e.g. a renamed
  path or volume, or a removed variable. Check the release notes before moving.
- **Minor** (`1.3.0`): new features that work with your existing setup.
- **Patch** (`1.2.1`): fixes.

The daily rebuilds update the newest release in place, picking up current
Debian packages along the way. They stay within the upstream majors that
release was published with (see [`upstream.env`](upstream.env)), so a new
CloudCLI, Claude Code, fnm or uv major arrives only with a release of this
image, and as a new major here if it breaks existing setups.

Only the newest release is rebuilt. Once `2.0.0` is out, `1` stops getting
updates; move to `2` after reading its release notes.

| Tag | Follows |
|---|---|
| `1` | the newest `1.x` release. Use this to auto-update without breaking changes. |
| `1.2` | the newest `1.2.x` release |
| `1.2.0` | exactly that release |
| `latest` | the newest release, including the next major |

To freeze an exact build, pin its digest (`…:1@sha256:…`). To see which
CloudCLI, Claude Code, fnm and uv a build contains:

```sh
docker inspect --format '{{json .Config.Labels}}' ghcr.io/cheziyi/claudecodeui:1
```

## Security

This container runs an AI agent that can execute arbitrary commands, with
passwordless `sudo` inside the container. Treat port 3001 like SSH access:

- Don't expose it to the internet directly. Use a VPN (e.g. Tailscale), or a
  reverse proxy with TLS and extra authentication.
- Only mount the directories you want the agent to be able to change.
- Never mount the Docker socket unless you understand that it gives root on the
  host (see [Docker](#docker)).

## Building locally

```sh
docker build -t claudecodeui .   # latest upstream versions
# Pin versions (CI resolves them from upstream.env):
docker build -t claudecodeui \
  --build-arg CLOUDCLI_VERSION=1.37.6 \
  --build-arg CLAUDE_CODE_VERSION=2.1.312 \
  --build-arg FNM_VERSION=1.39.0 \
  --build-arg UV_VERSION=0.13.6 .
```

## Releasing and publishing

To release, tag `main` with the new version and push the tag (or create a
GitHub release, which does the same):

```sh
git tag v1.2.0 && git push origin v1.2.0
```

`.github/workflows/build.yml` (*Build image*) then builds, smoke-tests and
publishes it to GHCR using the repository's built-in `GITHUB_TOKEN`. No secrets
are needed. Tags like `v1.3.0-rc.1` publish as a pre-release: only their exact
tag, never `1`, `1.3` or `latest`.

- **Pull requests**: every PR builds both architectures and smoke-tests the
  image, using the build cache so checks stay fast. Nothing is pushed. The job
  is named `build`, which is the check to require in branch protection.
- **Release tags**: publish that release. `1.2`, `1` and `latest` move only if
  it's the highest release in that line, so a patch to an older line can't take
  them backwards.
- **Daily** (04:17 UTC): rebuilds the newest release when an upstream
  version within its ranges changed, and skips otherwise.
- **Manual** (*Actions → Build image → Run workflow*, from `main`): rebuilds the
  latest release, or the version you enter, even if nothing upstream changed,
  e.g. to pick up security fixes.

Pushes to `main` don't publish: changes reach users with the next release.
Every run smoke-tests the amd64 build before the multi-arch build reuses its
layers, so the published image is the one that passed.

### Upstream majors

[`upstream.env`](upstream.env) sets which CloudCLI, Claude Code, fnm and uv
versions a release line accepts, as semver ranges (`^1` means any 1.x). Every
build installs the newest version inside each range: CloudCLI and Claude Code
up to their npm `latest` tag, fnm and uv from their published GitHub releases.
When a newer version is out that a range keeps out, the run notes it.

To adopt it, widen the range in a PR, and let the PR's smoke test and your own
testing decide the release: a new major of this image if it breaks existing
setups (changed settings or data, removed features), a minor otherwise.

## License

The files in this repository are MIT licensed. The image also contains
third-party software under its own licenses: CloudCLI UI is AGPL-3.0, and
Claude Code is subject to [Anthropic's terms](https://www.anthropic.com/legal/commercial-terms).
