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
    └── <skill-name>/
        └── SKILL.md
```

## Agent Skillとは

Agent Skillは、特定の作業で使う指示と必要な補助ファイルをまとめたものです。
`SKILL.md` 冒頭のYAML frontmatterに名前と用途を書き、その後に実行手順を記載します。
エージェントは最初に名前と説明を確認し、該当するSkillの本文、必要な補助資料の順に読み込みます（progressive disclosure）。

`references/` は必要時に読む資料、`scripts/` は実行用コード、`assets/` は成果物に使うテンプレートや素材の置き場です。必要のないディレクトリは作りません。

## Skill一覧

現在、登録済みのSkillはありません。

## 開発方針

共通ルールは [AGENTS.md](AGENTS.md) を参照してください。
`main` へ直接変更を入れず、目的ごとにコミットを分け、PRでレビューします。
