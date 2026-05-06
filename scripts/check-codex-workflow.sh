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
# `yq` (mikefarah v4) is preferred for richer YAML queries when available;
# otherwise we fall back to grep + the awk `assert_in_window` helper. Batch 0
# was authored without yq; Batch 1+ uses yq when present (see plan risk P3/P4).
#
# REQ → assertion mapping (grows monotonically across batches):
#   REQ-001  : workflow file exists, is workflow_call               (Batch 0)
#   REQ-002  : pr_number input declared as required number          (Batch 0)
#   REQ-003  : review_prompt / prompt_file optional string inputs   (Batch 1.1)
#   REQ-004  : openai_api_key secret declared required              (Batch 0)
#   REQ-005  : workflow-level permissions block                     (Batch 0)
#   REQ-006  : ref resolution step (gh pr view fallback, fail-fast) (Batch 1.1)
#   REQ-007  : pre-fetch base + head refs                           (Batch 1.1)
#   REQ-008  : sparse second-checkout of .codex-defaults/           (Batch 1.4)
#   REQ-009  : prompt resolution precedence                         (Batch 1.5)
#   REQ-010  : fail-fast on missing prompt source                   (Batch 1.5)
#   REQ-011  : pinned @v1, sandbox/safety, full passthroughs        (Batch 0+1.6)
#   REQ-012  : one comment posted via github-script@v7, gated       (Batch 0+1.7)
#   REQ-013  : retrigger footer (Markdown blockquote)               (Batch 1.7)
#   REQ-014  : continue-on-error on Codex + comment steps only      (Batch 0+1.9)
#   TR-3     : 60K char body truncation                             (Batch 1.8)
#
# REQ-021/REQ-022 (canary observations) are deferred to verify phase.
# REQ-015..020 land in Batches 2/3.

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

################################################################################
# BATCH 1 — Core reusable workflow (full signature, sparse-checkout, prompt
# resolution, comment footer, truncation).
################################################################################

# --- Helpers (yq-preferred; fall back to assert_in_window) -------------------

have_yq() { command -v yq >/dev/null 2>&1; }

# --- Task 1.1: Full input + secret signature (REQ-003) -----------------------
#
# Caller-tunable optional inputs `review_prompt` and `prompt_file` MUST be
# declared as string with default empty (so the prompt-resolution step in
# Task 1.5 can branch on emptiness without further validation).

if have_yq; then
  rp_type=$(yq '.on.workflow_call.inputs.review_prompt.type // ""' "$WORKFLOW_FILE")
  rp_default=$(yq '.on.workflow_call.inputs.review_prompt.default // "MISSING"' "$WORKFLOW_FILE")
  pf_type=$(yq '.on.workflow_call.inputs.prompt_file.type // ""' "$WORKFLOW_FILE")
  pf_default=$(yq '.on.workflow_call.inputs.prompt_file.default // "MISSING"' "$WORKFLOW_FILE")
  [ "$rp_type" = "string" ] \
    || fail "REQ-003: review_prompt must be 'type: string' (got: $rp_type)"
  [ "$rp_default" = "" ] \
    || fail "REQ-003: review_prompt default must be empty string (got: '$rp_default')"
  [ "$pf_type" = "string" ] \
    || fail "REQ-003: prompt_file must be 'type: string' (got: $pf_type)"
  [ "$pf_default" = "" ] \
    || fail "REQ-003: prompt_file default must be empty string (got: '$pf_default')"
else
  # Fallback: best-effort header window match.
  assert_in_window "$WORKFLOW_FILE" '^[[:space:]]*review_prompt:[[:space:]]*$' 6 \
    'type:[[:space:]]*string' \
    'default:[[:space:]]*""' \
    || fail "REQ-003: review_prompt must be string with default \"\""
  assert_in_window "$WORKFLOW_FILE" '^[[:space:]]*prompt_file:[[:space:]]*$' 6 \
    'type:[[:space:]]*string' \
    'default:[[:space:]]*""' \
    || fail "REQ-003: prompt_file must be string with default \"\""
fi
pass "REQ-003: review_prompt + prompt_file optional string inputs declared"

# --- Task 1.1: Ref resolution step uses gh pr view (REQ-006 Scenarios 2, 3) --
# The step MUST use `gh pr view ... --json headRefOid,baseRefOid` so callers
# can pass only `pr_number` and have the workflow resolve both SHAs.
grep -qE 'gh pr view' "$WORKFLOW_FILE" \
  || fail "REQ-006: ref-resolution step must shell out to 'gh pr view'"
grep -qE 'headRefOid' "$WORKFLOW_FILE" \
  || fail "REQ-006: ref-resolution step must capture 'headRefOid'"
grep -qE 'baseRefOid' "$WORKFLOW_FILE" \
  || fail "REQ-006: ref-resolution step must capture 'baseRefOid' (REQ-007 needs base)"
pass "REQ-006: ref-resolution step resolves head + base via gh pr view"

# --- Task 1.1: Refs step has id: refs (so checkout can reference outputs) ---
if have_yq; then
  refs_id_present=$(yq '[.jobs.review.steps[] | select(.id == "refs")] | length' "$WORKFLOW_FILE")
  [ "$refs_id_present" = "1" ] \
    || fail "REQ-006: refs resolution step must have 'id: refs'"
else
  grep -qE '^[[:space:]]+id:[[:space:]]*refs[[:space:]]*$' "$WORKFLOW_FILE" \
    || fail "REQ-006: refs resolution step must have 'id: refs'"
fi
pass "REQ-006: ref-resolution step has 'id: refs'"

# --- Task 1.1: Pre-fetch step exists (REQ-007) -------------------------------
# Some step MUST run `git fetch origin <base_sha> <head_sha>` (or equivalent)
# after the caller checkout so the diff is available to Codex.
grep -qE 'git fetch.*origin' "$WORKFLOW_FILE" \
  || fail "REQ-007: pre-fetch step missing — expected 'git fetch origin <base> <head>'"
pass "REQ-007: pre-fetch step runs 'git fetch origin'"

# --- Task 1.3: D16 hardened — assert against the inputs map (no Azure keys) -
# Stronger than the file-wide grep above: check the *declared* workflow_call
# inputs do not contain any Azure-shaped key. Will fire even if a future
# author adds e.g. `responses_api_endpoint` as a real input.
if have_yq; then
  bad_keys=$(
    yq '.on.workflow_call.inputs
         | keys
         | map(select(test("(?i)azure|responses_api|api_version|deployment")))
         | .[]' "$WORKFLOW_FILE" || true
  )
  if [ -n "$bad_keys" ]; then
    fail "D16: Azure-shaped input keys present in workflow_call.inputs: $bad_keys"
  fi
fi
pass "D16: workflow_call.inputs map has no Azure-shaped keys"

# --- Task 1.2: Tightened caller checkout (REQ-006 Scenario 1) ---------------
# The first checkout step (NOT the sparse second-checkout — that one has
# `path:` set) MUST pin to the resolved head SHA with full history.
if have_yq; then
  caller_checkout_count=$(
    yq '[.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path // "" == "")] | length' "$WORKFLOW_FILE"
  )
  [ "$caller_checkout_count" = "1" ] \
    || fail "REQ-006: expected exactly 1 caller-side actions/checkout@v4 step (no path:), found $caller_checkout_count"
  caller_ref=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path // "" == "")
         | .with.ref' "$WORKFLOW_FILE"
  )
  caller_depth=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path // "" == "")
         | .with["fetch-depth"]' "$WORKFLOW_FILE"
  )
  echo "$caller_ref" | grep -qE 'steps\.refs\.outputs\.head_sha' \
    || fail "REQ-006: caller checkout 'ref' must reference steps.refs.outputs.head_sha (got: $caller_ref)"
  [ "$caller_depth" = "0" ] \
    || fail "REQ-006: caller checkout fetch-depth must be 0 (got: $caller_depth)"
else
  grep -qE 'ref:[[:space:]]*\$\{\{[[:space:]]*steps\.refs\.outputs\.head_sha[[:space:]]*\}\}' "$WORKFLOW_FILE" \
    || fail "REQ-006: caller checkout missing ref: \${{ steps.refs.outputs.head_sha }}"
  grep -qE 'fetch-depth:[[:space:]]*0[[:space:]]*$' "$WORKFLOW_FILE" \
    || fail "REQ-006: caller checkout missing fetch-depth: 0"
fi
pass "REQ-006: caller checkout pinned to head_sha with full history"

# --- Task 1.4: Sparse second-checkout of default prompt (REQ-008) -----------
# A second actions/checkout@v4 step MUST exist that fetches
# `Keiron-HealthTech/ReusableWorkflow` into `.codex-defaults/` with
# sparse-checkout limited to `.github/codex/pr-review.prompt.md`. The ref MUST
# pin to `github.workflow_sha` with `github.sha` fallback (TR-1 mitigation).
if have_yq; then
  sparse=$(
    yq '[.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path == ".codex-defaults")] | length' "$WORKFLOW_FILE"
  )
  [ "$sparse" = "1" ] \
    || fail "REQ-008: expected exactly 1 sparse-checkout step into .codex-defaults, found $sparse"

  sparse_repo=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path == ".codex-defaults")
         | .with.repository' "$WORKFLOW_FILE"
  )
  [ "$sparse_repo" = "Keiron-HealthTech/ReusableWorkflow" ] \
    || fail "REQ-008: sparse-checkout repository must be Keiron-HealthTech/ReusableWorkflow (got: $sparse_repo)"

  sparse_cone=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path == ".codex-defaults")
         | .with["sparse-checkout-cone-mode"]' "$WORKFLOW_FILE"
  )
  [ "$sparse_cone" = "false" ] \
    || fail "REQ-008: sparse-checkout-cone-mode must be false (got: $sparse_cone)"

  sparse_paths=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path == ".codex-defaults")
         | .with["sparse-checkout"]' "$WORKFLOW_FILE"
  )
  echo "$sparse_paths" | grep -qE '\.github/codex/pr-review\.prompt\.md' \
    || fail "REQ-008: sparse-checkout paths must include '.github/codex/pr-review.prompt.md'"
fi
pass "REQ-008: sparse-checkout step fetches default prompt into .codex-defaults/"

# --- Task 1.4: TR-1 fallback (workflow_sha || github.sha) -------------------
# When the reusable workflow is dispatched directly (rare but possible),
# `github.workflow_sha` may be empty. Fall back to `github.sha`.
grep -qE 'github\.workflow_sha[[:space:]]*\|\|[[:space:]]*github\.sha' "$WORKFLOW_FILE" \
  || fail "REQ-008/TR-1: sparse-checkout ref must use 'github.workflow_sha || github.sha' fallback"
pass "REQ-008/TR-1: sparse-checkout ref has workflow_sha || github.sha fallback"

# --- Task 1.4: Existence assertion before Codex (R6 mitigation) -------------
# After sparse-checkout but BEFORE Codex runs, the workflow MUST verify
# that .codex-defaults/.github/codex/pr-review.prompt.md exists when the
# default branch of prompt resolution will be taken. (Plan §6 R6.)
grep -qE '\.codex-defaults/\.github/codex/pr-review\.prompt\.md' "$WORKFLOW_FILE" \
  || fail "REQ-008: workflow must reference '.codex-defaults/.github/codex/pr-review.prompt.md' explicitly"
pass "REQ-008: default prompt path .codex-defaults/.github/codex/pr-review.prompt.md referenced"

# --- Task 1.5: Prompt-resolution step (REQ-009, REQ-010, REQ-003) -----------
# A step `id: prompt` MUST run BEFORE the Codex step and MUST resolve the
# effective prompt by precedence: inline review_prompt > prompt_file >
# default. The step has NO continue-on-error (REQ-010 fail-fast).
if have_yq; then
  prompt_step_count=$(
    yq '[.jobs.review.steps[] | select(.id == "prompt")] | length' "$WORKFLOW_FILE"
  )
  [ "$prompt_step_count" = "1" ] \
    || fail "REQ-009: expected exactly 1 step with 'id: prompt', found $prompt_step_count"

  prompt_coe=$(
    yq '.jobs.review.steps[] | select(.id == "prompt") | .["continue-on-error"] // "absent"' "$WORKFLOW_FILE"
  )
  [ "$prompt_coe" = "absent" ] \
    || fail "REQ-010: prompt-resolution step must NOT have continue-on-error (got: $prompt_coe)"
fi
pass "REQ-009/REQ-010: prompt-resolution step exists, fail-fast"

# --- Task 1.5: Heredoc-safe multiline output for inline prompt --------------
grep -qE 'effective_prompt_inline<<EOF_PROMPT' "$WORKFLOW_FILE" \
  || fail "REQ-009: prompt step must use heredoc-safe 'effective_prompt_inline<<EOF_PROMPT' for multiline output"
pass "REQ-009: prompt step uses heredoc-safe multiline output"

# --- Task 1.5: Fail-fast error annotations name the missing path (REQ-010) --
grep -qE '::error::.*prompt_file' "$WORKFLOW_FILE" \
  || fail "REQ-010 Scenario 1: missing '::error::' annotation naming prompt_file"
grep -qE '::error::.*default prompt|::error::.*\.codex-defaults' "$WORKFLOW_FILE" \
  || fail "REQ-010 Scenario 2: missing '::error::' annotation for missing default prompt"
pass "REQ-010: fail-fast '::error::' annotations name the missing prompt path"

# --- Task 1.5: Both effective outputs declared ------------------------------
grep -qE 'effective_prompt_inline' "$WORKFLOW_FILE" \
  || fail "REQ-009: prompt step must emit 'effective_prompt_inline' output"
grep -qE 'effective_prompt_file' "$WORKFLOW_FILE" \
  || fail "REQ-009: prompt step must emit 'effective_prompt_file' output"
pass "REQ-009: prompt step emits effective_prompt_inline + effective_prompt_file outputs"

# --- Task 1.6: Codex step wired to resolved prompt + passthroughs (REQ-011) -
if have_yq; then
  codex_prompt=$(
    yq '.jobs.review.steps[] | select(.id == "codex") | .with.prompt' "$WORKFLOW_FILE"
  )
  echo "$codex_prompt" | grep -qE 'steps\.prompt\.outputs\.effective_prompt_inline' \
    || fail "REQ-011: codex.with.prompt must reference steps.prompt.outputs.effective_prompt_inline (got: $codex_prompt)"

  codex_pf=$(
    yq '.jobs.review.steps[] | select(.id == "codex") | .with["prompt-file"]' "$WORKFLOW_FILE"
  )
  echo "$codex_pf" | grep -qE 'steps\.prompt\.outputs\.effective_prompt_file' \
    || fail "REQ-011: codex.with.prompt-file must reference steps.prompt.outputs.effective_prompt_file (got: $codex_pf)"

  codex_sandbox=$(
    yq '.jobs.review.steps[] | select(.id == "codex") | .with.sandbox' "$WORKFLOW_FILE"
  )
  echo "$codex_sandbox" | grep -qE 'inputs\.sandbox|^read-only$' \
    || fail "REQ-011: codex.with.sandbox must reference inputs.sandbox or be read-only (got: $codex_sandbox)"

  codex_model=$(
    yq '.jobs.review.steps[] | select(.id == "codex") | .with.model // ""' "$WORKFLOW_FILE"
  )
  echo "$codex_model" | grep -qE 'inputs\.model' \
    || fail "REQ-011: codex.with.model must reference inputs.model (got: $codex_model)"

  codex_coe=$(
    yq '.jobs.review.steps[] | select(.id == "codex") | .["continue-on-error"]' "$WORKFLOW_FILE"
  )
  [ "$codex_coe" = "true" ] \
    || fail "REQ-014: codex step must keep continue-on-error: true (got: $codex_coe)"
fi
pass "REQ-011: codex step wired to resolved prompt + passthroughs"

# --- Task 1.7: comment_on_pr input declared (REQ-012 Scenario 2) ------------
if have_yq; then
  cop_type=$(yq '.on.workflow_call.inputs.comment_on_pr.type // ""' "$WORKFLOW_FILE")
  cop_default=$(yq '.on.workflow_call.inputs.comment_on_pr.default // "MISSING"' "$WORKFLOW_FILE")
  [ "$cop_type" = "boolean" ] \
    || fail "REQ-012: comment_on_pr must be 'type: boolean' (got: $cop_type)"
  [ "$cop_default" = "true" ] \
    || fail "REQ-012: comment_on_pr default must be true (got: $cop_default)"
fi
pass "REQ-012: comment_on_pr boolean input with default true"

# --- Task 1.7: comment step gated by comment_on_pr (REQ-012 Scenario 2) -----
if have_yq; then
  comment_if=$(
    yq '.jobs.review.steps[] | select(.uses == "actions/github-script@v7") | .if // ""' "$WORKFLOW_FILE"
  )
  echo "$comment_if" | grep -qE 'inputs\.comment_on_pr' \
    || fail "REQ-012: github-script comment step must be gated by inputs.comment_on_pr (got: $comment_if)"
fi
pass "REQ-012: comment step gated by inputs.comment_on_pr"

# --- Task 1.7: env-hardened body (REQ-012 / hardening) ----------------------
grep -qE 'process\.env\.CODEX_FINAL_MESSAGE' "$WORKFLOW_FILE" \
  || fail "hardening: comment script must read CODEX_FINAL_MESSAGE from process.env (no \${{ }} interpolation into JS)"
pass "hardening: comment body read from process.env (no JS interpolation)"

# --- Task 1.7: retrigger footer (REQ-013) -----------------------------------
# Footer line MUST start with '> ' (Markdown blockquote), contain the literal
# token 'Retrigger', and contain '@codex'. The locked wording is:
#   > Retrigger this review by commenting `@codex` (maintainers only).
grep -qE 'Retrigger this review' "$WORKFLOW_FILE" \
  || fail "REQ-013: comment script must contain 'Retrigger this review' footer text"
grep -qE "@codex" "$WORKFLOW_FILE" \
  || fail "REQ-013: footer must mention '@codex'"
# The footer is built as a JS string literal; assert the leading '> ' marker
# appears in proximity to 'Retrigger'.
grep -qE "'>[[:space:]]+Retrigger|\"\\>[[:space:]]+Retrigger|> Retrigger" "$WORKFLOW_FILE" \
  || fail "REQ-013: footer must be Markdown blockquote (line begins '> ' before 'Retrigger')"
pass "REQ-013: retrigger footer present, blockquote-formatted, mentions @codex"

# --- Task 1.8: 60K-char body truncation with continuation notice (TR-3) -----
# Comment body MUST be capped at <= 65000 chars (GitHub's hard limit) with
# a documented safety margin; we lock 60000 here. Truncation MUST happen
# BEFORE the footer is appended so the footer survives.
grep -qE 'MAX_BODY[[:space:]]*=[[:space:]]*60000|60000' "$WORKFLOW_FILE" \
  || fail "TR-3: comment script must define a numeric truncation cap (60000 chars)"
pass "TR-3: 60000-char truncation cap present"

grep -qE '\[truncated|truncated' "$WORKFLOW_FILE" \
  || fail "TR-3: comment script must emit a 'truncated' continuation notice"
pass "TR-3: continuation notice present"

# Footer must remain the absolute last appended fragment — assert by
# requiring `${truncated}\n\n${FOOTER}` ordering (loose check).
if have_yq; then
  comment_script=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/github-script@v7")
         | .with.script' "$WORKFLOW_FILE"
  )
  trunc_idx=$(echo "$comment_script" | grep -n 'truncated' | head -1 | cut -d: -f1 || true)
  footer_idx=$(echo "$comment_script" | grep -n 'FOOTER\|Retrigger this review' | tail -1 | cut -d: -f1 || true)
  if [ -n "$trunc_idx" ] && [ -n "$footer_idx" ]; then
    [ "$trunc_idx" -lt "$footer_idx" ] \
      || fail "TR-3: truncation logic must precede the footer append in the comment script"
  fi
fi
pass "TR-3: truncation precedes footer append"

# --- Task 1.9: Fail-fast assertions for resolution + checkout steps ---------
# REQ-006 Scenario 3: refs step must NOT have continue-on-error.
# REQ-010: prompt resolution step must NOT have continue-on-error.
# REQ-008: sparse-checkout step must NOT have continue-on-error (a missing
# default prompt is a fail-fast condition handled by the prompt step).
# Pre-fetch step must NOT have continue-on-error (REQ-007: refs must be on
# disk before Codex diffs them).
if have_yq; then
  for step_id in refs prompt; do
    coe=$(
      yq ".jobs.review.steps[] | select(.id == \"$step_id\") | .[\"continue-on-error\"] // \"absent\"" "$WORKFLOW_FILE"
    )
    [ "$coe" = "absent" ] \
      || fail "fail-fast: step id=$step_id must NOT have continue-on-error (got: $coe)"
  done

  sparse_coe=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path == ".codex-defaults")
         | .["continue-on-error"] // "absent"' "$WORKFLOW_FILE"
  )
  [ "$sparse_coe" = "absent" ] \
    || fail "fail-fast: sparse-checkout step must NOT have continue-on-error (got: $sparse_coe)"

  caller_checkout_coe=$(
    yq '.jobs.review.steps[]
         | select(.uses == "actions/checkout@v4")
         | select(.with.path // "" == "")
         | .["continue-on-error"] // "absent"' "$WORKFLOW_FILE"
  )
  [ "$caller_checkout_coe" = "absent" ] \
    || fail "fail-fast: caller checkout step must NOT have continue-on-error (got: $caller_checkout_coe)"

  prefetch_coe=$(
    yq '.jobs.review.steps[]
         | select(.name == "Pre-fetch PR refs")
         | .["continue-on-error"] // "absent"' "$WORKFLOW_FILE"
  )
  [ "$prefetch_coe" = "absent" ] \
    || fail "fail-fast: pre-fetch step must NOT have continue-on-error (got: $prefetch_coe)"
fi
pass "fail-fast: refs / prompt / sparse / caller-checkout / pre-fetch all without continue-on-error"

# --- Task 1.9: Exactly TWO continue-on-error: true total --------------------
# Codex + comment, no more. If a future task adds it elsewhere by accident
# this assertion catches it (the count is documented in the script header).
exact_coe=$(grep -cE '^\s*continue-on-error:\s*true\s*$' "$WORKFLOW_FILE" || true)
[ "$exact_coe" = "2" ] \
  || fail "fail-fast: expected exactly 2 'continue-on-error: true' lines (Codex + comment), found $exact_coe"
pass "fail-fast: exactly 2 continue-on-error: true lines (Codex + comment)"

# ============================================================================
# BATCH 2 — Default prompt file: .github/codex/pr-review.prompt.md
# REQ-015 Scenarios 1-4. These checks assert STRUCTURE, not exact wording —
# the default prompt may be polished in REFACTOR steps without breaking them.
# ============================================================================
PROMPT_FILE=".github/codex/pr-review.prompt.md"

# --- Task 2.1: REQ-015 Scenario 1 — file exists, non-empty, role declaration ---
[ -s "$PROMPT_FILE" ] \
  || fail "REQ-015 Scenario 1: $PROMPT_FILE must exist and be non-empty"
pass "REQ-015 Scenario 1: $PROMPT_FILE exists and is non-empty"

# Role declaration must appear in the first ~10 lines of the file (a model
# prompt should establish role up front, not bury it in the middle).
head -n 10 "$PROMPT_FILE" | grep -qiE 'you (are|will)|reviewing|reviewer' \
  || fail "REQ-015 Scenario 1: $PROMPT_FILE must contain a role declaration in the first 10 lines"
pass "REQ-015 Scenario 1: role declaration present in first 10 lines"

grep -qi 'pull request' "$PROMPT_FILE" \
  || fail "REQ-015 Scenario 1: $PROMPT_FILE must mention 'pull request'"
pass "REQ-015 Scenario 1: $PROMPT_FILE mentions 'pull request'"

# --- Task 2.2: REQ-015 Scenario 2 — eight review dimensions ---
# Each dimension MUST appear as its own heading (## Heading) so Codex
# treats them as discrete sections rather than a free-form paragraph.
# Pattern: case-insensitive ATX heading containing the dimension keyword.
# (Severity tokens checked separately in Task 2.3.)
declare -a CODEX_REVIEW_DIMENSIONS=(
  "correctness"
  "security"
  "error handling"
  "tests"
  "readability"
  "performance"
  "API|back-?compat|backward[ -]compat"
  "config|infra"
)
for dim in "${CODEX_REVIEW_DIMENSIONS[@]}"; do
  grep -qiE "^#{1,3}[[:space:]].*(${dim})" "$PROMPT_FILE" \
    || fail "REQ-015 Scenario 2: $PROMPT_FILE must contain a heading covering '${dim}'"
done
pass "REQ-015 Scenario 2: all eight review dimensions present as headings"

# --- Task 2.3: REQ-015 Scenario 3 — output format + verdict + severity ---
# Locked vocabulary (per design + launch contract):
#   Verdict ∈ { Approve, Request changes, Comment }
#   Severity ∈ { Blocker, Major, Minor, Nit }
#   Output-format markers (must each appear at least once): Verdict, Summary,
#     Findings, Coverage.
grep -qi 'verdict' "$PROMPT_FILE" \
  || fail "REQ-015 Scenario 3: $PROMPT_FILE must mention 'verdict'"
pass "REQ-015 Scenario 3: 'verdict' marker present"

declare -a CODEX_VERDICT_TOKENS=(
  "Approve"
  "Request changes"
  "Comment"
)
for v in "${CODEX_VERDICT_TOKENS[@]}"; do
  grep -qF "$v" "$PROMPT_FILE" \
    || fail "REQ-015 Scenario 3: $PROMPT_FILE must contain verdict token '$v'"
done
pass "REQ-015 Scenario 3: all three verdict tokens present (Approve / Request changes / Comment)"

declare -a CODEX_SEVERITY_TOKENS=(
  "Blocker"
  "Major"
  "Minor"
  "Nit"
)
for s in "${CODEX_SEVERITY_TOKENS[@]}"; do
  grep -qF "$s" "$PROMPT_FILE" \
    || fail "REQ-015 Scenario 3: $PROMPT_FILE must contain severity token '$s'"
done
pass "REQ-015 Scenario 3: all four severity tokens present (Blocker/Major/Minor/Nit)"

declare -a CODEX_OUTPUT_MARKERS=(
  "Verdict"
  "Summary"
  "Findings"
  "Coverage"
)
for m in "${CODEX_OUTPUT_MARKERS[@]}"; do
  grep -qF "$m" "$PROMPT_FILE" \
    || fail "REQ-015 Scenario 3: $PROMPT_FILE must contain output-format marker '$m'"
done
pass "REQ-015 Scenario 3: output-format markers present (Verdict/Summary/Findings/Coverage)"

# --- Task 2.4: REQ-015 Scenario 4 — Rules section forbidding preamble flattery ---
# Require a dedicated `# Rules` (or equivalent) section AND that the section
# contains the no-preamble instruction. The Summary section already mentions
# 'no preamble' in passing; we want a separate, explicit rules block so the
# instruction is unambiguous to the model.
grep -qiE '^#{1,2}[[:space:]]+(rules|hard rules|review rules)' "$PROMPT_FILE" \
  || fail "REQ-015 Scenario 4: $PROMPT_FILE must have a dedicated Rules heading"
pass "REQ-015 Scenario 4: dedicated Rules heading present"

# Inside-or-after-Rules: assert the no-preamble instruction body. We pull the
# tail of the file from the Rules heading onward and grep there.
awk '/^#{1,2}[[:space:]]+([Rr]ules|[Hh]ard [Rr]ules|[Rr]eview [Rr]ules)/{flag=1} flag' "$PROMPT_FILE" \
  | grep -qiE 'preamble|no preamble|flattery|do not (start|open|begin)|start directly' \
  || fail "REQ-015 Scenario 4: Rules section must forbid preamble/flattery"
pass "REQ-015 Scenario 4: Rules section forbids preamble / flattery"

echo
echo "ALL CODEX-WORKFLOW CHECKS PASSED (Batch 0 + Batch 1 + Batch 2)"
