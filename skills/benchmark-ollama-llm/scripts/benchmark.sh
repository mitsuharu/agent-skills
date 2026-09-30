#!/usr/bin/env bash
#
# Ollama LLM Benchmark (macOS / Linux)
#
# benchmark.ps1 と同じ計測・出力を bash + curl + perl + jq で行う。
# macOS標準の bash 3.2 で動くように書いている。
#
# Usage: ./benchmark.sh [options]   (./benchmark.sh --help)

set -euo pipefail

export LC_NUMERIC=C

MODEL="gemma4:12b"
PROMPT="Swiftで100万件の要素を効率よくソートする方法を説明してください。
アルゴリズムの計算量、メモリ使用量、Swiftでの実装例も含めてください。"
RUNS=10
# true / false / low / medium / high / max / default
THINK="true"
NUM_PREDICT=2048
TEMPERATURE=0
# 省略時は開始時刻入りの名前にして上書きを防ぐ
OUTPUT_CSV="ollama-benchmark-$(date +%Y%m%d-%H%M%S).csv"
# 指定すると毎回プロンプト先頭を変更して
# prompt cache が効きにくい状態で入力性能を測る
BUST_PROMPT_CACHE=false
OLLAMA_HOST_URL="http://localhost:11434"

usage() {
    cat <<'EOF'
Usage: benchmark.sh [options]

  -m, --model NAME          Model name (default: gemma4:12b)
  -p, --prompt TEXT         Prompt text
      --prompt-file PATH    Read the prompt from a file
  -n, --runs N              Number of measured runs (default: 10)
  -t, --think VALUE         true|false|low|medium|high|max|default (default: true)
      --num-predict N       Max output tokens (default: 2048)
      --temperature X       Sampling temperature (default: 0)
  -o, --output-csv PATH     CSV output path
                            (default: ollama-benchmark-YYYYMMDD-HHMMSS.csv)
      --bust-prompt-cache   Prefix a random id to the prompt on every run
      --host URL            Ollama URL (default: http://localhost:11434)
  -h, --help                Show this help

Exit codes: 0 ok, 1 error, 2 Ollama not reachable, 3 model not installed
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

need_value() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -m|--model) need_value "$@"; MODEL="$2"; shift 2 ;;
        -p|--prompt) need_value "$@"; PROMPT="$2"; shift 2 ;;
        --prompt-file)
            need_value "$@"
            [ -f "$2" ] || die "prompt file not found: $2"
            PROMPT="$(cat "$2")"
            shift 2 ;;
        -n|--runs) need_value "$@"; RUNS="$2"; shift 2 ;;
        -t|--think) need_value "$@"; THINK="$2"; shift 2 ;;
        --num-predict) need_value "$@"; NUM_PREDICT="$2"; shift 2 ;;
        --temperature) need_value "$@"; TEMPERATURE="$2"; shift 2 ;;
        -o|--output-csv) need_value "$@"; OUTPUT_CSV="$2"; shift 2 ;;
        --bust-prompt-cache) BUST_PROMPT_CACHE=true; shift ;;
        --host) need_value "$@"; OLLAMA_HOST_URL="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

case "$RUNS" in ''|*[!0-9]*) die "--runs must be a positive integer" ;; esac
[ "$RUNS" -ge 1 ] || die "--runs must be a positive integer"
case "$NUM_PREDICT" in ''|*[!0-9-]*) die "--num-predict must be an integer" ;; esac
echo "$TEMPERATURE" | grep -Eq '^[0-9]*\.?[0-9]+$' || die "--temperature must be a number"

for cmd in curl jq perl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required (macOS: brew install $cmd)"
done

OLLAMA_HOST_URL="${OLLAMA_HOST_URL%/}"
BASE_URL="$OLLAMA_HOST_URL/api/generate"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-benchmark.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# ------------------------------------------------------------
# Helper
# ------------------------------------------------------------

# true/false は真偽値、low〜max は文字列、それ以外は think を送らない
think_json() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        true) echo "true" ;;
        false) echo "false" ;;
        low|medium|high|max) echo "\"$(echo "$1" | tr '[:upper:]' '[:lower:]')\"" ;;
        *) echo "null" ;;
    esac
}

new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        perl -e 'printf "%08x-%04x-%04x-%04x-%012x\n", map { int(rand(16**$_)) } 8, 4, 4, 4, 12'
    fi
}

# ------------------------------------------------------------
# Preflight: Ollamaの起動とモデルの有無を確認する
#   exit 2: Ollamaに接続できない
#   exit 3: モデルがダウンロードされていない
# ------------------------------------------------------------

if ! TAGS_JSON="$(curl -sSf --max-time 10 "$OLLAMA_HOST_URL/api/tags" 2>/dev/null)"; then
    echo "Ollama is not reachable at $OLLAMA_HOST_URL. Start Ollama (or install it) and retry." >&2
    exit 2
fi

MODEL_NAME="$MODEL"
case "$MODEL_NAME" in *:*) ;; *) MODEL_NAME="$MODEL_NAME:latest" ;; esac

if ! echo "$TAGS_JSON" | jq -e --arg m "$MODEL_NAME" \
    '[.models[]?.name | ascii_downcase] | index($m | ascii_downcase) != null' >/dev/null; then
    echo "Model '$MODEL' is not installed. Run: ollama pull $MODEL" >&2
    exit 3
fi

# ------------------------------------------------------------
# Benchmark
# ------------------------------------------------------------

# ストリームの各NDJSON行に受信時刻（秒）を付けたファイルを解析し、
# 1回分の結果をJSONで出力する。先頭行は計測開始時刻。
# shellcheck disable=SC2016
ANALYZE_JQ='
def r(n): (. * pow(10; n) | round) / pow(10; n);
def sec: if . == null then 0 else . / 1e9 end;
def tps(c; d): if c == null or d == null or d <= 0 then 0 else c / (d / 1e9) end;
def nonempty: . != null and . != "";

[inputs | select(length > 0) | index("\t") as $i
  | {t: (.[:$i] | tonumber), o: (.[$i + 1:] | fromjson? // {})}] as $lines
| ($lines[0].t) as $start
| ($lines[1:]) as $all
| ([$all | to_entries[] | select(.value.o.done == true) | .key] | first) as $doneIdx
| (if $doneIdx == null then $all else $all[:$doneIdx + 1] end) as $ev
| ($ev | map(select(.o.thinking | nonempty))) as $th
| ($ev | map(select(.o.response | nonempty))) as $an
| ($ev | map(select((.o.thinking | nonempty) or (.o.response | nonempty)))) as $out
| (if $doneIdx == null then null else $all[$doneIdx] end) as $done
| ($done.o // {}) as $final
| (if $out | length > 0 then $out[0].t - $start else null end) as $firstOutput
| (if $th | length > 0 then $th[0].t - $start else null end) as $thinkingStart
| (if $an | length > 0 then $an[0].t - $start else null end) as $answerStart
| (if $done == null then null else $done.t - $start end) as $doneAt
| {
    Run: ($run | tonumber),
    Model: $model,
    ThinkMode: $think,
    PromptTokens: $final.prompt_eval_count,
    PromptCachedTokens: ($final.prompt_eval_cached_count // 0),
    PromptEvalSec: ($final.prompt_eval_duration | sec | r(4)),
    PromptTokPerSec: (tps($final.prompt_eval_count; $final.prompt_eval_duration) | r(2)),
    PreOutputSec: ($firstOutput // 0 | r(4)),
    ThinkingSec: (if $thinkingStart == null then 0
                  elif $answerStart != null then $answerStart - $thinkingStart
                  elif $doneAt != null then $doneAt - $thinkingStart
                  else 0 end | r(4)),
    ThinkingChars: ($th | map(.o.thinking) | add // "" | length),
    AnswerSec: (if $answerStart != null and $doneAt != null then $doneAt - $answerStart else 0 end | r(4)),
    AnswerChars: ($an | map(.o.response) | add // "" | length),
    OutputTokens: $final.eval_count,
    OutputEvalSec: ($final.eval_duration | sec | r(4)),
    OutputTokPerSec: (tps($final.eval_count; $final.eval_duration) | r(2)),
    LoadSec: ($final.load_duration | sec | r(4)),
    ServerTotalSec: ($final.total_duration | sec | r(4)),
    WallSec: ((if $doneAt != null then $doneAt else ($all | last | .t // $start) - $start end) | r(4)),
    _done: ($done != null),
    _error: ([$all[].o.error | select(. != null)] | first)
  }
'

# $1: run number, $2: "warmup" for warm-up run
run_benchmark() {
    local run="$1" warmup="${2:-}"
    local actual_prompt="$PROMPT"

    if [ "$BUST_PROMPT_CACHE" = true ]; then
        # Prefixを変更することで、同一prefixによる
        # prompt cacheの影響を減らす。
        actual_prompt="[benchmark-id: $(new_uuid)]
Ignore the benchmark-id above.

$PROMPT"
    fi

    local body_file="$WORK_DIR/body.json" stream_file="$WORK_DIR/stream-$run.txt"

    jq -n \
        --arg model "$MODEL" \
        --arg prompt "$actual_prompt" \
        --argjson temperature "$TEMPERATURE" \
        --argjson num_predict "$NUM_PREDICT" \
        --argjson think "$(think_json "$THINK")" \
        '{model: $model, prompt: $prompt, stream: true,
          options: {temperature: $temperature, num_predict: $num_predict},
          keep_alive: "10m"}
         + (if $think == null then {} else {think: $think} end)' >"$body_file"

    # 先頭行に開始時刻を書き、perl で受信した行ごとに時刻を付ける
    perl -MTime::HiRes=time -e 'printf "%.6f\t{}\n", time' >"$stream_file"
    if ! curl -sS -N --fail-with-body \
            -H "Content-Type: application/json" \
            --data-binary "@$body_file" "$BASE_URL" \
        | perl -MTime::HiRes=time -e '
            $| = 1;
            while (my $line = <STDIN>) { printf "%.6f\t%s", time, $line; }
          ' >>"$stream_file"; then
        echo "Ollama API error:" >&2
        cut -f2- "$stream_file" | tail -n +2 >&2
        exit 1
    fi

    local result
    result="$(jq -R -n -c \
        --arg run "$run" --arg model "$MODEL" --arg think "$THINK" \
        "$ANALYZE_JQ" <"$stream_file")"

    if [ "$(echo "$result" | jq -r '._done')" != true ]; then
        echo "Ollama API error: $(echo "$result" | jq -r '._error // "stream ended without done"')" >&2
        exit 1
    fi

    result="$(echo "$result" | jq -c 'del(._done, ._error)')"

    if [ "$warmup" != warmup ]; then
        local in_tps in_sec pre think_sec answer_sec out_tps out_tok wall
        read -r in_tps in_sec pre think_sec answer_sec out_tps out_tok wall <<EOF
$(echo "$result" | jq -r '[.PromptTokPerSec, .PromptEvalSec, .PreOutputSec, .ThinkingSec,
    .AnswerSec, .OutputTokPerSec, (.OutputTokens // 0), .WallSec] | @tsv')
EOF
        echo ""
        echo "Run $run"
        printf "  Input    : %.2f tok/s (%.3fs)\n" "$in_tps" "$in_sec"
        printf "  PreOutput: %.3fs\n" "$pre"
        printf "  Thinking : %.3fs\n" "$think_sec"
        printf "  Answer   : %.3fs\n" "$answer_sec"
        printf "  Output   : %.2f tok/s (%s tokens)\n" "$out_tps" "$out_tok"
        printf "  Total    : %.3fs\n" "$wall"
        echo "$result" >>"$WORK_DIR/results.jsonl"
    fi
}

# ------------------------------------------------------------
# Warm-up
# ------------------------------------------------------------

echo ""
echo "========================================="
echo " Ollama LLM Benchmark"
echo "========================================="
echo "Model : $MODEL"
echo "Think : $THINK"
echo "Runs  : $RUNS"
echo ""

echo "Warming up..."
run_benchmark 0 warmup
echo "Warm-up complete."

# ------------------------------------------------------------
# Runs
# ------------------------------------------------------------

i=1
while [ "$i" -le "$RUNS" ]; do
    run_benchmark "$i"
    i=$((i + 1))
done

# ------------------------------------------------------------
# CSV
# ------------------------------------------------------------

jq -s -r '
    (.[0] | keys_unsorted) as $cols
    | ($cols | @csv),
      (.[] | [.[$cols[]] | if . == null then "" else tostring end] | @csv)
' "$WORK_DIR/results.jsonl" >"$OUTPUT_CSV"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

read -r AVG_IN AVG_PRE AVG_THINK MED_THINK AVG_ANSWER AVG_OUT MED_OUT AVG_WALL MED_WALL <<EOF
$(jq -s -r '
    def avg(f): map(f) | add / length;
    def median(f): map(f) | sort | length as $n
        | if $n % 2 == 1 then .[($n - 1) / 2] else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
    [avg(.PromptTokPerSec), avg(.PreOutputSec), avg(.ThinkingSec), median(.ThinkingSec),
     avg(.AnswerSec), avg(.OutputTokPerSec), median(.OutputTokPerSec), avg(.WallSec), median(.WallSec)]
    | @tsv' "$WORK_DIR/results.jsonl")
EOF

echo ""
echo "========================================="
echo " Summary"
echo "========================================="
printf "Input speed       : %.2f tok/s avg\n" "$AVG_IN"
printf "Pre-output        : %.3f sec avg\n" "$AVG_PRE"
printf "Thinking          : %.3f sec avg / %.3f sec median\n" "$AVG_THINK" "$MED_THINK"
printf "Answer            : %.3f sec avg\n" "$AVG_ANSWER"
printf "Output speed      : %.2f tok/s avg / %.2f tok/s median\n" "$AVG_OUT" "$MED_OUT"
printf "Total wall time   : %.3f sec avg / %.3f sec median\n" "$AVG_WALL" "$MED_WALL"

echo ""
echo "CSV: $OUTPUT_CSV"
