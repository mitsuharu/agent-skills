---
name: setup-comfyui-qwen-image-gguf
description: WindowsのNVIDIA GPU環境に、ComfyUIとComfyUI-GGUFを入れてQwen-Image-2.1-Uncensored（GGUF）で画像生成できる状態を構築する。VRAMに合わせて量子化を選び、モデル配置、起動用バッチ、既定ワークフローまで整える。「ComfyUIでQwen-Image 2.1のGGUFを使えるようにして」という依頼で使用する。
---

# ComfyUIでQwen-Image-2.1-Uncensored（GGUF）を使えるようにする

対象モデルは [abenzerps/Qwen-Image-2.1-Uncensored-GGUF](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF)。
構築先フォルダはユーザーの指定に従い、指定がなければ作成前に確認する。以下では `<root>` と書く。

## 1. 環境を確認する

- `nvidia-smi` でGPU名、VRAM総量、使用中のVRAMとプロセスを確認する。RAM容量と `<root>` のドライブ空き容量（モデルだけで15〜20GB程度）も確認する。
- Python（3.12系推奨）とGitが使えるか確認する。ない場合はインストール方法をユーザーに確認する。
- GPU世代からPyTorchのCUDA版を決める。RTX 50系（Blackwell）はCUDA 12.8以上のビルドが必須で、実績は PyTorch 2.14 + CUDA 13.0（`cu130`）。インストールコマンドは [PyTorch公式](https://pytorch.org/get-started/locally/) で確認する。

## 2. モデルカードと量子化を決める

- モデルカード（README）とファイル一覧を読み、GGUF本体、テキストエンコーダ、VAEの推奨ファイルと配置先を確認する。READMEの推奨が下記と食い違う場合はREADMEを優先する。
- 量子化は [VRAMによる量子化の選び方](references/quant-selection.md) に従って選び、選んだ理由（VRAM・ファイルサイズ）をユーザーに伝える。判断が分かれる場合だけ、ダウンロード前に確認する。
- テキストエンコーダはREADME推奨のint8版（約9GB）を基本とする。RAMが32GB未満の場合はより小さい版の有無を確認する。

## 3. ComfyUIとComfyUI-GGUFをインストールする

1. `<root>` に [ComfyUI](https://github.com/comfyanonymous/ComfyUI) をcloneし、`<root>\ComfyUI\venv`（または `<root>\venv`）に仮想環境を作る。
2. 仮想環境で手順1で決めたCUDA版のPyTorch（torch・torchvision・torchaudio）を入れ、その後にComfyUIの `requirements.txt` を入れる。requirementsがCPU版torchで上書きしていないか `python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name())"` で確認する。
3. `custom_nodes` に [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) をcloneし、その `requirements.txt`（`gguf` など）を同じ仮想環境に入れる。

モデルのダウンロードは時間がかかるので、インストールと並行して始めてよい。

## 4. モデルをダウンロードして配置する

| 種類 | 配置先 |
| --- | --- |
| GGUF本体 | `ComfyUI\models\unet`（`diffusion_models` でも可） |
| テキストエンコーダ | `ComfyUI\models\text_encoders` |
| VAE | `ComfyUI\models\vae` |

- 大きいファイルは中断されやすいため、再開できる方法（`hf download`、`curl -C -` など）で取得する。
- Hugging Faceのファイル情報にあるSHA256と、`certutil -hashfile <file> SHA256` または `Get-FileHash` の値が一致することを確認する。途中で切れたファイルを使わない。

## 5. ワークフローと起動方法を整える

- ComfyUI公式のQwen-Image 2.1 Text-to-Imageテンプレートを基に、モデル読み込みをComfyUI-GGUFの `Unet Loader (GGUF)` に差し替えたワークフローを作り、`ComfyUI\user\default\workflows\Qwen-Image-2.1-UC_GGUF_t2i.json` に保存する。詳細と既知の問題は [ワークフローと既定表示の調整](references/workflow.md) を読む。
- `<root>\run_comfyui.bat` を作る。仮想環境のPythonで `ComfyUI\main.py --auto-launch` を実行し、ダブルクリックで起動してブラウザが開くようにする。

## 6. 検証する

1. `run_comfyui.bat` で起動し、ログでGPUが認識され、ComfyUI-GGUFの読み込みにエラーがないことを確認する。
2. API（`/prompt`）またはブラウザから、作ったワークフローで1024×1024・25ステップ程度のテスト画像を生成する。参考値はRTX 5070 Ti 16GB・Q8_0で初回約3分、2枚目以降約1分40秒。
3. まっさらなブラウザプロファイル（シークレットウィンドウなど）で開き、モデル不足の警告が出ずにQwenのワークフローが表示されることを確認する。

## 完了報告

起動方法（`run_comfyui.bat`）、開くワークフロー名、選んだ量子化とその理由、配置したモデルとチェックサム確認結果、生成時間を伝える。
ほかのアプリがVRAMを使っていて遅い場合はその旨も伝える。
