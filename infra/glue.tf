# -----------------------------------------------------------------------------
# AWS Glue Data Catalog — セルフマネージド Iceberg テーブル (ap-northeast-1)
# -----------------------------------------------------------------------------
# 本ファイルでは、AWS Glue Data Catalog に登録するセルフマネージド Apache Iceberg
# テーブル (Glue_Iceberg) を定義する (Req 6.1, 6.2, 6.5)。
#   - Glue database: Iceberg テーブルを束ねる論理データベース
#   - Glue table   : table_type=ICEBERG のセルフマネージド Iceberg テーブル
#
# データ実体は s3.tf で定義した glue-iceberg バケット (aws_s3_bucket.glue_iceberg)
# の prefix を location として指す (Req 6.2)。
#
# スキーマは S3 Tables 側 (s3tables.tf) と同一の小文字カラムに統一する (Req 6.5)。
# Iceberg テーブルプロパティは V2 / Parquet / Merge-on-Read 固定 (Req 6.4)。
# -----------------------------------------------------------------------------

locals {
  # Glue database / table 名 (Athena 等との互換のためハイフンをアンダースコアへ正規化)
  glue_database_name = "${replace(local.prefix, "-", "_")}_logs"
  glue_table_name    = "errors"

  # Iceberg データ実体の S3 location (Req 6.2)
  glue_iceberg_table_location = "s3://${aws_s3_bucket.glue_iceberg.bucket}/iceberg/errors/"
}

# -----------------------------------------------------------------------------
# Glue database — Req 6.1
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "iceberg" {
  name        = local.glue_database_name
  description = "Glue Data Catalog database for self-managed Iceberg error-log table"

  tags = merge(local.common_tags, {
    Name    = local.glue_database_name
    Purpose = "glue-iceberg-catalog"
  })
}

# -----------------------------------------------------------------------------
# Glue Iceberg table — Req 6.1, 6.2, 6.4, 6.5
# -----------------------------------------------------------------------------
# table_type=ICEBERG によりセルフマネージド Iceberg テーブルとして登録する。
# カラム名は S3 Tables テーブルと同一の小文字スキーマ (Req 6.5)。
# プロパティで Iceberg V2 / Parquet / Merge-on-Read を指定 (Req 6.4)。
resource "aws_glue_catalog_table" "iceberg_errors" {
  name          = local.glue_table_name
  database_name = aws_glue_catalog_database.iceberg.name
  table_type    = "EXTERNAL_TABLE"

  open_table_format_input {
    iceberg_input {
      metadata_operation = "CREATE"
      version            = "2"
    }
  }

  # 注意: open_table_format_input.iceberg_input を使う場合、Glue は table_type=ICEBERG と
  # metadata_location を自動的に設定する。これらは予約パラメータのため、parameters に
  # 含めると CreateTable が InvalidInputException
  # ("Cannot use reserved parameters table_type or metadata_location...") で失敗する。
  # したがって Iceberg の書き込みプロパティ (Req 6.4) のみを指定する。
  parameters = {
    # Iceberg テーブルプロパティ (Req 6.4)
    "format-version"       = "2"             # Iceberg V2
    "write.format.default" = "parquet"       # Parquet
    "write.delete.mode"    = "merge-on-read" # MoR
    "write.update.mode"    = "merge-on-read"
    "write.merge.mode"     = "merge-on-read"
  }

  storage_descriptor {
    # データ実体は glue-iceberg バケットの prefix を指す (Req 6.2)
    location = local.glue_iceberg_table_location

    # 小文字カラムの共通 Iceberg スキーマ (Req 6.5 / design.md)
    columns {
      name = "event_time"
      type = "timestamp"
    }
    columns {
      name = "severity_number"
      type = "int"
    }
    columns {
      name = "severity_text"
      type = "string"
    }
    columns {
      name = "body"
      type = "string"
    }
    columns {
      name = "resource_json"
      type = "string"
    }
    columns {
      name = "attributes_json"
      type = "string"
    }
    columns {
      name = "ingest_date"
      type = "string"
    }
  }

  # Iceberg テーブルへ Firehose が書き込みを開始すると、Glue カタログ側の
  # parameters (metadata_location / previous_metadata_location) や
  # storage_descriptor のカラム parameters (iceberg.field.*) が書き込みエンジン側で
  # 更新される。これらは Iceberg writer が所有する実行時メタデータであり、Terraform が
  # 管理対象にすると毎回ドリフト差分が出る。作成後はこれらを無視し、Iceberg メタデータを
  # source of truth とする。
  lifecycle {
    ignore_changes = [
      parameters,
      storage_descriptor,
    ]
  }
}

# -----------------------------------------------------------------------------
# Outputs — Firehose glue-iceberg ストリーム (15.3) / IAM (14.2) が参照する
# -----------------------------------------------------------------------------
output "glue_database_name" {
  description = "Glue Iceberg テーブルが属する Glue database 名"
  value       = aws_glue_catalog_database.iceberg.name
}

output "glue_iceberg_table_name" {
  description = "Glue セルフマネージド Iceberg テーブル名"
  value       = aws_glue_catalog_table.iceberg_errors.name
}

output "glue_iceberg_table_location" {
  description = "Glue Iceberg テーブルのデータ実体 S3 location"
  value       = local.glue_iceberg_table_location
}
