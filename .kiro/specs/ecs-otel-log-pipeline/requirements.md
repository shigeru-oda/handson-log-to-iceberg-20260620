# 要件定義書

## Introduction

本機能は、Amazon ECS Fargate 上で常駐稼働するアプリケーションが OpenTelemetry (OTel) Log Data Model 形式のログを継続的に出力し、そのログを 2 段階のパイプラインで処理・蓄積する仕組みを構築するものである。

- ステージ 1: エラーレベルのログを Amazon CloudWatch Logs へ、全ログを Amazon S3 へ配信する。
- ステージ 2: エラーレベルのログを Apache Iceberg テーブルへ、(a) Amazon S3 Tables によるマネージド Iceberg と (b) AWS Glue Data Catalog を用いた S3 上のセルフマネージド Iceberg の両方の方式で蓄積する。

すべてのインフラストラクチャは Terraform でプロビジョニングする。リージョンは ap-northeast-1 (東京) を対象とし、Terraform のステート管理はローカルバックエンドを用いる。ログ生成アプリケーションは Go で実装したダミーログジェネレーターとする。ログのルーティングは ECS FireLens (Fluent Bit) サイドカーを経由し、Amazon Data Firehose を介して各配信先へ届ける。

本書はビジネス要件およびシステム振る舞い要件を EARS パターンと INCOSE 品質ルールに従って定義する。実装方式の詳細は設計フェーズで扱う。

## Glossary

- **Log_Generator**: Go で実装され、ECS Fargate 上で常駐稼働し OTel Log Data Model 形式のログを出力するダミーアプリケーション。
- **OTel_Log_Record**: OpenTelemetry Log Data Model に準拠したログレコード。severity (重大度)、body (本文)、resource (リソース属性)、attributes (属性)、timestamp (タイムスタンプ) を含む。
- **FireLens_Router**: ECS FireLens を通じて構成される Fluent Bit ベースのログルーター (サイドカーコンテナ)。
- **Firehose_Stream**: Amazon Data Firehose の配信ストリーム。各配信先 (S3、CloudWatch Logs 経路、Iceberg) ごとに用意される。
- **Error_Log**: OTel severity が ERROR 以上 (ERROR または FATAL) のログレコード。
- **CloudWatch_Logs**: Amazon CloudWatch Logs。
- **S3_Bucket**: 全ログを格納する Amazon S3 バケット。
- **S3_Tables_Iceberg**: Amazon S3 Tables が提供するマネージド Apache Iceberg テーブル。
- **Glue_Iceberg**: AWS Glue Data Catalog に登録され、データ実体を Amazon S3 上に持つセルフマネージド Apache Iceberg テーブル。
- **Glue_Data_Catalog**: AWS Glue Data Catalog。
- **Terraform_Stack**: 本機能のインフラを定義する Terraform 構成。
- **Iceberg_Schema_Mapping**: OTel ログのネストされたフィールドを Iceberg テーブルのカラムへ対応付けるスキーマ定義。

## Requirements

### Requirement 1: Go 製ダミー OTel ログジェネレーター

**User Story:** 開発者として、OTel Log Data Model 形式のログを生成するダミーアプリケーションが欲しい。それによって、ログパイプライン全体を実データなしで検証できる。

#### Acceptance Criteria

1. THE Log_Generator SHALL Go 言語で実装される。
2. THE Log_Generator SHALL OpenTelemetry Log Data Model に準拠した OTel_Log_Record を出力する。
3. THE Log_Generator SHALL 各 OTel_Log_Record に severity、body、resource、attributes、timestamp の各フィールドを含める。
4. THE Log_Generator SHALL 各 OTel_Log_Record を標準出力 (stdout) へ出力する。
5. THE Log_Generator SHALL ERROR および FATAL を含む複数の severity レベルの OTel_Log_Record を生成する。

### Requirement 2: 常駐稼働と定期的なログ出力

**User Story:** 開発者として、アプリケーションが ECS Fargate 上で常駐し一定間隔でログを出し続けてほしい。それによって、パイプラインへ継続的にログが流れる状態を再現できる。

#### Acceptance Criteria

1. THE Log_Generator SHALL Amazon ECS Fargate (Linux) 上で常駐サービスとして稼働する。
2. WHILE THE Log_Generator が稼働している間、THE Log_Generator SHALL 設定された一定間隔で OTel_Log_Record を出力する。
3. THE Log_Generator SHALL ログ出力間隔を設定値として外部から指定可能にする。
4. IF THE Log_Generator のプロセスが終了した場合、THEN THE ECS Fargate サービス SHALL タスクを再起動して常駐稼働を継続する。

### Requirement 3: FireLens によるログルーティング

**User Story:** 開発者として、アプリケーションのログを FireLens 経由で振り分けたい。それによって、ログの重大度に応じて配信先を制御できる。

#### Acceptance Criteria

1. THE FireLens_Router SHALL ECS FireLens (Fluent Bit) サイドカーとして構成される。
2. THE FireLens_Router SHALL THE Log_Generator の標準出力を入力として受け取る。
3. THE FireLens_Router SHALL 各 OTel_Log_Record の OTel severity に基づいて配信先を振り分ける。
4. THE FireLens_Router SHALL ログを Amazon Data Firehose (kinesis_firehose 出力) へ転送する。
5. WHERE OTel severity が ERROR 以上である場合、THE FireLens_Router SHALL 当該 OTel_Log_Record を Error_Log として扱い、エラー向け配信先へルーティングする。

### Requirement 4: ステージ 1 - CloudWatch Logs と S3 への配信

**User Story:** 運用者として、エラーログを CloudWatch Logs で即時に確認しつつ全ログを S3 に蓄積したい。それによって、監視と完全な記録の両方を実現できる。

#### Acceptance Criteria

1. WHEN THE FireLens_Router が Error_Log を受け取ったとき、THE FireLens_Router SHALL 当該 Error_Log を CloudWatch_Logs へ配信する。
2. THE FireLens_Router SHALL すべての OTel_Log_Record を Firehose_Stream 経由で S3_Bucket へ配信する。
3. WHEN OTel_Log_Record が S3_Bucket へ配信されるとき、THE Firehose_Stream SHALL severity による絞り込みを行わず全ログを格納する。
4. THE S3_Bucket SHALL ap-northeast-1 リージョンに作成される。

### Requirement 5: ステージ 2 - S3 Tables によるマネージド Iceberg への蓄積

**User Story:** データ利用者として、エラーログを Amazon S3 Tables のマネージド Iceberg テーブルに蓄積したい。それによって、運用負荷の少ない方式でクエリ可能なエラーログを保持できる。

#### Acceptance Criteria

1. THE Terraform_Stack SHALL Amazon S3 Tables による S3_Tables_Iceberg テーブルを作成する。
2. WHEN Error_Log が配信されるとき、THE Firehose_Stream SHALL Iceberg 配信機能を用いて当該 Error_Log を S3_Tables_Iceberg へ書き込む。
3. THE Firehose_Stream SHALL Iceberg 配信において、テーブルフォーマットとして Iceberg V2 を用い、Iceberg テーブル内のデータファイル形式として Parquet を用い、行レベル操作方式として Merge-on-Read を用いる。
4. THE S3_Tables_Iceberg SHALL すべてのカラム名を小文字で定義する。
5. THE Iceberg_Schema_Mapping SHALL OTel_Log_Record のネストされたフィールドを、主要フィールドのフラット化および/またはネストデータの JSON 文字列カラム化によって S3_Tables_Iceberg のスキーマへ対応付ける。

### Requirement 6: ステージ 2 - Glue Data Catalog によるセルフマネージド Iceberg への蓄積

**User Story:** データ利用者として、エラーログを AWS Glue Data Catalog 管理下の S3 上 Iceberg テーブルにも蓄積したい。それによって、S3 Tables 方式とセルフマネージド方式を比較・検証できる。

#### Acceptance Criteria

1. THE Terraform_Stack SHALL Glue_Data_Catalog に登録された Glue_Iceberg テーブルを作成する。
2. THE Glue_Iceberg SHALL データ実体を Amazon S3 上に格納する。
3. WHEN Error_Log が配信されるとき、THE Firehose_Stream SHALL Iceberg 配信機能を用いて当該 Error_Log を Glue_Iceberg へ書き込む。
4. THE Firehose_Stream SHALL Glue_Iceberg への配信において、テーブルフォーマットとして Iceberg V2 を用い、Iceberg テーブル内のデータファイル形式として Parquet を用い、行レベル操作方式として Merge-on-Read を用いる。
5. THE Iceberg_Schema_Mapping SHALL OTel_Log_Record のネストされたフィールドを、主要フィールドのフラット化および/またはネストデータの JSON 文字列カラム化によって Glue_Iceberg のスキーマへ対応付ける。

### Requirement 7: Terraform によるプロビジョニングとリージョン・ステート管理

**User Story:** インフラ担当者として、すべてのリソースを Terraform で再現可能にプロビジョニングしたい。それによって、環境構築を自動化し一貫性を保てる。

#### Acceptance Criteria

1. THE Terraform_Stack SHALL 本機能で用いるすべての AWS リソースを定義する。
2. THE Terraform_Stack SHALL ap-northeast-1 (東京) リージョンを対象としてリソースを作成する。
3. THE Terraform_Stack SHALL ローカルバックエンドを用いてステートを管理する。
4. THE Terraform_Stack SHALL ローカルステートに対する自動ロック機構や同時アクセスの検知・防止機能を提供せず、ローカルステートへの同時アクセスを避けることを運用上の制約として明文化し、利用者が同時実行の調整を行う前提とする。
