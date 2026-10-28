# claudecodeui-docker

A ready-to-code Docker image with [CloudCLI UI](https://github.com/siteboon/claudecodeui)
(formerly Claude Code UI) and [Claude Code](https://docs.claude.com/en/docs/claude-code)
installed. Start the container, open the browser, log in to Claude, and start coding:
from your desktop, or from your phone.

```
ghcr.io/cheziyi/claudecodeui-docker:1
```

Built for `linux/amd64` and `linux/arm64`. Releases are versioned on their own
(see [Versions and tags](#versions-and-tags)), and the latest release is rebuilt
weekly when CloudCLI or Claude Code ships a new version.

## Quick start

```sh
mkdir -p ~/claudecodeui && cd ~/claudecodeui
curl -O https://raw.githubusercontent.com/cheziyi/claudecodeui-docker/main/compose.yaml
docker compose up -d
```

Or without Compose:

```sh
docker run -d --name claudecodeui -p 3001:3001 \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  -v ~/claudecodeui/workspaces:/workspaces \
  -v claudecodeui-home:/home/dev \
  ghcr.io/cheziyi/claudecodeui-docker:1
```

Either way, projects go in `~/claudecodeui/workspaces` and everything else in
the `claudecodeui-home` volume, so you can switch between Compose and
`docker run` without losing anything. The Podman setup below uses the same
folder and volume name, but Podman keeps its volumes separate from Docker's:
switching between Docker and Podman keeps your projects, not the home volume.
To bring it along, copy it across. Use the Podman unit's user namespace, or the
files land under a uid the container's `dev` user can't write to:

```sh
docker run --rm -v claudecodeui-home:/h debian:trixie-slim tar -C /h -c . \
  | podman run --rm -i --userns keep-id:uid=1000,gid=1000 --user 0:0 \
      -v claudecodeui-home:/h debian:trixie-slim tar -C /h -x
```

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

Projects go in `~/claudecodeui/workspaces`. To pick up new weekly builds, run
`podman auto-update`, or enable `systemctl --user enable --now podman-auto-update.timer`.

Without systemd, the equivalent one-off command is:

```sh
mkdir -p ~/claudecodeui/workspaces
podman run -d --name claudecodeui -p 3001:3001 \
  --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
  -v ~/claudecodeui/workspaces:/workspaces:Z \
  -v claudecodeui-home:/home/dev \
  ghcr.io/cheziyi/claudecodeui-docker:1
```

Under rootless Podman, `--userns keep-id` maps your host user to the
container's `dev` user, so files in the workspace stay owned by you. There's no
need for `PUID`/`PGID`.

Then:

1. Open <http://localhost:3001> and create the UI's admin account. The first
   visitor gets to create it, so do this right away.
2. Sign in to Claude: open the **Shell** tab, run `claude`, and follow the login
   link. Or set `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or
   `ANTHROPIC_API_KEY` instead (see `compose.yaml`).
3. Create a project under `/workspaces`, or clone one there from the shell, then
   start a chat.

Claude Code's tools are disabled by default in the UI. Enable the ones you want
under the gear icon in the sidebar.

## What's inside

- CloudCLI UI and Claude Code, at the versions recorded in the image labels
- Debian 13 (trixie) with `build-essential` and Python 3
- [fnm](https://github.com/Schniz/fnm) for Node.js versions and
  [uv](https://docs.astral.sh/uv/) for Python versions, packages and tools.
  Node.js 26 (LTS) is available out of the box.
- `git`, `git-lfs`, `gh` (GitHub CLI), `openssh-client`
- `ripgrep`, `fd`, `jq`, `tree`, `htop`, `vim`, `nano`, `curl`, `wget`, `zip`/`unzip`
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

The CloudCLI server's other settings (for example `API_KEY` and `JWT_SECRET`)
can be passed as environment variables too. See the
[CloudCLI docs](https://cloudcli.ai/docs).

### Volumes

| Path | Holds |
|---|---|
| `/workspaces` | Your projects. Bind-mount a host directory here. |
| `/home/dev` | Claude Code login, settings, MCP servers and session history (`~/.claude`, `~/.claude.json`), the UI's account database (`~/.cloudcli`), git/gh/ssh config, and the languages and tools you install (below). Keep it on a named volume so it survives image updates. |

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

Until you set a default, `node` is the image's Node.js 26. The UI server always
runs on that copy, so switching versions can't break it.

Anything installed with `sudo apt-get install` goes into the image's system
directories and is gone after an update. To keep system packages, build your own
image on top of this one:

```dockerfile
FROM ghcr.io/cheziyi/claudecodeui-docker:1
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
```

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

Each tag points at the newest build of its line, so every tag except a digest
gets the weekly upstream and security updates:

| Tag | Follows |
|---|---|
| `1` | the newest `1.x` release. Use this to auto-update without breaking changes. |
| `1.2` | the newest `1.2.x` release |
| `1.2.0` | exactly that release |
| `latest` | the newest release, including the next major |

To freeze an exact build, pin its digest (`…:1@sha256:…`). To see which
CloudCLI and Claude Code a build contains:

```sh
docker inspect --format '{{json .Config.Labels}}' ghcr.io/cheziyi/claudecodeui-docker:1
```

## Security

This container runs an AI agent that can execute arbitrary commands, with
passwordless `sudo` inside the container. Treat port 3001 like SSH access:

- Don't expose it to the internet directly. Use a VPN (e.g. Tailscale), or a
  reverse proxy with TLS and extra authentication.
- Only mount the directories you want the agent to be able to change.
- Never mount the Docker socket unless you understand that it gives root on the host.

## Building locally

```sh
docker build -t claudecodeui .
# Pin versions:
docker build -t claudecodeui \
  --build-arg CLOUDCLI_VERSION=1.37.6 \
  --build-arg CLAUDE_CODE_VERSION=2.1.312 .
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
- **Weekly** (Mondays 04:17 UTC): rebuilds the latest release when CloudCLI or
  Claude Code has a new version, and skips otherwise. Older release lines aren't
  rebuilt.
- **Manual** (*Actions → Build image → Run workflow*, from `main`): rebuilds the
  latest release, or the version you enter, even if nothing upstream changed,
  e.g. to pick up security fixes.

Pushes to `main` don't publish: changes reach users with the next release.

Every run first builds amd64 and smoke-tests it: it starts the container with a
non-default `PUID`, waits for the healthcheck, and runs `node`, `fnm`, `uv`,
`claude` and `gh` as `dev`. The multi-arch build then reuses those tested amd64
layers, so the published image is the one that passed. Builds that publish
don't use the build cache, so they always get current Debian packages, the base
image and the latest fnm and uv.

## License

The files in this repository are MIT licensed. The image also contains
third-party software under its own licenses: CloudCLI UI is AGPL-3.0, and
Claude Code is subject to [Anthropic's terms](https://www.anthropic.com/legal/commercial-terms).
