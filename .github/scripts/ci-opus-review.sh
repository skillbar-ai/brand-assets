#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

JQ_BIN="${JQ_BIN:-jq}"
CURL_BIN="${CURL_BIN:-curl}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
DATE_BIN="${DATE_BIN:-date}"
PARSE_REVIEWS_SCRIPT="${PARSE_REVIEWS_SCRIPT:-$(cd "$(dirname "$0")" && pwd)/parse-reviews.sh}"

OPUS_MODEL="${OPUS_MODEL:-claude-opus-4-6}"
# Strip provider prefix so callers can pass "anthropic/claude-opus-4-6" or just "claude-opus-4-6"
OPUS_MODEL="${OPUS_MODEL#anthropic/}"
OPUS_TIMEOUT_SECONDS="${OPUS_TIMEOUT_SECONDS:-300}"
OPUS_TIMEOUT_SECONDS="${OPUS_TIMEOUT_SECONDS%%.*}"
[[ -n "$OPUS_TIMEOUT_SECONDS" ]] || OPUS_TIMEOUT_SECONDS=0
if (( OPUS_TIMEOUT_SECONDS < 30 )); then
  printf '[ci-opus-review] WARNING: OPUS_TIMEOUT_SECONDS=%s is too low; clamping to 30\n' "$OPUS_TIMEOUT_SECONDS" >&2
  OPUS_TIMEOUT_SECONDS=30
fi
OPUS_SCORE_THRESHOLD="${OPUS_SCORE_THRESHOLD:-9.0}"
OPUS_INPUT_COST_PER_MTOKENS="${OPUS_INPUT_COST_PER_MTOKENS:-15}"
OPUS_OUTPUT_COST_PER_MTOKENS="${OPUS_OUTPUT_COST_PER_MTOKENS:-75}"
MAX_DIFF_CHARS="${MAX_DIFF_CHARS:-120000}"

usage() {
  cat >&2 <<'USAGE'
Usage:
  ci-opus-review.sh \
    --repo <owner/repo> \
    --pr-number <number> \
    --diff-file <path> \
    --state-file <path> \
    --result-file <path>

Environment:
  ANTHROPIC_API_KEY            Required.
  OPUS_MODEL                   Default: claude-opus-4-6
  OPUS_TIMEOUT_SECONDS         Default: 300
  OPUS_SCORE_THRESHOLD         Default: 9.0
  OPUS_INPUT_COST_PER_MTOKENS  Default: 15
  OPUS_OUTPUT_COST_PER_MTOKENS Default: 75
  MAX_DIFF_CHARS               Default: 120000
USAGE
}

fail() {
  printf '[ci-opus-review] ERROR: %s\n' "$*" >&2
  exit 1
}

REPO=""
PR_NUMBER=""
DIFF_FILE=""
STATE_FILE=""
RESULT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --pr-number)
      PR_NUMBER="${2:-}"
      shift 2
      ;;
    --diff-file)
      DIFF_FILE="${2:-}"
      shift 2
      ;;
    --state-file)
      STATE_FILE="${2:-}"
      shift 2
      ;;
    --result-file)
      RESULT_FILE="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$REPO" ]] || fail "--repo is required"
[[ "$REPO" == */* ]] || fail "--repo must be owner/repo"
[[ -n "$PR_NUMBER" && "$PR_NUMBER" =~ ^[0-9]+$ ]] || fail "--pr-number must be an integer"
[[ -f "$DIFF_FILE" ]] || fail "--diff-file does not exist: $DIFF_FILE"
[[ -n "$STATE_FILE" ]] || fail "--state-file is required"
[[ -n "$RESULT_FILE" ]] || fail "--result-file is required"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || fail "ANTHROPIC_API_KEY is required"
[[ -x "$PARSE_REVIEWS_SCRIPT" ]] || fail "parse-reviews.sh is missing or not executable: $PARSE_REVIEWS_SCRIPT"

command -v "$JQ_BIN" >/dev/null 2>&1 || fail "jq binary not found: $JQ_BIN"
command -v "$CURL_BIN" >/dev/null 2>&1 || fail "curl binary not found: $CURL_BIN"
command -v "$TIMEOUT_BIN" >/dev/null 2>&1 || fail "timeout binary not found: $TIMEOUT_BIN"
command -v "$DATE_BIN" >/dev/null 2>&1 || fail "date binary not found: $DATE_BIN"

now_iso() {
  "$DATE_BIN" -u +"%Y-%m-%dT%H:%M:%SZ"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

truncated_diff_file="$TMP_DIR/diff.txt"
original_diff_bytes="$(wc -c <"$DIFF_FILE" | tr -d '[:space:]')"
# Truncate by bytes, then sanitize to valid UTF-8. head -c bounds total file
# size; iconv -c silently drops only genuinely incomplete/invalid sequences
# (preserving valid multibyte chars that happen to end at the boundary).
head -c "$MAX_DIFF_CHARS" "$DIFF_FILE" | iconv -f utf-8 -t utf-8 -c >"$truncated_diff_file"
if [[ "$original_diff_bytes" -gt "$MAX_DIFF_CHARS" ]]; then
  echo "::warning::Diff truncated from $original_diff_bytes to $MAX_DIFF_CHARS bytes"
fi

raw_api_response="$TMP_DIR/anthropic-response.json"
started_at="$(now_iso)"

payload_file="$TMP_DIR/payload.json"
"$JQ_BIN" -n \
  --arg model "$OPUS_MODEL" \
  --rawfile diff "$truncated_diff_file" \
  '{
    model: $model,
    max_tokens: 1800,
    temperature: 0,
    system: "You are a strict code reviewer for pull requests. Return raw JSON only — no markdown, no code fences, no explanation. Keys: score (number 0.0-10.0), verdict (approve or request-changes), findings (array of objects with keys: severity, file, line, issue, fix). If score < 9.0, findings MUST explain why points were deducted.",
    messages: [
      {
        role: "user",
        content: (
          "Review this pull request diff. Score quality from 0.0 to 10.0 where 9.0+ is passing. " +
          "Prioritize correctness, regressions, and safety. Return JSON only.\\n\\n" +
          "PR Diff:\\n" +
          $diff
        )
      }
    ]
  }' >"$payload_file"

# Compute retry budget: leave 15s headroom for the last retry to complete
# before the outer timeout kills the process. Clamp to minimum 1.
RETRY_MAX_TIME=$((OPUS_TIMEOUT_SECONDS - 15))
if (( RETRY_MAX_TIME < 1 )); then RETRY_MAX_TIME=1; fi
# Retry delay must be shorter than retry budget, otherwise curl never retries.
RETRY_DELAY=$((RETRY_MAX_TIME / 3))
if (( RETRY_DELAY < 5 )); then RETRY_DELAY=5; fi

set +e
"$TIMEOUT_BIN" "${OPUS_TIMEOUT_SECONDS}s" "$CURL_BIN" -fsS \
  --retry 2 \
  --retry-delay "$RETRY_DELAY" \
  --retry-max-time "$RETRY_MAX_TIME" \
  https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  --data-binary "@$payload_file" \
  >"$raw_api_response"
api_exit=$?
set -e

mkdir -p "$(dirname "$STATE_FILE")"

update_state() {
  local review_json="$1"
  local status="$2"
  local opus_cost="$3"
  local input_tokens="$4"
  local output_tokens="$5"
  local now
  now="$(now_iso)"

  if [[ -f "$STATE_FILE" ]] && "$JQ_BIN" -e . "$STATE_FILE" >/dev/null 2>&1; then
    "$JQ_BIN" \
      --argjson review "$review_json" \
      --arg status "$status" \
      --arg now "$now" \
      --arg model "$OPUS_MODEL" \
      --argjson opusCost "$opus_cost" \
      --argjson inputTokens "$input_tokens" \
      --argjson outputTokens "$output_tokens" '
      .id = (.id // ("ci-opus-pr-" + ($review.prNumber|tostring)))
      | .task = (.task // "CI Opus PR review")
      | .iteration = (.iteration // 1)
      | .maxIterations = (.maxIterations // 1)
      | .startedAt = (.startedAt // $now)
      | .updatedAt = $now
      | .status = $status
      | .reviews = ((.reviews // []) + [
          {
            iteration: ((.reviews // []) | length) + 1,
            opus: {
              score: $review.score,
              findings: $review.findings,
              verdict: $review.verdict
            }
          }
        ])
      | .cost = (.cost // {})
      | .cost.codex = (.cost.codex // 0)
      | .cost.opus = (((.cost.opus // 0) + $opusCost) * 1000000 | round / 1000000)
      | .cost.total = (((.cost.total // 0) + $opusCost) * 1000000 | round / 1000000)
      | .cost.breakdown = (.cost.breakdown // {})
      | .cost.breakdown.opus = {
          tokens: ((.cost.breakdown.opus.tokens // 0) + $inputTokens + $outputTokens),
          costUsd: (((.cost.breakdown.opus.costUsd // 0) + $opusCost) * 1000000 | round / 1000000)
        }
      | .cost.reviews = ((.cost.reviews // []) + [
          {
            provider: "anthropic",
            model: $model,
            prNumber: $review.prNumber,
            score: $review.score,
            status: $status,
            inputTokens: $inputTokens,
            outputTokens: $outputTokens,
            costUsd: (($opusCost * 1000000) | round / 1000000),
            reviewedAt: $now
          }
        ])
    ' "$STATE_FILE" >"$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    "$JQ_BIN" -n \
      --arg id "ci-opus-pr-${PR_NUMBER}" \
      --arg task "CI Opus PR review" \
      --arg repo "$REPO" \
      --argjson prNumber "$PR_NUMBER" \
      --arg status "$status" \
      --arg startedAt "$started_at" \
      --arg updatedAt "$now" \
      --arg model "$OPUS_MODEL" \
      --argjson review "$review_json" \
      --argjson opusCost "$opus_cost" \
      --argjson inputTokens "$input_tokens" \
      --argjson outputTokens "$output_tokens" '
      {
        id: $id,
        task: $task,
        repo: $repo,
        prNumber: $prNumber,
        iteration: 1,
        maxIterations: 1,
        status: $status,
        reviews: [
          {
            iteration: 1,
            opus: {
              score: $review.score,
              findings: $review.findings,
              verdict: $review.verdict
            }
          }
        ],
        startedAt: $startedAt,
        updatedAt: $updatedAt,
        cost: {
          codex: 0,
          opus: (($opusCost * 1000000) | round / 1000000),
          total: (($opusCost * 1000000) | round / 1000000),
          breakdown: {
            opus: {
              tokens: ($inputTokens + $outputTokens),
              costUsd: (($opusCost * 1000000) | round / 1000000)
            }
          },
          reviews: [
            {
              provider: "anthropic",
              model: $model,
              prNumber: $prNumber,
              score: $review.score,
              status: $status,
              inputTokens: $inputTokens,
              outputTokens: $outputTokens,
              costUsd: (($opusCost * 1000000) | round / 1000000),
              reviewedAt: $updatedAt
            }
          ]
        }
      }
    ' >"$STATE_FILE"
  fi
}

# Exit 124 = GNU timeout killed the process; exit 28 = curl's own timeout
# (e.g., --retry-max-time exceeded). Both should fail open.
if [[ "$api_exit" -eq 124 || "$api_exit" -eq 28 ]]; then
  review_json="$($JQ_BIN -n --argjson prNumber "$PR_NUMBER" '{prNumber: $prNumber, score: null, verdict: "timeout", findings: []}')"
  update_state "$review_json" "warning" "0" "0" "0"
  "$JQ_BIN" -n \
    --arg model "$OPUS_MODEL" \
    --arg timeoutSeconds "$OPUS_TIMEOUT_SECONDS" \
    --argjson prNumber "$PR_NUMBER" \
    --argjson threshold "$OPUS_SCORE_THRESHOLD" '
      {
        timedOut: true,
        passed: true,
        status: "warning",
        threshold: $threshold,
        score: null,
        verdict: "timeout",
        findings: [],
        costUsd: 0,
        inputTokens: 0,
        outputTokens: 0,
        model: $model,
        warning: ("Opus review timed out after " + $timeoutSeconds + " seconds; failing open.")
      }
    ' >"$RESULT_FILE"
  exit 0
fi

[[ "$api_exit" -eq 0 ]] || fail "Opus API request failed with exit code $api_exit"

if ! "$JQ_BIN" -e . "$raw_api_response" >/dev/null 2>&1; then
  fail "Opus API returned invalid JSON"
fi

review_text_file="$TMP_DIR/review.txt"
"$JQ_BIN" -r '[.content[]? | select(.type == "text") | .text] | join("\n")' "$raw_api_response" >"$review_text_file"

if [[ ! -s "$review_text_file" ]]; then
  fail "Opus API response did not contain text content"
fi

greptile_stub="$TMP_DIR/greptile.json"
printf '[]\n' >"$greptile_stub"

parsed_file="$TMP_DIR/parsed-review.json"
"$PARSE_REVIEWS_SCRIPT" \
  --iteration 1 \
  --opus-file "$review_text_file" \
  --greptile-json "$greptile_stub" \
  --out "$parsed_file"

score="$($JQ_BIN -r '.opus.score // "null"' "$parsed_file")"
verdict="$($JQ_BIN -r '.opus.verdict // "request-changes"' "$parsed_file")"
findings_json="$($JQ_BIN -c '.opus.findings // []' "$parsed_file")"

# If score couldn't be parsed, treat as explicit failure (not score=0)
if [[ "$score" == "null" || -z "$score" ]]; then
  printf '[ci-opus-review] WARNING: Opus returned no parseable score — failing safely\n' >&2
  score="null"
  verdict="request-changes"
fi

input_tokens="$($JQ_BIN -r '.usage.input_tokens // 0 | tonumber' "$raw_api_response")"
output_tokens="$($JQ_BIN -r '.usage.output_tokens // 0 | tonumber' "$raw_api_response")"

opus_cost="$($JQ_BIN -n \
  --argjson inputTokens "$input_tokens" \
  --argjson outputTokens "$output_tokens" \
  --argjson inputRate "$OPUS_INPUT_COST_PER_MTOKENS" \
  --argjson outputRate "$OPUS_OUTPUT_COST_PER_MTOKENS" '
  ((($inputTokens / 1000000) * $inputRate) + (($outputTokens / 1000000) * $outputRate))
')"

if [[ "$score" == "null" ]]; then
  passed="false"
else
  passed="$($JQ_BIN -n --argjson score "$score" --argjson threshold "$OPUS_SCORE_THRESHOLD" '($score >= $threshold)')"
fi
status="failed"
if [[ "$passed" == "true" ]]; then
  status="ready"
fi

review_json="$($JQ_BIN -n \
  --argjson prNumber "$PR_NUMBER" \
  --argjson score "$score" \
  --arg verdict "$verdict" \
  --argjson findings "$findings_json" '
  {prNumber: $prNumber, score: $score, verdict: $verdict, findings: $findings}
')"

update_state "$review_json" "$status" "$opus_cost" "$input_tokens" "$output_tokens"

"$JQ_BIN" -n \
  --arg model "$OPUS_MODEL" \
  --arg verdict "$verdict" \
  --arg status "$status" \
  --argjson threshold "$OPUS_SCORE_THRESHOLD" \
  --argjson score "$score" \
  --argjson findings "$findings_json" \
  --argjson costUsd "$opus_cost" \
  --argjson inputTokens "$input_tokens" \
  --argjson outputTokens "$output_tokens" \
  --argjson passed "$passed" '
  {
    timedOut: false,
    passed: $passed,
    status: $status,
    threshold: $threshold,
    score: $score,
    verdict: $verdict,
    findings: $findings,
    costUsd: (($costUsd * 1000000) | round / 1000000),
    inputTokens: $inputTokens,
    outputTokens: $outputTokens,
    model: $model
  }
' >"$RESULT_FILE"
