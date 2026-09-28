#!/usr/bin/env bash
#
# Tests the inline scripts of .github/workflows/simple-tag-and-release.yaml.
#
# The scripts are extracted from the workflow with yq and run against throwaway
# git repositories, so what is tested is exactly what the workflow runs. `gh` is
# replaced by a stub (below) that keeps releases in a directory and creates tags
# in a local bare "origin", which is what `git ls-remote origin` then sees.
#
# Needs: bash, git, yq (mikefarah v4), sha256sum, curl (only if svu is not on
# PATH: it is then downloaded and checked exactly like the workflow does).

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/simple-tag-and-release.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

wf() { yq -r "$1" "$WORKFLOW"; }
step_run() { wf ".jobs.release.steps[] | select(.id == \"$1\") | .run" >"$WORK/$1.sh"; }

RELEASE_TAG_REGEX=$(wf '.jobs.release.env.RELEASE_TAG_REGEX')
export RELEASE_TAG_REGEX
step_run version
step_run reconcile
step_run aliases

# svu, from the same pinned archive and checksum as the workflow.
if ! command -v svu >/dev/null 2>&1; then
	SVU_VERSION=$(wf '.jobs.release.env.SVU_VERSION')
	SVU_ARCHIVE=$(wf '.jobs.release.env.SVU_ARCHIVE')
	SVU_SHA256=$(wf '.jobs.release.env.SVU_SHA256')
	mkdir -p "$WORK/svu"
	curl -fsSL --retry 3 -o "$WORK/svu/$SVU_ARCHIVE" \
		"https://github.com/caarlos0/svu/releases/download/v${SVU_VERSION}/${SVU_ARCHIVE}"
	echo "$SVU_SHA256  $WORK/svu/$SVU_ARCHIVE" | sha256sum --check --strict --quiet
	tar -xzf "$WORK/svu/$SVU_ARCHIVE" -C "$WORK/svu" svu
	PATH="$WORK/svu:$PATH"
fi

# The gh stub. State lives under $GH_STUB_DIR:
#   releases/<tag>/draft   "true" or "false"
#   releases/<tag>/target  the target commit
#   releases/<tag>/assets/ the uploaded files
#   latest                 the tag carrying the Latest badge
#   calls                  one line per invocation
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$GH_STUB_DIR/calls"
rel="$GH_STUB_DIR/releases"
case "$1 $2" in
"release view")
	tag=$3
	[ -d "$rel/$tag" ] || { echo "release not found" >&2; exit 1; }
	case "$*" in
	*isDraft,targetCommitish*) printf '%s\t%s\n' "$(cat "$rel/$tag/draft")" "$(cat "$rel/$tag/target")" ;;
	*assets*) ls -1 "$rel/$tag/assets" ;;
	esac
	;;
"release create")
	tag=$3
	shift 3
	target=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--target) target=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	mkdir -p "$rel/$tag/assets"
	echo true >"$rel/$tag/draft"
	echo "$target" >"$rel/$tag/target"
	;;
"release upload")
	[ -e "$rel/$3/assets/$(basename "$4")" ] && { echo "asset exists" >&2; exit 1; }
	cp "$4" "$rel/$3/assets/"
	;;
"release download")
	tag=$3
	shift 3
	pattern="" dir=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--pattern) pattern=$2; shift 2 ;;
		--dir) dir=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	cp "$rel/$tag/assets/$pattern" "$dir/"
	;;
"release edit")
	tag=$3
	[ -d "$rel/$tag" ] || { echo "release not found" >&2; exit 1; }
	for arg in "$@"; do
		case "$arg" in
		--draft=false)
			echo false >"$rel/$tag/draft"
			git -C "$GH_STUB_ORIGIN" tag "$tag" "$(cat "$rel/$tag/target")"
			;;
		--latest | --latest=true) echo "$tag" >"$GH_STUB_DIR/latest" ;;
		esac
	done
	;;
"api repos/"*)
	path=$2
	case "$path" in
	*/releases/latest) [ -s "$GH_STUB_DIR/latest" ] || exit 1; cat "$GH_STUB_DIR/latest" ;;
	*/git/ref/tags/*) git -C "$GH_STUB_ORIGIN" rev-parse -q --verify "refs/tags/${path##*/}" >/dev/null ;;
	*) echo "unexpected gh api $*" >&2; exit 1 ;;
	esac
	;;
"api -X")
	method=$3 path=$4
	sha=$(printf '%s\n' "$@" | sed -n 's/^sha=//p')
	case "$method $path" in
	"PATCH "*/git/refs/tags/*) git -C "$GH_STUB_ORIGIN" tag -f "${path##*/}" "$sha" >/dev/null ;;
	"POST "*/git/refs)
		ref=$(printf '%s\n' "$@" | sed -n 's/^ref=refs\/tags\///p')
		git -C "$GH_STUB_ORIGIN" tag "$ref" "$sha"
		;;
	*) echo "unexpected gh api $*" >&2; exit 1 ;;
	esac
	;;
*) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
PATH="$WORK/bin:$PATH"

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok   - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "FAIL - $1"
	if [ -n "${2:-}" ]; then
		while IFS= read -r line; do printf '       %s\n' "$line"; done <<<"$2"
	fi
}

# A fresh origin (bare) and a clone of it at $REPO, with one commit.
N=0
new_repo() {
	N=$((N + 1))
	ORIGIN="$WORK/origin-$N.git"
	REPO="$WORK/repo-$N"
	git init -q --bare "$ORIGIN"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" config commit.gpgsign false
	git -C "$REPO" config tag.gpgsign false
	git -C "$REPO" remote add origin "$ORIGIN"
	commit "chore(repo): initial commit"
	export GH_STUB_DIR="$WORK/gh-$N" GH_STUB_ORIGIN="$ORIGIN"
	mkdir -p "$GH_STUB_DIR/releases"
	: >"$GH_STUB_DIR/calls"
}
commit() { git -C "$REPO" commit -q --allow-empty -m "$1"; }
# Tags HEAD locally and on origin, as a published release would be.
release_tag() {
	git -C "$REPO" tag "$1" "${2:-HEAD}"
	git -C "$REPO" push -q origin "refs/tags/$1"
}
push_head() { git -C "$REPO" push -q origin HEAD:refs/heads/main; }

# Runs a step script in $REPO. Sets STATUS, OUTPUT (the step's output file) and
# LOG (stdout and stderr).
run_step() {
	local script=$1
	shift
	OUT_FILE="$WORK/output"
	: >"$OUT_FILE"
	STATUS=0
	LOG=$(cd "$REPO" && env GITHUB_OUTPUT="$OUT_FILE" "$@" bash "$WORK/$script.sh" 2>&1) || STATUS=$?
	OUTPUT=$(cat "$OUT_FILE")
}
out() { sed -n "s/^$1=//p" <<<"$OUTPUT"; }

resolve() { run_step version INPUT_VERSION="${1:-}" INPUT_SEMVER="${2:-}"; }
expect_version() {
	local name=$1 want=$2
	if [ "$STATUS" -eq 0 ] && [ "$(out version)" = "$want" ]; then ok "$name"; else not_ok "$name (want $want, status $STATUS, got '$(out version)')" "$LOG"; fi
}
expect_fail() {
	local name=$1 pattern=$2
	if [ "$STATUS" -ne 0 ] && grep -q -- "$pattern" <<<"$LOG"; then ok "$name"; else not_ok "$name (want a failure matching '$pattern', status $STATUS)" "$LOG"; fi
}

echo "# resolve"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
resolve "1.2.1" "v1.2.1"
expect_version "semver and version that normalize equal are accepted" v1.2.1
resolve "1.2.1" "1.2.2"
expect_fail "conflicting semver and version fail" "they differ"
resolve "" "1.2.1"
expect_version "the deprecated semver alone still works" v1.2.1
for bad in 1.2 v01.2.3 1.2.3-rc.1 1.2.3+meta x1.2.3; do
	resolve "$bad"
	expect_fail "malformed version '$bad' fails" "must be X.Y.Z"
done
resolve "1.1.9"
expect_fail "a lower version fails" "lower than the latest release"
resolve "1.2.0"
expect_fail "the latest version, not on HEAD, fails" "already released"
resolve ""
expect_version "fix derives a patch" v1.2.1
if [ "$(out explicit)" = "false" ] && [ "$(out previous)" = "v1.2.0" ] && [ "$(out major)" = "v1" ]; then ok "derived outputs"; else not_ok "derived outputs" "$OUTPUT"; fi

new_repo
resolve ""
expect_fail "no base tag and no version fails" "nothing to derive a version from"
resolve "0.1.0"
expect_version "no base tag with an explicit version works" v0.1.0

new_repo
release_tag v1.2.0
commit "feat(api): a feature"
resolve ""
expect_version "feat derives a minor" v1.3.0
commit "feat(api)!: a breaking change"
resolve ""
expect_version "a breaking change derives a major" v2.0.0

new_repo
release_tag v1.2.0
commit "chore(deps): bump something"
commit "docs(readme): words"
resolve ""
expect_fail "only chore/docs commits: nothing to bump" "nothing to bump"

new_repo
release_tag v1.2.0
git -C "$REPO" tag v1.9.0-rc.1
git -C "$REPO" tag latest
git -C "$REPO" tag v1
commit "fix(core): a fix"
resolve ""
expect_version "stray non-release tags are ignored" v1.2.1

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
release_tag v1.2.1
resolve ""
expect_version "a derived re-run with the tag on HEAD is a recovery" v1.2.1
if [ "$(out recovery)" = "true" ] && [ "$(out previous)" = "v1.2.0" ]; then ok "recovery outputs"; else not_ok "recovery outputs" "$OUTPUT"; fi
resolve "1.2.1"
expect_version "an explicit re-run with the tag on HEAD is a recovery" v1.2.1

new_repo
release_tag v1.2.0
commit "fix(core): the old fix"
OLD=$(git -C "$REPO" rev-parse HEAD)
release_tag v1.2.1
commit "feat(api): newer"
release_tag v1.3.0
git -C "$REPO" checkout -q "$OLD"
resolve "1.2.1"
expect_version "recovering an older release on its own commit works" v1.2.1
resolve "1.2.2"
expect_fail "a new lower version is still refused" "lower than the latest release"

echo "# reconcile"

ASSETS="$WORK/assets"
mkdir -p "$ASSETS"
echo one >"$ASSETS/a.zip"
echo two >"$ASSETS/b.txt"

reconcile() {
	run_step reconcile VERSION="$1" TARGET="$(git -C "$REPO" rev-parse HEAD)" ASSETS_DIR="${2:-}" DRY_RUN="${3:-false}" REPO=leinardi/test
}
calls() { cat "$GH_STUB_DIR/calls"; }
writes() { grep -E '^release (create|upload|edit)|^api -X' "$GH_STUB_DIR/calls" || true; }
remote_tag() { git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$1^{commit}" || true; }

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
push_head
reconcile v1.2.1 "$ASSETS" true
if [ "$STATUS" -eq 0 ] && [ -z "$(writes)" ] && [ -z "$(remote_tag v1.2.1)" ]; then ok "a dry run writes nothing"; else not_ok "a dry run writes nothing" "$LOG$(calls)"; fi

reconcile v1.2.1 "$ASSETS"
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag v1.2.1)" = "$(git -C "$REPO" rev-parse HEAD)" ] \
	&& [ "$(cat "$GH_STUB_DIR/releases/v1.2.1/draft")" = false ] \
	&& [ -f "$GH_STUB_DIR/releases/v1.2.1/assets/a.zip" ] && [ -f "$GH_STUB_DIR/releases/v1.2.1/assets/b.txt" ] \
	&& [ "$(cat "$GH_STUB_DIR/latest")" = v1.2.1 ]; then
	ok "no release: draft, upload, publish, tag on target, latest"
else
	not_ok "no release: draft, upload, publish, tag on target, latest" "$LOG$(calls)"
fi

: >"$GH_STUB_DIR/calls"
reconcile v1.2.1 "$ASSETS"
if [ "$STATUS" -eq 0 ] && [ -z "$(writes)" ]; then ok "re-running a complete release is a no-op"; else not_ok "re-running a complete release is a no-op" "$LOG$(calls)"; fi

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
push_head
TARGET=$(git -C "$REPO" rev-parse HEAD)
gh release create v1.2.1 --draft --target "$TARGET" >/dev/null
cp "$ASSETS/a.zip" "$GH_STUB_DIR/releases/v1.2.1/assets/"
: >"$GH_STUB_DIR/calls"
reconcile v1.2.1 "$ASSETS"
if [ "$STATUS" -eq 0 ] && ! grep -q '^release create' "$GH_STUB_DIR/calls" \
	&& grep -q "^release upload v1.2.1 .*b.txt" "$GH_STUB_DIR/calls" && ! grep -q "^release upload v1.2.1 .*a.zip" "$GH_STUB_DIR/calls" \
	&& [ "$(remote_tag v1.2.1)" = "$TARGET" ]; then
	ok "an existing draft is reused and only missing assets are uploaded"
else
	not_ok "an existing draft is reused and only missing assets are uploaded" "$LOG$(calls)"
fi

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
gh release create v1.2.1 --draft --target 0000000000000000000000000000000000000000 >/dev/null
reconcile v1.2.1 "$ASSETS"
expect_fail "a draft targeting another commit fails" "not this commit"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
push_head
TARGET=$(git -C "$REPO" rev-parse HEAD)
gh release create v1.2.1 --draft --target "$TARGET" >/dev/null
cp "$ASSETS/a.zip" "$GH_STUB_DIR/releases/v1.2.1/assets/"
gh release edit v1.2.1 --draft=false --latest >/dev/null
: >"$GH_STUB_DIR/calls"
reconcile v1.2.1 "$ASSETS"
if [ "$STATUS" -eq 0 ] && grep -q "^release upload v1.2.1 .*b.txt" "$GH_STUB_DIR/calls" \
	&& ! grep -q -- '--draft=false' "$GH_STUB_DIR/calls" && ! grep -q '^release create' "$GH_STUB_DIR/calls"; then
	ok "a published release missing assets gets them, without a re-publish"
else
	not_ok "a published release missing assets gets them, without a re-publish" "$LOG$(calls)"
fi

echo changed >"$GH_STUB_DIR/releases/v1.2.1/assets/a.zip"
reconcile v1.2.1 "$ASSETS"
expect_fail "a same-name asset with other content fails" "differs from this run's"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
push_head
TARGET=$(git -C "$REPO" rev-parse HEAD)
gh release create v1.2.1 --draft --target "$TARGET" >/dev/null
echo stray >"$GH_STUB_DIR/releases/v1.2.1/assets/stray.bin"
reconcile v1.2.1 "$ASSETS"
expect_fail "an unexpected asset fails" "unexpected asset"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
git -C "$ORIGIN" tag v1.2.1 "$(git -C "$REPO" rev-parse HEAD~1)"
reconcile v1.2.1
expect_fail "a remote tag on another commit fails" "already exists on"

new_repo
release_tag v1.2.0
commit "fix(core): the old fix"
OLD=$(git -C "$REPO" rev-parse HEAD)
commit "feat(api): newer"
release_tag v1.3.0
push_head
echo v1.3.0 >"$GH_STUB_DIR/latest"
git -C "$REPO" checkout -q "$OLD"
reconcile v1.2.1
if [ "$STATUS" -eq 0 ] && grep -q -- '--latest=false' "$GH_STUB_DIR/calls" && [ "$(cat "$GH_STUB_DIR/latest")" = v1.3.0 ]; then
	ok "an older release is published without taking Latest"
else
	not_ok "an older release is published without taking Latest" "$LOG$(calls)"
fi

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
push_head
NESTED_ASSETS="$WORK/nested-assets"
mkdir -p "$NESTED_ASSETS/sub"
echo one >"$NESTED_ASSETS/a.zip"
echo deep >"$NESTED_ASSETS/sub/b.zip"
reconcile v1.2.1 "$NESTED_ASSETS"
if [ "$STATUS" -ne 0 ] && grep -q "not a top-level file" <<<"$LOG" && [ -z "$(writes)" ]; then ok "a nested artifact fails before any write"; else not_ok "a nested artifact fails before any write" "$LOG$(calls)"; fi

echo "# aliases"

aliases() {
	run_step aliases VERSION="$1" MAJOR="$2" TARGET="$(git -C "$REPO" rev-parse HEAD)" REPO=leinardi/test
}

new_repo
release_tag v1.2.0
git -C "$ORIGIN" tag v1 "$(git -C "$REPO" rev-parse HEAD)"
git -C "$ORIGIN" tag latest "$(git -C "$REPO" rev-parse HEAD)"
commit "fix(core): a fix"
release_tag v1.2.1
aliases v1.2.1 v1
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag v1)" = "$HEAD_SHA" ] && [ "$(remote_tag latest)" = "$HEAD_SHA" ]; then
	ok "the highest release moves v1 and latest"
else
	not_ok "the highest release moves v1 and latest" "$LOG$(calls)"
fi

new_repo
release_tag v1.2.0
commit "fix(core): the old fix"
OLD=$(git -C "$REPO" rev-parse HEAD)
release_tag v1.2.1
commit "feat(api): newer"
release_tag v1.3.0
NEW=$(git -C "$REPO" rev-parse HEAD)
git -C "$ORIGIN" tag v1 "$NEW"
git -C "$ORIGIN" tag latest "$NEW"
git -C "$REPO" checkout -q "$OLD"
aliases v1.2.1 v1
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag v1)" = "$NEW" ] && [ "$(remote_tag latest)" = "$NEW" ]; then
	ok "recovering an older release moves nothing backwards"
else
	not_ok "recovering an older release moves nothing backwards" "$LOG$(calls)"
fi

new_repo
release_tag v1.2.0
commit "feat(api)!: v2"
release_tag v2.0.0
V2=$(git -C "$REPO" rev-parse HEAD)
git -C "$ORIGIN" tag latest "$V2"
git -C "$ORIGIN" tag v2 "$V2"
git -C "$REPO" checkout -q v1.2.0
git -C "$REPO" checkout -q -b maint
commit "fix(core): backport"
release_tag v1.2.1
aliases v1.2.1 v1
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag v1)" = "$(git -C "$REPO" rev-parse HEAD)" ] && [ "$(remote_tag latest)" = "$V2" ]; then
	ok "a v1 backport under v2 moves v1 only (and creates it)"
else
	not_ok "a v1 backport under v2 moves v1 only (and creates it)" "$LOG$(calls)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
