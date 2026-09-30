# Repository guidelines

このリポジトリは、自作の Agent Skills を `skills/` に保管・配布する。
説明文と手順は原則日本語で書き、Skill名・パス・コマンドは英語表記を使う。

## Pull Request

- すべての変更は作業用ブランチで行い、Pull Request経由で追加する。
- `main` へ直接コミット・pushしない。PRのマージは別途依頼がある場合だけ行う。
- 作業開始時にブランチと未コミットの変更を確認し、他の作業を上書きしない。

## Commit

- 機能・目的・論理的な変更単位で分割し、異なる目的を巨大なコミットにまとめない。
- 各コミットが単体で目的を説明できるようにする。関連するSkill一覧の更新はSkill追加と同じコミットに含めてよい。
- Conventional Commitsに近い形式を使う。例:
  - `chore: initialize agent skills repository`
  - `feat: add skill creation skill`
  - `docs: document skill creation workflow`

## Skill development

- 新規追加前に既存の `skills/` とREADMEの一覧を確認し、目的の重複と命名・構成の一貫性を確認する。
- `skills/<skill-name>/SKILL.md` を配置の基本とし、ディレクトリ名とfrontmatterの `name` を一致させる。
- Skill追加には `skills/add-skill/SKILL.md` を読み、その手順を適用する。
- Skill固有の詳細は各 `SKILL.md` や `references/` に置き、このファイルに集約しない。
- `SKILL.md` を簡潔に保ち、補助資料・スクリプト・素材は実際に必要な場合だけ追加する。
- Skillを追加・変更したらREADMEの一覧と使い方を同期する。不要な設定や生成物を追加しない。

## GitHub Actions

- 外部のactionはタグではなくフルのコミットSHAで固定し、行末にバージョンをコメントで書く。例: `uses: actions/checkout@<40桁のSHA> # v7.0.1`
- SHAはタグが指すコミットを公式リポジトリで確認して使う（`git ls-remote --tags https://github.com/<owner>/<repo>` など）。更新時もSHAとコメントを一緒に変える。
- Node.jsのバージョンはルートの `.node-version` で指定する（現在は24）。非推奨のNode.jsで動くactionは、そのランタイムに対応したバージョンへ上げる。
- PRを検証するCIは `pull_request` の `types: [opened, synchronize, reopened]` で起動し、`push` トリガーは付けない。対象Skillのファイルだけで動くよう `paths` を指定する。
- 同じPRで重複して走らないよう、workflowには次の `concurrency` を付ける。

  ```yaml
  concurrency:
    group: ci-${{ github.workflow }}-${{ github.ref }}
    cancel-in-progress: true
  ```

- actionの更新はDependabot（`.github/dependabot.yml` の `github-actions`）で月1回確認する。新しい依存のエコシステムを追加したら同じファイルに設定を足す。

## Validation

- PR作成前に `skills/add-skill/references/validation.md` に従い、frontmatter・リンク・Skillの動作手順を確認する。
- `npx skills add . --list` で配布対象が検出されることを確認する。これはインストールを行わない。
- CLI仕様を書くときは公式ドキュメントを確認する。
- `git diff --check` と差分・コミット履歴を確認し、不要なファイルや機密情報がないことを確かめる。
- 実施した検証と未実施の項目を区別して報告する。
