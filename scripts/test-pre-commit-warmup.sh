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
# Tests the prune step of .github/workflows/pre-commit-warmup.yaml.
#
# The script is extracted from the workflow with yq, so what is tested is exactly what the workflow
# runs. `gh` is replaced by a stub (below) that serves a fixed cache list through the real jq,
# records every call, and fails the way the GitHub API does when asked to.
#
# Needs: bash, yq (mikefarah v4), jq.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/pre-commit-warmup.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

yq -r '.jobs.prune.steps[] | select(.id == "prune") | .run' "$WORKFLOW" >"$WORK/prune.sh"
if [ ! -s "$WORK/prune.sh" ]; then
	echo "no step with id 'prune' in $WORKFLOW" >&2
	exit 1
fi

# The gh stub. State lives under $GH_STUB_DIR:
#   caches     the JSON array `gh cache list --json id` returns, newest first
#   list_fail  if present, `gh cache list` fails with its content on stderr
#   del_fail   if present, `gh cache delete` fails with its content on stderr
#   calls      one line per invocation
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$GH_STUB_DIR/calls"
case "$1 $2" in
"cache list")
	if [ -e "$GH_STUB_DIR/list_fail" ]; then
		cat "$GH_STUB_DIR/list_fail" >&2
		exit 1
	fi
	expr=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--jq) expr=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	jq -r "$expr" "$GH_STUB_DIR/caches"
	;;
"cache delete")
	if [ -e "$GH_STUB_DIR/del_fail" ]; then
		cat "$GH_STUB_DIR/del_fail" >&2
		exit 1
	fi
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
	printf '%s\n' "$2" | sed 's/^/       /'
}

# A fresh stub state with caches 5 (newest) down to 1 (oldest).
reset() {
	export GH_STUB_DIR="$WORK/state"
	rm -rf "$GH_STUB_DIR"
	mkdir -p "$GH_STUB_DIR"
	echo '[{"id":5},{"id":4},{"id":3},{"id":2},{"id":1}]' >"$GH_STUB_DIR/caches"
	: >"$GH_STUB_DIR/calls"
}

# prune KEEP: runs the step as the workflow would; sets STATUS and LOG.
prune() {
	STATUS=0
	LOG=$(env GH_REPO=owner/repo CACHE_REF=refs/heads/main KEY_PREFIX=pre-commit KEEP="$1" \
		bash "$WORK/prune.sh" 2>&1) || STATUS=$?
}
deleted() { sed -n 's/^cache delete //p' "$GH_STUB_DIR/calls" | tr '\n' ' '; }
fails() {
	not_ok "$1" "status=$STATUS deleted=[$(deleted)]
$LOG
$(cat "$GH_STUB_DIR/calls")"
}

reset
prune 2
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "3 2 1 " ]; then
	ok "keeps the newest two and deletes the rest"
else
	fails "keeps the newest two and deletes the rest"
fi
if grep -q -- "--ref refs/heads/main --key pre-commit| --sort created_at --order desc" "$GH_STUB_DIR/calls"; then
	ok "lists only the calling ref, under the key prefix and its separator"
else
	fails "lists only the calling ref, under the key prefix and its separator"
fi

reset
prune 5
if [ "$STATUS" -eq 0 ] && [ -z "$(deleted)" ] && grep -q "Nothing to prune" <<<"$LOG"; then
	ok "deletes nothing when there are no more caches than it keeps"
else
	fails "deletes nothing when there are no more caches than it keeps"
fi

reset
prune 1
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "4 3 2 1 " ]; then
	ok "keep_caches 1 keeps only the newest"
else
	fails "keep_caches 1 keeps only the newest"
fi

for bad in 0 -1 abc 1.5 ""; do
	reset
	prune "$bad"
	if [ "$STATUS" -ne 0 ] && [ ! -s "$GH_STUB_DIR/calls" ] && grep -q "::error" <<<"$LOG"; then
		ok "keep_caches '$bad' fails before calling gh"
	else
		fails "keep_caches '$bad' fails before calling gh"
	fi
done

reset
echo "X Failed to get caches: HTTP 403: Resource not accessible by integration" >"$GH_STUB_DIR/list_fail"
prune 2
if [ "$STATUS" -eq 0 ] && [ -z "$(deleted)" ] && grep -q "^::warning" <<<"$LOG"; then
	ok "a caller without actions permissions gets a warning and a skipped prune"
else
	fails "a caller without actions permissions gets a warning and a skipped prune"
fi

reset
echo "X Failed to delete cache: HTTP 403: Resource not accessible by integration" >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "3 " ] && grep -q "^::warning" <<<"$LOG"; then
	ok "a caller with actions: read only gets a warning after the first refused delete"
else
	fails "a caller with actions: read only gets a warning after the first refused delete"
fi

reset
echo "X Could not find a cache matching 3 in owner/repo" >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "3 2 1 " ]; then
	ok "a cache another run already deleted is not an error"
else
	fails "a cache another run already deleted is not an error"
fi

reset
echo "X Failed to get caches: HTTP 502: Bad Gateway" >"$GH_STUB_DIR/list_fail"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "HTTP 502" <<<"$LOG"; then
	ok "any other list error fails the job"
else
	fails "any other list error fails the job"
fi

reset
echo "X Failed to delete cache: HTTP 500: Internal Server Error" >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "HTTP 500" <<<"$LOG"; then
	ok "any other delete error fails the job"
else
	fails "any other delete error fails the job"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
