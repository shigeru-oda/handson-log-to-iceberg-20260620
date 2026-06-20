# -----------------------------------------------------------------------------
# S3 Buckets (ap-northeast-1)
# -----------------------------------------------------------------------------
# 本ファイルでは 2 種類の S3 バケットを定義する (Req 4.2, 4.4, 6.2)。
#   1. full-logs バケット : 全 OTel ログ (raw) を格納する (Firehose full-logs ストリームの配信先)
#   2. glue-iceberg データ実体バケット : Glue Data Catalog 管理のセルフマネージド
#      Iceberg テーブルのデータ実体 (location) を格納する
#
# バケット名はグローバルに一意である必要があるため、アカウント ID とリージョンを
# サフィックスとして付与する。
# -----------------------------------------------------------------------------

# 現在の AWS アカウント ID / リージョンを取得 (バケット名のグローバル一意化に使用)
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  # バケット名サフィックス: {account_id}-{region}
  s3_bucket_name_suffix = "${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"

  # 全ログ raw 用バケット名 (Req 4.2, 4.4)
  full_logs_bucket_name = "${local.prefix}-full-logs-${local.s3_bucket_name_suffix}"

  # Glue Iceberg データ実体用バケット名 (Req 6.2)
  glue_iceberg_bucket_name = "${local.prefix}-glue-iceberg-${local.s3_bucket_name_suffix}"
}

# -----------------------------------------------------------------------------
# 1. full-logs バケット (全 OTel ログ raw 格納) — Req 4.2, 4.4
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "full_logs" {
  bucket = local.full_logs_bucket_name

  tags = merge(local.common_tags, {
    Name    = local.full_logs_bucket_name
    Purpose = "full-logs-raw"
  })
}

resource "aws_s3_bucket_public_access_block" "full_logs" {
  bucket = aws_s3_bucket.full_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "full_logs" {
  bucket = aws_s3_bucket.full_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "full_logs" {
  bucket = aws_s3_bucket.full_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# 2. Glue Iceberg データ実体バケット — Req 6.2
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "glue_iceberg" {
  bucket = local.glue_iceberg_bucket_name

  tags = merge(local.common_tags, {
    Name    = local.glue_iceberg_bucket_name
    Purpose = "glue-iceberg-data"
  })
}

resource "aws_s3_bucket_public_access_block" "glue_iceberg" {
  bucket = aws_s3_bucket.glue_iceberg.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "glue_iceberg" {
  bucket = aws_s3_bucket.glue_iceberg.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "glue_iceberg" {
  bucket = aws_s3_bucket.glue_iceberg.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs — Firehose (15.x) / Glue (13.2) が参照する
# -----------------------------------------------------------------------------
output "full_logs_bucket_name" {
  description = "全 OTel ログ (raw) を格納する S3 バケット名"
  value       = aws_s3_bucket.full_logs.bucket
}

output "full_logs_bucket_arn" {
  description = "全 OTel ログ (raw) を格納する S3 バケットの ARN"
  value       = aws_s3_bucket.full_logs.arn
}

output "glue_iceberg_bucket_name" {
  description = "Glue Iceberg データ実体を格納する S3 バケット名"
  value       = aws_s3_bucket.glue_iceberg.bucket
}

output "glue_iceberg_bucket_arn" {
  description = "Glue Iceberg データ実体を格納する S3 バケットの ARN"
  value       = aws_s3_bucket.glue_iceberg.arn
}
