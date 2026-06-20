# 実装計画: ecs-otel-log-pipeline

## Overview

本計画は、要件定義書 (`requirements.md`) と設計書 (`design.md`) に厳密に基づき、ECS Fargate 上で常駐稼働する Go 製ダミー OTel ログジェネレーター、FireLens (Fluent Bit) による severity ベースのルーティング、Amazon Data Firehose を介した S3 / CloudWatch Logs / Iceberg (S3 Tables・Glue) への 2 段階配信、および Terraform による全インフラ定義を、段階的かつテスト駆動で構築するためのコーディングタスク一覧である。

実装言語は設計書に従い Go (アプリ) と HCL/Terraform (インフラ) を用いる。Go の純粋ロジックには設計の Correctness Property 1〜6 をプロパティベーステスト (PBT) として実装する。PBT ライブラリは `pgregory.net/rapid` または `testing/quick` を採用し、各テストは最低 100 回反復、コメントタグ `Feature: ecs-otel-log-pipeline, Property N: ...` を付す。

ステップは前段の成果物の上に積み上がり、最後に main・コンテナ・Terraform を結線して全体を統合する。

## Tasks

- [x] 1. Go プロジェクト雛形とディレクトリ構成のセットアップ
  - `app/` 配下に Go module を初期化 (`go mod init`)
  - `internal/config`、`internal/otel`、`internal/routing`、`internal/scheduler`、`internal/iceberg`、`cmd/log-generator` のパッケージ骨格を作成
  - PBT ライブラリ (`pgregory.net/rapid` もしくは `testing/quick`) の依存を追加し、ビルド・テスト実行が通る最小状態にする
  - _Requirements: 1.1_

- [x] 2. 設定読み込み (config パッケージ) の実装
  - [x] 2.1 `LoadConfig(env map[string]string) (Config, error)` を実装
    - 環境変数 `LOG_INTERVAL_MS` を読み込み `IntervalMillis` に設定
    - 空・非数値・0・負値を無効値として error を返す (フェイルファスト)
    - _Requirements: 2.3_
  - [x] 2.2 `LoadConfig` のユニットテストを作成
    - 有効値および境界値 (空、`0`、負値、非数値、正常値) を検証
    - _Requirements: 2.3_

- [x] 3. OTel ログレコードモデルと生成ロジック (otel パッケージ) の実装
  - [x] 3.1 `SeverityNumber` 定数群と `LogRecord` 構造体を定義
    - `timestamp`、`severityNumber`、`severityText`、`body`、`resource`、`attributes` の JSON タグを設計どおり付与
    - `SeverityTrace..SeverityFatal` (1..21) と ERROR 下限 (17) を定義
    - _Requirements: 1.2, 1.3_
  - [x] 3.2 `Generate(rng *rand.Rand, now time.Time) LogRecord` を実装
    - 乱数源と時刻を注入し決定的にテスト可能にする
    - ERROR / FATAL を含む複数 severity を生成し、必須フィールドをすべて埋める
    - _Requirements: 1.2, 1.3, 1.5_
  - [x] 3.3 Property 1 のプロパティベーステストを作成
    - **Property 1: OTel レコードのスキーマ妥当性と JSON ラウンドトリップ**
    - **Validates: Requirements 1.2, 1.3**
    - 必須フィールド存在・`severityNumber` が 1..24・JSON シリアライズ/デシリアライズ等価を検証 (>=100 反復、タグ付与)
  - [x] 3.4 `Generate` の出力に関するユニットテストを作成
    - JSON Lines として 1 行で書けること、注入した `io.Writer` (bytes.Buffer) へ書き込めることを検証
    - _Requirements: 1.4_

- [x] 4. ルーティング判定リファレンス関数 (routing パッケージ) の実装
  - [x] 4.1 `IsError` と経路判定関数 `Route(severityNumber) []Destination` を実装
    - `severityNumber >= 17` を ERROR 以上と判定する正典ロジック
    - 全件→S3、ERROR 以上→CloudWatch / S3 Tables Iceberg / Glue Iceberg の Fluent Bit 設定と同等のリファレンス実装
    - _Requirements: 3.3, 3.5_
  - [x] 4.2 Property 2 のプロパティベーステストを作成
    - **Property 2: 全ログの S3 ルーティング (severity 非依存)**
    - **Validates: Requirements 4.2, 4.3**
    - 任意のレコード集合で S3 経路集合が入力全体と一致することを検証 (>=100 反復、タグ付与)
  - [x] 4.3 Property 3 のプロパティベーステストを作成
    - **Property 3: Error_Log のルーティング正当性**
    - **Validates: Requirements 3.3, 3.5, 4.1, 5.2, 6.3**
    - CloudWatch / S3 Tables / Glue の 3 経路集合が `severityNumber >= 17` のレコード集合と正確に一致することを検証 (>=100 反復、タグ付与)
  - [x] 4.4 severity 境界のユニットテストを作成
    - `severityNumber=16` (非エラー) と `17` (エラー) の分岐を検証
    - _Requirements: 3.3, 3.5_

- [x] 5. 出力間隔スケジューラ (scheduler パッケージ) の実装
  - [x] 5.1 `Scheduler` 構造体と `Next(prev time.Time) time.Time` を実装
    - `Interval` に設定値を反映し、`Next` は `prev + Interval` を返す (時計注入で純粋にテスト可能)
    - _Requirements: 2.2, 2.3_
  - [x] 5.2 Property 6 のプロパティベーステストを作成
    - **Property 6: 設定された出力間隔の適用**
    - **Validates: Requirements 2.2, 2.3**
    - `LoadConfig` の間隔が `Scheduler.Interval` に反映され `Next(prev)==prev+Interval`、無効値で `LoadConfig` がエラーを返すことを検証 (>=100 反復、タグ付与)

- [x] 6. Iceberg スキーママッピング (iceberg パッケージ) の実装
  - [x] 6.1 `LogRecord` → Iceberg 行へのマッピング関数を実装
    - 主要フィールド (`event_time`、`severity_number`、`severity_text`、`body`) をフラット化し、`resource`/`attributes` を JSON 文字列カラム (`resource_json`/`attributes_json`) にシリアライズ
    - 全カラム名を小文字に統一し、S3 Tables 用・Glue 用で同一論理スキーマを返す
    - _Requirements: 5.4, 5.5, 6.5_
  - [x] 6.2 Property 4 のプロパティベーステストを作成
    - **Property 4: Iceberg スキーマの小文字カラム不変条件**
    - **Validates: Requirements 5.4**
    - 生成スキーマの全カラム名 `c` について `lower(c)==c` を S3 Tables 用・Glue 用の両方で検証 (>=100 反復、タグ付与)
  - [x] 6.3 Property 5 のプロパティベーステストを作成
    - **Property 5: スキーママッピングのネスト保持ラウンドトリップと両ターゲット等価性**
    - **Validates: Requirements 5.5, 6.5**
    - 主要フィールドの平坦カラム化、`resource`/`attributes` の JSON ラウンドトリップ等価、S3 Tables 用と Glue 用マッピング結果の論理的等価を検証 (>=100 反復、タグ付与)

- [x] 7. アプリ本体 (cmd/log-generator) の結線
  - [x] 7.1 `main` を実装し各コンポーネントを結線
    - `LoadConfig` → 乱数源初期化 → `Generate` → `os.Stdout` へ JSON Lines 出力 → `Scheduler.Next` に従い sleep する無限ループ
    - 設定エラー時は明確なログを出して非ゼロ終了 (フェイルファスト)
    - _Requirements: 1.4, 2.2, 2.3_
  - [x] 7.2 main ループの統合テストを作成
    - writer 注入と短い間隔・回数制限で複数行の JSON Lines が出力されることを検証
    - _Requirements: 1.4, 2.2_

- [x] 8. チェックポイント - Go アプリの全テストを通す
  - すべてのテストが通ることを確認し、疑問点があればユーザーに確認する。

- [x] 9. Go アプリのコンテナ化
  - [x] 9.1 マルチステージ `Dockerfile` を作成しコンテナをビルド
    - Linux/amd64 向けに Go アプリをビルドし、最小ランタイムイメージに格納
    - ローカルでコンテナビルドが成功することを確認
    - _Requirements: 1.1, 2.1_

- [x] 10. Terraform provider・バックエンド・共通設定
  - [x] 10.1 provider / backend / variables / locals を定義
    - `provider "aws"` を `ap-northeast-1` に設定、backend を `local` に設定 (ロック機構なし)
    - ローカルステート同時アクセスを避ける運用制約をコメント/README に明文化
    - 共通変数・命名 locals を定義
    - _Requirements: 7.1, 7.2, 7.3, 7.4_

- [x] 11. Terraform ネットワーク構成
  - [x] 11.1 VPC・サブネット・セキュリティグループを定義
    - マルチ AZ (ap-northeast-1a/1c) のサブネット、アウトバウンド 443 許可の SG、Firehose/CloudWatch/ECR への到達性 (パブリック IP もしくは NAT)
    - _Requirements: 2.1, 3.4_

- [x] 12. Terraform ストレージ・ログ基盤 (S3 / CloudWatch)
  - [x] 12.1 S3 バケット 2 種を定義
    - 全ログ raw 用バケット (full-logs)、Glue Iceberg データ実体用バケットを `ap-northeast-1` に作成
    - _Requirements: 4.2, 4.4, 6.2_
  - [x] 12.2 CloudWatch Logs ロググループを定義
    - エラーログ用ロググループ (例: `/ecs/otel-pipeline/errors`) を作成
    - _Requirements: 4.1_

- [x] 13. Terraform Iceberg カタログ (S3 Tables / Glue)
  - [x] 13.1 S3 Tables の table bucket・namespace・table を定義
    - 設計のスキーマ表どおり全カラム名を小文字で定義 (`event_time`、`severity_number`、`severity_text`、`body`、`resource_json`、`attributes_json` 等)
    - _Requirements: 5.1, 5.4, 5.5_
  - [x] 13.2 Glue database と Iceberg テーブルを定義
    - `table_type=ICEBERG`、`location` を S3 実体バケット prefix、`format-version=2`/`write.format.default=parquet`/MoR プロパティ、S3 Tables と同一の小文字スキーマ
    - _Requirements: 6.1, 6.2, 6.5_

- [x] 14. Terraform IAM ロール
  - [x] 14.1 ECS タスクロールとタスク実行ロールを定義
    - 実行ロール: ECR 取得・起動時ログ権限。タスクロール: `firehose:PutRecordBatch` (3 ストリーム) と CloudWatch Logs 出力権限
    - _Requirements: 3.4, 4.1_
  - [x] 14.2 Firehose 配信ロール 3 種を定義
    - full-logs (S3 書き込み)、s3tables-iceberg (S3 Tables/Glue 連携 + 中間 S3)、glue-iceberg (Glue 操作 + データ実体 S3) を最小権限で定義
    - _Requirements: 4.2, 5.2, 6.3_

- [x] 15. Terraform Amazon Data Firehose 配信ストリーム
  - [x] 15.1 `full-logs` ストリーム (→ S3) を定義
    - 全 OTel ログを絞り込みなしで S3 raw へ配信、時刻プレフィックス、エラープレフィックス退避
    - _Requirements: 4.2, 4.3_
  - [x] 15.2 `s3tables-iceberg` ストリーム (→ S3 Tables Iceberg) を定義
    - Iceberg V2 / Parquet / Merge-on-Read、宛先 S3 Tables テーブル、配信ロール紐付け
    - _Requirements: 5.2, 5.3_
  - [x] 15.3 `glue-iceberg` ストリーム (→ Glue Iceberg) を定義
    - Iceberg V2 / Parquet / Merge-on-Read、宛先 Glue テーブル、配信ロール紐付け
    - _Requirements: 6.3, 6.4_

- [x] 16. Fluent Bit カスタム設定 (FireLens) の作成
  - [x] 16.1 `custom.conf` を作成し severity ベースのルーティングを実装
    - `rewrite_tag` で `severityNumber>=17` に `error.*` タグを派生
    - 全件→`kinesis_firehose` (full-logs)、`error.*`→`cloudwatch_logs` + 両 Iceberg `kinesis_firehose` ストリームへ出力
    - region は `ap-northeast-1`、配信ストリーム名/ロググループ名は環境変数で注入
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 5.2, 6.3_

- [x] 17. Terraform ECS (クラスタ・タスク定義・サービス)
  - [x] 17.1 ECS クラスタを定義
    - Fargate 用クラスタを作成
    - _Requirements: 2.1_
  - [x] 17.2 タスク定義 (app + FireLens Fluent Bit サイドカー) を定義
    - app コンテナ: `logDriver=awsfirelens`、`LOG_INTERVAL_MS` 環境変数注入
    - log_router コンテナ: `firelensConfiguration` (fluentbit)、custom.conf 参照
    - _Requirements: 2.3, 3.1, 3.2, 3.4_
  - [x] 17.3 ECS サービス (Fargate, desiredCount=1) を定義
    - `launchType=FARGATE`、`desiredCount=1`、サブネット/SG 紐付け、タスク異常終了時の自己修復
    - _Requirements: 2.1, 2.4_

- [x] 18. チェックポイント - Go テストと Terraform 構成の整合確認
  - すべてのテストが通ることを確認し、疑問点があればユーザーに確認する。

- [x] 19. 検証 (Terraform 静的検証と E2E チェックリスト)
  - [x] 19.1 Terraform `validate`/`plan` のスナップショット検証を実装
    - 必要リソース (VPC/サブネット/SG、ECS サービス・タスク定義、Firehose 3 ストリーム、S3 バケット 2 種、CloudWatch ロググループ、S3 Tables テーブル、Glue database/table、IAM ロール群) の存在、provider region=`ap-northeast-1`、backend=`local` (ロックなし)、`desiredCount>=1`、`logDriver=awsfirelens`、Iceberg `format-version=2`/Parquet/MoR、Glue `location` が S3 を自動検証するテスト/スクリプトを作成
    - _Requirements: 2.1, 2.4, 3.1, 3.2, 5.3, 6.2, 6.4, 7.1, 7.2, 7.3, 7.4_
  - [x] 19.2 手動 E2E 検証チェックリストを作成
    - デプロイ後に (1) S3 に全 severity が蓄積、(2) CloudWatch に ERROR/FATAL のみ、(3) S3 Tables / Glue Iceberg テーブルを Athena でクエリしエラーログのみが行として存在することを確認する手順を Markdown チェックリストとして記述
    - _Requirements: 4.1, 4.2, 4.3, 5.2, 6.3_

## Notes

- `*` 付きのサブタスクは任意 (主にテスト) であり、MVP を急ぐ場合はスキップ可能。コア実装タスクには `*` を付けない。
- 各タスクはトレーサビリティのため具体的な要件番号を参照する。
- プロパティテストは設計の Correctness Property (Property 1〜6) を 1 プロパティ = 1 テストで実装し、最低 100 反復・タグ付与を行う。
- ユニットテストは境界値・エラー条件など具体例を検証し、プロパティテストと相補的に用いる。
- Terraform・マネージド挙動は PBT 非適用のため、スナップショット/静的検証 (19.1) と手動 E2E (19.2) で補完する。
- チェックポイントで段階的に検証を行う。

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["2.1", "3.1", "10.1"] },
    { "id": 2, "tasks": ["2.2", "3.2", "4.1", "5.1", "6.1", "11.1", "12.1", "12.2"] },
    { "id": 3, "tasks": ["3.3", "3.4", "4.2", "4.3", "4.4", "5.2", "6.2", "6.3", "13.1", "13.2", "14.1", "14.2"] },
    { "id": 4, "tasks": ["7.1", "15.1", "15.2", "15.3", "16.1", "17.1"] },
    { "id": 5, "tasks": ["7.2", "9.1", "17.2"] },
    { "id": 6, "tasks": ["17.3"] },
    { "id": 7, "tasks": ["19.1", "19.2"] }
  ]
}
```
