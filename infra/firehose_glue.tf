# -----------------------------------------------------------------------------
# Amazon Data Firehose 配信ストリーム — glue-iceberg (→ Glue Iceberg) — Req 6.3, 6.4
# -----------------------------------------------------------------------------
# 本ファイルでは、Error_Log を AWS Glue Data Catalog 管理のセルフマネージド
# Apache Iceberg テーブル (Glue_Iceberg) へ書き込む Firehose 配信ストリームを
# 定義する。
#
# 設計書 (design.md / 「4. Amazon Data Firehose 配信ストリーム」) のとおり:
#   - 配信先          : iceberg (Glue Data Catalog の Iceberg テーブル)
#   - 内容            : Error_Log のみ (severity>=ERROR) — ルーティングは FireLens 側
#   - テーブル        : aws_glue_catalog_database.iceberg / aws_glue_catalog_table.iceberg_errors
#   - 配信ロール      : aws_iam_role.firehose_glue (iam_firehose.tf)
#
# 【Iceberg V2 / Parquet / Merge-on-Read について (Req 6.4)】
# Firehose の Iceberg 配信は宛先 Iceberg テーブルの定義に従ってデータファイルを
# 書き込む。テーブルフォーマット (V2) / データファイル形式 (Parquet) / 行レベル
# 操作方式 (Merge-on-Read) は、宛先となる Glue テーブル側のプロパティ
# (glue.tf: format-version=2 / write.format.default=parquet /
#  write.{delete,update,merge}.mode=merge-on-read) によって enforce される。
# provider v5.100.0 の iceberg_configuration には V2/Parquet/MoR を直接指定する
# 引数は存在しないため、ここではテーブル参照と配信ロールの紐付けに専念する。
#
# 既存リソース参照 (再宣言しない):
#   - aws_iam_role.firehose_glue                  (iam_firehose.tf)
#   - aws_glue_catalog_database.iceberg           (glue.tf)
#   - aws_glue_catalog_table.iceberg_errors       (glue.tf)
#   - aws_s3_bucket.glue_iceberg                  (s3.tf)
#   - local.firehose_stream_names.glue            (iam_ecs.tf)
#   - data.aws_region.current / data.aws_caller_identity.current (s3.tf)
#   - local.common_tags                           (locals.tf)
#
# ストリーム名は IAM タスクロール (iam_ecs.tf) が参照する命名と一致させるため、
# local.firehose_stream_names.glue ("${local.prefix}-glue-iceberg") を用いる。
# -----------------------------------------------------------------------------

locals {
  # 標準的な Glue Data Catalog の ARN (arn:aws:glue:<region>:<account>:catalog)
  firehose_glue_catalog_arn = "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog"
}

resource "aws_kinesis_firehose_delivery_stream" "glue_iceberg" {
  name        = local.firehose_stream_names.glue
  destination = "iceberg"

  # CreateDeliveryStream 時に配信ロールの Glue 権限が検証されるため、inline ポリシー
  # および Lake Formation の grant が揃ってからストリームを作成するよう依存させる。
  depends_on = [
    aws_iam_role_policy.firehose_glue,
    aws_lakeformation_permissions.firehose_glue_database,
    aws_lakeformation_permissions.firehose_glue_table,
  ]

  iceberg_configuration {
    role_arn    = aws_iam_role.firehose_glue.arn
    catalog_arn = local.firehose_glue_catalog_arn

    # バッファリング設定 (他の Firehose ストリーム [full-logs / s3tables-iceberg] と統一)。
    buffering_size     = 5
    buffering_interval = 300

    # 宛先 Iceberg テーブル (Glue database / table) — Req 6.3
    # テーブルの V2 / Parquet / Merge-on-Read 設定は glue.tf 側で enforce される (Req 6.4)。
    destination_table_configuration {
      database_name = aws_glue_catalog_database.iceberg.name
      table_name    = aws_glue_catalog_table.iceberg_errors.name
    }

    # 中間 / 配信失敗レコードの退避先 (Firehose Iceberg 配信に必須)。
    # データ実体バケットを流用し、errors/ プレフィックスへ退避する。
    s3_configuration {
      role_arn            = aws_iam_role.firehose_glue.arn
      bucket_arn          = aws_s3_bucket.glue_iceberg.arn
      error_output_prefix = "errors/!{firehose:error-output-type}/"
      buffering_size      = 5
      buffering_interval  = 300
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "firehose_glue_iceberg_stream_name" {
  description = "glue-iceberg Firehose 配信ストリーム名 (→ Glue Iceberg)"
  value       = aws_kinesis_firehose_delivery_stream.glue_iceberg.name
}

output "firehose_glue_iceberg_stream_arn" {
  description = "glue-iceberg Firehose 配信ストリームの ARN"
  value       = aws_kinesis_firehose_delivery_stream.glue_iceberg.arn
}
