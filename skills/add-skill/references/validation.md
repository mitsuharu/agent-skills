# Skill追加時の検証

Skill作成後、PRを作成する前に使うチェックリスト。

## 構造とfrontmatter

- [ ] `skills/<skill-name>/SKILL.md` が存在し、先頭が `---` で区切られた有効なYAMLになっている。
- [ ] `name` と `description` が空ではない文字列である。YAMLの特殊文字を含む値は引用符やブロックスカラーを使う。
- [ ] `name` はディレクトリ名と一致し、英小文字・数字・ハイフンのみの1〜64文字。先頭末尾のハイフン・連続ハイフンがない。
- [ ] `description` は1〜1024文字で、機能と利用場面が明確である。
- [ ] 任意のfrontmatter項目を使う場合は、[Agent Skills仕様](https://agentskills.io/specification)で型と制約を確認する。
- [ ] 本文は500行未満を目安に簡潔に保つ。補助ファイルへのリンク先が存在し、必要な場面が書かれている。
- [ ] 未記入のTODO、不要なサンプル、空ディレクトリ、機密情報、実行環境固有の絶対パスがない。

## 内容と動作

- [ ] 既存Skillと用途・名前が重複せず、READMEの一覧に実在する相対リンクと用途が載っている。
- [ ] 代表的な依頼を1つ選び、説明から選択できることと、手順を追って期待する成果物まで到達できることを確認する。
- [ ] 対象外の依頼を1つ選び、説明がその依頼を不必要に拾わないことを確認する。
- [ ] 補助スクリプトがあれば必要な依存関係を明記し、一時ディレクトリで代表的な入力を実行して出力を確認する。
- [ ] READMEのCLIオプションが [skills CLI公式README](https://github.com/vercel-labs/skills#readme) と一致する。

## 配布と差分

リポジトリのルートで実行する。

```sh
npx skills add . --list
git diff --check
git diff --cached --check
git status --short
git log --oneline main..HEAD
git diff --stat main...HEAD
```

一覧に新しいSkillが名前・説明付きで表示されることを確認する。
`--list` はインストールを行わない。検出できてもfrontmatterの全制約を検証できるわけではないので、上のチェックも実施する。

コミット済みの変更は `git diff --check main...HEAD` でも確認する。
差分に必要なファイルだけが含まれ、コミットが論理的な変更単位になっていることを確認する。
利用できる仕様検証ツールがある場合は併用し、実行したコマンドと結果、目視確認、未実施の項目を区別して報告する。
