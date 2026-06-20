# -----------------------------------------------------------------------------
# Amazon Data Firehose 配信ストリーム: s3tables-iceberg (→ S3 Tables Iceberg)
# task 15.2 / Req 5.2, 5.3
# -----------------------------------------------------------------------------
# 本ファイルでは、FireLens (Fluent Bit) から PutRecordBatch される Error_Log を
# Amazon S3 Tables のマネージド Apache Iceberg テーブルへ書き込む Firehose 配信
# ストリームを定義する。
#
# 【Iceberg V2 / Parquet / Merge-on-Read について (Req 5.3)】
# Firehose の Iceberg 配信 (destination = "iceberg") は、テーブルフォーマットに
# Iceberg V2、データファイル形式に Parquet、行レベル操作方式に Merge-on-Read を
# 用いることが配信機能側の前提仕様として強制される。provider (hashicorp/aws
# v5.100.0) の iceberg_configuration ブロックには version / format / write-mode を
# 個別指定する引数は存在しないため、これらは Firehose Iceberg 配信のデフォルト挙動と
# 宛先テーブル定義 (s3tables.tf: format = "ICEBERG") によって担保される。
#
# 【既存リソース参照 (再宣言しない)】
#   - ストリーム名 : local.firehose_stream_names.s3tables           (iam_ecs.tf)
#   - 配信ロール   : aws_iam_role.firehose_s3tables                 (iam_firehose.tf)
#   - 宛先テーブル : aws_s3tables_namespace.iceberg / aws_s3tables_table.error_logs (s3tables.tf)
#   - 中間/バックアップ S3 : aws_s3_bucket.full_logs                (s3.tf)
#   - data.aws_region.current / data.aws_caller_identity.current    (s3.tf)
# -----------------------------------------------------------------------------

locals {
  # S3 Tables 連携用 Glue federated カタログ ARN。
  # Firehose の Iceberg 配信が S3 Tables を宛先とする場合、Glue Data Catalog の
  # S3 Tables federated カタログ (s3tablescatalog) 配下のテーブルバケットを指す。
  # 形式: arn:aws:glue:<region>:<account>:catalog/s3tablescatalog/<table-bucket-name>
  firehose_s3tables_catalog_arn = "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog/s3tablescatalog/${local.s3tables_bucket_name}"
}

resource "aws_kinesis_firehose_delivery_stream" "s3tables_iceberg" {
  # ストリーム名は ECS タスクロールがスコープする ARN と一致させる必要がある
  # (iam_ecs.tf: local.firehose_stream_names.s3tables = "${local.prefix}-s3tables-iceberg")。
  name        = local.firehose_stream_names.s3tables
  destination = "iceberg"

  # CreateDeliveryStream 時に配信ロールの Glue/S3 Tables 権限が検証される。
  # inline ポリシー attach 後にストリームを作成するよう依存させる。
  # S3 Tables の Lake Formation grant は provider 制約により CLI で付与するため
  # (lakeformation.tf 参照)、その grant 実施後に本ストリームを apply すること。
  depends_on = [aws_iam_role_policy.firehose_s3tables]

  iceberg_configuration {
    # S3 Tables 連携用 Glue federated カタログ ARN
    catalog_arn = local.firehose_s3tables_catalog_arn

    # Firehose Iceberg 配信ロール (S3 Tables / Glue 連携 / 中間 S3 権限)
    role_arn = aws_iam_role.firehose_s3tables.arn

    # バッファリング設定 (Iceberg 配信)
    buffering_interval = 60 # 秒
    buffering_size     = 64 # MiB

    # 失敗データのみを中間/バックアップ S3 へ退避する
    s3_backup_mode = "FailedDataOnly"

    # 宛先 S3 Tables Iceberg テーブル (namespace = database / table)
    destination_table_configuration {
      database_name = aws_s3tables_namespace.iceberg.namespace
      table_name    = aws_s3tables_table.error_logs.name
    }

    # 中間 / バックアップ (Firehose のエラー出力退避先) — full-logs バケットを流用
    s3_configuration {
      role_arn            = aws_iam_role.firehose_s3tables.arn
      bucket_arn          = aws_s3_bucket.full_logs.arn
      buffering_interval  = 60
      buffering_size      = 64
      compression_format  = "GZIP"
      prefix              = "firehose-s3tables-iceberg/"
      error_output_prefix = "firehose-s3tables-iceberg-errors/"
    }
  }

  tags = merge(local.common_tags, {
    Name    = local.firehose_stream_names.s3tables
    Purpose = "firehose-delivery-s3tables-iceberg"
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "firehose_s3tables_iceberg_stream_name" {
  description = "s3tables-iceberg Firehose 配信ストリーム名"
  value       = aws_kinesis_firehose_delivery_stream.s3tables_iceberg.name
}

output "firehose_s3tables_iceberg_stream_arn" {
  description = "s3tables-iceberg Firehose 配信ストリームの ARN"
  value       = aws_kinesis_firehose_delivery_stream.s3tables_iceberg.arn
}
