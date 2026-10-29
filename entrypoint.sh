#!/bin/bash
# Prepares the runtime user, then runs the command as that user.
#
# Started as root (the default): remaps the "dev" user to PUID/PGID so files
# written to bind mounts belong to the host user, fixes ownership of the
# persisted home, and drops privileges with gosu.
# Started as non-root (`--user`): skips all of that and runs the command as-is,
# with HOME pointed at the persisted home.
set -euo pipefail

home=/home/dev

as_dev() {
    if [ "$(id -u)" = "0" ]; then
        gosu dev "$@"
    else
        "$@"
    fi
}

if [ "$(id -u)" = "0" ]; then
    puid="${PUID:-1000}"
    pgid="${PGID:-1000}"

    if [ "$(id -g dev)" != "$pgid" ]; then
        groupmod -o -g "$pgid" dev
    fi
    if [ "$(id -u dev)" != "$puid" ]; then
        usermod -o -u "$puid" dev
    fi

    # A mounted Docker socket (opt-in, see the README): let dev use it by
    # joining the group that owns it, under any name, or a docker-host group
    # created for that gid. The host's docker group has no fixed gid.
    sock=/var/run/docker.sock
    if [ -S "$sock" ]; then
        sock_gid="$(stat -c %g "$sock")"
        sock_group="$(getent group "$sock_gid" | cut -d: -f1 || true)"
        if [ -z "$sock_group" ]; then
            sock_group=docker-host
            # Kept across restarts; the host's gid may have changed since.
            if getent group "$sock_group" >/dev/null; then
                groupmod -g "$sock_gid" "$sock_group"
            else
                groupadd -g "$sock_gid" "$sock_group"
            fi
        fi
        usermod -aG "$sock_group" dev
    fi

    # Create missing state directories already owned by dev, so a volume that
    # lacks one doesn't end up with a root-owned directory.
    for dir in "$home" "$home/.claude" "$home/.cloudcli" "$home/.npm-global"; do
        [ -d "$dir" ] || install -d -o "$puid" -g "$pgid" "$dir"
    done
    mkdir -p /workspaces

    # The home volume may hold files from an earlier PUID/PGID; re-own it then.
    # (usermod re-owns the home's uid but not its gid, so compare both.)
    if [ "$(stat -c %u:%g "$home" "$home/.claude" | sort -u)" != "$puid:$pgid" ]; then
        chown -R "$puid:$pgid" "$home"
    fi
    # Only claim the workspace root when Docker created it (root-owned) or it
    # is still empty (e.g. the image's own directory under another PUID);
    # never touch ownership of a user's existing project files.
    if [ "$(stat -c %u /workspaces)" = "0" ] || [ -z "$(ls -A /workspaces)" ]; then
        chown "$puid:$pgid" /workspaces
    fi
elif ! getent passwd "$(id -u)" >/dev/null; then
    # A --user uid with no passwd entry gets HOME=/ from Docker; keep git,
    # Claude and the UI's state in the persisted home instead.
    export HOME="$home"
fi

# A home with no fnm default gets the image's Node.js as its own default, so
# `node` stays on it after a first `fnm install` (fnm would make that the
# default). A clean copy without the server's packages and npmrc, not a link:
# the home volume outlives the image. Never blocks the start if it fails.
fnm_dir="$home/.local/share/fnm"
if [ ! -L "$fnm_dir/aliases/default" ]; then
    node_dir="$(readlink -f /opt/node)"
    version="$(basename "$(dirname "$node_dir")")"
    if ! as_dev bash -euo pipefail -c '
        node_dir="$1" dest="$2" alias="$3"
        if [ ! -d "$dest" ]; then
            tmp="$dest.tmp"
            rm -rf "$tmp"
            mkdir -p "$tmp/lib/node_modules"
            tar -C "$node_dir" --exclude=./etc --exclude=./lib/node_modules -cf - . | tar -C "$tmp" -xf -
            cp -a "$node_dir/lib/node_modules/npm" "$tmp/lib/node_modules/"
            # Drop bin links to the excluded packages (claude, cloudcli).
            find "$tmp/bin" -xtype l -delete
            mv "$tmp" "$dest"
        fi
        mkdir -p "$(dirname "$alias")"
        ln -sfn "$dest" "$alias"
    ' bash "$node_dir" "$fnm_dir/node-versions/$version/installation" "$fnm_dir/aliases/default"; then
        echo "cloudcli-entrypoint: could not set up Node.js $version as the fnm default" >&2
    fi
fi

if [ -n "${GIT_USER_NAME:-}" ]; then
    as_dev git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    as_dev git config --global user.email "$GIT_USER_EMAIL"
fi
# Let `git` use gh's stored token for https remotes once `gh auth login` ran.
# The helper persists in ~/.gitconfig, so only set it up while it's missing;
# `gh auth token` reads the stored token without a network call.
if ! as_dev git config --global --get-all credential.https://github.com.helper >/dev/null \
    && as_dev gh auth token >/dev/null 2>&1; then
    as_dev gh auth setup-git >/dev/null 2>&1 || true
fi

if [ "$(id -u)" = "0" ]; then
    exec gosu dev "$@"
fi
exec "$@"
