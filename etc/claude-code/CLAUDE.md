# Container environment

You are running inside the claudecodeui-docker container: Debian 13 (trixie),
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

Other tools available: `git`, `gh`, `rg`, `fd`, `jq`, `build-essential`.
