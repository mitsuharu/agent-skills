---
name: benchmark-ollama-llm
description: Ollamaで動かすローカルLLMの速度（入力・出力のtok/s、思考時間、応答時間）を計測し、CSVとサマリーを出す。WindowsはPowerShell、macOSはbashのスクリプトを実行環境に応じて使い分ける。「qwen3:30bを10回ベンチマークして」のようにモデル・回数・thinkなどを指定した依頼で使用する。
---

# OllamaでLLMのベンチマークを取る

ローカルのOllama API（`/api/generate` のストリーミング）に同じプロンプトを繰り返し送り、ウォームアップ1回の後に指定回数を計測する。
スクリプトは `scripts/` にあり、計測項目・CSV列・既定値は両OSで同じ。

## 1. パラメーターを決める

依頼から次の値を読み取り、指定がないものは既定値を使う。実行前に使う値を一言で伝える。

| 項目 | Windows (`benchmark.ps1`) | macOS (`benchmark.sh`) | 既定値 |
| --- | --- | --- | --- |
| モデル | `-Model` | `--model` | `gemma4:12b` |
| 計測回数 | `-Runs` | `--runs` | `1` |
| think | `-Think` | `--think` | `true` |
| 最大出力トークン | `-NumPredict` | `--num-predict` | `2048` |
| temperature | `-Temperature` | `--temperature` | `0` |
| プロンプト | `-Prompt` | `--prompt` / `--prompt-file` | Swiftのソートの説明（スクリプト内） |
| CSV出力先 | `-OutputCsv` | `--output-csv` | `ollama-benchmark.csv` |
| prompt cacheを避ける | `-BustPromptCache` | `--bust-prompt-cache` | なし |
| Ollamaの接続先 | `-OllamaHost` | `--host` | `http://localhost:11434` |

- `think` は `true` / `false` / `low` / `medium` / `high` / `max` / `default`。`default` はリクエストに `think` を含めない。thinking非対応のモデルでエラーになった場合は `false` か `default` を提案する。
- 入力速度を比べたいときは prompt cache の影響を避けるため `BustPromptCache` を付ける。
- CSVは指定がなければ作業ディレクトリに出る。上書きしてよいか分からない既存ファイルがあれば別名にする。

## 2. OSを判定する

- Windows: `scripts/benchmark.ps1` を Windows PowerShell 5.1 または PowerShell 7 で実行する。
- macOS: `scripts/benchmark.sh` を使う。`curl`・`perl` は標準で入っている。`jq` はmacOS 15以降は標準、それより前は `brew install jq` が必要（入れる前にユーザーに確認する）。
- Linuxでも `benchmark.sh` が動く（`curl`・`perl`・`jq` が必要）。

## 3. Ollamaを用意する

1. `ollama --version` でインストールを確認する。
2. ない場合はユーザーにインストールしてよいか確認してから入れる。
   - Windows: `winget install --id Ollama.Ollama -e`。インストール後は新しいシェルで `ollama` を使う。
   - macOS: Homebrewがあれば `brew install ollama`、なければ [公式ダウンロード](https://ollama.com/download) のアプリを入れてもらう。
   - パッケージマネージャーが使えない・ユーザーが自分で入れたい場合は、公式ダウンロードページを案内して完了を待つ。
3. `curl http://localhost:11434/api/version`（Windowsは `Invoke-RestMethod`）でサーバーが応答するか確認する。応答しなければOllamaアプリを起動するか、`ollama serve` をバックグラウンドで起動する。

## 4. モデルを用意する

`ollama list` で対象モデルがあるか確認する。ない場合は、モデル名とおおよそのサイズ（[Ollamaのライブラリ](https://ollama.com/library) で確認）を伝え、ダウンロードしてよいか確認してから `ollama pull <model>` を実行する。断られたら中止し、インストール済みのモデル一覧を示す。

## 5. 実行する

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>/scripts/benchmark.ps1 -Model qwen3:30b -Runs 10 -Think false
```

macOS:

```sh
bash <skill-dir>/scripts/benchmark.sh --model qwen3:30b --runs 10 --think false
```

`<skill-dir>` はこの `SKILL.md` があるディレクトリ。大きいモデルや回数が多い場合は時間がかかるので、タイムアウトを長めに取る。

終了コードで失敗理由を判断する。

- `2`: Ollamaに接続できない → 手順3に戻る。
- `3`: モデルがない → 手順4に戻る。
- `1`: APIエラーや引数の誤り → 表示されたメッセージを確認する。

## 6. 結果を伝える

サマリー（入力速度、出力前待ち時間、思考時間、回答時間、出力速度、合計時間）とCSVのパスを伝える。各項目の意味は次のとおり。

- Input / PromptTokPerSec: プロンプト処理速度（Ollamaの `prompt_eval_*`）。
- PreOutput: リクエスト送信から最初のthinkingまたは回答が届くまでの時間。
- Thinking / Answer: thinking開始から回答開始まで、回答開始から完了までの時間。
- Output / OutputTokPerSec: 生成速度（Ollamaの `eval_*`）。思考トークンも含む。
- WallSec: 1回分のリクエスト全体の時間。LoadSecが大きい場合はモデルのロード時間が含まれている。
