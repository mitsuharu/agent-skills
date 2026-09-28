# agent-skills

自作の Agent Skills をGitHubで管理し、Codexなどの対応エージェントから再利用するためのリポジトリです。
Skillのソースは `skills/` にまとめ、変更は作業用ブランチからPull Requestで追加します。

## ディレクトリ構成

```text
agent-skills/
├── README.md
├── .gitignore
├── AGENTS.md
└── skills/
    ├── add-skill/
    │   ├── SKILL.md
    │   └── references/
    │       └── validation.md
    ├── play-torneko-chotto-dungeon/
    │   └── SKILL.md
    └── setup-comfyui-qwen-image-gguf/
        ├── SKILL.md
        └── references/
            ├── quant-selection.md
            └── workflow.md
```

## Agent Skillとは

Agent Skillは、特定の作業で使う指示と必要な補助ファイルをまとめたものです。
`SKILL.md` 冒頭のYAML frontmatterに名前と用途を書き、その後に実行手順を記載します。
エージェントは最初に名前と説明を確認し、該当するSkillの本文、必要な補助資料の順に読み込みます（progressive disclosure）。

`references/` は必要時に読む資料、`scripts/` は実行用コード、`assets/` は成果物に使うテンプレートや素材の置き場です。必要のないディレクトリは作りません。

## Skill一覧

| Skill | 用途 |
| --- | --- |
| [add-skill](skills/add-skill/SKILL.md) | このリポジトリへのSkill追加、重複確認、README更新、構造検証 |
| [setup-comfyui-qwen-image-gguf](skills/setup-comfyui-qwen-image-gguf/SKILL.md) | Windows + NVIDIA GPUにComfyUIを構築し、Qwen-Image-2.1-Uncensored（GGUF）をVRAMに合った量子化で使えるようにする |
| [play-torneko-chotto-dungeon](skills/play-torneko-chotto-dungeon/SKILL.md) | Steam版トルネコの大冒険リマスターをコンピュータ操作でプレイし、ちょっと不思議のダンジョンの宝石箱を持ち帰る。プレイごとに攻略情報を更新する |

## インストール

Node.js・npm（`npx`）とGitが使える環境で、Skillを利用したいプロジェクトのディレクトリから実行します。

公開済みSkillの一覧を確認（インストールはしません）:

```sh
npx skills add mitsuharu/agent-skills --list
```

特定Skillをインストール（`<skill-name>` を一覧の名前に置き換えます）:

```sh
npx skills add mitsuharu/agent-skills --skill <skill-name>
```

Codex向けに `add-skill` をインストールする例:

```sh
npx skills add mitsuharu/agent-skills --skill add-skill --agent codex
```

デフォルトはプロジェクト単位です。`--agent codex` でCodexを指定でき、複数プロジェクトで使う場合は `--global` を追加します。対象エージェントやインストール方法はCLIの案内に従って選びます。
これらのリモート指定は既定ブランチの内容を参照するため、初回PRのマージ前やローカル変更の確認には次のローカル指定を使います。

## 新しいSkillを追加する

### add-skillを利用する

このリポジトリをcloneし、ルートでローカルの `add-skill` をインストールします。

```sh
git clone https://github.com/mitsuharu/agent-skills.git
cd agent-skills
npx skills add . --skill add-skill --agent codex
```

すでにclone済みなら、そのチェックアウトで最後のコマンドだけ実行します。
`skills/` は配布用ソースであり、置いただけでCodexの自動検出先になるわけではありません。CLIでCodex向けにインストールしてから、このリポジトリをCodexで開きます。Skillが表示されなければCodexを再起動してください。

たとえば次のように依頼します。用途の説明に一致すると `add-skill` が選択されます。

```text
このリポジトリにQiita記事を書くためのSkillを追加して。
```

Codex CLI・IDE拡張では明示的に指定することもできます。

```text
$add-skill このリポジトリにQiita記事を書くためのSkillを追加して。
```

インストールせずに進めたい場合は、読むファイルを直接指定できます。

```text
skills/add-skill/SKILL.md を読み、その手順に従って、このリポジトリにQiita記事を書くためのSkillを追加して。
```

Agentは既存Skillの重複確認、作業ブランチでの作成、README一覧更新、検証、目的別コミット、PR作成まで進めます。
Qiita向けSkillは依頼例であり、現時点で収録されているのは上記一覧のSkillのみです。

### 手動で追加する

1. `main` から作業ブランチを作り、[AGENTS.md](AGENTS.md) と既存Skillを確認します。
2. 目的が重複しない名前で `skills/<skill-name>/SKILL.md` を作成します。名前は英小文字・数字・ハイフンの1〜64文字とし、先頭末尾・連続ハイフンを避けます。
3. frontmatterの `name` をディレクトリ名に合わせ、`description` に機能と利用場面を簡潔に記載します。本文には手順と成果物の確認方法を書きます。
4. 必要な場合だけ補助ファイルを追加し、本文から相対リンクで読むタイミングを示します。
5. このREADMEのSkill一覧を更新し、[検証チェックリスト](skills/add-skill/references/validation.md) に沿って確認します。
6. 目的ごとにコミットを分け、PRを作成します。

最小の記述例（`skills/write-qiita-article/SKILL.md`）:

```markdown
---
name: write-qiita-article
description: Qiita向けの技術記事の草稿を作成する。検証済みの技術メモから記事を構成したいときに使用する。
---

# Qiita記事の草稿を作成する

読者と伝えたい内容を確認し、提供された技術メモから見出しと本文を作成する。
未検証のコードや主張は区別し、公開前の確認事項とともにMarkdownの草稿を渡す。
```

追加後の検出確認はリポジトリのルートで行います。

```sh
npx skills add . --list
```

これはSkillの検出確認です。YAMLの妥当性や名前の制約、参照先、手順の内容はチェックリストで別途確認してください。

## 開発方針

共通ルールは [AGENTS.md](AGENTS.md) を参照してください。
`main` へ直接変更を入れず、目的ごとにコミットを分け、PRでレビューします。

## 公式資料

- [Agent Skills仕様](https://agentskills.io/specification)
- [skills CLIの利用方法・オプション](https://github.com/vercel-labs/skills#readme)
- [CodexのSkill作成・利用方法](https://developers.openai.com/codex/skills/)
