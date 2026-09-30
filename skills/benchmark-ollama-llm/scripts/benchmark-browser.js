// Ollama LLM Benchmark (browser)
//
// benchmark.ps1 / benchmark.sh と同じ計測・CSV列・サマリーを、
// Ollamaと同じPC上のブラウザから fetch で行う。
// シェルが使えず、ブラウザだけ操作できるエージェント向け。
//
// Usage: Ollamaのページ（http://localhost:11434）を開き、このファイルの中身を
// ページのJavaScriptとして実行してから、次を順に呼ぶ。
//
//   ollamaBenchmark.start({ model: "gemma4:12b", runs: 10, think: "true" })
//   ollamaBenchmark.status()   // 実行中は status: "running"。完了まで繰り返し確認する
//   ollamaBenchmark.summary()  // サマリー（benchmark.sh と同じ書式）
//   ollamaBenchmark.csv()      // CSV文字列（benchmark.sh と同じ列）
//   ollamaBenchmark.csvFileName() // 保存名 ollama-benchmark-YYYYMMDD-HHMMSS.csv（開始時刻）
//
// start は計測をバックグラウンドで始めてすぐ戻る。ツール呼び出しのタイムアウトを
// 避けるため、結果は status() で取りに行く。
//
// status().status: idle / running / pulling / done / error
// status().code  : 0 ok, 1 error, 2 Ollama not reachable, 3 model not installed

(function (root) {
    "use strict";

    var DEFAULTS = {
        model: "gemma4:12b",
        prompt: "Swiftで100万件の要素を効率よくソートする方法を説明してください。\n" +
            "アルゴリズムの計算量、メモリ使用量、Swiftでの実装例も含めてください。",
        runs: 10,
        // true / false / low / medium / high / max / default
        think: "true",
        numPredict: 2048,
        temperature: 0,
        // 指定すると毎回プロンプト先頭を変更して
        // prompt cache が効きにくい状態で入力性能を測る
        bustPromptCache: false,
        // Ollama APIの接続先。省略時は開いているページのorigin
        host: null
    };

    var COLUMNS = [
        "Run", "Model", "ThinkMode",
        "PromptTokens", "PromptCachedTokens", "PromptEvalSec", "PromptTokPerSec",
        "PreOutputSec", "ThinkingSec", "ThinkingChars", "AnswerSec", "AnswerChars",
        "OutputTokens", "OutputEvalSec", "OutputTokPerSec",
        "LoadSec", "ServerTotalSec", "WallSec"
    ];

    var state = newState();

    function newState() {
        return {
            status: "idle", code: null, error: null, options: null, startedAt: null,
            done: 0, runs: 0, warmup: null, results: [], log: [], pull: null
        };
    }

    function round(x, digits) {
        var f = Math.pow(10, digits);
        return Math.round(x * f) / f;
    }

    function sec(ns) {
        return ns == null ? 0 : ns / 1e9;
    }

    function tps(count, ns) {
        return count == null || ns == null || ns <= 0 ? 0 : count / (ns / 1e9);
    }

    function thinkValue(value) {
        switch (String(value).toLowerCase()) {
            case "true": return true;
            case "false": return false;
            case "low": case "medium": case "high": case "max": return String(value).toLowerCase();
            default: return null;
        }
    }

    function baseUrl(host) {
        if (host) return String(host).replace(/\/+$/, "");
        if (root.location && /^https?:$/.test(root.location.protocol)) return root.location.origin;
        return "http://localhost:11434";
    }

    function uuid() {
        if (root.crypto && root.crypto.randomUUID) return root.crypto.randomUUID();
        return Date.now().toString(16) + "-" + Math.random().toString(16).slice(2);
    }

    function fail(code, message) {
        var e = new Error(message);
        e.code = code;
        return e;
    }

    function log(line) {
        state.log.push(line);
    }

    // NDJSONのストリームを1行ずつ受け取り、受信時刻とともに onLine に渡す
    async function readNdjson(response, onLine) {
        var reader = response.body.getReader();
        var decoder = new TextDecoder();
        var buf = "";
        for (;;) {
            var chunk = await reader.read();
            if (chunk.done) break;
            buf += decoder.decode(chunk.value, { stream: true });
            var nl;
            while ((nl = buf.indexOf("\n")) >= 0) {
                var line = buf.slice(0, nl).trim();
                buf = buf.slice(nl + 1);
                if (line && onLine(JSON.parse(line)) === false) {
                    try { await reader.cancel(); } catch (e) { /* ignore */ }
                    return;
                }
            }
        }
        buf = buf.trim();
        if (buf) onLine(JSON.parse(buf));
    }

    async function preflight(opts) {
        var tags;
        try {
            var res = await fetch(baseUrl(opts.host) + "/api/tags");
            if (!res.ok) throw new Error("HTTP " + res.status);
            tags = await res.json();
        } catch (e) {
            throw fail(2, "Ollama is not reachable at " + baseUrl(opts.host) +
                ". Start Ollama (or install it) and retry.");
        }
        var name = opts.model.indexOf(":") >= 0 ? opts.model : opts.model + ":latest";
        var installed = (tags.models || []).map(function (m) { return m.name; });
        if (installed.indexOf(name) < 0) {
            throw fail(3, "Model '" + opts.model + "' is not installed. Run: ollama pull " +
                opts.model + " (or ollamaBenchmark.pull(\"" + opts.model + "\"))");
        }
    }

    async function runOnce(opts, run) {
        var prompt = opts.prompt;
        if (opts.bustPromptCache) {
            // Prefixを変更することで、同一prefixによる
            // prompt cacheの影響を減らす。
            prompt = "[benchmark-id: " + uuid() + "]\nIgnore the benchmark-id above.\n\n" + opts.prompt;
        }

        var body = {
            model: opts.model,
            prompt: prompt,
            stream: true,
            options: { temperature: opts.temperature, num_predict: opts.numPredict },
            keep_alive: "10m"
        };
        var think = thinkValue(opts.think);
        if (think !== null) body.think = think;

        var start = performance.now();
        var res = await fetch(baseUrl(opts.host) + "/api/generate", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
        });
        if (!res.ok) {
            throw fail(1, "Ollama API error: " + res.status + "\n" + (await res.text()));
        }

        var firstOutput = null, thinkingStart = null, answerStart = null, doneAt = null;
        var thinkingChars = 0, answerChars = 0, final = null, streamError = null;

        await readNdjson(res, function (o) {
            var now = performance.now() - start;
            if (o.error) streamError = o.error;
            if (o.thinking) {
                if (firstOutput === null) firstOutput = now;
                if (thinkingStart === null) thinkingStart = now;
                thinkingChars += o.thinking.length;
            }
            if (o.response) {
                if (firstOutput === null) firstOutput = now;
                if (answerStart === null) answerStart = now;
                answerChars += o.response.length;
            }
            if (o.done === true) {
                doneAt = now;
                final = o;
                return false;
            }
            return true;
        });

        var wall = (performance.now() - start) / 1000;
        if (final === null) {
            throw fail(1, "Ollama API error: " + (streamError || "stream ended without done"));
        }

        var thinkingSec = 0;
        if (thinkingStart !== null) {
            thinkingSec = ((answerStart !== null ? answerStart : doneAt) - thinkingStart) / 1000;
        }
        var answerSec = answerStart !== null ? (doneAt - answerStart) / 1000 : 0;

        return {
            Run: run,
            Model: opts.model,
            ThinkMode: String(opts.think),
            PromptTokens: final.prompt_eval_count,
            PromptCachedTokens: final.prompt_eval_cached_count == null ? 0 : final.prompt_eval_cached_count,
            PromptEvalSec: round(sec(final.prompt_eval_duration), 4),
            PromptTokPerSec: round(tps(final.prompt_eval_count, final.prompt_eval_duration), 2),
            PreOutputSec: round(firstOutput !== null ? firstOutput / 1000 : 0, 4),
            ThinkingSec: round(thinkingSec, 4),
            ThinkingChars: thinkingChars,
            AnswerSec: round(answerSec, 4),
            AnswerChars: answerChars,
            OutputTokens: final.eval_count,
            OutputEvalSec: round(sec(final.eval_duration), 4),
            OutputTokPerSec: round(tps(final.eval_count, final.eval_duration), 2),
            LoadSec: round(sec(final.load_duration), 4),
            ServerTotalSec: round(sec(final.total_duration), 4),
            WallSec: round(wall, 4)
        };
    }

    function fmt(x, digits) {
        return Number(x || 0).toFixed(digits);
    }

    function logRun(r) {
        log("");
        log("Run " + r.Run);
        log("  Input    : " + fmt(r.PromptTokPerSec, 2) + " tok/s (" + fmt(r.PromptEvalSec, 3) + "s)");
        log("  PreOutput: " + fmt(r.PreOutputSec, 3) + "s");
        log("  Thinking : " + fmt(r.ThinkingSec, 3) + "s");
        log("  Answer   : " + fmt(r.AnswerSec, 3) + "s");
        log("  Output   : " + fmt(r.OutputTokPerSec, 2) + " tok/s (" + (r.OutputTokens || 0) + " tokens)");
        log("  Total    : " + fmt(r.WallSec, 3) + "s");
    }

    async function execute(opts) {
        try {
            if (!(opts.runs >= 1) || Math.floor(opts.runs) !== opts.runs) {
                throw fail(1, "runs must be a positive integer");
            }
            await preflight(opts);

            log("=========================================");
            log(" Ollama LLM Benchmark");
            log("=========================================");
            log("Model : " + opts.model);
            log("Think : " + opts.think);
            log("Runs  : " + opts.runs);
            log("");
            log("Warming up...");
            state.warmup = await runOnce(opts, 0);
            log("Warm-up complete.");

            for (var i = 1; i <= opts.runs; i++) {
                var r = await runOnce(opts, i);
                state.results.push(r);
                state.done = i;
                logRun(r);
            }
            state.status = "done";
            state.code = 0;
        } catch (e) {
            state.status = "error";
            state.code = e.code || 1;
            state.error = e.message || String(e);
        }
    }

    function start(options) {
        if (state.status === "running" || state.status === "pulling") {
            throw new Error("a benchmark or pull is already running; check ollamaBenchmark.status()");
        }
        var opts = {};
        Object.keys(DEFAULTS).forEach(function (k) {
            opts[k] = options && options[k] !== undefined ? options[k] : DEFAULTS[k];
        });
        opts.runs = Number(opts.runs);
        opts.numPredict = Number(opts.numPredict);
        opts.temperature = Number(opts.temperature);
        opts.think = String(opts.think);

        state = newState();
        state.status = "running";
        state.options = opts;
        state.startedAt = new Date();
        state.runs = opts.runs;
        state.promise = execute(opts);
        return { status: state.status, options: opts };
    }

    function status() {
        return {
            status: state.status,
            code: state.code,
            error: state.error,
            done: state.done,
            runs: state.runs,
            warmup: state.warmup,
            last: state.results.length ? state.results[state.results.length - 1] : null,
            pull: state.pull
        };
    }

    function csvCell(v) {
        return '"' + (v == null ? "" : String(v)).replace(/"/g, '""') + '"';
    }

    function csv() {
        var lines = [COLUMNS.map(csvCell).join(",")];
        state.results.forEach(function (r) {
            lines.push(COLUMNS.map(function (c) { return csvCell(r[c]); }).join(","));
        });
        return lines.join("\n") + "\n";
    }

    function pad2(n) {
        return (n < 10 ? "0" : "") + n;
    }

    // 複数回実行しても上書きしないよう、開始時刻（ローカル時刻）を名前に入れる
    function csvFileName() {
        var d = state.startedAt || new Date();
        return "ollama-benchmark-" + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
            "-" + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds()) + ".csv";
    }

    function avg(values) {
        return values.reduce(function (a, b) { return a + b; }, 0) / values.length;
    }

    function median(values) {
        var s = values.slice().sort(function (a, b) { return a - b; });
        var n = s.length;
        return n % 2 === 1 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
    }

    function summary() {
        var rs = state.results;
        if (!rs.length) return "";
        var col = function (k) { return rs.map(function (r) { return Number(r[k] || 0); }); };
        return [
            "=========================================",
            " Summary",
            "=========================================",
            "Input speed       : " + fmt(avg(col("PromptTokPerSec")), 2) + " tok/s avg",
            "Pre-output        : " + fmt(avg(col("PreOutputSec")), 3) + " sec avg",
            "Thinking          : " + fmt(avg(col("ThinkingSec")), 3) + " sec avg / " +
                fmt(median(col("ThinkingSec")), 3) + " sec median",
            "Answer            : " + fmt(avg(col("AnswerSec")), 3) + " sec avg",
            "Output speed      : " + fmt(avg(col("OutputTokPerSec")), 2) + " tok/s avg / " +
                fmt(median(col("OutputTokPerSec")), 2) + " tok/s median",
            "Total wall time   : " + fmt(avg(col("WallSec")), 3) + " sec avg / " +
                fmt(median(col("WallSec")), 3) + " sec median"
        ].join("\n");
    }

    // モデルをダウンロードする。ユーザーの了承を得てから呼ぶ。
    // 進捗は status().pull で確認する。
    function pull(model, host) {
        if (state.status === "running" || state.status === "pulling") {
            throw new Error("a benchmark or pull is already running; check ollamaBenchmark.status()");
        }
        state = newState();
        state.status = "pulling";
        state.pull = { model: model, status: "starting", completed: 0, total: 0 };
        state.promise = (async function () {
            try {
                var res = await fetch(baseUrl(host) + "/api/pull", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ model: model, stream: true })
                });
                if (!res.ok) throw fail(1, "Ollama API error: " + res.status + "\n" + (await res.text()));
                await readNdjson(res, function (o) {
                    if (o.error) throw fail(1, "Ollama API error: " + o.error);
                    state.pull.status = o.status || state.pull.status;
                    if (o.total) state.pull.total = o.total;
                    if (o.completed) state.pull.completed = o.completed;
                });
                if (state.pull.status !== "success") throw fail(1, "pull ended with status: " + state.pull.status);
                state.status = "done";
                state.code = 0;
            } catch (e) {
                state.status = "error";
                state.code = e.code || 1;
                state.error = e.message || String(e);
            }
        })();
        return { status: state.status, model: model };
    }

    root.ollamaBenchmark = {
        start: start,
        status: status,
        results: function () { return state.results.slice(); },
        log: function () { return state.log.join("\n"); },
        csv: csv,
        csvFileName: csvFileName,
        summary: summary,
        pull: pull,
        // テストや待ち合わせ用。完了まで待つ Promise を返す
        wait: function () { return state.promise || Promise.resolve(); }
    };
})(globalThis);
