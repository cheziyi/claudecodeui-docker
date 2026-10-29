#!/bin/bash
# Prepares the runtime user, then runs the command as that user.
#
# Started as root (the default): remaps the "dev" user to PUID/PGID so files
# written to bind mounts belong to the host user, fixes ownership of the
# persisted home, and drops privileges with gosu. With DIND=1 on a privileged
# container, also runs a Docker daemon for the command's lifetime.
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

    # Docker in Docker (opt-in with DIND=1 on a privileged container, see the
    # README): run dockerd here, so the agent's containers, images and paths
    # stay inside this container. Its socket is then handled like a mounted
    # one below. Never blocks the start: the UI comes up even if dockerd fails.
    sock=/var/run/docker.sock
    case "${DIND:-}" in
    1 | true | yes)
        if grep -qE ' /(var/)?run/docker\.sock ' /proc/self/mountinfo; then
            echo "cloudcli-entrypoint: DIND is set but a Docker socket is mounted; using the mounted one" >&2
        elif ! (( 16#$(awk '/^CapEff:/ { print $2 }' /proc/self/status) >> 21 & 1 )); then
            # No CAP_SYS_ADMIN: not privileged, so dockerd can't mount or
            # manage cgroups.
            echo "cloudcli-entrypoint: DIND needs a privileged container (--privileged); not starting dockerd" >&2
        else
            if ! grep -q ' /var/lib/docker ' /proc/self/mountinfo; then
                echo "cloudcli-entrypoint: /var/lib/docker is not a volume; images won't survive an update and storage may be slow" >&2
            fi
            # cgroup v2 nesting, as in Docker's own dind script: move every
            # process out of the root cgroup so dockerd can delegate controllers
            # to the containers it starts.
            if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
                mkdir -p /sys/fs/cgroup/init
                xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs || true
                sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers \
                    > /sys/fs/cgroup/cgroup.subtree_control || true
            fi
            mount --make-rshared / || true
            # A restarted container keeps the last run's runtime state, whose
            # pid files can name unrelated processes now. The daemon's data is
            # in /var/lib/docker.
            rm -rf "$sock" /var/run/docker.pid /var/run/docker /var/run/containerd
            dockerd --group docker > /var/log/dockerd.log 2>&1 &
            dockerd_pid=$!
            # A stop before the command starts still stops dockerd (below).
            trap 'stopping=1' TERM INT
            # Even if dockerd is slow to create its socket for the check below.
            usermod -aG docker dev
            for _ in $(seq 60); do
                docker info >/dev/null 2>&1 && break
                kill -0 "$dockerd_pid" 2>/dev/null || break
                sleep 0.5
            done
            if ! docker info >/dev/null 2>&1; then
                echo "cloudcli-entrypoint: dockerd did not start; see /var/log/dockerd.log:" >&2
                tail -n 20 /var/log/dockerd.log >&2 || true
            fi
        fi
        ;;
    esac

    # A mounted Docker socket (opt-in, see the README): let dev use it by
    # joining the group that owns it, under any name, or a docker-host group
    # created for that gid. The host's docker group has no fixed gid. Never the
    # root group (e.g. Docker Desktop's root:root socket): `sudo docker` covers
    # that without giving every dev process root's group.
    if [ -S "$sock" ] && sock_gid="$(stat -c %g "$sock")" && [ "$sock_gid" != 0 ]; then
        sock_group="$(getent group "$sock_gid" | cut -d: -f1 || true)"
        if [ -z "$sock_group" ]; then
            sock_group=docker-host
            # Kept across restarts; the host's gid may have changed since.
            if getent group "$sock_group" >/dev/null; then
                groupmod -g "$sock_gid" "$sock_group"
            else
                groupadd -g "$sock_gid" "$sock_group"
            fi
        elif [ "$sock_group" != docker-host ] && getent group docker-host >/dev/null; then
            # An earlier start's group for a gid the socket no longer has.
            groupdel docker-host
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
else
    case "${DIND:-}" in
    1 | true | yes) echo "cloudcli-entrypoint: DIND needs the container to start as root (no --user); not starting dockerd" >&2 ;;
    esac
    # A --user uid with no passwd entry gets HOME=/ from Docker; keep git,
    # Claude and the UI's state in the persisted home instead.
    getent passwd "$(id -u)" >/dev/null || export HOME="$home"
fi

# The image's Node.js becomes the home's fnm default, so `node` stays on it
# after a first `fnm install` (fnm would make that the default). A copy, not a
# link: the home volume outlives the image. It leaves out the server's packages
# but keeps the image's npmrc, so `npm install -g` still goes to ~/.npm-global.
# A marker records the copy: while the default still points at it, an image
# with a different Node.js moves the default to a copy of that one and deletes
# the old copy, unless another alias uses it. A default the user changed or
# removed is left alone. Never blocks the start if it fails.
fnm_dir="$home/.local/share/fnm"
alias="$fnm_dir/aliases/default"
marker="$fnm_dir/.cloudcli-default"
node_dir="$(readlink -f /opt/node)"
version="$(basename "$(dirname "$node_dir")")"
dest="$fnm_dir/node-versions/$version/installation"
seeded="$(cat "$marker" 2>/dev/null || true)"
seed_default() {
    if [ -z "$seeded" ]; then
        [ ! -e "$alias" ] && [ ! -L "$alias" ]
    else
        [ "$(readlink "$alias" || true)" = "$seeded" ] && [ "$seeded" != "$dest" ]
    fi
}
if seed_default; then
    if ! as_dev bash -euo pipefail -c '
        node_dir="$1" dest="$2" alias="$3" marker="$4" old="$5"
        if [ ! -d "$dest" ]; then
            tmp="$dest.tmp"
            rm -rf "$tmp"
            mkdir -p "$tmp/lib/node_modules"
            tar -C "$node_dir" --exclude=./lib/node_modules -cf - . | tar -C "$tmp" -xf -
            cp -a "$node_dir/lib/node_modules/npm" "$tmp/lib/node_modules/"
            # Drop bin links to the excluded packages (claude, cloudcli).
            find "$tmp/bin" -xtype l -delete
            # Marks a copy made here, unlike a version installed with fnm.
            touch "$tmp/.cloudcli-copy"
            mv "$tmp" "$dest"
        fi
        mkdir -p "$(dirname "$alias")"
        ln -sfn "$dest" "$alias"
        echo "$dest" > "$marker"
        # The copy this replaces, if made here and no other alias points at it.
        if [ -n "$old" ] && [ "$old" != "$dest" ] && [ -f "$old/.cloudcli-copy" ]; then
            for a in "$(dirname "$alias")"/*; do
                [ "$(readlink "$a" || true)" != "$old" ] || exit 0
            done
            rm -rf "$old"
            rmdir "$(dirname "$old")" 2>/dev/null || true
        fi
    ' bash "$node_dir" "$dest" "$alias" "$marker" "$seeded"; then
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

if [ -n "${dockerd_pid:-}" ]; then
    # Stay up to stop dockerd after the command: tini only signals its direct
    # child, and a dockerd killed at the stop timeout leaves its containers
    # uncleanly stopped.
    status=0
    if [ -z "${stopping:-}" ]; then
        gosu dev "$@" &
        cmd_pid=$!
        trap 'kill -TERM "$cmd_pid" 2>/dev/null || true' TERM INT
        # A stop that arrived while the command was starting.
        [ -z "${stopping:-}" ] || kill -TERM "$cmd_pid" 2>/dev/null || true
        # wait returns early when the trap runs; wait again until it has exited.
        while :; do
            wait "$cmd_pid" && status=0 || status=$?
            kill -0 "$cmd_pid" 2>/dev/null || break
        done
    fi
    kill -TERM "$dockerd_pid" 2>/dev/null || true
    wait "$dockerd_pid" || true
    exit "$status"
fi
if [ "$(id -u)" = "0" ]; then
    exec gosu dev "$@"
fi
exec "$@"
