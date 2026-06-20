# -----------------------------------------------------------------------------
# Amazon S3 Tables (マネージド Apache Iceberg) — Req 5.1, 5.4, 5.5
# -----------------------------------------------------------------------------
# 本ファイルでは Firehose の s3tables-iceberg ストリーム (task 15.2) の配信先となる
# Amazon S3 Tables のリソースを定義する。
#   1. table bucket : S3 Tables のテーブルバケット (マネージド Iceberg の格納先)
#   2. namespace    : テーブルを束ねる論理名前空間
#   3. table        : Apache Iceberg 形式 (format = "ICEBERG") のエラーログテーブル
#
# 【カラムスキーマについて (Req 5.4, 5.5)】
# 設計書 (design.md / Iceberg_Schema_Mapping) のスキーマ表どおり、全カラム名は
# 小文字で定義する。下記 local.s3tables_iceberg_columns がその正典 (小文字カラム一覧)。
#
# ただし、本環境にインストールされている AWS provider (hashicorp/aws v5.100.0) の
# aws_s3tables_table リソースは、カラムスキーマをインラインで宣言する引数
# (metadata / schema / field 等) を **サポートしていない** (format / name /
# namespace / table_bucket_arn / encryption_configuration /
# maintenance_configuration のみ)。
# したがって、テーブルは format = "ICEBERG" で作成し、実際のスキーマ (小文字カラム) は
# Firehose の Iceberg 配信 (Iceberg V2 / Parquet / Merge-on-Read) もしくは Athena の
# DDL によって作成・管理される。レコード側のキー名を下記の小文字カラム名と一致させる
# ことで、Firehose が宛先テーブルスキーマへ正しくマッピングできる (design.md 参照)。
#
# 【tags について】
# aws_s3tables_* リソース群は tags 引数をサポートしないため local.common_tags は
# 付与していない (provider v5.100.0)。
# -----------------------------------------------------------------------------

locals {
  # S3 Tables テーブルバケット名 (グローバル一意・小文字・ハイフン区切り)
  s3tables_bucket_name = "${local.prefix}-s3tables"

  # namespace / table 名 (S3 Tables は小文字英数字とアンダースコアを使用)
  s3tables_namespace = replace(local.prefix, "-", "_") # 例: otel_log_pipeline_dev
  s3tables_table     = "error_logs"

  # Iceberg テーブルスキーマの正典 (全カラム名は小文字) — Req 5.4, 5.5
  # design.md の Iceberg_Schema_Mapping 表に対応。Firehose Iceberg 配信 / Athena DDL が
  # このスキーマでテーブルを具現化する。S3 Tables / Glue で同一論理スキーマを共有する。
  s3tables_iceberg_columns = [
    { name = "event_time", type = "timestamp", from = "timestamp" },     # RFC3339Nano -> Iceberg timestamp
    { name = "severity_number", type = "int", from = "severityNumber" }, # そのまま
    { name = "severity_text", type = "string", from = "severityText" },  # そのまま
    { name = "body", type = "string", from = "body" },                   # そのまま
    { name = "resource_json", type = "string", from = "resource" },      # object -> JSON 文字列
    { name = "attributes_json", type = "string", from = "attributes" },  # object -> JSON 文字列
    { name = "ingest_date", type = "string", from = "timestamp" },       # YYYY-MM-DD パーティション列 (任意)
  ]
}

# -----------------------------------------------------------------------------
# 1. S3 Tables テーブルバケット — Req 5.1
# -----------------------------------------------------------------------------
resource "aws_s3tables_table_bucket" "iceberg" {
  name = local.s3tables_bucket_name

  # S3 Tables テーブルバケットはデフォルトでサーバーサイド暗号化 (SSE-S3/AES256) が
  # 有効になる。provider v5.100.0 はこのデフォルトを構成へ反映しないため、未指定だと
  # apply 後に "Provider produced inconsistent result" エラーが発生する。
  # API が返すデフォルト値を明示することで config と一致させる。
  encryption_configuration = {
    sse_algorithm = "AES256"
    kms_key_arn   = null
  }
}

# -----------------------------------------------------------------------------
# 2. namespace — Req 5.1
# -----------------------------------------------------------------------------
resource "aws_s3tables_namespace" "iceberg" {
  namespace        = local.s3tables_namespace
  table_bucket_arn = aws_s3tables_table_bucket.iceberg.arn
}

# -----------------------------------------------------------------------------
# 3. table (Apache Iceberg) — Req 5.1, 5.4, 5.5
# -----------------------------------------------------------------------------
# format = "ICEBERG" 固定。小文字カラムスキーマ (local.s3tables_iceberg_columns) は
# Firehose Iceberg 配信 / Athena DDL により具現化される (provider v5.100.0 は
# インラインスキーマ定義をサポートしないため)。
resource "aws_s3tables_table" "error_logs" {
  name             = local.s3tables_table
  namespace        = aws_s3tables_namespace.iceberg.namespace
  table_bucket_arn = aws_s3tables_table_bucket.iceberg.arn
  format           = "ICEBERG"
}

# -----------------------------------------------------------------------------
# Outputs — Firehose s3tables-iceberg ストリーム (15.2) / IAM (14.2) が参照する
# -----------------------------------------------------------------------------
output "s3tables_bucket_arn" {
  description = "S3 Tables テーブルバケットの ARN"
  value       = aws_s3tables_table_bucket.iceberg.arn
}

output "s3tables_namespace" {
  description = "S3 Tables の namespace 名"
  value       = aws_s3tables_namespace.iceberg.namespace
}

output "s3tables_table_name" {
  description = "S3 Tables の Iceberg テーブル名"
  value       = aws_s3tables_table.error_logs.name
}

output "s3tables_table_arn" {
  description = "S3 Tables の Iceberg テーブル ARN"
  value       = aws_s3tables_table.error_logs.arn
}

output "s3tables_iceberg_columns" {
  description = "S3 Tables Iceberg テーブルの小文字カラム定義 (Req 5.4, 5.5 の正典)"
  value       = local.s3tables_iceberg_columns
}
