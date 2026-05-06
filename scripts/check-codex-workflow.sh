#!/usr/bin/env bash
# scripts/check-codex-workflow.sh
#
# Static-inspection suite for `.github/workflows/codexPrReview.yml`.
# This script is the executable spec compliance matrix for the Codex
# PR Review reusable workflow. Every assertion below is traceable to
# a REQ in `flow/codex-action-integration/spec` (engram observation #193).
#
# RED-GREEN-REFACTOR maps to:
#   - RED: append a failing assertion (file/string missing)
#   - GREEN: edit the workflow YAML so the assertion passes
#   - REFACTOR: tidy YAML / comments without breaking assertions
#
# Tooling assumptions:
#   - bash (set -euo pipefail)
#   - actionlint  (https://github.com/rhysd/actionlint)  — YAML + expr lint
#   - grep -E / -F                                       — substring assertions
#   - jq                                                 — used only if needed
#
# `yq` (mikefarah v4) is NOT required — assertions use grep patterns instead,
# because yq is not pre-installed on this workstation. See plan risk P3 / P4.
#
# REQ → assertion mapping (Batch 0 tracer scope only — later batches append):
#   REQ-001  : workflow file exists, is workflow_call               (asserts 1, 2)
#   REQ-002  : pr_number input declared as required number          (assert 3)
#   REQ-004  : openai_api_key secret declared required              (assert 4)
#   REQ-005  : workflow-level permissions block                     (assert 5)
#   REQ-011  : pinned to openai/codex-action@v1, sandbox/safety     (asserts 6,8,9)
#   REQ-012  : comment posted via actions/github-script@v7          (assert 7)
#   REQ-014  : continue-on-error on Codex + comment steps           (asserts 10,11)
#
# REQ-021/REQ-022 (canary observations) are deferred to verify phase.
# REQ-003 / REQ-006..010 / REQ-013 / REQ-015..020 land in Batch 1+.

set -euo pipefail

WORKFLOW_FILE=".github/workflows/codexPrReview.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok: $*"
}

echo "Running static-inspection checks against $WORKFLOW_FILE"
echo

# --- REQ-001 Scenario 1: file exists ---
[ -f "$WORKFLOW_FILE" ] || fail "REQ-001: $WORKFLOW_FILE does not exist"
pass "REQ-001: workflow file exists"

# --- REQ-001 Scenario 1: actionlint passes ---
if command -v actionlint >/dev/null 2>&1; then
  actionlint "$WORKFLOW_FILE" || fail "REQ-001: actionlint reported errors"
  pass "REQ-001: actionlint clean"
else
  echo "  warn: actionlint not installed — skipping syntactic lint"
fi

# --- REQ-001 Scenario 1: declares workflow_call trigger ---
grep -qE '^\s*workflow_call:\s*$' "$WORKFLOW_FILE" \
  || fail "REQ-001: missing 'workflow_call:' trigger"
pass "REQ-001: workflow_call trigger present"

# Helper: assert that within a window of N lines after a header key,
# all of the given patterns appear at least once. Exits 0 on success.
# Args: $1 = file, $2 = header regex, $3 = window size, $4..N = patterns
assert_in_window() {
  local file="$1" header="$2" window="$3"
  shift 3
  awk -v hdr="$header" -v win="$window" -v patcsv="$(IFS=$'\x1f'; echo "$*")" '
    BEGIN {
      n = split(patcsv, pats, "\x1f")
      for (i=1; i<=n; i++) seen[i]=0
    }
    {
      if (in_window) {
        for (i=1; i<=n; i++) if ($0 ~ pats[i]) seen[i]=1
        win--
        if (win == 0) in_window = 0
      }
      if ($0 ~ hdr) { in_window=1; win=ENVIRON["WIN"] ? ENVIRON["WIN"]+0 : 8 }
    }
    END {
      ok=1
      for (i=1; i<=n; i++) if (!seen[i]) ok=0
      exit ok ? 0 : 1
    }
  ' WIN="$window" "$file"
}

# --- REQ-002 Scenario 1: pr_number declared as required number ---
assert_in_window "$WORKFLOW_FILE" '^[[:space:]]*pr_number:[[:space:]]*$' 8 \
  'type:[[:space:]]*number' \
  'required:[[:space:]]*true' \
  || fail "REQ-002: pr_number must be declared with 'type: number' and 'required: true'"
pass "REQ-002: pr_number is required number input"

# --- REQ-004 Scenario 1: openai_api_key secret required ---
assert_in_window "$WORKFLOW_FILE" '^[[:space:]]*openai_api_key:[[:space:]]*$' 6 \
  'required:[[:space:]]*true' \
  || fail "REQ-004: secret 'openai_api_key' must be declared required: true"
pass "REQ-004: openai_api_key secret is required"

# --- REQ-005 Scenario 1: workflow-level permissions block with three scopes ---
# Match the workflow-level (not job-level) permissions: block — the
# tracer has only one permissions: block, so a simple grep is sufficient.
grep -qE '^\s*contents:\s*read\s*$'           "$WORKFLOW_FILE" \
  || fail "REQ-005: missing 'contents: read' permission"
grep -qE '^\s*pull-requests:\s*write\s*$'     "$WORKFLOW_FILE" \
  || fail "REQ-005: missing 'pull-requests: write' permission"
grep -qE '^\s*issues:\s*write\s*$'            "$WORKFLOW_FILE" \
  || fail "REQ-005: missing 'issues: write' permission"
pass "REQ-005: permissions block declares contents/pull-requests/issues"

# --- REQ-011 Scenario 1: pinned to openai/codex-action@v1 (exactly once) ---
codex_pin_count=$(grep -cE '^\s*uses:\s*openai/codex-action@v1\s*$' "$WORKFLOW_FILE" || true)
[ "$codex_pin_count" = "1" ] \
  || fail "REQ-011: expected exactly one 'uses: openai/codex-action@v1' line, found $codex_pin_count"
pass "REQ-011: pinned to openai/codex-action@v1"

# --- REQ-012 Scenario 1: comment posted via actions/github-script@v7 ---
grep -qE '^\s*uses:\s*actions/github-script@v7\s*$' "$WORKFLOW_FILE" \
  || fail "REQ-012: missing 'uses: actions/github-script@v7' for comment posting"
pass "REQ-012: actions/github-script@v7 step present"

# --- REQ-011 Scenario 2: sandbox: read-only on Codex step ---
grep -qE '^\s*sandbox:\s*read-only\s*$' "$WORKFLOW_FILE" \
  || fail "REQ-011: Codex step must set 'sandbox: read-only'"
pass "REQ-011: sandbox is read-only"

# --- REQ-011 Scenario 2: safety-strategy: drop-sudo on Codex step ---
grep -qE '^\s*safety-strategy:\s*drop-sudo\s*$' "$WORKFLOW_FILE" \
  || fail "REQ-011: Codex step must set 'safety-strategy: drop-sudo'"
pass "REQ-011: safety-strategy is drop-sudo"

# --- REQ-014 Scenario 1: continue-on-error: true appears at least twice ---
# (once for Codex step, once for comment step). Tracer minimum is 2.
coe_count=$(grep -cE '^\s*continue-on-error:\s*true\s*$' "$WORKFLOW_FILE" || true)
[ "$coe_count" -ge 2 ] \
  || fail "REQ-014: expected at least 2 'continue-on-error: true' lines (Codex + comment), found $coe_count"
pass "REQ-014: continue-on-error: true present on >= 2 steps ($coe_count)"

# --- D16 negative assertion: no Azure passthrough inputs ---
if grep -qE 'responses_api_endpoint|azure_endpoint|azure_api_version' "$WORKFLOW_FILE"; then
  fail "D16: Azure passthrough input detected — v1 is OpenAI-only"
fi
pass "D16: no Azure passthrough inputs"

echo
echo "ALL CODEX-WORKFLOW CHECKS PASSED (Batch 0 tracer scope)"
