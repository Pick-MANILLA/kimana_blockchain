#!/usr/bin/env bash
# Fails when Slither reports a Medium or High finding that docs/security/review.md does not accept.
# Accepted findings are the rows of the "Static analysis" table whose assessment starts with **Accepted.**:
# column 1 holds the detector in backticks, column 2 the affected functions in backticks.
# A finding matches on detector + function, not on line numbers, so moving code does not break the gate.
#
#   slither . --config-file slither.config.json --json slither.json
#   bash script/slither-gate.sh slither.json docs/security/review.md
set -euo pipefail

REPORT="${1:-slither.json}"
REVIEW="${2:-docs/security/review.md}"

[[ -f "$REPORT" ]] || { echo "slither-gate: report $REPORT not found" >&2; exit 2; }
[[ -f "$REVIEW" ]] || { echo "slither-gate: review $REVIEW not found" >&2; exit 2; }

# === Accepted findings, one "check<TAB>function" per line
accepted=$(
  awk '/^## Static analysis/ { on = 1; next } /^## / { on = 0 } on && /^\|/ && /\*\*Accepted\.\*\*/' "$REVIEW" |
    while IFS='|' read -r _ finding location _; do
      check=$(grep -o '`[^`]*`' <<<"$finding" | head -n1 | tr -d '`' | tr -d ':')
      grep -o '`[^`]*`' <<<"$location" | tr -d '`' | while read -r fn; do
        printf '%s\t%s\n' "$check" "$fn"
      done
    done
)

if [[ -z "$accepted" ]]; then
  echo "slither-gate: no accepted findings parsed from $REVIEW; check the table format" >&2
  exit 2
fi

# === Medium and High findings from Slither, one "check<TAB>function<TAB>description" per line
# The first element is the function the finding is about; for node elements, use the enclosing function.
findings=$(jq -r '
  .results.detectors // [] | .[]
  | select(.impact == "Medium" or .impact == "High")
  | (.elements[0] // {}) as $e
  | [.check,
     (if $e.type == "node" then $e.type_specific_fields.parent.name else ($e.name // "") end),
     (.description | split("\n")[0])]
  | @tsv' "$REPORT")

# === Compare
unaccepted=0
while IFS=$'\t' read -r check fn desc; do
  [[ -z "$check" ]] && continue
  if grep -qxF "$(printf '%s\t%s' "$check" "$fn")" <<<"$accepted"; then
    echo "  accepted  $check in $fn"
  else
    echo "  FAIL      $check in $fn: $desc"
    unaccepted=$((unaccepted + 1))
  fi
done <<<"$findings"

if ((unaccepted > 0)); then
  echo
  echo "slither-gate: $unaccepted Medium/High finding(s) not accepted in $REVIEW."
  echo "Fix them, or add a reviewed **Accepted.** row to the Static analysis table."
  exit 1
fi

echo "slither-gate: no unaccepted Medium/High findings."
