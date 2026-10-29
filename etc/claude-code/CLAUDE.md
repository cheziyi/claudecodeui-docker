# Container environment

You are running inside the claudecodeui container: Debian 13 (trixie),
user `dev` with passwordless `sudo`, projects under `/workspaces`.

## Node.js: fnm

Node.js versions are managed with **fnm**. Don't install nvm, volta or n, and
don't install Node.js with apt.

- `fnm list` shows installed versions; `fnm default` is what plain `node` runs.
- Your shell commands don't switch versions on `cd`. In a project with an
  `.nvmrc` or `.node-version` file, run `fnm install` once (it reads the file),
  then run Node commands through the project's version:
  `fnm exec -- npm test`, or `eval "$(fnm env)" && fnm use && npm test` within
  one command.
- `fnm install <version>` / `fnm default <version>` add or change versions.
  Ask before changing the default; the user relies on it.
- `/opt/node` is the Node.js that runs the CloudCLI UI server. Never modify it
  or install packages into it.
- npm 11 skips dependency install scripts unless they're allowed. If a package
  needs its script (native modules, binaries), use
  `npm install -g --allow-scripts=<pkg> <pkg>` for global installs, or the
  `allowScripts` field in the project's `package.json`.

## Python: uv

Python is managed with **uv**. The system `python3` has no pip; don't use pip
or install Python packages with apt.

- Projects: `uv sync`, `uv add <pkg>`, `uv run <cmd>`.
- Plain virtualenvs: `uv venv`, then `uv pip install <pkg>`.
- Python versions: `uv python install 3.12`; uv also fetches them on demand.
- CLI tools: `uv tool install <tool>` (on PATH in `~/.local/bin`), or
  `uvx <tool>` for a one-off run.

## What persists

`/home/dev` and `/workspaces` survive image updates, so anything installed with
fnm, uv, `uv tool`, or `npm install -g` persists. Packages installed with
`sudo apt-get install` are lost on the next image update; that's fine for
something temporary, but tell the user when they'll need it permanently.

Other tools available: `git`, `gh`, `rg`, `fd`, `jq`, `rsync`, `build-essential`,
`pkg-config`, and for debugging `ip`/`ss`, `ping`, `dig`, `nc`, `lsof`, `strace`.

## Docker

The `docker` CLI (with `compose` and `buildx`) is installed. It works only if
the user enabled Docker; if `docker info` fails, say so rather than trying to
install or start a daemon. There are two setups. If
`docker info --format '{{.Name}}'` prints this container's `hostname`, the
daemon runs inside this container:

- Paths and ports behave normally: `-v "$PWD:/src"` mounts what you expect,
  and published ports are on `localhost` here.
- Files an inner container writes to a bind mount belong to the user it runs
  as. When it writes into the user's projects, run it with
  `--user "$(id -u):$(id -g)"`, or `sudo chown` the files back to `dev`
  afterwards; root-owned files there may not be writable by the user on the
  host.
- Its containers, images and volumes belong to this container. Still ask
  before removing ones you didn't create; the user may have made them.

Otherwise it's the host's Docker or Podman, and containers you start run on
the host:

- Bind-mount paths are host paths. `/workspaces` is a different directory on
  the host, so `-v "$PWD:/src"` won't mount what you expect. Prefer named
  volumes, `docker cp`, or a build context (which the CLI uploads, so
  `docker build .` is fine).
- Published ports are on the host, not on `localhost` here.
- You're acting on the user's host: don't stop, remove or prune containers,
  images or volumes you didn't create without asking.
