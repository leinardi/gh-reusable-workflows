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
# Tests the inline scripts of .github/workflows/version-bump-pr.yaml.
#
# The scripts are extracted from the workflow with yq and run against throwaway git repositories
# with a local bare "origin", so what is tested is exactly what the workflow runs. Like the
# workflow, each test uses two checkouts: $REPO for the bump job (the commands, the guard, the patch
# export) and a fresh clone $PUB for the publish job (apply, check, push). `gh` is replaced by a stub
# (below) that serves canned tag and pull request listings through the real jq, reads commits from
# the bare origin, records every call, and fails the way the GitHub API does when asked to. The
# version itself is resolved by the release-version action of leinardi/gh-composite-actions, tested
# there; here it is passed in as that action outputs it.
#
# Needs: bash, git, yq (mikefarah v4), jq.

# The bump and version commands are strings the workflow runs later with bash -c, so their
# `$RELEASE_VERSION` is meant to stay unexpanded here.
# shellcheck disable=SC2016

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/version-bump-pr.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

wf() { yq -r "$1" "$WORKFLOW"; }
extract() {
	wf ".jobs.$1.steps[] | select(.id == \"$2\") | .run" >"$WORK/$2.sh"
	if [ ! -s "$WORK/$2.sh" ]; then
		echo "no step with id '$2' in job '$1' of $WORKFLOW" >&2
		exit 1
	fi
}
extract bump current
extract bump bump
extract bump export
extract publish publish

# The gh stub. State lives under $GH_STUB_DIR:
#   refs.json   the array `git/matching-refs/tags/<tag>` returns ([] when absent)
#   pulls.json  the array `pulls?state=open...` returns
#   race        if present, run (bash) while the open pull requests are listed: another actor
#               acting between the publish step's reads and its push
#   fail_refs, fail_pulls, fail_commit, fail_create
#               if present, that call fails with the file's content on stderr
#   calls       one line per invocation
# `commits/<sha>` is answered from the bare origin ($GH_STUB_ORIGIN).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$GH_STUB_DIR/calls"
case "$1 $2" in
"pr create")
	[ ! -e "$GH_STUB_DIR/fail_create" ] || { cat "$GH_STUB_DIR/fail_create" >&2; exit 1; }
	echo "https://github.com/leinardi/test/pull/42"
	;;
"workflow run") ;;
api*)
	jq_expr="" path=""
	for arg in "$@"; do
		case "$arg" in
		repos/*) [ -n "$path" ] || path=$arg ;;
		esac
	done
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--jq) jq_expr=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	case "$path" in
	*/git/matching-refs/tags/*)
		[ ! -e "$GH_STUB_DIR/fail_refs" ] || { cat "$GH_STUB_DIR/fail_refs" >&2; exit 1; }
		jq -r "$jq_expr" "$GH_STUB_DIR/refs.json"
		;;
	*/pulls)
		[ ! -e "$GH_STUB_DIR/fail_pulls" ] || { cat "$GH_STUB_DIR/fail_pulls" >&2; exit 1; }
		[ ! -e "$GH_STUB_DIR/race" ] || bash "$GH_STUB_DIR/race" >/dev/null 2>&1
		jq -r "$jq_expr" "$GH_STUB_DIR/pulls.json"
		;;
	*/commits/*)
		[ ! -e "$GH_STUB_DIR/fail_commit" ] || { cat "$GH_STUB_DIR/fail_commit" >&2; exit 1; }
		sha=${path##*/}
		fmt() { git -C "$GH_STUB_ORIGIN" log -1 --format="$1" "$sha"; }
		jq -n --arg p "$(fmt %P)" --arg t "$(fmt %T)" --arg an "$(fmt %an)" --arg ae "$(fmt %ae)" \
			--arg cn "$(fmt %cn)" --arg ce "$(fmt %ce)" \
			'{parents: ($p | split(" ") | map(select(. != "") | {sha: .})),
			  commit: {tree: {sha: $t}, author: {name: $an, email: $ae}, committer: {name: $cn, email: $ce}}}' | jq -r "$jq_expr"
		;;
	*) echo "unexpected gh api path '$path'" >&2; exit 1 ;;
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

git_identity() {
	git -C "$1" config user.email test@example.com
	git -C "$1" config user.name test
	git -C "$1" config commit.gpgsign false
}

# A fresh origin (bare) with one commit on main carrying VERSION 1.2.0, the bump job's checkout of
# it at $REPO and the publish job's at $PUB.
N=0
new_repo() {
	N=$((N + 1))
	ORIGIN="$WORK/origin-$N.git"
	REPO="$WORK/repo-$N"
	PUB="$WORK/pub-$N"
	PATCH="$WORK/patch-$N/bump.patch"
	git init -q --bare "$ORIGIN"
	git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
	git init -q -b main "$REPO"
	git_identity "$REPO"
	git -C "$REPO" remote add origin "$ORIGIN"
	echo 1.2.0 >"$REPO/VERSION"
	echo "# test" >"$REPO/README.md"
	git -C "$REPO" add VERSION README.md
	git -C "$REPO" commit -q -m "chore(repo): initial commit"
	git -C "$REPO" push -q origin HEAD:refs/heads/main
	HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
	fresh_pub
	export GH_STUB_DIR="$WORK/gh-$N" GH_STUB_ORIGIN="$ORIGIN"
	mkdir -p "$GH_STUB_DIR"
	echo '[]' >"$GH_STUB_DIR/refs.json"
	echo '[]' >"$GH_STUB_DIR/pulls.json"
	: >"$GH_STUB_DIR/calls"
}
# A new publish checkout of the dispatched commit, as a re-run of the publish job gets.
fresh_pub() {
	rm -rf "$PUB"
	git clone -q "$ORIGIN" "$PUB"
	git -C "$PUB" checkout -q --detach "$HEAD_SHA"
}

# Runs a step script in $RUN_IN (default $REPO). Sets STATUS, OUTPUT and LOG.
run_step() {
	local script=$1
	shift
	OUT_FILE="$WORK/output"
	: >"$OUT_FILE"
	STATUS=0
	LOG=$(cd "${RUN_IN:-$REPO}" && env GITHUB_OUTPUT="$OUT_FILE" "$@" bash "$WORK/$script.sh" 2>&1) || STATUS=$?
	OUTPUT=$(cat "$OUT_FILE")
}
out() { sed -n "s/^$1=//p" <<<"$OUTPUT"; }
expect_fail() {
	local name=$1 pattern=$2
	if [ "$STATUS" -ne 0 ] && grep -q -- "$pattern" <<<"$LOG"; then ok "$name"; else not_ok "$name (want a failure matching '$pattern', status $STATUS)" "$LOG"; fi
}
calls() { cat "$GH_STUB_DIR/calls"; }
writes() { grep -E '^(pr create|workflow run)' "$GH_STUB_DIR/calls" || true; }
remote_refs() { git -C "$ORIGIN" for-each-ref --format='%(refname) %(objectname)'; }
branch_sha() { git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" || true; }

VERSION_COMMAND='cat VERSION'
BUMP_COMMAND='printf "%s\n" "$RELEASE_VERSION" >VERSION'

current() { run_step current VERSION_COMMAND="${1-$VERSION_COMMAND}"; }
# bump VERSION [TAG] [extra env...]: the bump step, as the workflow runs it after release-version.
bump() {
	local version=$1 tag=${2:-v$1}
	shift 2 || shift $#
	run_step bump BUMP_COMMAND="${BUMP:-$BUMP_COMMAND}" VERSION_COMMAND="$VERSION_COMMAND" \
		ALLOWED_FILES="${ALLOWED-VERSION}" TAG_PREFIX="${PREFIX:-v}" RELEASE_VERSION="$version" \
		RELEASE_TAG="$tag" RECOVERY="${RECOVERY:-false}" CURRENT_VERSION=1.2.0 EXPECTED_HEAD="$HEAD_SHA" "$@"
}
export_patch() { run_step export PATCH_DIR="$(dirname "$PATCH")"; }
# The bump job, end to end: bump, then export. Fails the test run if either fails.
bump_job() {
	bump "$@"
	[ "$STATUS" -eq 0 ] || { not_ok "setup: the bump job succeeds" "$LOG"; return 1; }
	export_patch
	[ "$STATUS" -eq 0 ] || { not_ok "setup: the patch export succeeds" "$LOG"; return 1; }
}
publish() {
	RUN_IN="$PUB" run_step publish DRY_RUN="${1:-false}" REPO=leinardi/test DEFAULT_BRANCH=main BASE_SHA="$HEAD_SHA" \
		VERSION="${VERSION_OUT-1.2.1}" TAG="${TAG_OUT-v1.2.1}" TAG_PREFIX="${PREFIX:-v}" \
		ALLOWED_FILES="${PUB_ALLOWED-VERSION}" CI_WORKFLOW="${CI-ci.yaml}" PATCH="$PATCH" GH_TOKEN=stub
}
pr() {
	# number head_repo head_ref login
	jq -n --argjson n "$1" --arg repo "$2" --arg ref "$3" --arg login "$4" \
		'{number: $n, head: {repo: (if $repo == "" then null else {full_name: $repo} end), ref: $ref}, user: {login: $login}}'
}
bot_pr() { pr "${1:-7}" leinardi/test "${2:-release/v1.2.1}" 'github-actions[bot]' | jq -s . >"$GH_STUB_DIR/pulls.json"; }

echo "# current"

new_repo
current
if [ "$STATUS" -eq 0 ] && [ "$(out version)" = 1.2.0 ]; then ok "reads the carried version"; else not_ok "reads the carried version" "$LOG"; fi
current 'echo v1.2.0'
expect_fail "a version with a v is not X.Y.Z" "not one X.Y.Z line"
current 'printf "1.2.0\n1.3.0\n"'
expect_fail "two lines are refused" "not one X.Y.Z line"
current 'false'
expect_fail "a failing version command fails" "version_command failed"
current ''
expect_fail "an empty version command fails" "version_command is empty"

echo "# bump"

new_repo
bump 1.2.1
if [ "$STATUS" -eq 0 ] && [ "$(cat "$REPO/VERSION")" = 1.2.1 ] \
	&& [ "$(git -C "$REPO" diff --cached --name-only)" = VERSION ] && grep -q '^+1.2.1' <<<"$LOG"; then
	ok "writes the version through RELEASE_VERSION, stages it and prints the diff"
else
	not_ok "writes the version through RELEASE_VERSION, stages it and prints the diff" "$LOG"
fi

new_repo
BUMP='printf "%s\n" "$RELEASE_TAG" >TAG_SEEN; printf "%s\n" "$RELEASE_VERSION" >VERSION' ALLOWED="VERSION TAG_SEEN" bump 1.2.1
if [ "$STATUS" -eq 0 ] && [ "$(cat "$REPO/TAG_SEEN")" = v1.2.1 ]; then ok "the bump command gets RELEASE_TAG"; else not_ok "the bump command gets RELEASE_TAG" "$LOG"; fi

for bad in "1.2" "01.2.1" "1.2.1-rc.1" '1.2.1; touch PWNED' '$(touch PWNED)'; do
	new_repo
	BUMP='touch RAN' bump "$bad" "v$bad"
	if [ "$STATUS" -ne 0 ] && grep -q "Refusing version" <<<"$LOG" && [ ! -e "$REPO/RAN" ] && [ ! -e "$REPO/PWNED" ]; then
		ok "version '$bad' is refused before the bump command runs"
	else
		not_ok "version '$bad' is refused before the bump command runs" "$LOG"
	fi
done

new_repo
BUMP='touch RAN' bump 1.2.1 foo--v1.2.1
if [ "$STATUS" -ne 0 ] && [ ! -e "$REPO/RAN" ]; then ok "a tag that is not <prefix><version> is refused"; else not_ok "a tag that is not <prefix><version> is refused" "$LOG"; fi

new_repo
PREFIX=gtk-rs-skills--v bump 1.2.1 gtk-rs-skills--v1.2.1
if [ "$STATUS" -eq 0 ]; then ok "a prefixed tag is accepted"; else not_ok "a prefixed tag is accepted" "$LOG"; fi

new_repo
RECOVERY=true BUMP='touch RAN' bump 1.2.1
if [ "$STATUS" -ne 0 ] && grep -q "already marks this commit" <<<"$LOG" && [ ! -e "$REPO/RAN" ]; then
	ok "a tag already on HEAD fails before the bump"
else
	not_ok "a tag already on HEAD fails before the bump" "$LOG"
fi

new_repo
bump 1.2.0
expect_fail "the version the repository already carries fails" "already carries 1.2.0"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; echo x >>README.md' bump 1.2.1
expect_fail "a tracked change outside allowed_files fails" "outside allowed_files: README.md"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; echo x >stray.txt' bump 1.2.1
expect_fail "an untracked file outside allowed_files fails" "outside allowed_files: stray.txt"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; git rm -q README.md' bump 1.2.1
expect_fail "a deletion outside allowed_files fails" "outside allowed_files: README.md"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; git mv README.md VERSION.md' ALLOWED=VERSION bump 1.2.1
expect_fail "a rename counts both paths" "outside allowed_files: README.md VERSION.md"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; mkdir -p d; echo x >d/VERSION' ALLOWED="VERSION d" bump 1.2.1
expect_fail "allowed_files names files, not directories" "outside allowed_files: d/VERSION"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; echo x >"$(printf "evil\nVERSION")"' bump 1.2.1
expect_fail "a path with a newline is refused, even when a line of it is allowed" "outside allowed_files: \$'evil\\\\nVERSION'"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; echo x >"$(printf "VERSION\t")"' bump 1.2.1
expect_fail "a path with a tab is refused" "outside allowed_files: \$'VERSION\\\\t'"

new_repo
BUMP='true' bump 1.2.1
expect_fail "a bump that changes nothing fails" "changed nothing"

new_repo
BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; git commit -qam bump' bump 1.2.1
expect_fail "a bump that commits fails" "it must change files, not commit"

new_repo
BUMP='echo 1.2.2 >VERSION' bump 1.2.1
expect_fail "a bump that writes another version fails" "prints '1.2.2', not 1.2.1"

new_repo
BUMP='exit 3' bump 1.2.1
expect_fail "a failing bump command fails" "bump_command failed"

for bad in "" "../VERSION" "/etc/passwd" "./VERSION" "a/../VERSION" ".git/config"; do
	new_repo
	ALLOWED="$bad" BUMP='touch RAN' bump 1.2.1
	if [ "$STATUS" -ne 0 ] && [ ! -e "$REPO/RAN" ] && grep -q "allowed_files" <<<"$LOG"; then
		ok "allowed_files '$bad' is refused before the bump"
	else
		not_ok "allowed_files '$bad' is refused before the bump" "$LOG"
	fi
done

new_repo
echo dirty >>"$REPO/README.md"
BUMP='touch RAN' bump 1.2.1
if [ "$STATUS" -ne 0 ] && grep -q "not clean before the bump" <<<"$LOG" && [ ! -e "$REPO/RAN" ]; then
	ok "a dirty checkout fails before the bump"
else
	not_ok "a dirty checkout fails before the bump" "$LOG"
fi

new_repo
ALLOWED=$'Cargo.toml\nVERSION\n' bump 1.2.1
if [ "$STATUS" -eq 0 ]; then ok "allowed_files may be newline separated, and need not all change"; else not_ok "allowed_files may be newline separated, and need not all change" "$LOG"; fi

echo "# export"

new_repo
bump 1.2.1 >/dev/null
export_patch
if [ "$STATUS" -eq 0 ] && [ -s "$PATCH" ] && git -C "$PUB" apply --check "$PATCH"; then
	ok "the staged bump is exported as a patch that applies to a fresh checkout"
else
	not_ok "the staged bump is exported as a patch that applies to a fresh checkout" "$LOG"
fi

new_repo
git -C "$REPO" config diff.external "$WORK/bin/no-such-diff"
bump 1.2.1 >/dev/null
export_patch
if [ "$STATUS" -eq 0 ] && grep -q '^+1.2.1' "$PATCH"; then ok "the export ignores an external diff driver the bump configured"; else not_ok "the export ignores an external diff driver the bump configured" "$LOG"; fi

echo "# job boundaries"

check() {
	if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "want: $3
got:  $2"; fi
}
check "the bump job's token is read-only" "$(wf '.jobs.bump.permissions | to_entries | map(.key + ":" + .value) | join(" ")')" "contents:read"
check "the bump job's steps get no token" "$(wf '[.jobs.bump.steps[] | .env // {} | keys[] | select(test("TOKEN"))] | length')" "0"
check "the bump job's checkout persists no credential" \
	"$(wf '.jobs.bump.steps[] | select((.uses // "") | test("^actions/checkout@")) | .with["persist-credentials"]')" "false"
check "the publish job runs neither command" \
	"$(wf '[.jobs.publish.steps[] | tostring | select(test("bump_command|version_command"))] | length')" "0"
check "the publish job checks out the dispatched commit, without a credential" \
	"$(wf '.jobs.publish.steps[] | select((.uses // "") | test("^actions/checkout@")) | .with.ref + " " + (.with["persist-credentials"] | tostring)')" \
	"\${{ github.sha }} false"
check "the publish job has exactly the write grants it uses" \
	"$(wf '.jobs.publish.permissions | to_entries | map(.key + ":" + .value) | join(" ")')" \
	"contents:write pull-requests:write actions:write"
check "the publish job needs the bump job" "$(wf '.jobs.publish.needs')" "bump"

echo "# publish"

new_repo
bump_job 1.2.1
publish
BRANCH_SHA=$(branch_sha release/v1.2.1)
if [ "$STATUS" -eq 0 ] && [ -n "$BRANCH_SHA" ] \
	&& [ "$(git -C "$ORIGIN" rev-parse "$BRANCH_SHA^")" = "$HEAD_SHA" ] \
	&& [ "$(git -C "$ORIGIN" show "$BRANCH_SHA:VERSION")" = 1.2.1 ] \
	&& [ "$(git -C "$ORIGIN" log -1 --format='%s|%an <%ae>|%cn <%ce>' "$BRANCH_SHA")" = "chore(release): bump version to 1.2.1|github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>|github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ] \
	&& grep -q '^pr create --repo leinardi/test --base main --head release/v1.2.1 ' "$GH_STUB_DIR/calls" \
	&& grep -qx 'workflow run ci.yaml --repo leinardi/test --ref release/v1.2.1' "$GH_STUB_DIR/calls" \
	&& [ "$(out pull_request)" = 42 ] && [ "$(out branch)" = release/v1.2.1 ] && [ "$(out tag)" = v1.2.1 ]; then
	ok "fresh: one bot-authored and bot-committed bump on the dispatched commit, as release/<tag>, PR opened, CI dispatched"
else
	not_ok "fresh: one bot-authored and bot-committed bump on the dispatched commit, as release/<tag>, PR opened, CI dispatched" "$LOG$(calls)"
fi
if [ "$(sed -n '/^pr create/=' "$GH_STUB_DIR/calls")" -lt "$(sed -n '/^workflow run/=' "$GH_STUB_DIR/calls")" ]; then
	ok "CI is dispatched after the PR is opened"
else
	not_ok "CI is dispatched after the PR is opened" "$(calls)"
fi

new_repo
BEFORE=$(remote_refs)
current >/dev/null
bump_job 1.2.1
publish true
if [ "$STATUS" -eq 0 ] && [ "$(remote_refs)" = "$BEFORE" ] && [ -z "$(writes)" ] && grep -q "Dry run: would push this bump to release/v1.2.1, then open a pull request" <<<"$LOG" \
	&& grep -q '^+1.2.1' <<<"$LOG" && [ "$(git -C "$PUB" rev-parse HEAD)" = "$HEAD_SHA" ]; then
	ok "dry run: prints the diff and the plan; no branch, no commit, no PR, no dispatch"
else
	not_ok "dry run: prints the diff and the plan; no branch, no commit, no PR, no dispatch" "$LOG$(calls)"
fi

# An open PR whose branch is exactly this bump on this commit: reused as it is.
new_repo
bump_job 1.2.1
publish >/dev/null
FIRST=$(branch_sha release/v1.2.1)
bot_pr 7
: >"$GH_STUB_DIR/calls"
fresh_pub
publish
if [ "$STATUS" -eq 0 ] && [ "$(branch_sha release/v1.2.1)" = "$FIRST" ] && ! grep -q '^pr create' "$GH_STUB_DIR/calls" \
	&& grep -qx 'workflow run ci.yaml --repo leinardi/test --ref release/v1.2.1' "$GH_STUB_DIR/calls" && [ "$(out pull_request)" = 7 ]; then
	ok "an open bot PR that is this bump is reused as it is and its CI dispatched again"
else
	not_ok "an open bot PR that is this bump is reused as it is and its CI dispatched again" "$LOG$(calls)"
fi
if grep -q -- '-f state=open -f base=main -f head=leinardi:release/v1.2.1' "$GH_STUB_DIR/calls"; then
	ok "the open PRs are asked for by this owner's branch into the default branch"
else
	not_ok "the open PRs are asked for by this owner's branch into the default branch" "$(calls)"
fi

# An open PR whose branch is not this bump (an older main, an extra commit, the bump under a
# human identity): it gets this bump.
for setup in "the default branch moved on" "someone pushed to it" "a human recommitted it" "a human committed the bot's commit"; do
	new_repo
	if [ "$setup" = "the default branch moved on" ]; then
		git -C "$REPO" switch -q -c old
		echo 1.2.1 >"$REPO/VERSION"
		git -C "$REPO" commit -qam "chore(release): bump version to 1.2.1"
		OLD=$(git -C "$REPO" rev-parse HEAD)
		git -C "$REPO" switch -q main
		git -C "$REPO" commit -q --allow-empty -m "fix(core): main moved on"
		git -C "$REPO" push -q origin HEAD:refs/heads/main "$OLD:refs/heads/release/v1.2.1"
		HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
		fresh_pub
	elif [ "$setup" = "a human recommitted it" ] || [ "$setup" = "a human committed the bot's commit" ]; then
		# The same parent and tree as this bump, under another identity: release-on-merge
		# would refuse it, so it is not reused.
		bump_job 1.2.1
		publish >/dev/null
		if [ "$setup" = "a human recommitted it" ]; then
			git -C "$PUB" -c user.name=Human -c user.email=human@example.com commit -q --amend --no-edit --reset-author
		else
			git -C "$PUB" -c user.name=Human -c user.email=human@example.com commit -q --amend --no-edit
		fi
		git -C "$PUB" push -q -f origin HEAD:refs/heads/release/v1.2.1
		git -C "$REPO" reset -q --hard "$HEAD_SHA"
		fresh_pub
	else
		bump_job 1.2.1
		publish >/dev/null
		git -C "$PUB" commit -q --allow-empty -m "feat(core): sneaked in"
		git -C "$PUB" push -q origin HEAD:refs/heads/release/v1.2.1
		git -C "$REPO" reset -q --hard "$HEAD_SHA"
		fresh_pub
	fi
	STALE=$(branch_sha release/v1.2.1)
	bot_pr 7
	: >"$GH_STUB_DIR/calls"
	bump_job 1.2.1
	publish
	NEW=$(branch_sha release/v1.2.1)
	if [ "$STATUS" -eq 0 ] && [ "$NEW" != "$STALE" ] && [ "$(git -C "$ORIGIN" log --format=%P -1 "$NEW")" = "$HEAD_SHA" ] \
		&& ! grep -q '^pr create' "$GH_STUB_DIR/calls" && grep -q '^workflow run' "$GH_STUB_DIR/calls" \
		&& [ "$(git -C "$ORIGIN" log -1 --format='%an <%ae>|%cn <%ce>' "$NEW")" = "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>|github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ] \
		&& [ "$(out pull_request)" = 7 ] && grep -q "is not this bump" <<<"$LOG"; then
		ok "an open bot PR whose branch is not this bump ($setup) gets this one bot bump commit, CI dispatched"
	else
		not_ok "an open bot PR whose branch is not this bump ($setup) gets this one bot bump commit, CI dispatched" "$LOG$(calls)"
	fi
done

new_repo
bump_job 1.2.1
publish >/dev/null
FIRST=$(branch_sha release/v1.2.1)
bot_pr 7
: >"$GH_STUB_DIR/calls"
fresh_pub
publish true
if [ "$STATUS" -eq 0 ] && [ -z "$(writes)" ] && [ "$(branch_sha release/v1.2.1)" = "$FIRST" ] && grep -q "would dispatch ci.yaml" <<<"$LOG"; then
	ok "dry run with an open PR writes nothing"
else
	not_ok "dry run with an open PR writes nothing" "$LOG$(calls)"
fi

new_repo
bot_pr 7
bump_job 1.2.1
publish
expect_fail "an open PR whose branch is gone fails" "is open but release/v1.2.1 is gone"

new_repo
pr 7 leinardi/test release/v1.2.1 leinardi | jq -s . >"$GH_STUB_DIR/pulls.json"
bump_job 1.2.1
publish
if [ "$STATUS" -ne 0 ] && grep -q "opened by leinardi" <<<"$LOG" && [ -z "$(writes)" ] && [ -z "$(branch_sha release/v1.2.1)" ]; then
	ok "an open PR opened by someone else fails, nothing written"
else
	not_ok "an open PR opened by someone else fails, nothing written" "$LOG$(calls)"
fi

new_repo
{
	pr 7 leinardi/test release/v1.2.1 'github-actions[bot]'
	pr 8 leinardi/test release/v1.2.1 'github-actions[bot]'
} | jq -s . >"$GH_STUB_DIR/pulls.json"
bump_job 1.2.1
publish
if [ "$STATUS" -ne 0 ] && grep -q "has 2 open pull requests" <<<"$LOG" && [ -z "$(writes)" ]; then
	ok "two open PRs on the branch fail"
else
	not_ok "two open PRs on the branch fail" "$LOG$(calls)"
fi

new_repo
{
	pr 9 someone/test release/v1.2.1 someone
	pr 10 "" release/v1.2.1 someone
	pr 11 leinardi/test release/v1.2.10 'github-actions[bot]'
} | jq -s . >"$GH_STUB_DIR/pulls.json"
bump_job 1.2.1
publish
if [ "$STATUS" -eq 0 ] && [ -n "$(branch_sha release/v1.2.1)" ] && grep -q '^pr create' "$GH_STUB_DIR/calls"; then
	ok "a fork's or a deleted fork's PR, and another branch's, are not this branch's PR"
else
	not_ok "a fork's or a deleted fork's PR, and another branch's, are not this branch's PR" "$LOG$(calls)"
fi

new_repo
git -C "$REPO" switch -q -c stale
echo 9.9.9 >"$REPO/VERSION"
git -C "$REPO" commit -qam "chore(release): an old bump"
git -C "$REPO" push -q origin HEAD:refs/heads/release/v1.2.1
STALE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q main
bump_job 1.2.1
publish
NEW=$(branch_sha release/v1.2.1)
if [ "$STATUS" -eq 0 ] && [ "$NEW" != "$STALE" ] && [ "$(git -C "$ORIGIN" rev-parse "$NEW^")" = "$HEAD_SHA" ] \
	&& [ "$(git -C "$ORIGIN" show "$NEW:VERSION")" = 1.2.1 ] && grep -q "recreated" <<<"$LOG" && grep -q '^pr create' "$GH_STUB_DIR/calls"; then
	ok "a stale branch with no open PR is recreated from this commit"
else
	not_ok "a stale branch with no open PR is recreated from this commit" "$LOG$(calls)"
fi

new_repo
bump_job 1.2.1
echo "X GraphQL: a pull request already exists (createPullRequest)" >"$GH_STUB_DIR/fail_create"
publish
FIRST=$(branch_sha release/v1.2.1)
rm "$GH_STUB_DIR/fail_create"
if [ "$STATUS" -ne 0 ] && [ -n "$FIRST" ] && ! grep -q '^workflow run' "$GH_STUB_DIR/calls"; then
	ok "a failed PR create stops before the dispatch"
else
	not_ok "a failed PR create stops before the dispatch" "$LOG$(calls)"
fi
: >"$GH_STUB_DIR/calls"
fresh_pub
publish
if [ "$STATUS" -eq 0 ] && [ "$(git -C "$ORIGIN" rev-parse "$(branch_sha release/v1.2.1)^")" = "$HEAD_SHA" ] \
	&& grep -q '^pr create' "$GH_STUB_DIR/calls" && grep -q '^workflow run' "$GH_STUB_DIR/calls"; then
	ok "the re-run after it recreates the branch it left and finishes"
else
	not_ok "the re-run after it recreates the branch it left and finishes" "$LOG$(calls)"
fi

new_repo
bump_job 1.2.1
cat >"$GH_STUB_DIR/race" <<RACE
git -C "$REPO" push -q -f origin "$HEAD_SHA:refs/heads/release/v1.2.1"
RACE
publish
if [ "$STATUS" -ne 0 ] && [ "$(branch_sha release/v1.2.1)" = "$HEAD_SHA" ] && [ -z "$(writes)" ]; then
	ok "a branch pushed between the read and the push is not overwritten (the lease), and no PR is opened"
else
	not_ok "a branch pushed between the read and the push is not overwritten (the lease), and no PR is opened" "$LOG$(calls)"
fi

new_repo
echo '[{"ref":"refs/tags/v1.2.1"}]' >"$GH_STUB_DIR/refs.json"
bump_job 1.2.1
publish
if [ "$STATUS" -ne 0 ] && grep -q "tag v1.2.1 already exists" <<<"$LOG" && [ -z "$(writes)" ] && [ -z "$(branch_sha release/v1.2.1)" ]; then
	ok "an existing tag fails, nothing written"
else
	not_ok "an existing tag fails, nothing written" "$LOG$(calls)"
fi

new_repo
echo '[{"ref":"refs/tags/v1.2.10"},{"ref":"refs/tags/v1.2.11"}]' >"$GH_STUB_DIR/refs.json"
bump_job 1.2.1
publish
if [ "$STATUS" -eq 0 ] && [ -n "$(branch_sha release/v1.2.1)" ]; then
	ok "a tag that only starts with the tag (v1.2.10) is not the tag"
else
	not_ok "a tag that only starts with the tag (v1.2.10) is not the tag" "$LOG$(calls)"
fi

for err in "HTTP 502: Bad Gateway" "HTTP 403: Resource not accessible by integration" "HTTP 404: Not Found"; do
	for what in refs pulls; do
		new_repo
		echo "gh: $err" >"$GH_STUB_DIR/fail_$what"
		bump_job 1.2.1
		publish
		if [ "$STATUS" -ne 0 ] && grep -q "Could not" <<<"$LOG" && [ -z "$(writes)" ] && [ -z "$(branch_sha release/v1.2.1)" ]; then
			ok "the $what lookup failing with '$err' fails closed"
		else
			not_ok "the $what lookup failing with '$err' fails closed" "$LOG$(calls)"
		fi
	done
	new_repo
	bump_job 1.2.1
	publish >/dev/null
	FIRST=$(branch_sha release/v1.2.1)
	bot_pr 7
	echo "gh: $err" >"$GH_STUB_DIR/fail_commit"
	: >"$GH_STUB_DIR/calls"
	fresh_pub
	publish
	if [ "$STATUS" -ne 0 ] && grep -q "Could not read release/v1.2.1's head" <<<"$LOG" && [ -z "$(writes)" ] && [ "$(branch_sha release/v1.2.1)" = "$FIRST" ]; then
		ok "reading the open PR's head failing with '$err' fails closed"
	else
		not_ok "reading the open PR's head failing with '$err' fails closed" "$LOG$(calls)"
	fi
done

for bad in "" "ci" "../ci.yaml" "ci.yaml --ref main" "sub/ci.yaml"; do
	new_repo
	bump_job 1.2.1
	CI="$bad" publish
	if [ "$STATUS" -ne 0 ] && grep -q "ci_workflow must be" <<<"$LOG" && [ ! -s "$GH_STUB_DIR/calls" ]; then
		ok "ci_workflow '$bad' is refused before any call"
	else
		not_ok "ci_workflow '$bad' is refused before any call" "$LOG$(calls)"
	fi
done

# The bump job's outputs are checked again: it ran repository code.
for pair in "1.2:v1.2" "1.2.1:v1.2.2" "1.2.1:1.2.1" '1.2.1$(touch PWNED):v1.2.1$(touch PWNED)' ":"; do
	new_repo
	bump_job 1.2.1
	VERSION_OUT="${pair%%:*}" TAG_OUT="${pair#*:}" publish
	if [ "$STATUS" -ne 0 ] && grep -q "from the bump job" <<<"$LOG" && [ ! -s "$GH_STUB_DIR/calls" ] && [ ! -e "$PUB/PWNED" ]; then
		ok "a bump job output of version/tag '$pair' is refused before any call"
	else
		not_ok "a bump job output of version/tag '$pair' is refused before any call" "$LOG$(calls)"
	fi
done

# The patch is judged again, after it is applied: a bump job that ran hostile code could have
# uploaded anything.
new_repo
ALLOWED="VERSION README.md" BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION; echo x >>README.md' bump_job 1.2.1
publish
if [ "$STATUS" -ne 0 ] && grep -q "README.md (not in allowed_files)" <<<"$LOG" && [ ! -s "$GH_STUB_DIR/calls" ]; then
	ok "a patch that changes a file outside allowed_files is refused before any call"
else
	not_ok "a patch that changes a file outside allowed_files is refused before any call" "$LOG$(calls)"
fi

new_repo
ALLOWED=$'VERSION' BUMP='printf "%s\n" "$RELEASE_VERSION" >VERSION' bump_job 1.2.1
(cd "$REPO" && git reset -q && printf 'x\n' >"$(printf 'evil\nVERSION')" && git add -A && git diff --cached --binary >"$PATCH")
publish
if [ "$STATUS" -ne 0 ] && grep -q "(control character)" <<<"$LOG" && [ ! -s "$GH_STUB_DIR/calls" ]; then
	ok "a patch with a newline in a path is refused"
else
	not_ok "a patch with a newline in a path is refused" "$LOG$(calls)"
fi

new_repo
bump_job 1.2.1
(cd "$REPO" && git reset -q && git checkout -q VERSION && rm VERSION && ln -s /etc/passwd VERSION && git add -A && git diff --cached --binary >"$PATCH")
publish
if [ "$STATUS" -ne 0 ] && grep -q "VERSION (mode 120000: only regular files)" <<<"$LOG" && [ ! -s "$GH_STUB_DIR/calls" ]; then
	ok "a patch that turns an allowed file into a symlink is refused"
else
	not_ok "a patch that turns an allowed file into a symlink is refused" "$LOG$(calls)"
fi

new_repo
bump_job 1.2.1
printf 'diff --git a/.git/config b/.git/config\nnew file mode 100644\n--- /dev/null\n+++ b/.git/config\n@@ -0,0 +1 @@\n+[core]\n' >"$PATCH"
PUB_ALLOWED=".git/config" publish
if [ "$STATUS" -ne 0 ] && [ ! -s "$GH_STUB_DIR/calls" ]; then ok "a patch into .git is refused"; else not_ok "a patch into .git is refused" "$LOG$(calls)"; fi

new_repo
bump_job 1.2.1
printf 'garbage\n' >"$PATCH"
publish
if [ "$STATUS" -ne 0 ] && [ ! -s "$GH_STUB_DIR/calls" ]; then ok "a patch that is not a patch is refused"; else not_ok "a patch that is not a patch is refused" "$LOG$(calls)"; fi

new_repo
bump_job 1.2.1
git -C "$PUB" commit -q --allow-empty -m "not the dispatched commit"
publish
expect_fail "a publish checkout that is not the dispatched commit is refused" "is not a clean $HEAD_SHA"

new_repo
bump_job 1.2.1
PUB_ALLOWED="" publish
expect_fail "an empty allowed_files is refused in publish too" "allowed_files is empty"

# Nothing from the checkout's own git config runs while the token is in the environment.
new_repo
bump_job 1.2.1
mkdir -p "$PUB/.git/hooks"
for hook in pre-commit commit-msg post-commit pre-push reference-transaction; do
	printf '#!/bin/sh\ntouch "%s/RAN-%s"\n' "$WORK" "$hook" >"$PUB/.git/hooks/$hook"
	chmod +x "$PUB/.git/hooks/$hook"
done
printf '#!/bin/sh\ntouch "%s/RAN-fsmonitor"\n' "$WORK" >"$WORK/fsmonitor"
chmod +x "$WORK/fsmonitor"
git -C "$PUB" config core.fsmonitor "$WORK/fsmonitor"
publish
RAN=$(find "$WORK" -maxdepth 1 -name 'RAN-*' -printf '%f ')
if [ "$STATUS" -eq 0 ] && [ -z "$RAN" ]; then
	ok "no git hook and no fsmonitor in the checkout runs while the token is in the environment"
else
	not_ok "no git hook and no fsmonitor in the checkout runs while the token is in the environment" "ran: $RAN
$LOG"
fi

new_repo
PREFIX=gtk-rs-skills--v bump_job 1.2.1 gtk-rs-skills--v1.2.1
PREFIX=gtk-rs-skills--v VERSION_OUT=1.2.1 TAG_OUT=gtk-rs-skills--v1.2.1 publish
if [ "$STATUS" -eq 0 ] && [ -n "$(branch_sha release/gtk-rs-skills--v1.2.1)" ] \
	&& grep -q 'git/matching-refs/tags/gtk-rs-skills--v1.2.1' "$GH_STUB_DIR/calls"; then
	ok "a prefixed tag gets release/<prefix>X.Y.Z"
else
	not_ok "a prefixed tag gets release/<prefix>X.Y.Z" "$LOG$(calls)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
