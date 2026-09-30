#!/usr/bin/env bash
#
# benchmark.sh をモックのOllama APIに対して実行して結果を確認する。
# Usage: tests/benchmark-ollama-llm/test_benchmark.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TEST_DIR/../../skills/benchmark-ollama-llm/scripts/benchmark.sh"
PORT="${MOCK_PORT:-11435}"
HOST="http://127.0.0.1:$PORT"
TMP="$(mktemp -d)"
LOG="$TMP/requests.jsonl"
FAILURES=0

python3 "$TEST_DIR/mock_ollama.py" "$PORT" "$LOG" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
    curl -sf "$HOST/api/tags" >/dev/null 2>&1 && break
    sleep 0.1
done

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }
check() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

# csv_value <file> <row(1-based)> <column>
csv_value() {
    python3 -c '
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8-sig")))
print(rows[int(sys.argv[2]) - 1][sys.argv[3]])' "$@"
}

# --- normal run ---------------------------------------------------------
CSV="$TMP/out.csv"
OUT="$(bash "$SCRIPT" --host "$HOST" --model mock-model --runs 3 --think true \
    --num-predict 128 --temperature 0.5 --prompt "hello" --output-csv "$CSV")"
check "exit 0 and prints summary" grep -q "Output speed      : 50.00 tok/s avg / 50.00 tok/s median" <<<"$OUT"
check "prints each run" test "$(grep -c '^Run [0-9]' <<<"$OUT")" -eq 3
check "csv has header + 3 rows" test "$(wc -l <"$CSV" | tr -d ' ')" -eq 4
check "csv columns match benchmark.ps1" test "$(head -1 "$CSV")" = \
    '"Run","Model","ThinkMode","PromptTokens","PromptCachedTokens","PromptEvalSec","PromptTokPerSec","PreOutputSec","ThinkingSec","ThinkingChars","AnswerSec","AnswerChars","OutputTokens","OutputEvalSec","OutputTokPerSec","LoadSec","ServerTotalSec","WallSec"'
check "OutputTokPerSec = eval_count / eval_duration" test "$(csv_value "$CSV" 1 OutputTokPerSec)" = 50
check "PromptTokPerSec" test "$(csv_value "$CSV" 2 PromptTokPerSec)" = 200
check "ThinkingChars" test "$(csv_value "$CSV" 3 ThinkingChars)" = 6
check "AnswerChars" test "$(csv_value "$CSV" 3 AnswerChars)" = 8
check "ThinkingSec > 0" python3 -c "import sys; sys.exit(not float('$(csv_value "$CSV" 1 ThinkingSec)') > 0)"
check "warm-up + 3 runs requested" test "$(wc -l <"$LOG" | tr -d ' ')" -eq 4
check "request options" test "$(tail -1 "$LOG" | jq -c '[.model, .think, .options.num_predict, .options.temperature, .stream, .prompt]')" = \
    '["mock-model",true,128,0.5,true,"hello"]'

# --- think / bust cache -------------------------------------------------
: >"$LOG"
bash "$SCRIPT" --host "$HOST" --model mock-model --runs 1 --think high --bust-prompt-cache \
    --prompt "hello" --output-csv "$TMP/b.csv" >/dev/null
check "think level is sent as string" test "$(tail -1 "$LOG" | jq -r '.think')" = high
check "bust cache prefixes a unique id" test "$(jq -r '.prompt | split("\n")[0]' "$LOG" | sort -u | grep -c '^\[benchmark-id: ')" -eq 2
check "bust cache keeps the prompt" test "$(tail -1 "$LOG" | jq -r '.prompt | split("\n") | last')" = hello

: >"$LOG"
bash "$SCRIPT" --host "$HOST" --model mock-model --runs 1 --think default --output-csv "$TMP/c.csv" >/dev/null
check "think=default omits think" test "$(tail -1 "$LOG" | jq 'has("think")')" = false
check "no thinking -> ThinkingSec 0" test "$(csv_value "$TMP/c.csv" 1 ThinkingSec)" = 0

bash "$SCRIPT" --host "$HOST" --model mock-model --runs 1 --think false --output-csv "$TMP/d.csv" >/dev/null
check "think=false is sent as boolean" test "$(tail -1 "$LOG" | jq -c '.think')" = false

# --- errors -------------------------------------------------------------
set +e
bash "$SCRIPT" --host "$HOST" --model missing-model --output-csv "$TMP/e.csv" >/dev/null 2>&1
check "missing model exits 3" test $? -eq 3
bash "$SCRIPT" --host "http://127.0.0.1:1" --model mock-model --output-csv "$TMP/e.csv" >/dev/null 2>&1
check "unreachable Ollama exits 2" test $? -eq 2
bash "$SCRIPT" --host "$HOST" --model error-model --output-csv "$TMP/e.csv" >/dev/null 2>&1
check "API error exits 1" test $? -eq 1
bash "$SCRIPT" --host "$HOST" --runs 0 >/dev/null 2>&1
check "invalid --runs exits 1" test $? -eq 1
bash "$SCRIPT" --unknown >/dev/null 2>&1
check "unknown option exits 1" test $? -eq 1
set -e

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES test(s) failed"
    exit 1
fi
echo "all tests passed"
