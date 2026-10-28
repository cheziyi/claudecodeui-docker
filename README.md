# claudecodeui-docker

A ready-to-code Docker image with [CloudCLI UI](https://github.com/siteboon/claudecodeui)
(formerly Claude Code UI) and [Claude Code](https://docs.claude.com/en/docs/claude-code)
installed. Start the container, open the browser, log in to Claude, and start coding:
from your desktop, or from your phone.

```
ghcr.io/cheziyi/claudecodeui-docker:latest
```

Built for `linux/amd64` and `linux/arm64`, and rebuilt weekly when either upstream
releases a new version.

## Quick start

```sh
curl -O https://raw.githubusercontent.com/cheziyi/claudecodeui-docker/main/compose.yaml
docker compose up -d
```

Or without Compose:

```sh
docker run -d --name claudecodeui -p 3001:3001 \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  -v "$PWD/workspace:/workspace" \
  -v claudecodeui-home:/home/node \
  ghcr.io/cheziyi/claudecodeui-docker:latest
```

### Podman

[`podman/`](podman/) has a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
unit, the Podman equivalent of `compose.yaml`. systemd runs the container,
restarts it on failure and starts it at boot. Tested with Podman 4.9.

```sh
mkdir -p ~/.config/containers/systemd ~/claudecodeui/workspace
cp podman/claudecodeui.container podman/claudecodeui-home.volume ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start claudecodeui
loginctl enable-linger "$USER"   # keep it running after you log out
```

Projects go in `~/claudecodeui/workspace`. To pick up new weekly builds, run
`podman auto-update`, or enable `systemctl --user enable --now podman-auto-update.timer`.

Without systemd, the equivalent one-off command is:

```sh
mkdir -p ~/claudecodeui/workspace
podman run -d --name claudecodeui -p 3001:3001 \
  --userns keep-id:uid=1000,gid=1000 --user 1000:1000 \
  -v ~/claudecodeui/workspace:/workspace:Z \
  -v claudecodeui-home:/home/node \
  ghcr.io/cheziyi/claudecodeui-docker:latest
```

Under rootless Podman, `--userns keep-id` maps your host user to the
container's `node` user, so files in the workspace stay owned by you. There's no
need for `PUID`/`PGID`.

Then:

1. Open <http://localhost:3001> and create the UI's admin account. The first
   visitor gets to create it, so do this right away.
2. Sign in to Claude: open the **Shell** tab, run `claude`, and follow the login
   link. Or set `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or
   `ANTHROPIC_API_KEY` instead (see `compose.yaml`).
3. Create a project under `/workspace`, or clone one there from the shell, then
   start a chat.

Claude Code's tools are disabled by default in the UI. Enable the ones you want
under the gear icon in the sidebar.

## What's inside

- CloudCLI UI and Claude Code, both pinned to the versions in the image tag
- Node.js 22, Python 3 (with `venv`/`pip`), and `build-essential`
- `git`, `git-lfs`, `gh` (GitHub CLI), `openssh-client`
- `ripgrep`, `fd`, `jq`, `tree`, `htop`, `vim`, `nano`, `curl`, `wget`, `zip`/`unzip`
- Passwordless `sudo`, so you (or Claude) can `sudo apt-get install` anything else
- `tini` as the init process, plus a `/health` healthcheck

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PUID` / `PGID` | `1000` | uid/gid the server runs as. Set them to your host user's so files in `/workspace` belong to you. |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | – | Sets `git config --global user.name` / `user.email` at startup. |
| `CLAUDE_CODE_OAUTH_TOKEN` | – | Claude subscription token from `claude setup-token`. Lets you skip the interactive login. |
| `ANTHROPIC_API_KEY` | – | Use API billing instead of a subscription. |
| `SERVER_PORT` | `3001` | Port the UI listens on inside the container. |
| `WORKSPACES_ROOT` | `/workspace` | The UI only opens projects under this path. |
| `TZ` | `Etc/UTC` | Container time zone. |

The CloudCLI server's other settings (for example `API_KEY` and `JWT_SECRET`)
can be passed as environment variables too. See the
[CloudCLI docs](https://cloudcli.ai/docs).

### Volumes

| Path | Holds |
|---|---|
| `/workspace` | Your projects. Bind-mount a host directory here. |
| `/home/node` | Claude Code login, settings, MCP servers and session history (`~/.claude`, `~/.claude.json`), the UI's account database (`~/.cloudcli`), git/gh/ssh config, user-level `npm install -g` packages. Keep it on a named volume so it survives image updates. |

### GitHub access

From the UI's shell, run `gh auth login` once. The token is stored in the home
volume, and the container configures `git` to use it for `https://` remotes
on every start. For SSH remotes, put a key in `~/.ssh` instead.

### Shell access from the host

The UI has a built-in shell. To open one from the host, use `-u node` so files
you create aren't owned by root:

```sh
docker exec -it -u node claudecodeui bash
```

### Running as a fixed user

If you'd rather not start the container as root (for example under rootless
Docker or Kubernetes), run it with `--user <uid>:<gid>`. The entrypoint then
skips the `PUID`/`PGID` remapping, so make sure the volumes are writable by
that uid.

## Updating

```sh
docker compose pull && docker compose up -d
```

Your login, sessions and projects live in the volumes, so updating doesn't lose
them. Claude Code's built-in auto-updater is turned off because the image is the
update mechanism.

Tags:

- `latest`: newest build
- `<cloudcli>-claude<claude-code>`, e.g. `1.37.6-claude2.1.312`: a specific pair, for pinning
- `<cloudcli>`, e.g. `1.37.6`: newest build of that CloudCLI release

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

## Publishing

`.github/workflows/publish.yml` builds multi-arch images and pushes them to
GHCR using the repository's built-in `GITHUB_TOKEN`. No secrets are needed.

- **Weekly** (Mondays 04:17 UTC): looks up the latest CloudCLI and Claude Code on
  npm, and skips the build if that pair is already published.
- **Manual** (*Actions → Publish image → Run workflow*): always rebuilds, e.g. to
  pick up base-image security fixes.
- **Push to `main`** that changes the image: rebuilds and publishes.
- **Pull requests**: build only, no push.

After the first publish, set the package to public once: *your profile →
Packages → claudecodeui-docker → Package settings → Change visibility*.

## License

The files in this repository are MIT licensed. The image also contains
third-party software under its own licenses: CloudCLI UI is AGPL-3.0, and
Claude Code is subject to [Anthropic's terms](https://www.anthropic.com/legal/commercial-terms).
