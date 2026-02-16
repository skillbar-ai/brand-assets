#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

JQ_BIN="${JQ_BIN:-jq}"

usage() {
  cat >&2 <<'USAGE'
Usage:
  parse-reviews.sh --iteration <n> --opus-file <path> --greptile-json <path> [--out <path>]

Reads:
  - Opus review output (JSON or markdown/plaintext)
  - Greptile comments JSON (from gh api)

Writes normalized JSON to stdout or --out.
USAGE
}

fail() {
  printf '[parse-reviews] ERROR: %s\n' "$*" >&2
  exit 1
}

extract_opus_json() {
  local file="$1"
  local raw
  raw="$(cat "$file")"

  # Try raw file as JSON first
  if "$JQ_BIN" -e . "$file" >/dev/null 2>&1; then
    "$JQ_BIN" -c '{score: (.score // null), verdict: (.verdict // "request-changes"), findings: (.findings // [])}' "$file"
    return
  fi

  # Strip markdown code fences (```json ... ``` or ``` ... ```) and try again
  local stripped
  stripped="$(printf '%s\n' "$raw" | sed -n '/^```/,/^```/{/^```/d;p}')"
  if [[ -n "$stripped" ]] && printf '%s\n' "$stripped" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    printf '%s\n' "$stripped" | "$JQ_BIN" -c '{score: (.score // null), verdict: (.verdict // "request-changes"), findings: (.findings // [])}'
    return
  fi

  local score verdict
  # Regex fallback: grabs first number after "score". May match wrong value if
  # the review text contains multiple score-like numbers (e.g., "would score 7.5
  # but rating 6.0" → grabs 7.5). Acceptable since JSON parsing is tried first.
  score="$(printf '%s\n' "$raw" | sed -nE 's/.*[Ss]core[^0-9]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  verdict="$(printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | sed -nE 's/.*\b(approve|request-changes|reject)\b.*/\1/p' | head -n1)"
  [[ -n "$verdict" ]] || verdict="request-changes"

  printf '%s\n' "$raw" \
    | sed -nE 's/^[-*][[:space:]]+(.+)/\1/p' \
    | "$JQ_BIN" -R -s --arg score "${score:-null}" --arg verdict "$verdict" '
      split("\n") | map(select(length>0)) |
      {
        score: (if $score == "null" then null else ($score | tonumber) end),
        verdict: $verdict,
        findings: map({severity: "medium", issue: ., fix: null})
      }
    '
}

ITERATION=""
OPUS_FILE=""
GREPTILE_JSON=""
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iteration)
      ITERATION="${2:-}"
      shift 2
      ;;
    --opus-file)
      OPUS_FILE="${2:-}"
      shift 2
      ;;
    --greptile-json)
      GREPTILE_JSON="${2:-}"
      shift 2
      ;;
    --out)
      OUT_FILE="${2:-}"
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

[[ -n "$ITERATION" ]] || fail "--iteration is required"
[[ "$ITERATION" =~ ^[0-9]+$ ]] || fail "--iteration must be integer"
[[ -f "$OPUS_FILE" ]] || fail "--opus-file does not exist: $OPUS_FILE"
[[ -f "$GREPTILE_JSON" ]] || fail "--greptile-json does not exist: $GREPTILE_JSON"

if ! "$JQ_BIN" -e . "$GREPTILE_JSON" >/dev/null 2>&1; then
  fail "Greptile JSON is not valid JSON: $GREPTILE_JSON"
fi

OPUS_JSON="$(extract_opus_json "$OPUS_FILE")"

RESULT_JSON="$($JQ_BIN -n \
  --argjson iteration "$ITERATION" \
  --argjson opus "$OPUS_JSON" \
  --slurpfile g "$GREPTILE_JSON" '
  def arr(x): if (x|type) == "array" then x else [x] end;
  def comments:
    (arr($g[0]))
    # Expected bot: "greptile[bot]" - update if Greptile changes their username
    | map(select(((.user.login // "") | test("greptile"; "i")) or ((.body // "") | test("greptile"; "i"))))
    | map({
        id: (.id // null),
        author: (.user.login // "unknown"),
        createdAt: (.created_at // null),
        url: (.html_url // null),
        body: (.body // "")
      });
  def status(cs):
    if ([cs[] | .body | ascii_downcase | test("changes requested|request changes|request-changes")] | any) then "changes_requested"
    elif ([cs[] | .body | ascii_downcase | test("approved|lgtm")] | any) then "approved"
    elif (cs|length) == 0 then "pending"
    else "changes_requested"
    end;
  (comments) as $cs
  | {
      iteration: $iteration,
      opus: {
        score: ($opus.score // null),
        findings: ($opus.findings // []),
        verdict: ($opus.verdict // "request-changes")
      },
      greptile: {
        comments: $cs,
        status: status($cs)
      }
    }
')"

if [[ -n "$OUT_FILE" ]]; then
  printf '%s\n' "$RESULT_JSON" >"$OUT_FILE"
else
  printf '%s\n' "$RESULT_JSON"
fi
