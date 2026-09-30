// benchmark-browser.js をモックのOllama APIに対してNode.jsで実行して結果を確認する。
// ブラウザと同じ fetch / ReadableStream / performance を使うため、Node.js 18以降で動く。
// Usage: node --test tests/benchmark-ollama-llm/test-benchmark-browser.mjs

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const scriptPath = join(here, "../../skills/benchmark-ollama-llm/scripts/benchmark-browser.js");
const defaults = JSON.parse(readFileSync(join(here, "../../skills/benchmark-ollama-llm/scripts/defaults.json"), "utf8"));
const port = Number(process.env.MOCK_PORT || 11439);
const host = `http://127.0.0.1:${port}`;
const tmp = mkdtempSync(join(tmpdir(), "bench-browser-"));
const log = join(tmp, "requests.jsonl");
let mock;

// ページに貼り付けて実行するのと同じく、スクリプトをグローバルに評価する
vm.runInThisContext(readFileSync(scriptPath, "utf8"), { filename: scriptPath });
const bench = globalThis.ollamaBenchmark;

const requests = () =>
    readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));

async function run(options) {
    writeFileSync(log, "");
    bench.start({ ...defaults, host, ...options });
    await bench.wait();
    return bench.status();
}

before(async () => {
    writeFileSync(log, "");
    const python = process.platform === "win32" ? "python" : "python3";
    mock = spawn(python, [join(here, "mock_ollama.py"), String(port), log], { stdio: "ignore" });
    for (let i = 0; i < 50; i++) {
        try {
            if ((await fetch(`${host}/api/tags`)).ok) return;
        } catch {
            // not ready yet
        }
        await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error("mock server did not start");
});

after(() => {
    mock?.kill();
    rmSync(tmp, { recursive: true, force: true });
});

test("normal run matches benchmark.sh output", async () => {
    const s = await run({ model: "mock-model", runs: 3, think: "true", numPredict: 128, temperature: 0.5, prompt: "hello" });
    assert.equal(s.status, "done");
    assert.equal(s.code, 0);
    assert.equal(s.done, 3);

    const lines = bench.csv().trim().split("\n");
    assert.equal(lines.length, 4);
    assert.equal(
        lines[0],
        '"Run","Model","ThinkMode","PromptTokens","PromptCachedTokens","PromptEvalSec","PromptTokPerSec","PreOutputSec","ThinkingSec","ThinkingChars","AnswerSec","AnswerChars","OutputTokens","OutputEvalSec","OutputTokPerSec","LoadSec","ServerTotalSec","WallSec"',
    );

    const [r1, r2, r3] = bench.results();
    assert.equal(r1.OutputTokPerSec, 50);
    assert.equal(r2.PromptTokPerSec, 200);
    assert.equal(r3.ThinkingChars, 6);
    assert.equal(r3.AnswerChars, 8);
    assert.ok(r1.ThinkingSec > 0);
    assert.match(bench.summary(), /Output speed {6}: 50\.00 tok\/s avg \/ 50\.00 tok\/s median/);
    assert.match(bench.log(), /^Run 3$/m);

    const reqs = requests();
    assert.equal(reqs.length, 4, "warm-up + 3 runs");
    const last = reqs.at(-1);
    assert.deepEqual(
        [last.model, last.think, last.options.num_predict, last.options.temperature, last.stream, last.prompt],
        ["mock-model", true, 128, 0.5, true, "hello"],
    );
});

test("csv file name has the start timestamp", async () => {
    await run({ model: "mock-model", runs: 1 });
    assert.match(bench.csvFileName(), /^ollama-benchmark-\d{8}-\d{6}\.csv$/);
});

test("think level, bust cache and default", async () => {
    await run({ model: "mock-model", runs: 1, think: "high", bustPromptCache: true, prompt: "hello" });
    let reqs = requests();
    assert.equal(reqs.at(-1).think, "high");
    assert.match(reqs[0].prompt, /^\[benchmark-id: /);
    assert.notEqual(reqs[0].prompt, reqs[1].prompt);
    assert.equal(reqs.at(-1).prompt.split("\n").at(-1), "hello");

    await run({ model: "mock-model", runs: 1, think: "default" });
    reqs = requests();
    assert.equal("think" in reqs.at(-1), false);
    assert.equal(bench.results()[0].ThinkingSec, 0);

    await run({ model: "mock-model", runs: 1, think: "false" });
    assert.equal(requests().at(-1).think, false);
});

test("error codes", async () => {
    let s = await run({ model: "missing-model" });
    assert.deepEqual([s.status, s.code], ["error", 3]);

    s = await run({ model: "mock-model", host: "http://127.0.0.1:1" });
    assert.deepEqual([s.status, s.code], ["error", 2]);

    s = await run({ model: "error-model" });
    assert.deepEqual([s.status, s.code], ["error", 1]);

    s = await run({ model: "mock-model", runs: 0 });
    assert.deepEqual([s.status, s.code], ["error", 1]);
});

test("defaults.json values are sent", async () => {
    const s = await run({ runs: 1 });
    assert.equal(s.status, "done");
    const last = requests().at(-1);
    assert.deepEqual(
        [last.model, String(last.think), last.options.num_predict, last.options.temperature, last.prompt],
        [defaults.model, String(defaults.think), defaults.numPredict, defaults.temperature, defaults.prompt],
    );
});

test("settings are validated", () => {
    assert.throws(() => bench.start({ model: "mock-model" }), /missing settings: prompt, runs/);
    assert.throws(() => bench.start({ ...defaults, modle: "typo" }), /unknown settings: modle/);
});

test("pull streams until success", async () => {
    bench.pull("new-model", host);
    await bench.wait();
    const s = bench.status();
    assert.equal(s.status, "done");
    assert.equal(s.pull.status, "success");
});
