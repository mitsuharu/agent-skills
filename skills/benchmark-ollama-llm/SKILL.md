---
name: benchmark-ollama-llm
description: Ollamaで動かすローカルLLMの速度（入力・出力のtok/s、思考時間、応答時間）を計測し、CSVとサマリーを出す。WindowsはPowerShell、macOSはbashのスクリプトを使い、シェルが使えずブラウザだけ操作できる場合はブラウザからAPIを呼ぶスクリプトを使う。「qwen3:30bを10回ベンチマークして」のようにモデル・回数・thinkなどを指定した依頼で使用する。
---

# OllamaでLLMのベンチマークを取る

ローカルのOllama API（`/api/generate` のストリーミング）に同じプロンプトを繰り返し送り、ウォームアップ1回の後に指定回数を計測する。
スクリプトは `scripts/` にあり、計測項目・CSV列・既定値はすべての実行方法で同じ。

## 1. パラメーターを決める

依頼から次の値を読み取り、指定がないものは既定値を使う。実行前に使う値を一言で伝える。

| 項目 | Windows (`benchmark.ps1`) | macOS (`benchmark.sh`) | ブラウザ (`benchmark-browser.js`) | 既定値 |
| --- | --- | --- | --- | --- |
| モデル | `-Model` | `--model` | `model` | `gemma4:12b` |
| 計測回数 | `-Runs` | `--runs` | `runs` | `10` |
| think | `-Think` | `--think` | `think` | `true` |
| 最大出力トークン | `-NumPredict` | `--num-predict` | `numPredict` | `2048` |
| temperature | `-Temperature` | `--temperature` | `temperature` | `0` |
| プロンプト | `-Prompt` | `--prompt` / `--prompt-file` | `prompt` | Swiftのソートの説明（スクリプト内） |
| CSV出力先 | `-OutputCsv` | `--output-csv` | `csvFileName()` の名前で保存 | `ollama-benchmark-YYYYMMDD-HHMMSS.csv` |
| prompt cacheを避ける | `-BustPromptCache` | `--bust-prompt-cache` | `bustPromptCache: true` | なし |
| Ollamaの接続先 | `-OllamaHost` | `--host` | `host`（省略時は開いているページ） | `http://localhost:11434` |

- `think` は `true` / `false` / `low` / `medium` / `high` / `max` / `default`。`default` はリクエストに `think` を含めない。thinking非対応のモデルでエラーになった場合は `false` か `default` を提案する。
- 入力速度を比べたいときは prompt cache の影響を避けるため `BustPromptCache` を付ける。
- CSVの既定名は計測開始時刻入りなので、繰り返し実行しても上書きされない。出力先を指定した場合はその名前をそのまま使う。

## 2. 実行方法を決める

Ollamaが動いているPCで何を操作できるかで選ぶ。

- そのPCでシェルを実行できる:
  - Windows: `scripts/benchmark.ps1` を Windows PowerShell 5.1 または PowerShell 7 で実行する。
  - macOS: `scripts/benchmark.sh` を使う。`curl`・`perl` は標準で入っている。`jq` はmacOS 15以降は標準、それより前は `brew install jq` が必要（入れる前にユーザーに確認する）。
  - Linuxでも `benchmark.sh` が動く（`curl`・`perl`・`jq` が必要）。
- シェルがない、またはシェルがそのPCの `localhost` に届かない（別マシンやVMで動いている）が、そのPCのブラウザを操作できる: `scripts/benchmark-browser.js` を使う（手順5のブラウザ）。

## 3. Ollamaを用意する

1. `ollama --version` でインストールを確認する。ブラウザの場合は `http://localhost:11434` を開き、`Ollama is running` と表示されるかで確認する。
2. ない場合はユーザーにインストールしてよいか確認してから入れる。
   - Windows: `winget install --id Ollama.Ollama -e`。インストール後は新しいシェルで `ollama` を使う。
   - macOS: Homebrewがあれば `brew install ollama`、なければ [公式ダウンロード](https://ollama.com/download) のアプリを入れてもらう。
   - パッケージマネージャーが使えない・ユーザーが自分で入れたい場合（ブラウザだけの場合も）は、公式ダウンロードページを案内して完了を待つ。
3. `curl http://localhost:11434/api/version`（Windowsは `Invoke-RestMethod`）でサーバーが応答するか確認する。応答しなければOllamaアプリを起動するか、`ollama serve` をバックグラウンドで起動する。

## 4. モデルを用意する

`ollama list`（ブラウザでは `/api/tags`）で対象モデルがあるか確認する。ない場合は、モデル名とおおよそのサイズ（[Ollamaのライブラリ](https://ollama.com/library) で確認）を伝え、ダウンロードしてよいか確認してから `ollama pull <model>`（ブラウザでは `ollamaBenchmark.pull("<model>")` を呼び、`status()` の `pull` で進捗を見る）を実行する。断られたら中止し、インストール済みのモデル一覧を示す。

## 5. 実行する

`<skill-dir>` はこの `SKILL.md` があるディレクトリ。大きいモデルや回数が多い場合は時間がかかるので、タイムアウトを長めに取る。

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>/scripts/benchmark.ps1 -Model qwen3:30b -Runs 10 -Think false
```

macOS:

```sh
bash <skill-dir>/scripts/benchmark.sh --model qwen3:30b --runs 10 --think false
```

終了コードで失敗理由を判断する。

- `2`: Ollamaに接続できない → 手順3に戻る。
- `3`: モデルがない → 手順4に戻る。
- `1`: APIエラーや引数の誤り → 表示されたメッセージを確認する。

ブラウザ:

1. Ollamaと同じPCのブラウザで `http://localhost:11434` を開く。同じoriginから呼ぶのでCORSの設定は要らない。
2. `scripts/benchmark-browser.js` の中身を読み、そのページでJavaScriptとして実行する。`ollamaBenchmark` が定義される。
3. `ollamaBenchmark.start({ model: "qwen3:30b", runs: 10, think: "false" })` を実行する。計測はバックグラウンドで進み、すぐ戻る。
4. `ollamaBenchmark.status()` を間を空けて呼び、`status` が `done` か `error` になるまで待つ。`done` / `runs` と `last` で進み具合が分かる。1回の時間は `warmup` と `last` の `WallSec` から見積もる。
5. `error` の場合は `code` を上の終了コードと同じ意味で扱い、`error` のメッセージを確認する。
6. `ollamaBenchmark.summary()` でサマリー、`ollamaBenchmark.csv()` でCSV文字列、`ollamaBenchmark.csvFileName()` で保存名を取得する。ブラウザからはファイルを書けないので、CSVは自分の作業環境にその名前で保存してユーザーに渡す。

## 6. 結果を伝える

サマリー（入力速度、出力前待ち時間、思考時間、回答時間、出力速度、合計時間）とCSVのパスを伝える。各項目の意味は次のとおり。

- Input / PromptTokPerSec: プロンプト処理速度（Ollamaの `prompt_eval_*`）。`PromptCachedTokens` が `PromptTokens` に近いときはキャッシュで大半を省いているので、入力速度の比較には `BustPromptCache` を付けて測り直す。
- PreOutput: リクエスト送信から最初のthinkingまたは回答が届くまでの時間。
- Thinking / Answer: thinking開始から回答開始まで、回答開始から完了までの時間。
- Output / OutputTokPerSec: 生成速度（Ollamaの `eval_*`）。思考トークンも含む。`OutputTokens` が最大出力トークンと同じなら上限で打ち切られており、Answerは回答全体の時間ではない。
- WallSec: 1回分のリクエスト全体の時間。LoadSecが大きい場合はモデルのロード時間が含まれている。
