#!/usr/bin/env bash
# Writes the upstream versions to build (cloudcli, claude, fnm, uv) to
# $GITHUB_OUTPUT.
#
# resolve-versions.sh [release]: if versions.env pins that release, uses its
# versions as they are, so a release builds exactly what its release commit
# names. Otherwise picks the newest version inside each range in upstream.env.
# Needs GH_TOKEN for that.
set -euo pipefail
# A failed lookup inside $(...) fails the script, instead of leaving no versions
# and a misleading "no release matches" error.
shopt -s inherit_errexit

if [ -n "${1:-}" ] && [ -f versions.env ] && [ "$(sed -n 's/^RELEASE=//p' versions.env)" = "$1" ]; then
  # shellcheck source=/dev/null
  . ./versions.env
  # shellcheck disable=SC2153 # set by versions.env
  {
    echo "cloudcli=$CLOUDCLI"
    echo "claude=$CLAUDE_CODE"
    echo "fnm=$FNM"
    echo "uv=$UV"
  } >> "$GITHUB_OUTPUT"
  {
    echo "Pinned by versions.env for $1:"
    echo "- CloudCLI $CLOUDCLI"
    echo "- Claude Code $CLAUDE_CODE"
    echo "- fnm $FNM"
    echo "- uv $UV"
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# shellcheck source=/dev/null
. ./upstream.env
npm install --prefix "$RUNNER_TEMP/semver" --no-audit --no-fund --loglevel=error semver@7.7.2
semver="$RUNNER_TEMP/semver/node_modules/.bin/semver"
# Stable versions matching a range, ascending; prints nothing if none.
matching() { "$semver" -r "$1" "${@:2}" || true; }
# Up to the `latest` dist-tag, like `npm install`: a package can publish ahead
# of it.
npm_versions() {
  local info latest
  info="$(npm view "$1" dist-tags.latest versions --json)"
  latest="$(jq -r '.["dist-tags.latest"]' <<<"$info")"
  # shellcheck disable=SC2046 # one version per word
  matching "<=$latest" $(jq -r '.versions[]' <<<"$info")
}
# gh_versions <repo> <assets...>: published releases that have every asset the
# Dockerfile downloads. A tag can exist hours before its release, and a release
# can be published before its assets upload.
gh_versions() {
  local repo="$1" tags
  shift
  tags="$(gh api --paginate "repos/$repo/releases?per_page=100" | jq -r --args '.[]
    | select((.draft or .prerelease) | not)
    | select($ARGS.positional - [.assets[] | select(.state == "uploaded") | .name] == [])
    | .tag_name' "$@")"
  # shellcheck disable=SC2086 # one version per word
  matching '*' $tags
}

# resolve <name> <output> <range> <versions...>: picks the newest version in the
# range, and notes a newer one the range keeps out. The versions come sorted, so
# the last one is the newest.
resolve() {
  local name="$1" output="$2" range="$3" pick
  shift 3
  pick="$(matching "$range" "$@" | tail -1)"
  if [ -z "$pick" ]; then
    echo "::error::No $name release matches $range in upstream.env"
    exit 1
  fi
  if [ "${!#}" != "$pick" ]; then
    echo "::notice::$name ${!#} is out but outside $range; staying on $pick. Widen the range in upstream.env to adopt it."
  fi
  echo "$output=$pick" >> "$GITHUB_OUTPUT"
  echo "- $name $pick (\`$range\`)" >> "$GITHUB_STEP_SUMMARY"
}

cloudcli="$(npm_versions @cloudcli-ai/cloudcli)"
claude="$(npm_versions @anthropic-ai/claude-code)"
fnm="$(gh_versions Schniz/fnm fnm-linux.zip fnm-arm64.zip)"
uv="$(gh_versions astral-sh/uv uv-{x86_64,aarch64}-unknown-linux-gnu.tar.gz{,.sha256})"
# shellcheck disable=SC2086 # one version per word
{
  resolve CloudCLI cloudcli "$CLOUDCLI_RANGE" $cloudcli
  resolve "Claude Code" claude "$CLAUDE_CODE_RANGE" $claude
  resolve fnm fnm "$FNM_RANGE" $fnm
  resolve uv uv "$UV_RANGE" $uv
}
