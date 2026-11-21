# RideCom 開発指示の入口

作業前に、以下の基準となる資料を読み、今回の変更に適用すること。本リポジトリの共通指示として必ず適用する。

| 区分 | 基準となる資料 | 内容 |
|---|---|---|
| アプリの根本要求 | [製品要求](docs/requirements/製品要求.md) | 目的・背景・利用者価値・共通品質方針 |
| 作り方 | [開発方針](docs/policies/開発方針.md) | TDD、packageとAppの工程分離、設計・UI・技術・開発環境の制約 |
| 記録の仕方 | [文書作成規約](docs/policies/文書作成規約.md) | 計画、見出しによる識別、情報保持、文書更新・命名・要求管理 |
| ログの実装 | [ログ記録規約](docs/policies/ログ記録規約.md) | レベル、構造、機密情報の保護 |

すべての作業で最初に[常設セキュリティ監査](.agents/skills/security-audit/SKILL.md)を適用し、出力先を決めてから調査し、変更の受入・外部送信前に最新の Astra で判定する。

すべての作業で[責務分離スキル](.agents/skills/architecture-refinement/SKILL.md#常時適用)の入口を適用し、変更に関係する節だけを読む。

すべての作業で[再実装のためのスキル](.agents/skills/rebuild-from-spec/SKILL.md)を適用し、用途・要求・仕様と検証結果を区切りごとに照合する。

各作業の区切り、日本語の文書・画面文言・スキルを変更するとき、依頼者が言い回しを指摘したときは、[言葉の使い方を確かめる手順](.agents/skills/japanese-word-usage/SKILL.md)を適用する。

**作業の着手前と区切りには、[小さく動く単位での検証・コミットと未コミットの滞留管理](docs/policies/開発方針.md#小さく動く単位で検証・コミットする)を必ず適用する。**

GUIの実装・変更・点検では、[UI Stackを含むUI・UX方針](docs/policies/開発方針.md#uiux方針)を必ず適用する。Standard（一般向け）とAdvanced（詳細表示）の画面は、[StandardとAdvancedの設計の絶対ルール](docs/policies/開発方針.md#standardとadvancedの設計の絶対ルール)に例外なく従う。

[文書入口](docs/README.md)から、対象の仕様・マニュアル・検証状況も確認する。過去の計画は経緯の確認に使い、今回の判断には現行の要求・方針・仕様を適用する。規約変更は該当する文書にまとめ、この入口には参照を保つ。
