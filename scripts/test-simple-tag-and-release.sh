#!/usr/bin/env bash
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Tests the inline scripts of .github/workflows/simple-tag-and-release.yaml.
#
# The scripts are extracted from the workflow with yq and run against throwaway
# git repositories, so what is tested is exactly what the workflow runs. `gh` is
# replaced by a stub (below) that keeps releases in a directory and creates tags
# in a local bare "origin", which is what `git ls-remote origin` then sees.
#
# The version itself is resolved by the release-version action of
# leinardi/gh-composite-actions, whose own tests cover it; here the version is
# passed to the later steps as that action would output it.
#
# Needs: bash, git, yq (mikefarah v4), sha256sum.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/simple-tag-and-release.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

wf() { yq -r "$1" "$WORKFLOW"; }
step_run() { wf ".jobs.release.steps[] | select(.id == \"$1\") | .run" >"$WORK/$1.sh"; }

step_run input
step_run reconcile
step_run aliases
for step in input reconcile aliases; do
	if [ ! -s "$WORK/$step.sh" ]; then
		echo "no step with id '$step' in $WORKFLOW" >&2
		exit 1
	fi
done

# The gh stub. State lives under $GH_STUB_DIR:
#   releases/<tag>/draft   "true" or "false"
#   releases/<tag>/target  the target commit
#   releases/<tag>/assets/ the uploaded files
#   latest                 the tag carrying the Latest badge
#   latest_fail            if present, reading the Latest release fails with it
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
	*/releases/latest)
		if [ -e "$GH_STUB_DIR/latest_fail" ]; then
			cat "$GH_STUB_DIR/latest_fail" >&2
			exit 1
		fi
		[ -s "$GH_STUB_DIR/latest" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
		cat "$GH_STUB_DIR/latest"
		;;
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

pick() { run_step input INPUT_VERSION="${1:-}" INPUT_SEMVER="${2:-}" TAG_PREFIX="${3-v}"; }
expect_pick() {
	local name=$1 want=$2
	if [ "$STATUS" -eq 0 ] && [ "$(out version)" = "$want" ]; then ok "$name"; else not_ok "$name (want '$want', status $STATUS, got '$(out version)')" "$LOG"; fi
}
expect_fail() {
	local name=$1 pattern=$2
	if [ "$STATUS" -ne 0 ] && grep -q -- "$pattern" <<<"$LOG"; then ok "$name"; else not_ok "$name (want a failure matching '$pattern', status $STATUS)" "$LOG"; fi
}
# The tag regex the input step builds for prefix $1.
regex_for() {
	pick "" "" "$1"
	[ "$STATUS" -eq 0 ] || { not_ok "the input step accepts the prefix '$1'" "$LOG"; return 1; }
	out tag_regex
}
# matches REGEX TAG: whether the tag is a release tag under the regex, the way
# the step scripts test it (grep -E).
matches() { grep -qE "$1" <<<"$2"; }

echo "# input"

new_repo
pick "1.2.1" "v1.2.1"
expect_pick "semver and version that normalize equal are accepted" "1.2.1"
pick "1.2.1" "1.2.2"
expect_fail "conflicting semver and version fail" "they differ"
pick "" "1.2.1"
expect_pick "the deprecated semver alone still works" "1.2.1"
pick "v1.2.1" ""
expect_pick "version alone is passed on as given" "v1.2.1"
pick "" ""
expect_pick "no version and no semver: derive" ""
pick "foo--v1.2.1" "1.2.1" "foo--v"
expect_pick "semver and a prefixed version that normalize equal are accepted" "foo--v1.2.1"
pick "foo--v1.2.1" "v1.2.2" "foo--v"
expect_fail "conflicting prefixed version and semver fail" "they differ"
for bad in "" "a b" 'v$' "v*" "x;y" "v\\"; do
	pick "" "" "$bad"
	expect_fail "the tag prefix '$bad' is refused" "tag_prefix"
done

V_REGEX=$(regex_for v)
for good in v0.0.0 v1.2.3 v10.20.30; do
	if matches "$V_REGEX" "$good"; then ok "prefix v: $good is a release tag"; else not_ok "prefix v: $good is a release tag" "$V_REGEX"; fi
done
for bad in v1 latest v01.2.3 v1.2.3-rc.1 v1.2.3+meta 1.2.3 xv1.2.3 foo--v1.2.3 v1.2.3x; do
	if ! matches "$V_REGEX" "$bad"; then ok "prefix v: $bad is not a release tag"; else not_ok "prefix v: $bad is not a release tag" "$V_REGEX"; fi
done
P_REGEX=$(regex_for my.plugin--v)
if matches "$P_REGEX" my.plugin--v1.2.3; then ok "prefix my.plugin--v: its own tag matches"; else not_ok "prefix my.plugin--v: its own tag matches" "$P_REGEX"; fi
for bad in myXplugin--v1.2.3 v1.2.3 my.plugin--v1 my.plugin--v1.2.3-rc.1; do
	if ! matches "$P_REGEX" "$bad"; then ok "prefix my.plugin--v: $bad is not a release tag (dots are literal)"; else not_ok "prefix my.plugin--v: $bad is not a release tag" "$P_REGEX"; fi
done
S_REGEX=$(regex_for pkg/v)
if matches "$S_REGEX" pkg/v1.2.3 && ! matches "$S_REGEX" v1.2.3; then ok "prefix pkg/v: only pkg/vX.Y.Z matches"; else not_ok "prefix pkg/v: only pkg/vX.Y.Z matches" "$S_REGEX"; fi

echo "# reconcile"

ASSETS="$WORK/assets"
mkdir -p "$ASSETS"
echo one >"$ASSETS/a.zip"
echo two >"$ASSETS/b.txt"

reconcile() {
	run_step reconcile VERSION="$1" TARGET="$(git -C "$REPO" rev-parse HEAD)" ASSETS_DIR="${2:-}" DRY_RUN="${3:-false}" REPO=leinardi/test \
		RELEASE_TAG_REGEX="${REGEX:-$V_REGEX}"
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

echo "# reconcile: Latest badge"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
push_head
reconcile v1.2.1
if [ "$STATUS" -eq 0 ] && [ "$(cat "$GH_STUB_DIR/latest")" = v1.2.1 ]; then
	ok "no release carries Latest yet (HTTP 404): the new highest takes it"
else
	not_ok "no release carries Latest yet (HTTP 404): the new highest takes it" "$LOG$(calls)"
fi

for err in "HTTP 502: Bad Gateway" "HTTP 403: API rate limit exceeded" "HTTP 401: Bad credentials"; do
	new_repo
	release_tag v1.2.0
	commit "fix(core): a fix"
	push_head
	echo "gh: $err" >"$GH_STUB_DIR/latest_fail"
	reconcile v1.2.1
	expect_fail "reading the Latest release fails with '$err': the step fails, not 'none'" "Could not read which release carries the Latest badge"
	rm "$GH_STUB_DIR/latest_fail"
	: >"$GH_STUB_DIR/calls"
	reconcile v1.2.1
	if [ "$STATUS" -eq 0 ] && [ "$(cat "$GH_STUB_DIR/latest")" = v1.2.1 ] && ! grep -q '^release create' "$GH_STUB_DIR/calls"; then
		ok "after '$err', a re-run finishes the badge without re-creating the release"
	else
		not_ok "after '$err', a re-run finishes the badge without re-creating the release" "$LOG$(calls)"
	fi
done

echo "# reconcile: tag prefix"

new_repo
REGEX=$(regex_for gtk-rs-skills--v)
release_tag gtk-rs-skills--v0.1.0
release_tag v9.9.9
commit "fix(core): a fix"
push_head
echo v9.9.9 >"$GH_STUB_DIR/latest"
reconcile gtk-rs-skills--v0.1.1
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag gtk-rs-skills--v0.1.1)" = "$(git -C "$REPO" rev-parse HEAD)" ] \
	&& [ "$(out is_latest)" = true ] && grep -q -- '--title gtk-rs-skills--v0.1.1' "$GH_STUB_DIR/calls"; then
	ok "a prefixed release is the highest of its prefix: another prefix's higher tag does not count"
else
	not_ok "a prefixed release is the highest of its prefix: another prefix's higher tag does not count" "$LOG$(calls)"
fi
unset REGEX

new_repo
REGEX=$(regex_for gtk-rs-skills--v)
release_tag gtk-rs-skills--v0.2.0
commit "fix(core): an old fix"
push_head
git -C "$REPO" tag gtk-rs-skills--v0.1.0 HEAD~1
git -C "$REPO" push -q origin refs/tags/gtk-rs-skills--v0.1.0
echo gtk-rs-skills--v0.2.0 >"$GH_STUB_DIR/latest"
reconcile gtk-rs-skills--v0.1.1
if [ "$STATUS" -eq 0 ] && [ "$(out is_latest)" = false ] && [ "$(cat "$GH_STUB_DIR/latest")" = gtk-rs-skills--v0.2.0 ]; then
	ok "a prefixed release below its prefix's highest does not take Latest"
else
	not_ok "a prefixed release below its prefix's highest does not take Latest" "$LOG$(calls)"
fi
unset REGEX

new_repo
REGEX=$(regex_for pkg/v)
release_tag pkg/v1.9.0
commit "fix(core): a fix"
push_head
reconcile pkg/v1.10.0
if [ "$STATUS" -eq 0 ] && [ "$(out is_latest)" = true ] && [ "$(remote_tag pkg/v1.10.0)" = "$(git -C "$REPO" rev-parse HEAD)" ]; then
	ok "a prefix with a slash: tag names are read whole, and 1.10.0 sorts above 1.9.0"
else
	not_ok "a prefix with a slash: tag names are read whole, and 1.10.0 sorts above 1.9.0" "$LOG$(calls)"
fi
reconcile pkg/v1.9.1
if [ "$STATUS" -eq 0 ] && [ "$(out is_latest)" = false ]; then
	ok "a prefix with a slash: a lower version is not latest"
else
	not_ok "a prefix with a slash: a lower version is not latest" "$LOG$(calls)"
fi
unset REGEX

echo "# aliases"

aliases() {
	run_step aliases VERSION="$1" MAJOR="$2" TARGET="$(git -C "$REPO" rev-parse HEAD)" REPO=leinardi/test \
		TAG_PREFIX="${PREFIX:-v}" RELEASE_TAG_REGEX="${REGEX:-$V_REGEX}"
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


new_repo
release_tag v1.2.0
git -C "$ORIGIN" tag v1 "$(git -C "$REPO" rev-parse HEAD)"
commit "fix(core): a fix"
release_tag v1.2.1
aliases v1.2.1 v1
if [ "$STATUS" -eq 0 ] && grep -q '^api -X PATCH repos/leinardi/test/git/refs/tags/v1 ' "$GH_STUB_DIR/calls" \
	&& grep -q '^api -X POST repos/leinardi/test/git/refs ' "$GH_STUB_DIR/calls" \
	&& ! grep -q '^api repos/leinardi/test/git/ref/' "$GH_STUB_DIR/calls"; then
	ok "an existing moving tag is updated and a missing one created, decided from the listing"
else
	not_ok "an existing moving tag is updated and a missing one created, decided from the listing" "$LOG$(calls)"
fi

new_repo
release_tag v1.2.0
git -C "$ORIGIN" tag v1 "$(git -C "$REPO" rev-parse HEAD)"
commit "fix(core): a fix"
release_tag v1.10.0
release_tag v10.0.0 HEAD~1
git -C "$ORIGIN" tag v10 "$(git -C "$REPO" rev-parse HEAD~1)"
aliases v1.10.0 v1
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag v1)" = "$(git -C "$REPO" rev-parse HEAD)" ] \
	&& [ "$(remote_tag v10)" = "$(git -C "$REPO" rev-parse HEAD~1)" ] \
	&& [ "$(remote_tag latest)" = "" ]; then
	ok "v1.10.0 is the highest v1 release, v10.0.0 is not a v1 release, and latest stays with v10.0.0"
else
	not_ok "v1.10.0 is the highest v1 release, v10.0.0 is not a v1 release, and latest stays with v10.0.0" "$LOG$(calls)"
fi

new_repo
PREFIX=gtk-rs-skills--v
REGEX=$(regex_for "$PREFIX")
release_tag gtk-rs-skills--v0.1.0
commit "fix(core): a fix"
release_tag gtk-rs-skills--v0.1.1
aliases gtk-rs-skills--v0.1.1 gtk-rs-skills--v0
if [ "$STATUS" -eq 0 ] && [ -z "$(writes)" ] && [ -z "$(remote_tag latest)" ] && [ -z "$(remote_tag gtk-rs-skills--v0)" ] \
	&& [ -z "$(out moved)" ] && grep -q "no vMAJOR or latest tag is moved" <<<"$LOG"; then
	ok "a prefix other than v moves no tag at all"
else
	not_ok "a prefix other than v moves no tag at all" "$LOG$(calls)"
fi
unset PREFIX REGEX

new_repo
release_tag v1.2.0
git -C "$ORIGIN" tag latest "$(git -C "$REPO" rev-parse HEAD)"
release_tag plugin--v5.0.0
commit "fix(core): a fix"
release_tag v1.2.1
aliases v1.2.1 v1
if [ "$STATUS" -eq 0 ] && [ "$(remote_tag latest)" = "$(git -C "$REPO" rev-parse HEAD)" ]; then
	ok "prefix v: another prefix's higher tag does not keep latest"
else
	not_ok "prefix v: another prefix's higher tag does not keep latest" "$LOG$(calls)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
