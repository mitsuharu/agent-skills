import argparse
import hashlib
import json
import os
import statistics
import time
import urllib.request
from pathlib import Path

CASES = Path(__file__).resolve().parents[1] / "assets" / "cases.json"

def rate(count, ns):
    return count * 1e9 / ns if count is not None and ns else None

def run(args, prompt):
    ollama = args.backend == "ollama"
    base = args.url.rstrip("/")
    url = base + "/api/chat" if ollama else base.removesuffix("/v1") + "/v1/chat/completions"
    body = dict(model=args.model, messages=[dict(role="user", content=prompt)], stream=True)
    if ollama:
        body["options"] = dict(temperature=0, num_predict=args.max_tokens)
    else:
        body.update(temperature=0, max_tokens=args.max_tokens, stream_options={"include_usage": True})
    headers = {"Content-Type": "application/json"}
    if os.environ.get("BENCHMARK_API_KEY"):
        headers["Authorization"] = "Bearer " + os.environ["BENCHMARK_API_KEY"]
    request = urllib.request.Request(url, json.dumps(body).encode(), headers)
    start = time.perf_counter()
    first = answer_start = None
    answer, reasoning = [], []
    usage, timings, final = {}, {}, {}
    finish = None
    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        for raw in response:
            line = raw.decode().strip()
            if not line or (not ollama and not line.startswith("data:")):
                continue
            line = line.removeprefix("data:").strip()
            if line == "[DONE]":
                break
            event = json.loads(line)
            if event.get("error"):
                raise RuntimeError(str(event["error"]))
            choices = event.get("choices") or []
            delta = event.get("message", {}) if ollama else (choices[0].get("delta", {}) if choices else {})
            thought = delta.get("thinking") or delta.get("reasoning_content") or delta.get("reasoning") or ""
            content = delta.get("content") or ""
            now = time.perf_counter() - start
            if (thought or content) and first is None:
                first = now
            if content and answer_start is None:
                answer_start = now
            answer.append(content)
            reasoning.append(thought)
            usage.update(event.get("usage") or {})
            timings.update(event.get("timings") or {})
            if ollama and event.get("done"):
                final = event
                finish = event.get("done_reason") or "done"
            elif choices and choices[0].get("finish_reason"):
                finish = choices[0]["finish_reason"]
    if finish is None:
        raise RuntimeError("Stream ended without finish reason")
    return dict(answer="".join(answer), reasoning="".join(reasoning), ttft_s=first,
                answer_start_s=answer_start, wall_s=time.perf_counter()-start,
                prompt_tokens=final.get("prompt_eval_count") if ollama else usage.get("prompt_tokens", timings.get("prompt_n")),
                completion_tokens=final.get("eval_count") if ollama else usage.get("completion_tokens", timings.get("predicted_n")),
                prefill_tps=rate(final.get("prompt_eval_count"), final.get("prompt_eval_duration")) if ollama else timings.get("prompt_per_second"),
                decode_tps=rate(final.get("eval_count"), final.get("eval_duration")) if ollama else timings.get("predicted_per_second"),
                finish=finish, usage=usage, timings=timings, load_ns=final.get("load_duration"))

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--backend", choices=["ollama","openai"], required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--max-tokens", type=int, default=2048)
    p.add_argument("--timeout", type=float, default=600)
    p.add_argument("--environment", default="", help="GPU, quantization, context, runtime version, thinking/cache settings")
    args = p.parse_args()
    if min(args.runs, args.max_tokens, args.timeout) <= 0 or args.out.exists():
        p.error("positive limits and a new output path required")
    payload = CASES.read_bytes()
    cases = json.loads(payload)
    run(args, "1+1の答えを数字だけで返してください。")
    report = dict(version=1, cases_sha256=hashlib.sha256(payload).hexdigest(),
                  config={k: str(v) if isinstance(v, Path) else v for k,v in vars(args).items()},
                  rows=[])
    for case in cases:
        for repeat in range(1,args.runs+1):
            row = dict(id=case["id"], repeat=repeat)
            try:
                row.update(run(args,case["prompt"]))
            except Exception as exc:
                row["error"] = str(exc)
            report["rows"].append(row)
            print(case["id"], repeat, "error" if "error" in row else "ok", flush=True)
            args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    summary = {}
    for key in ("ttft_s","answer_start_s","wall_s","prefill_tps","decode_tps"):
        vals = [r[key] for r in report["rows"] if r.get(key) is not None]
        summary[key] = dict(median=statistics.median(vals) if vals else None, n=len(vals))
    report["summary"] = summary
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

if __name__ == "__main__":
    main()
