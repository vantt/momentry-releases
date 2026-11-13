#!/bin/sh
# Smoke test of one momentry release on Linux or macOS, run by .github/workflows/smoke.yml on the assets exactly as
# they were uploaded to the (draft) release. Usage: sh smoke.sh <tag> <assets dir> [<previous release dir>]
# The previous release dir, when it holds TAG and install.sh (the workflow fills it from the latest published
# release), adds the update check; without it the check is skipped.
# Needs only what a GitHub runner has: sh, tar, jq, perl, sha256sum or shasum, git. Every check runs in a throwaway
# HOME; nothing here reads a real user's files, and no token is in the environment.
set -eu

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
is_tag() {
  case "$1" in *[!0-9A-Za-z.v-]*|'') return 1 ;; esac
  printf '%s\n' "$1" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?'
}

[ $# -eq 2 ] || [ $# -eq 3 ] || fail "usage: sh smoke.sh <tag> <assets dir> [<previous release dir>]"
TAG=$1
is_tag "$TAG" || fail "not a release tag: $TAG"
ASSETS=$(cd "$2" && pwd) || fail "no assets dir: $2"
PREV_DIR=${3:-}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' HUP INT TERM

case "$(uname -s)" in Linux) GOOS=linux ;; Darwin) GOOS=darwin ;; *) fail "unsupported OS: $(uname -s)" ;; esac
case "$(uname -m)" in x86_64|amd64) GOARCH=amd64 ;; aarch64|arm64) GOARCH=arm64 ;; *) fail "unsupported CPU: $(uname -m)" ;; esac
ARCHIVE="momentry-$TAG-$GOOS-$GOARCH.tar.gz"

if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$@"; }; else sha256() { shasum -a 256 "$@"; }; fi

# Paths and hash of a version dir, one line per entry, to prove a step left it untouched.
tree_digest() { (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
  if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(sha256 < "$f" | cut -d' ' -f1)"; else printf '%s\n' "$f"; fi
done) | sha256 | cut -d' ' -f1; }

# A fresh HOME with the installer's default layout; doctor needs a claude CLI on PATH, so a stub stands in for it
# (the smoke tests momentry, not Claude Code; no model is ever called).
use_home() {
  export HOME="$WORK/$1"
  unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME MOMENTRY_HOME MOMENTRY_INSTALL_DIR MOMENTRY_RELEASE_BASE
  export MOMENTRY_NO_MODIFY_PATH=1
  mkdir -p "$HOME/.claude" "$WORK/stub"
  printf '#!/bin/sh\necho "2.1.0 (Claude Code)"\n' > "$WORK/stub/claude"; chmod +x "$WORK/stub/claude"
  case ":$PATH:" in *":$WORK/stub:"*) ;; *) PATH="$WORK/stub:$PATH" ;; esac
  MDIR="$HOME/.local/share/momentry"
  BIN="$HOME/.local/bin/momentry"
}

expect_version() {
  got=$("$BIN" --version) || fail "momentry --version failed"
  [ "$got" = "momentry ${1#v}" ] || fail "momentry --version says '$got', want 'momentry ${1#v}'"
}

# privacy source, a git repo, init: what doctor needs to say ok
init_repo() {
  "$BIN" config privacy-add 'Smoke Probe Name' >/dev/null
  mkdir -p "$HOME/repo"; git -C "$HOME/repo" init -q
  (cd "$HOME/repo" && "$BIN" init --yes) || fail "momentry init --yes failed"
}

step "checksums.txt of $TAG"
[ -f "$ASSETS/checksums.txt" ] || fail "checksums.txt missing"
grep -q "  $ARCHIVE\$" "$ASSETS/checksums.txt" || fail "checksums.txt does not list $ARCHIVE"
(cd "$ASSETS" && sha256 -c checksums.txt) || fail "an asset does not match checksums.txt"

step "install with install.sh"
use_home main
MOMENTRY_RELEASE_BASE="$ASSETS" sh "$ASSETS/install.sh" --yes || fail "install.sh failed"
expect_version "$TAG"
VDIR="$MDIR/versions/$TAG"
[ "$(cat "$MDIR/current")" = "$TAG" ] || fail "current is not $TAG"

step "the installed tree is exactly BUILD.files"
[ -f "$VDIR/BUILD" ] || fail "no BUILD in $VDIR"
target=$(jq -r '.target.goos + "/" + .target.goarch' "$VDIR/BUILD")
[ "$target" = "$GOOS/$GOARCH" ] || fail "BUILD.target is $target on a $GOOS/$GOARCH runner"
jq -r '.files[].path' "$VDIR/BUILD" | LC_ALL=C sort > "$WORK/want"
(cd "$VDIR" && find . ! -type d ! -path ./BUILD | sed 's|^\./||' | LC_ALL=C sort) > "$WORK/have"
cmp -s "$WORK/want" "$WORK/have" || { diff "$WORK/want" "$WORK/have" >&2 || true; fail "the files of $VDIR differ from BUILD.files"; }
(cd "$VDIR" && find . ! -type d ! -type f | grep -q .) && fail "$VDIR holds links or special files"
jq -r '.files[] | .sha256 + "  " + .path' "$VDIR/BUILD" > "$WORK/sums"
(cd "$VDIR" && sha256 -c "$WORK/sums" >/dev/null) || fail "a file of $VDIR does not match its BUILD.files sha256"

step "doctor --json"
init_repo
(cd "$HOME/repo" && "$BIN" doctor --json) > "$WORK/doctor.json" || true
jq -e '.schema == 1' "$WORK/doctor.json" >/dev/null || fail "doctor --json: schema is not 1"
jq -e '.ok == true' "$WORK/doctor.json" >/dev/null || {
  jq -r '.data.checks[]? | select(.status != "ok") | "\(.code): \(.status) \(.detail)"' "$WORK/doctor.json" >&2
  fail "doctor --json: ok is not true"; }

step "reinstalling the same release changes nothing"
before=$(tree_digest "$VDIR")
MOMENTRY_RELEASE_BASE="$ASSETS" sh "$ASSETS/install.sh" --yes || fail "the second install.sh exited non-zero"
[ "$(cat "$MDIR/current")" = "$TAG" ] || fail "current changed on reinstall"
[ "$(tree_digest "$VDIR")" = "$before" ] || fail "reinstall changed $VDIR"

step "a tampered archive is refused"
mkdir "$WORK/tampered"; cp "$ASSETS"/* "$WORK/tampered/"
byte=$(od -An -tu1 -j 100 -N 1 "$WORK/tampered/$ARCHIVE" | tr -d ' ')
if [ "$byte" = 0 ]; then printf '\001'; else printf '\000'; fi \
  | dd of="$WORK/tampered/$ARCHIVE" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
cmp -s "$ASSETS/$ARCHIVE" "$WORK/tampered/$ARCHIVE" && fail "could not change a byte of $ARCHIVE"
if MOMENTRY_RELEASE_BASE="$WORK/tampered" sh "$WORK/tampered/install.sh" --yes; then fail "install.sh accepted a tampered $ARCHIVE"; fi
[ "$(cat "$MDIR/current")" = "$TAG" ] || fail "current changed after a refused install"
[ "$(tree_digest "$VDIR")" = "$before" ] || fail "a refused install changed $VDIR"

step "hook probe: the harvest the hook starts outlives the hook's process group"
# Agent hosts kill the hook's whole process group or session when a session ends. The parent runs the hook in a new
# session of its own (perl's POSIX::setsid, on Linux and macOS alike); once it exits, its group is killed. A harvest
# that Detach did not move into its own session dies with it, and the alive marker never comes.
mark="$WORK/mark"; mkdir "$mark"
(cd "$HOME/repo" && MOMENTRY_PROBE_MARK="$mark" exec perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' \
  sh -c 'printf "{}" | "$1" hook session-start >/dev/null' sh "$BIN") &
leader=$!
status=0; wait "$leader" || status=$?
perl -e 'kill "KILL", -$ARGV[0]' "$leader"   # the group, as a host ends a session (gone already: nothing to do)
[ "$status" = 0 ] || fail "momentry hook session-start exited $status"
i=0
while [ $i -lt 60 ] && ! { [ -f "$mark/start" ] && [ -f "$mark/alive" ]; }; do sleep 1; i=$((i + 1)); done
[ -f "$mark/start" ] || fail "no start marker: the hook did not start a harvest"
[ -f "$mark/alive" ] || fail "start marker but no alive marker within 60 s: the harvest died with its parent's process group"

step "update from the previous release"
if [ -z "$PREV_DIR" ] || [ ! -f "$PREV_DIR/TAG" ]; then
  echo "bỏ qua: chưa có bản trước (skipped: no previous release)"
else
  (
    prev=$(cat "$PREV_DIR/TAG")
    is_tag "$prev" || fail "the previous release tag is not a release tag"
    [ -f "$PREV_DIR/install.sh" ] || fail "no install.sh of $prev in $PREV_DIR"
    use_home update
    sh "$PREV_DIR/install.sh" --yes || fail "installing $prev from the public release failed"
    expect_version "$prev"
    init_repo
    settings=$(sha256 < "$HOME/.claude/settings.json")
    MOMENTRY_RELEASE_BASE="$ASSETS" "$BIN" update --version "$TAG" --yes || fail "momentry update $prev -> $TAG failed"
    expect_version "$TAG"
    [ -d "$MDIR/versions/$prev" ] || fail "update removed the previous version $prev"
    [ "$(sha256 < "$HOME/.claude/settings.json")" = "$settings" ] || fail "update changed the hooks in ~/.claude/settings.json"
    "$BIN" uninstall --yes >/dev/null || fail "uninstall after the update failed"
  )
fi

step "uninstall"
use_home main
"$BIN" uninstall --yes || fail "momentry uninstall --yes failed"
[ ! -e "$BIN" ] || fail "the momentry shim is still there after uninstall"

step "smoke passed: $TAG on $GOOS/$GOARCH"
