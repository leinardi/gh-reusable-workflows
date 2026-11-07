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
# Tests .github/workflows/pre-commit-warmup.yaml.
#
# The install step's script is extracted with yq and run with stub `python` and `pre-commit`
# commands, so what is tested is exactly what the workflow runs. The cache key and the prune call
# are checked as written in the workflow, against the key format the callers' CI must restore and
# against this repository's own CI (local-ci.yaml), which restores it. The prune itself is the
# prune-caches action of leinardi/gh-composite-actions, tested there.
#
# Needs: bash, yq (mikefarah v4).

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/pre-commit-warmup.yaml"
LOCAL_CI="$ROOT/.github/workflows/local-ci.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

wf() { yq -r "$1" "$WORKFLOW"; }
step() { wf ".jobs[\"$1\"].steps[] | select(.id == \"$2\") | $3"; }
ci_step() { yq -r ".jobs[\"pre-commit-all\"].steps[] | select($1) | $2" "$LOCAL_CI"; }

step warm-pre-commit-cache install .run >"$WORK/install.sh"
if [ ! -s "$WORK/install.sh" ]; then
	echo "no step with id 'install' in $WORKFLOW" >&2
	exit 1
fi

# Stubs: `python -m pip ...` and `pre-commit --version` record their arguments.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/python" <<'STUB'
#!/usr/bin/env bash
echo "python $*" >>"$STUB_CALLS"
STUB
cat >"$WORK/bin/pre-commit" <<'STUB'
#!/usr/bin/env bash
echo "pre-commit $*" >>"$STUB_CALLS"
STUB
chmod +x "$WORK/bin/python" "$WORK/bin/pre-commit"
PATH="$WORK/bin:$PATH"
export STUB_CALLS="$WORK/calls"

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok   - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "FAIL - $1"
	printf '%s\n' "${2:-}" | sed 's/^/       /'
}
check() {
	local name=$1 got=$2 want=$3
	if [ "$got" = "$want" ]; then
		ok "$name"
	else
		not_ok "$name" "want: $want
got:  $got"
	fi
}

install() {
	: >"$STUB_CALLS"
	STATUS=0
	LOG=$(env PRE_COMMIT_VERSION="$1" bash "$WORK/install.sh" 2>&1) || STATUS=$?
}

echo "# install"

install 4.6.2
if [ "$STATUS" -eq 0 ] && grep -qxF "python -m pip install --disable-pip-version-check --no-cache-dir pre-commit==4.6.2" "$STUB_CALLS"; then
	ok "installs exactly the pinned pre-commit"
else
	not_ok "installs exactly the pinned pre-commit" "$LOG
$(cat "$STUB_CALLS")"
fi

for bad in "" 4.6 4.6.2.1 v4.6.2 "4.6.2 --index-url=https://example.invalid" ">=4" 04.6.2 4.6.2rc1; do
	install "$bad"
	if [ "$STATUS" -ne 0 ] && [ ! -s "$STUB_CALLS" ] && grep -q "::error" <<<"$LOG"; then
		ok "pre_commit_version '$bad' fails before pip runs"
	else
		not_ok "pre_commit_version '$bad' fails before pip runs" "$LOG
$(cat "$STUB_CALLS")"
	fi
done

echo "# defaults"

DEFAULT_PRE_COMMIT=$(wf '.on.workflow_call.inputs.pre_commit_version.default')
check "pre_commit_version defaults to the version template-default's CI pins" "$DEFAULT_PRE_COMMIT" "4.6.2"
check "local-ci installs the warm-up's default pre-commit" \
	"$(ci_step '.name == "Install pre-commit"' .run)" "pip install --no-cache-dir pre-commit==$DEFAULT_PRE_COMMIT"
check "local-ci sets up the warm-up's default Python" \
	"$(ci_step '.id == "python"' '.with["python-version"]')" "$(wf '.on.workflow_call.inputs.python_version.default')"

echo "# cache key"

# The documented format, as a caller's CI writes it (the warm-up's prefix is an input).
KEY_FORMAT="\${{ inputs.cache_key_prefix }}|\${{ runner.os }}|\${{ steps.python.outputs.python-version }}|\${{ hashFiles('.pre-commit-config.yaml') }}"
check "the key is <prefix>|<os>|<resolved python>|<config hash>" "$(step warm-pre-commit-cache key .env.KEY)" "$KEY_FORMAT"
check "the resolved Python comes from a setup-python step with id 'python'" \
	"$(step warm-pre-commit-cache python '.uses | sub(" .*"; "") | sub("@.*"; "")')" "actions/setup-python"
check "the cache is saved under that key" "$(step warm-pre-commit-cache precommit '.with.key')" "\${{ steps.key.outputs.key }}"
check "local-ci restores the same setup-python as the warm-up" \
	"$(ci_step '.id == "python"' .uses)" "$(step warm-pre-commit-cache python .uses)"
DEFAULT_PREFIX=$(wf '.on.workflow_call.inputs.cache_key_prefix.default')
check "local-ci restores the warm-up's key, with the default prefix" \
	"$(ci_step '.name == "Restore the pre-commit cache"' .with.key)" \
	"${KEY_FORMAT/"\${{ inputs.cache_key_prefix }}"/$DEFAULT_PREFIX}"

echo "# prune"

PRUNE_STEP='.jobs.prune.steps[0]'
check "the prune is the pinned prune-caches action" \
	"$(wf "$PRUNE_STEP.uses")" "leinardi/gh-composite-actions/prune-caches@73fdb81c6cb1d2a3ea7c669e3bc136538e0f4ffa"
check "the prune deletes under the key prefix and its separator only" \
	"$(wf "$PRUNE_STEP.with[\"key-prefix\"]")" "\${{ inputs.cache_key_prefix }}|"
check "the prune keeps keep_caches entries" "$(wf "$PRUNE_STEP.with.keep")" "\${{ inputs.keep_caches }}"
check "the prune touches the calling ref only" "$(wf "$PRUNE_STEP.with.ref")" "\${{ github.ref }}"
check "the prune job declares no permissions (it runs with the calling job's grant)" \
	"$(wf '.jobs.prune | has("permissions")')" "false"
check "every job has a timeout" "$(wf '[.jobs[] | has("timeout-minutes")] | all')" "true"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
