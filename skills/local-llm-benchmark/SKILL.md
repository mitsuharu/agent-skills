---
name: local-llm-benchmark
description: ローカルLLMの日本語理解、Swift/iOS、React Native、コードレビュー、設計、推論、指示遵守の品質と入力・生成速度を固定問題で比較する。Ollama、llama.cpp、LM StudioのAPIを使った実務能力の評価に使用する。速度だけのOllama計測はbenchmark-ollama-llmを使う。
---

# ローカルLLMの実務ベンチマーク

1. 対象モデル、API方式、接続先、量子化、GPU、コンテキスト長、ランタイム版、thinking設定を確認する。モデルの設定はサーバー側で固定し記録する。既定は3回・temperature 0・最大生成2048。対象ごとに同じ条件を使う。
2. Python 3.10以上（標準ライブラリのみ）で実行する。接続先は利用者が許可したローカルまたはLANのAPIに限定する。モデルのダウンロードや設定変更は勝手に行わない。
3. [実行・採点方法](references/protocol.md) に従う。問題は [cases.json](assets/cases.json) に固定し、採点基準は評価対象へ送らない。
4. 出力JSONを保存する。品質は別の評価者が採点し、速度と独立して報告する。生成コードを自動実行しない。コンパイル・テストが未実施なら明記する。

例（Skillディレクトリから）:

```sh
python scripts/benchmark.py --backend ollama --url http://localhost:11434 --model gemma4:12b --out gemma.json
python scripts/benchmark.py --backend openai --url http://localhost:1234 --model MODEL_ID --out lmstudio.json
python scripts/benchmark.py --backend openai --url http://localhost:8080 --model MODEL_ID --out llama.json
```

Windowsでpythonが見つからなければpy -3を使う。速度のみの依頼は対象外。結果の再現条件、未採点、エラー、打ち切りを隠さない。
