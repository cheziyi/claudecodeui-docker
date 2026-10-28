#!/bin/bash
# Prepares the runtime user, then runs the command as that user.
#
# Started as root (the default): remaps the "node" user to PUID/PGID so files
# written to bind mounts belong to the host user, fixes ownership of the
# persisted home, and drops privileges with gosu.
# Started as non-root (`--user`): skips all of that and runs the command as-is.
set -euo pipefail

home=/home/node

as_node() {
    if [ "$(id -u)" = "0" ]; then
        gosu node "$@"
    else
        "$@"
    fi
}

if [ "$(id -u)" = "0" ]; then
    puid="${PUID:-1000}"
    pgid="${PGID:-1000}"

    if [ "$(id -g node)" != "$pgid" ]; then
        groupmod -o -g "$pgid" node
    fi
    if [ "$(id -u node)" != "$puid" ]; then
        usermod -o -u "$puid" node
    fi

    mkdir -p "$home/.claude" "$home/.cloudcli" "$home/.npm-global" /workspace

    # The home volume may hold files from an earlier PUID/PGID; re-own it then.
    # (usermod re-owns the home's uid but not its gid, so compare both.)
    if [ "$(stat -c %u:%g "$home/.claude")" != "$puid:$pgid" ]; then
        chown -R "$puid:$pgid" "$home"
    fi
    # Only claim the workspace root when Docker created it (root-owned); never
    # touch ownership of a user's existing project files.
    if [ "$(stat -c %u /workspace)" = "0" ]; then
        chown "$puid:$pgid" /workspace
    fi
fi

if [ -n "${GIT_USER_NAME:-}" ]; then
    as_node git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    as_node git config --global user.email "$GIT_USER_EMAIL"
fi
# Let `git` use gh's stored token for https remotes once `gh auth login` ran.
if as_node gh auth status >/dev/null 2>&1; then
    as_node gh auth setup-git >/dev/null 2>&1 || true
fi

if [ "$(id -u)" = "0" ]; then
    exec gosu node "$@"
fi
exec "$@"
