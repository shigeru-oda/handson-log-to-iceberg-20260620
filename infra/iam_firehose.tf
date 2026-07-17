# -----------------------------------------------------------------------------
# IAM — Amazon Data Firehose 配信ロール 3 種 (最小権限) — Req 4.2, 5.2, 6.3
# -----------------------------------------------------------------------------
# 本ファイルでは、設計書 (design.md / 「6. IAM ロール」) のとおり Firehose の
# 配信先別に 3 つの配信ロールを定義する。いずれも assume-role プリンシパルは
# firehose.amazonaws.com とし、各ロールは必要なリソース ARN に限定する。
#
#   1. full-logs        : full-logs S3 バケットへの書き込み (Firehose S3 配信)
#   2. s3tables-iceberg : S3 Tables (マネージド Iceberg) + Glue カタログ連携 +
#                         中間/バックアップ S3 (Firehose のエラー出力退避先)
#   3. glue-iceberg     : Glue 操作 + データ実体 S3 (セルフマネージド Iceberg)
#
# 既存リソースは以下の Terraform アドレスを参照する (再宣言しない):
#   - aws_s3_bucket.full_logs / aws_s3_bucket.glue_iceberg          (s3.tf)
#   - aws_s3tables_table_bucket.iceberg                              (s3tables.tf)
#   - aws_glue_catalog_database.iceberg / aws_glue_catalog_table.iceberg_errors (glue.tf)
#   - data.aws_caller_identity.current / data.aws_region.current     (s3.tf)
# -----------------------------------------------------------------------------

locals {
  # Glue ARN 構築用の共通要素 (data ソースは s3.tf で宣言済み)
  glue_arn_prefix = "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"

  # Glue カタログ / database / table の ARN
  glue_catalog_arn  = "${local.glue_arn_prefix}:catalog"
  glue_database_arn = "${local.glue_arn_prefix}:database/${aws_glue_catalog_database.iceberg.name}"
  glue_table_arn    = "${local.glue_arn_prefix}:table/${aws_glue_catalog_database.iceberg.name}/${aws_glue_catalog_table.iceberg_errors.name}"

  # S3 Tables の federated Glue カタログ (s3tablescatalog) ARN — S3 Tables 連携用
  glue_s3tables_catalog_arn = "${local.glue_arn_prefix}:catalog/s3tablescatalog"
}

# -----------------------------------------------------------------------------
# Assume-role ポリシー (3 ロール共通) — プリンシパル: firehose.amazonaws.com
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

# =============================================================================
# 1. full-logs 配信ロール — Req 4.2
#    full-logs S3 バケットへの書き込み (Firehose S3 配信)
# =============================================================================
resource "aws_iam_role" "firehose_full_logs" {
  name               = "${local.prefix}-firehose-full-logs"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json

  tags = merge(local.common_tags, {
    Name    = "${local.prefix}-firehose-full-logs"
    Purpose = "firehose-delivery-full-logs"
  })
}

data "aws_iam_policy_document" "firehose_full_logs" {
  # バケットレベル操作
  statement {
    sid    = "S3BucketLevel"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.full_logs.arn]
  }

  # オブジェクトレベル操作
  statement {
    sid    = "S3ObjectLevel"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.full_logs.arn}/*"]
  }
}

resource "aws_iam_role_policy" "firehose_full_logs" {
  name   = "${local.prefix}-firehose-full-logs-policy"
  role   = aws_iam_role.firehose_full_logs.id
  policy = data.aws_iam_policy_document.firehose_full_logs.json
}

# =============================================================================
# 2. s3tables-iceberg 配信ロール — Req 5.2
#    S3 Tables (マネージド Iceberg) + Glue カタログ連携 + 中間/バックアップ S3
# =============================================================================
resource "aws_iam_role" "firehose_s3tables" {
  name               = "${local.prefix}-firehose-s3tables-iceberg"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json

  tags = merge(local.common_tags, {
    Name    = "${local.prefix}-firehose-s3tables-iceberg"
    Purpose = "firehose-delivery-s3tables-iceberg"
  })
}

data "aws_iam_policy_document" "firehose_s3tables" {
  # S3 Tables テーブルバケット / namespace / table への操作。
  # AWS 公式ドキュメント (Grant Firehose access to Amazon S3 Tables / IAM access
  # control) が示す最小権限セットに絞る (s3tables:* ワイルドカードは避ける)。
  # https://docs.aws.amazon.com/firehose/latest/dev/controlling-access.html
  statement {
    sid    = "S3TablesAccess"
    effect = "Allow"
    actions = [
      "s3tables:GetNamespace",
      "s3tables:GetTable",
      "s3tables:GetTableData",
      "s3tables:GetTableMetadataLocation",
      "s3tables:PutTableData",
      "s3tables:UpdateTableMetadataLocation",
    ]
    resources = [
      "${aws_s3tables_table_bucket.iceberg.arn}",
      "${aws_s3tables_table_bucket.iceberg.arn}/table/*",
    ]
  }

  statement {
    sid       = "S3TableBucketAccess"
    effect    = "Allow"
    actions   = ["s3tables:GetTableBucket"]
    resources = [aws_s3tables_table_bucket.iceberg.arn]
  }

  # S3 Tables の Glue federated カタログ連携 (read) — Firehose の Iceberg 配信が
  # 宛先テーブルスキーマを解決するために必要。
  # S3 Tables を「IAM アクセスコントロール」で統合 (s3tablescatalog を IAM_ALLOWED_PRINCIPALS
  # で作成) した場合、アクセスは IAM のみで決まり Lake Formation の grant は不要。
  # ここでは AWS ドキュメントの Firehose ロールサンプルに合わせ、federated カタログ配下の
  # database / table も解決できるよう database/* と table/*/* を含める。
  statement {
    sid    = "GlueS3TablesCatalogRead"
    effect = "Allow"
    actions = [
      "glue:GetCatalog",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
      "glue:UpdateTable",
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_s3tables_catalog_arn,
      "${local.glue_s3tables_catalog_arn}/*",
      "${local.glue_arn_prefix}:database/*",
      "${local.glue_arn_prefix}:table/*/*",
    ]
  }

  # Lake Formation のデータアクセス資格情報発行。S3 Tables フェデレーションカタログは
  # IAM アクセスコントロールでもデータアクセスの vending が Lake Formation 経由となるため、
  # 配信ロールに lakeformation:GetDataAccess を許可しておく (AWS の Firehose ロールサンプル準拠)。
  statement {
    sid       = "LakeFormationDataAccess"
    effect    = "Allow"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }

  # 中間 / バックアップ (Firehose エラー出力) 用 S3 — full-logs バケットを退避先に流用
  statement {
    sid    = "S3BackupBucketLevel"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.full_logs.arn]
  }

  statement {
    sid    = "S3BackupObjectLevel"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.full_logs.arn}/*"]
  }
}

resource "aws_iam_role_policy" "firehose_s3tables" {
  name   = "${local.prefix}-firehose-s3tables-iceberg-policy"
  role   = aws_iam_role.firehose_s3tables.id
  policy = data.aws_iam_policy_document.firehose_s3tables.json
}

# =============================================================================
# 3. glue-iceberg 配信ロール — Req 6.3
#    Glue 操作 + データ実体 S3 (セルフマネージド Iceberg)
# =============================================================================
resource "aws_iam_role" "firehose_glue" {
  name               = "${local.prefix}-firehose-glue-iceberg"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json

  tags = merge(local.common_tags, {
    Name    = "${local.prefix}-firehose-glue-iceberg"
    Purpose = "firehose-delivery-glue-iceberg"
  })
}

data "aws_iam_policy_document" "firehose_glue" {
  # Glue Data Catalog の Iceberg テーブル操作
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetTable",
      "glue:GetDatabase",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
      "glue:UpdateTable",
    ]
    resources = [
      local.glue_catalog_arn,
      local.glue_database_arn,
      local.glue_table_arn,
    ]
  }

  # データ実体バケットへの read/write/delete
  statement {
    sid    = "S3DataBucketLevel"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.glue_iceberg.arn]
  }

  statement {
    sid    = "S3DataObjectLevel"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.glue_iceberg.arn}/*"]
  }
}

resource "aws_iam_role_policy" "firehose_glue" {
  name   = "${local.prefix}-firehose-glue-iceberg-policy"
  role   = aws_iam_role.firehose_glue.id
  policy = data.aws_iam_policy_document.firehose_glue.json
}

# -----------------------------------------------------------------------------
# Outputs — Firehose ストリーム (tasks 15.1 / 15.2 / 15.3) が参照する
# -----------------------------------------------------------------------------
output "firehose_full_logs_role_arn" {
  description = "Firehose full-logs ストリームの配信ロール ARN"
  value       = aws_iam_role.firehose_full_logs.arn
}

output "firehose_s3tables_role_arn" {
  description = "Firehose s3tables-iceberg ストリームの配信ロール ARN"
  value       = aws_iam_role.firehose_s3tables.arn
}

output "firehose_glue_role_arn" {
  description = "Firehose glue-iceberg ストリームの配信ロール ARN"
  value       = aws_iam_role.firehose_glue.arn
}
