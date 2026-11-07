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
# Tests the inline scripts of .github/workflows/release-on-merge.yaml.
#
# The scripts are extracted from the workflow with yq, so what is tested is exactly what the
# workflow runs: the versions job's comparison against throwaway git repositories, the authorize
# job's checks against canned GitHub API responses served by a stub `gh` (that job has no checkout).
# The CI gate (require-ci-green) is tested in its own repository; the job graph is checked here as
# written.
#
# Needs: bash, git, yq (mikefarah v4), jq.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/release-on-merge.yaml"

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
extract versions versions
extract authorize authorize

# The gh stub. State lives under $GH_STUB_DIR, one file per endpoint, printed raw (so several JSON
# arrays stand for several pages) and filtered through the real jq when the call passes --jq:
#   list.<n>            the n-th `commits/{sha}/pulls` listing (missing: prints nothing)
#   pr.<number>         `pulls/<number>` (missing: HTTP 404)
#   prcommits.<number>  `pulls/<number>/commits`
#   commit.<sha>        `commits/<sha>` (missing: HTTP 404)
#   compare             `compare/<base>...<head>`
#   <file>.fail         that call fails with the file's content on stderr (list.fail for listings)
#   calls               one line per invocation
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$GH_STUB_DIR/calls"
[ "$1" = api ] || { echo "unexpected gh $*" >&2; exit 1; }
shift
path="" jq_expr=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--jq) jq_expr=$2; shift 2 ;;
	--paginate) shift ;;
	*) path=$1; shift ;;
	esac
done
serve() {
	local file="$GH_STUB_DIR/$1"
	[ ! -e "$file.fail" ] || { cat "$file.fail" >&2; exit 1; }
	if [ ! -e "$file" ]; then
		[ "${2:-}" = optional ] && return 0
		echo "gh: Not Found (HTTP 404)" >&2
		exit 1
	fi
	if [ -n "$jq_expr" ]; then jq -r "$jq_expr" "$file"; else cat "$file"; fi
}
case "$path" in
repos/*/commits/*/pulls\?per_page=100)
	[ ! -e "$GH_STUB_DIR/list.fail" ] || { cat "$GH_STUB_DIR/list.fail" >&2; exit 1; }
	n=$(grep -c '/pulls?per_page=100' "$GH_STUB_DIR/calls")
	serve "list.$n" optional
	;;
repos/*/pulls/*/commits\?per_page=100) n=${path#*/pulls/}; serve "prcommits.${n%%/*}" ;;
repos/*/pulls/*) serve "pr.${path##*/}" ;;
repos/*/compare/*) serve compare ;;
repos/*/commits/*) serve "commit.${path##*/}" ;;
*) echo "unexpected gh api $path" >&2; exit 1 ;;
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

run_step() {
	local script=$1
	shift
	OUT_FILE="$WORK/output"
	: >"$OUT_FILE"
	STATUS=0
	LOG=$(cd "${RUN_IN:-$WORK}" && env GITHUB_OUTPUT="$OUT_FILE" "$@" bash "$WORK/$script.sh" 2>&1) || STATUS=$?
	OUTPUT=$(cat "$OUT_FILE")
}
out() { sed -n "s/^$1=//p" <<<"$OUTPUT"; }
expect_fail() {
	local name=$1 pattern=$2
	if [ "$STATUS" -ne 0 ] && grep -q -- "$pattern" <<<"$LOG"; then ok "$name"; else not_ok "$name (want a failure matching '$pattern', status $STATUS)" "$LOG"; fi
}

echo "# versions"

N=0
# A fresh repository at $REPO whose first commit carries VERSION $1 (default 1.2.0). BEFORE is
# the tip of main before the push under test.
new_repo() {
	N=$((N + 1))
	REPO="$WORK/repo-$N"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" config commit.gpgsign false
	echo "${1:-1.2.0}" >"$REPO/VERSION"
	git -C "$REPO" add VERSION
	git -C "$REPO" commit -q -m "chore(repo): initial commit"
	git -C "$REPO" commit -q --allow-empty -m "fix(core): main moves on"
	BEFORE=$(git -C "$REPO" rev-parse HEAD)
}
# Merges a release/<tag> branch that sets VERSION to $1 into main with a merge commit, the way
# GitHub merges a pull request: one push whose before is the old main.
merge_bump() {
	git -C "$REPO" switch -q -c "release/v$1" HEAD~1
	echo "$1" >"$REPO/VERSION"
	git -C "$REPO" commit -q -am "chore(release): bump version to $1"
	git -C "$REPO" switch -q main
	git -C "$REPO" merge -q --no-ff -m "Merge pull request #42 from leinardi/release/v$1" "release/v$1"
}
versions() {
	RUN_IN="$REPO" run_step versions VERSION_COMMAND="${CMD:-cat VERSION}" TAG_PREFIX="${PREFIX-v}" \
		SHA="$(git -C "$REPO" rev-parse HEAD)" BEFORE="${BEFORE_IN-$BEFORE}"
}

new_repo
git -C "$REPO" commit -q --allow-empty -m "fix(core): a fix"
versions
if [ "$STATUS" -eq 0 ] && [ "$(out candidate)" = false ] && grep -q "unchanged (1.2.0)" <<<"$LOG"; then
	ok "an unchanged version is a green no-op"
else
	not_ok "an unchanged version is a green no-op" "$LOG"
fi

new_repo
merge_bump 1.3.0
versions
if [ "$STATUS" -eq 0 ] && [ "$(out candidate)" = true ] && [ "$(out version)" = 1.3.0 ] && [ "$(out previous)" = 1.2.0 ]; then
	ok "a merge that raises the version is a candidate, compared with the first parent"
else
	not_ok "a merge that raises the version is a candidate, compared with the first parent" "$LOG$OUTPUT"
fi
if [ -z "$(git -C "$REPO" worktree list | sed 1d)" ]; then ok "the worktrees are removed"; else not_ok "the worktrees are removed" "$(git -C "$REPO" worktree list)"; fi

new_repo
merge_bump 1.10.0
BEFORE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q -c lower
echo 1.9.0 >"$REPO/VERSION"
git -C "$REPO" commit -q -am "chore(release): go down"
git -C "$REPO" switch -q main
git -C "$REPO" merge -q --no-ff -m "Merge pull request #43 from leinardi/lower" lower
versions
expect_fail "a version that goes down (1.10.0 -> 1.9.0) fails" "went down (1.10.0 -> 1.9.0)"

new_repo
echo 1.3.0 >"$REPO/VERSION"
git -C "$REPO" commit -q -am "chore(release): a hand bump, pushed straight to main"
versions
if [ "$STATUS" -eq 0 ] && [ "$(out candidate)" = true ]; then
	ok "a single plain commit that changes the version reaches the authorization (which refuses it)"
else
	not_ok "a single plain commit that changes the version reaches the authorization (which refuses it)" "$LOG"
fi

new_repo
echo 1.3.0 >"$REPO/VERSION"
git -C "$REPO" commit -q -am "chore(release): the bump"
git -C "$REPO" commit -q --allow-empty -m "fix(core): and one more commit in the same push"
versions
expect_fail "a push of several commits that changes the version fails red, not a no-op" "changed (1.2.0 -> 1.3.0) in a push of more than one commit"

new_repo
merge_bump 1.3.0
git -C "$REPO" commit -q --allow-empty -m "fix(core): pushed with the merge"
versions
expect_fail "a merge pushed together with a later commit fails red" "in a push of more than one commit"

new_repo
echo 1.3.0 >"$REPO/VERSION"
git -C "$REPO" commit -q -am "chore(release): up"
echo 1.2.0 >"$REPO/VERSION"
git -C "$REPO" commit -q -am "chore(release): and down again"
versions
if [ "$STATUS" -eq 0 ] && [ "$(out candidate)" = false ]; then
	ok "a push of several commits that leaves the version as it was is a no-op"
else
	not_ok "a push of several commits that leaves the version as it was is a no-op" "$LOG"
fi

for bad in "" 0000000000000000000000000000000000000000 abc; do
	new_repo
	merge_bump 1.3.0
	BEFORE_IN="$bad" versions
	expect_fail "a push whose before is '$bad' fails red" "has no previous commit"
done

new_repo
merge_bump 1.3.0
BEFORE_IN=1234567890123456789012345678901234567890 versions
expect_fail "a push whose before is not in the history (a force push) fails red" "is not in the history"

new_repo
merge_bump 1.3.0
RUN_IN="$REPO" run_step versions VERSION_COMMAND="cat VERSION" TAG_PREFIX=v SHA=1234567890123456789012345678901234567890 BEFORE="$BEFORE"
expect_fail "a checkout that is not the pushed commit fails" "not the pushed"

new_repo
git -C "$REPO" checkout -q --orphan root
git -C "$REPO" commit -q -m "chore(repo): a root commit"
BEFORE_IN="" versions
expect_fail "a commit without a parent fails" "has no parent"

new_repo
git -C "$REPO" rm -q VERSION
echo 1.3.0 >"$REPO/NEWVERSION"
git -C "$REPO" add NEWVERSION
git -C "$REPO" commit -q -m "chore(repo): move the version"
CMD='cat NEWVERSION' versions
expect_fail "the version command failing on the parent fails" "failed on the first parent"

for bad in "v1.3.0" "1.3" "" "1.3.0-rc.1"; do
	new_repo
	git -C "$REPO" commit -q --allow-empty -m "fix(core): a fix"
	CMD="echo '$bad'" versions
	expect_fail "a version command printing '$bad' fails" "not one X.Y.Z line"
done

for bad in "" "a b" 'v$'; do
	new_repo
	merge_bump 1.3.0
	PREFIX="$bad" versions
	expect_fail "the tag prefix '$bad' is refused" "tag_prefix"
done

echo "# authorize"

SHA=$(printf 'a%.0s' {1..40})
PARENT=$(printf 'b%.0s' {1..40})
BUMP_SHA=$(printf 'c%.0s' {1..40})
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

# A canned API where everything qualifies: the merge commit $SHA of pull request #42, whose one
# commit $BUMP_SHA changes VERSION. Each case then breaks one thing.
fixture() {
	N=$((N + 1))
	export GH_STUB_DIR="$WORK/gh-$N"
	mkdir -p "$GH_STUB_DIR"
	: >"$GH_STUB_DIR/calls"
	jq -n --arg sha "$SHA" --arg p "$PARENT" --arg c "$BUMP_SHA" \
		'{sha: $sha, parents: [{sha: $p}, {sha: $c}], commit: {message: "Merge pull request #42 from leinardi/release/v1.3.0\n\nchore(release): bump version to 1.3.0"}}' \
		>"$GH_STUB_DIR/commit.$SHA"
	echo '{"status": "ahead", "files": [{"filename": "VERSION", "status": "modified"}]}' >"$GH_STUB_DIR/compare"
	echo '[{"number": 42}]' >"$GH_STUB_DIR/list.1"
	pr_json 42 >"$GH_STUB_DIR/pr.42"
	jq -n --arg c "$BUMP_SHA" --arg n "$BOT_NAME" --arg e "$BOT_EMAIL" \
		'[{sha: $c, commit: {author: {name: $n, email: $e}, committer: {name: $n, email: $e}}}]' >"$GH_STUB_DIR/prcommits.42"
	jq -n --arg c "$BUMP_SHA" '{sha: $c, files: [{filename: "VERSION", status: "modified"}]}' >"$GH_STUB_DIR/commit.$BUMP_SHA"
}
# A pull request record as `GET pulls/{number}` returns it, qualifying by default; a jq filter in $2
# changes it.
pr_json() {
	jq -n --argjson n "$1" --arg sha "$SHA" --arg c "$BUMP_SHA" '{
		number: $n, state: "closed", merged: true, merged_at: "2026-11-07T12:00:00Z",
		merge_commit_sha: $sha,
		base: {ref: "main", repo: {full_name: "leinardi/test"}},
		head: {ref: "release/v1.3.0", sha: $c, repo: {full_name: "leinardi/test"}},
		user: {login: "github-actions[bot]", type: "Bot"}
	}' | jq "${2:-.}"
}
edit() {
	local file="$GH_STUB_DIR/$1"
	jq "$2" "$file" >"$file.new"
	mv "$file.new" "$file"
}
authorize() {
	run_step authorize REPO=leinardi/test SHA="${SHA_IN-$SHA}" DEFAULT_BRANCH=main VERSION="${VERSION_IN-1.3.0}" \
		TAG_PREFIX="${PREFIX-v}" ALLOWED_FILES="${ALLOWED-VERSION}" GH_TOKEN=stub \
		AUTHORIZE_ATTEMPTS="${ATTEMPTS:-1}" AUTHORIZE_DELAY=0
}
expect_refused() {
	local name=$1 pattern=$2
	authorize
	if [ "$STATUS" -ne 0 ] && grep -q -- "$pattern" <<<"$LOG" && [ -z "$(out authorized)" ]; then
		ok "$name"
	else
		not_ok "$name (want a refusal matching '$pattern', status $STATUS)" "$LOG"
	fi
}

fixture
authorize
if [ "$STATUS" -eq 0 ] && [ "$(out authorized)" = true ] && [ "$(out pull_request)" = 42 ] \
	&& [ "$(out tag)" = v1.3.0 ] && [ "$(out version)" = 1.3.0 ] \
	&& grep -q "'Merge pull request #42 from leinardi/release/v1.3.0' (diagnostic only)" <<<"$LOG"; then
	ok "exactly one qualifying PR with its one bump commit authorizes; the subject is only printed"
else
	not_ok "exactly one qualifying PR with its one bump commit authorizes; the subject is only printed" "$LOG"
fi
if grep -q "compare/$PARENT...$SHA" "$GH_STUB_DIR/calls"; then ok "the merge is compared with the first parent the API reports"; else not_ok "the merge is compared with the first parent the API reports" "$(cat "$GH_STUB_DIR/calls")"; fi

fixture
echo '[{"number": 41}, {"number": 42}]' >"$GH_STUB_DIR/list.1"
pr_json 41 '.merge_commit_sha = "0000000000000000000000000000000000000000" | .head.ref = "feature"' >"$GH_STUB_DIR/pr.41"
authorize
if [ "$STATUS" -eq 0 ] && [ "$(out pull_request)" = 42 ] && grep -q "#41: merged as 0000" <<<"$LOG"; then
	ok "one qualifying PR among others: authorized, the others explained"
else
	not_ok "one qualifying PR among others: authorized, the others explained" "$LOG"
fi

fixture
rm "$GH_STUB_DIR/list.1"
ATTEMPTS=3 expect_refused "zero PRs (an empty list, read again): refused" "is not the merge of version-bump-pr's release/v1.3.0 pull request (0 associated)"
if [ "$(grep -c '/pulls?per_page=100' "$GH_STUB_DIR/calls")" = 3 ]; then ok "an empty list is read AUTHORIZE_ATTEMPTS times"; else not_ok "an empty list is read AUTHORIZE_ATTEMPTS times" "$(cat "$GH_STUB_DIR/calls")"; fi

fixture
mv "$GH_STUB_DIR/list.1" "$GH_STUB_DIR/list.2"
ATTEMPTS=3 authorize
if [ "$STATUS" -eq 0 ] && [ "$(out pull_request)" = 42 ]; then ok "a PR association that shows up on a later read authorizes"; else not_ok "a PR association that shows up on a later read authorizes" "$LOG"; fi

fixture
edit pr.42 '.head.ref = "feature"'
ATTEMPTS=3 expect_refused "a non-qualifying PR is not read again" "1 associated"
if [ "$(grep -c '/pulls?per_page=100' "$GH_STUB_DIR/calls")" = 1 ]; then ok "only an empty list is read again"; else not_ok "only an empty list is read again" "$(cat "$GH_STUB_DIR/calls")"; fi

fixture
echo '[{"number": 42}, {"number": 43}]' >"$GH_STUB_DIR/list.1"
pr_json 43 >"$GH_STUB_DIR/pr.43"
expect_refused "several qualifying PRs: refused" "2 qualifying pull requests (42 43)"

fixture
edit pr.42 '.head.repo.full_name = "someone/test"'
expect_refused "a fork head: refused" "from someone/test, not leinardi/test"

fixture
edit pr.42 '.head.repo = null'
expect_refused "a deleted fork head: refused" "from a deleted repository"

for ref in feature release/v1.3.0-x release/v1.3 release/foo--v1.3.0 refs/heads/release/v1.3.0; do
	fixture
	edit pr.42 ".head.ref = \"$ref\""
	expect_refused "head ref '$ref': refused" "from branch $ref, not release/v1.3.0"
done

fixture
edit pr.42 '.head.ref = "release/v1.3.1"'
expect_refused "the version file (1.3.0) does not match the PR's tag (v1.3.1): refused" "not release/v1.3.0"

fixture
PREFIX=gtk-rs-skills--v expect_refused "a v branch does not authorize a prefixed tag" "not release/gtk-rs-skills--v1.3.0"

fixture
edit pr.42 '.head.ref = "release/gtk-rs-skills--v1.3.0"'
PREFIX=gtk-rs-skills--v authorize
if [ "$STATUS" -eq 0 ] && [ "$(out tag)" = gtk-rs-skills--v1.3.0 ]; then ok "a prefixed release branch authorizes its tag"; else not_ok "a prefixed release branch authorizes its tag" "$LOG"; fi

fixture
edit pr.42 '.user = {login: "leinardi", type: "User"}'
expect_refused "opened by a person: refused" "opened by leinardi, not github-actions\[bot\]"

fixture
edit pr.42 '.user.type = "User"'
expect_refused "the bot's login on a user account: refused" "not github-actions\[bot\]"

fixture
edit pr.42 '.user.login = "dependabot[bot]"'
expect_refused "opened by another bot: refused" "opened by dependabot\[bot\]"

fixture
edit pr.42 '.merge_commit_sha = "1111111111111111111111111111111111111111"'
expect_refused "merge_commit_sha is not the pushed SHA: refused" "merged as 1111111111111111111111111111111111111111, not $SHA"

fixture
edit pr.42 'del(.merge_commit_sha)'
expect_refused "no merge_commit_sha: refused" "merged as nothing"

fixture
edit pr.42 '.merged = false | .merged_at = null | .state = "open"'
expect_refused "not merged: refused" "not merged"

fixture
edit pr.42 '.merged = false'
expect_refused "merged_at set but merged false: refused" "not merged"

fixture
edit pr.42 '.base.ref = "develop"'
expect_refused "merged into another branch: refused" "into leinardi/test:develop, not leinardi/test:main"

fixture
edit pr.42 '.base.repo.full_name = "someone/test"'
expect_refused "merged into another repository: refused" "into someone/test:main"

echo "# authorize: content"

fixture
jq -n --arg c "$BUMP_SHA" --arg n "$BOT_NAME" --arg e "$BOT_EMAIL" \
	'[{sha: $c, commit: {author: {name: $n, email: $e}, committer: {name: $n, email: $e}}},
	  {sha: "dddddddddddddddddddddddddddddddddddddddd", commit: {author: {name: "leinardi", email: "x@y"}, committer: {name: "leinardi", email: "x@y"}}}]' \
	>"$GH_STUB_DIR/prcommits.42"
expect_refused "an extra commit on the bot PR: refused" "holds 2 commits, not the one bump commit"

fixture
echo '[]' >"$GH_STUB_DIR/prcommits.42"
expect_refused "a PR with no commits: refused" "holds 0 commits"

fixture
{
	echo '[]'
	jq -n --arg c "$BUMP_SHA" --arg n "$BOT_NAME" --arg e "$BOT_EMAIL" \
		'[{sha: $c, commit: {author: {name: $n, email: $e}, committer: {name: $n, email: $e}}}]'
	jq -n --arg n "$BOT_NAME" --arg e "$BOT_EMAIL" \
		'[{sha: "dddddddddddddddddddddddddddddddddddddddd", commit: {author: {name: $n, email: $e}, committer: {name: $n, email: $e}}}]'
} >"$GH_STUB_DIR/prcommits.42"
expect_refused "every page of the PR's commits counts: a second commit on page 2 is refused" "holds 2 commits"

for field in author.name author.email committer.name committer.email; do
	fixture
	edit prcommits.42 ".[0].commit.$field = \"someone\""
	expect_refused "the bump commit's $field is not version-bump-pr's: refused" "is not version-bump-pr's"
done

fixture
edit prcommits.42 '.[0].sha = "dddddddddddddddddddddddddddddddddddddddd"'
expect_refused "the one commit is not the PR's head: refused" "is not its head"

fixture
edit "commit.$BUMP_SHA" '.files += [{filename: "src/main.rs", status: "modified"}]'
expect_refused "an extra file in the bump commit: refused" "bump commit $BUMP_SHA changes files outside allowed_files: \"src/main.rs\" (not in allowed_files)"

fixture
edit "commit.$BUMP_SHA" '.files = [{filename: "VERSION", previous_filename: "src/main.rs", status: "renamed"}]'
ALLOWED="VERSION" expect_refused "a rename onto an allowed file counts its old name too: refused" '"src/main.rs" (not in allowed_files)'

fixture
edit compare '.files += [{filename: ".github/workflows/release.yaml", status: "modified"}]'
expect_refused "a non-bump workflow's release/<tag> PR with other files: refused by the merge diff" "changes files outside allowed_files: \".github/workflows/release.yaml\""

fixture
edit compare '.files = [{filename: "evil\nVERSION", status: "added"}]'
ALLOWED="VERSION" expect_refused "a file name with a newline in the merge diff: refused" 'outside allowed_files: "evil\\nVERSION" (control character)'

fixture
edit "commit.$BUMP_SHA" '.files = [{filename: "VERSION\t", status: "added"}]'
expect_refused "a file name with a tab in the bump commit: refused" 'outside allowed_files: "VERSION\\t" (control character)'

fixture
edit compare '.files = [range(300) | {filename: "VERSION", status: "modified"}]'
expect_refused "a merge diff of 300 files (possibly truncated): refused" "malformed or incomplete"

for bad in '{"status": "ahead"}' '{"files": []}' '[]' 'not json' '{"files": [{"filename": 1}]}'; do
	fixture
	printf '%s\n' "$bad" >"$GH_STUB_DIR/compare"
	expect_refused "a merge diff of $bad: refused" "allowed_files\|malformed or incomplete"
done

fixture
ALLOWED="Cargo.toml Cargo.lock VERSION" authorize
if [ "$STATUS" -eq 0 ]; then ok "allowed_files may list files the bump did not change"; else not_ok "allowed_files may list files the bump did not change" "$LOG"; fi

for bad in "" "../VERSION" "/VERSION" "./VERSION" ".git/config"; do
	fixture
	ALLOWED="$bad" expect_refused "allowed_files '$bad' is refused" "allowed_files"
	if [ ! -s "$GH_STUB_DIR/calls" ]; then ok "... before any API call"; else not_ok "... before any API call" "$(cat "$GH_STUB_DIR/calls")"; fi
done

echo "# authorize: API errors and malformed answers"

for err in "HTTP 403: Resource not accessible by integration" "HTTP 502: Bad Gateway" "HTTP 500: Internal Server Error" "HTTP 409: Conflict"; do
	for what in "commit.$SHA:Could not read $SHA" "compare:Could not compare" "list:Could not list the pull requests" \
		"pr.42:Could not read pull request #42" "prcommits.42:Could not list the commits" "commit.$BUMP_SHA:Could not read the bump commit"; do
		fixture
		echo "gh: $err" >"$GH_STUB_DIR/${what%%:*}.fail"
		expect_refused "${what%%.*} failing with '$err': refused" "${what#*:}"
	done
done

fixture
rm "$GH_STUB_DIR/pr.42"
expect_refused "a listed PR that cannot be read (HTTP 404): refused" "Could not read pull request #42"

for bad in 'not json' '{"number": 42}' '["42"]' '[{"id": 42}]' '[{"number": "42"}]' '[{"number": 42}] {"x": 1}' '[null]'; do
	fixture
	printf '%s\n' "$bad" >"$GH_STUB_DIR/list.1"
	expect_refused "a malformed PR listing ($bad): refused" "malformed"
done

for bad in 'not json' '[1]' '"x"'; do
	fixture
	printf '%s\n' "$bad" >"$GH_STUB_DIR/pr.42"
	expect_refused "a malformed PR record ($bad): refused" "malformed"
done

fixture
echo '{}' >"$GH_STUB_DIR/pr.42"
expect_refused "an empty PR record: refused, not trusted" "not merged"

for bad in 'not json' '{}' '[{"commit": {}}]' '[{"sha": "x", "commit": {}}]'; do
	fixture
	printf '%s\n' "$bad" >"$GH_STUB_DIR/prcommits.42"
	expect_refused "a malformed PR commit list ($bad): refused" "malformed\|not version-bump-pr's"
done

for bad in '{"sha": "x"}' '{"parents": []}' '{"parents": [{"sha": "nope"}]}' 'not json'; do
	fixture
	printf '%s\n' "$bad" >"$GH_STUB_DIR/commit.$SHA"
	expect_refused "a pushed commit without a first parent ($bad): refused" "no first parent"
done

fixture
pr_json 42 >"$GH_STUB_DIR/pr.42"
{
	jq -n '[range(1; 101) | {number: (1000 + .)}]'
	echo '[{"number": 42}]'
} >"$GH_STUB_DIR/list.1"
for i in $(seq 1001 1100); do pr_json "$i" '.head.ref = "feature"' >"$GH_STUB_DIR/pr.$i"; done
authorize
if [ "$STATUS" -eq 0 ] && [ "$(out pull_request)" = 42 ] && grep -q -- '--paginate repos/leinardi/test/commits/.*/pulls' "$GH_STUB_DIR/calls"; then
	ok "every page is read: the qualifying PR on page 2 authorizes"
else
	not_ok "every page is read: the qualifying PR on page 2 authorizes" "$LOG"
fi

echo "# authorize: the versions job's outputs"

# shellcheck disable=SC2016 # the command substitution must reach the step unexpanded.
for bad in "" "1.3" "v1.3.0" '1.3.0$(touch PWNED)' "1.3.0
release=true"; do
	fixture
	VERSION_IN="$bad" expect_refused "a reported version '$bad' is refused" "not X.Y.Z"
	if [ ! -s "$GH_STUB_DIR/calls" ] && [ ! -e "$WORK/PWNED" ]; then ok "... before any API call"; else not_ok "... before any API call" "$(cat "$GH_STUB_DIR/calls")"; fi
done

for bad in "" "abc" "$(printf 'A%.0s' {1..40})" "0123456"; do
	fixture
	SHA_IN="$bad" expect_refused "the pushed SHA '$bad' is refused" "not a full commit SHA"
	if [ ! -s "$GH_STUB_DIR/calls" ]; then ok "... before any API call"; else not_ok "... before any API call" "$(cat "$GH_STUB_DIR/calls")"; fi
done

for bad in "" "a b" 'v$'; do
	fixture
	PREFIX="$bad" expect_refused "the tag prefix '$bad' is refused" "tag_prefix"
done

echo "# job graph"

check() {
	if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "want: $3
got:  $2"; fi
}
perms() { wf ".jobs.$1.permissions | to_entries | map(.key + \":\" + .value) | join(\" \")"; }
check "versions: read-only" "$(perms versions)" "contents:read"
check "versions: no token in any step" "$(wf '[.jobs.versions.steps[] | .env // {} | keys[] | select(test("TOKEN"))] | length')" "0"
check "versions: the checkout persists no credential" \
	"$(wf '.jobs.versions.steps[] | select((.uses // "") | test("^actions/checkout@")) | .with["persist-credentials"]')" "false"
check "authorize: read-only, pull requests and contents" "$(perms authorize)" "contents:read pull-requests:read"
check "authorize: no checkout and no repository code" \
	"$(wf '[.jobs.authorize.steps[] | select(.uses != null or (tostring | test("version_command")))] | length')" "0"
check "authorize: runs only for a candidate" "$(wf '.jobs.authorize.if')" "needs.versions.outputs.candidate == 'true'"
check "ci: actions read only" "$(perms ci)" "actions:read"
check "ci: needs the authorization" "$(wf '.jobs.ci.needs + " " + .jobs.ci.if')" "authorize needs.authorize.outputs.authorized == 'true'"
check "ci: waits on the pushed SHA, for the push to the default branch" \
	"$(wf '.jobs.ci.steps[0].with.sha + " " + .jobs.ci.steps[0].with["accepted-events"]')" "\${{ github.sha }} push"
check "ci: the pinned require-ci-green" "$(wf '.jobs.ci.steps[0].uses')" \
	"leinardi/gh-composite-actions/require-ci-green@73fdb81c6cb1d2a3ea7c669e3bc136538e0f4ffa"
check "ci: release=true is written after the gate, in the same job" "$(wf '.jobs.ci.steps[1].id')" "mark"
check "the release output is the ci job's mark only" "$(wf '.on.workflow_call.outputs.release.value')" "\${{ jobs.ci.outputs.release }}"
check "no job calls another workflow (the caller calls simple-tag-and-release)" "$(wf '[.jobs[] | select(has("uses"))] | length')" "0"
check "the workflow's group is its own and never cancelled" \
	"$(wf '.concurrency.group + " " + (.concurrency["cancel-in-progress"] | tostring)')" \
	"release-on-merge-\${{ github.repository }} false"
check "every job has a timeout" "$(wf '[.jobs[] | has("timeout-minutes")] | all')" "true"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
