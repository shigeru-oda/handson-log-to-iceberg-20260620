# -----------------------------------------------------------------------------
# AWS Lake Formation 権限 — Firehose 配信ロールへの grant
# -----------------------------------------------------------------------------
# 本アカウントは Lake Formation が有効化され、Glue Data Catalog (標準カタログおよび
# S3 Tables の federated カタログ s3tablescatalog) を統制している。そのため、IAM 権限
# だけでは Firehose が宛先 Iceberg テーブルへアクセスできず、Lake Formation の grant が
# 別途必要になる。
#
# 【前提 (Terraform 実行前に手動で 1 回)】
#   terraform apply を実行する IAM プリンシパル (SSO ロール) を Lake Formation の
#   データレイク管理者に登録しておくこと。未登録だと plan 段階の GetDatabase で
#   "Insufficient Lake Formation permission(s): Required Describe" となり失敗する。
#   また、ここで定義する grant 自体も「LF 管理者 (もしくは grant 権限保有者)」でないと
#   付与できない。SSO ロール ARN (aws-reserved/... パス) は Terraform で組み立てづらいため、
#   管理者登録はコンソール (Lake Formation → Administrative roles and tasks) もしくは
#   CLI (aws lakeformation put-data-lake-settings) で追加するのが安全。
#
# 既存リソース参照 (再宣言しない):
#   - aws_iam_role.firehose_glue / aws_iam_role.firehose_s3tables   (iam_firehose.tf)
#   - aws_glue_catalog_database.iceberg / aws_glue_catalog_table.iceberg_errors (glue.tf)
#   - aws_s3tables_namespace.iceberg / aws_s3tables_table.error_logs (s3tables.tf)
#   - local.s3tables_bucket_name                                     (s3tables.tf)
#   - data.aws_caller_identity.current                               (s3.tf)
# -----------------------------------------------------------------------------

# =============================================================================
# 1. glue-iceberg 配信ロール — セルフマネージド Glue Iceberg テーブルへの grant
# =============================================================================
# Firehose の Iceberg 配信はテーブルメタデータの読み取り (DESCRIBE/SELECT) と
# データ書き込み・スナップショットコミット (INSERT/ALTER) を行う。ハンズオンでは
# 取り回しを優先し ALL (SUPER 相当) を付与する。最小権限にするなら
# database = ["DESCRIBE"], table = ["DESCRIBE","SELECT","INSERT","ALTER"] に絞る。
resource "aws_lakeformation_permissions" "firehose_glue_database" {
  principal   = aws_iam_role.firehose_glue.arn
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.iceberg.name
  }
}

resource "aws_lakeformation_permissions" "firehose_glue_table" {
  principal   = aws_iam_role.firehose_glue.arn
  permissions = ["ALL"]

  table {
    database_name = aws_glue_catalog_database.iceberg.name
    name          = aws_glue_catalog_table.iceberg_errors.name
  }
}

# =============================================================================
# 2. s3tables-iceberg 配信ロール — S3 Tables (federated カタログ) への grant
# =============================================================================
# 注意: S3 Tables は s3tablescatalog 配下のサブカタログ (テーブルバケット単位) として
# Glue に現れ、LF リソースの CatalogId は "<account_id>:s3tablescatalog/<bucket>" 形式に
# なる。しかし provider v5.100.0 の aws_lakeformation_permissions は catalog_id を
# 「12桁のアカウントIDのみ」に制限しており、この federated 形式を受け付けない。
# そのため S3 Tables 側の grant は Terraform では定義できず、CLI で付与する。
#
# 付与コマンド (テーブルバケット/namespace/table 作成後に実行):
#   ROLE=arn:aws:iam::<account>:role/${local.prefix}-firehose-s3tables-iceberg
#   CAT=<account>:s3tablescatalog/${local.s3tables_bucket_name}
#
#   aws lakeformation grant-permissions --region <region> \
#     --principal DataLakePrincipalIdentifier=$ROLE \
#     --permissions DESCRIBE \
#     --resource "{\"Database\":{\"CatalogId\":\"$CAT\",\"Name\":\"<namespace>\"}}"
#
#   aws lakeformation grant-permissions --region <region> \
#     --principal DataLakePrincipalIdentifier=$ROLE \
#     --permissions ALL \
#     --resource "{\"Table\":{\"CatalogId\":\"$CAT\",\"DatabaseName\":\"<namespace>\",\"Name\":\"error_logs\"}}"

# =============================================================================
# 3. Athena クエリ用ロール — Glue セルフマネージド Iceberg テーブルへの SELECT 付与
# =============================================================================
# Lake Formation 完全管理モード (CreateTableDefaultPermissions が空) では、Data Lake
# 管理者であってもテーブルデータへの SELECT は自動付与されない。この状態で Athena から
# 検索すると "COLUMN_NOT_FOUND: Relation contains no accessible columns" となる
# (全列が SELECT 実効権限不足でフィルタされる症状)。
#
# クエリを実行するロール ARN を var.athena_query_role_arns に渡すと、当該ロールへ
# database の DESCRIBE と table の SELECT/DESCRIBE を付与する。未指定 (既定 []) の
# 場合は何も作成しない (Lake Formation 無効アカウントや手動付与運用と両立)。
#
# 注意: SSO ロール ARN は aws-reserved/... パスで環境依存のため変数化する。実体 ARN は
#   aws iam list-roles --query "Roles[?contains(RoleName,'AWSReservedSSO_AWSAdministratorAccess')].Arn"
# などで取得できる。S3 Tables 側 (federated カタログ) の付与は provider 制約により
# Terraform では扱えないため、引き続き README の CLI 手順を参照すること。
variable "athena_query_role_arns" {
  description = <<-EOT
    Athena で Glue Iceberg テーブル (otel_log_pipeline_dev_logs.errors) を検索する
    IAM/SSO ロール ARN のリスト。指定したロールへ Lake Formation の SELECT/DESCRIBE を
    付与する。空 (既定) の場合は付与しない。
  EOT
  type        = list(string)
  default     = []
}

resource "aws_lakeformation_permissions" "athena_query_database" {
  for_each = toset(var.athena_query_role_arns)

  principal   = each.value
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.iceberg.name
  }
}

resource "aws_lakeformation_permissions" "athena_query_table" {
  for_each = toset(var.athena_query_role_arns)

  principal   = each.value
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.iceberg.name
    name          = aws_glue_catalog_table.iceberg_errors.name
  }
}

