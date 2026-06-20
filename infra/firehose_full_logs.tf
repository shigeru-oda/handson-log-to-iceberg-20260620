# -----------------------------------------------------------------------------
# Amazon Data Firehose 配信ストリーム — full-logs (→ S3) — Req 4.2, 4.3
# -----------------------------------------------------------------------------
# 本ファイルでは、全 OTel ログ (severity による絞り込みなし) を full-logs S3
# バケットの raw プレフィックスへ配信する Firehose 配信ストリームを定義する。
#
# 設計書 (design.md / 「4. Amazon Data Firehose 配信ストリーム」「S3 全ログ格納
# モデル」) のとおり:
#   - 配信先          : extended_s3 (aws_s3_bucket.full_logs)
#   - 内容            : 全 severity を無加工で格納 (絞り込みなし) — Req 4.3
#   - プレフィックス  : raw/YYYY/MM/DD/HH/ (時刻ベース)
#   - エラー退避先    : errors/<error-output-type>/ (バックアップ/エラー出力)
#
# 既存リソース参照 (再宣言しない):
#   - aws_iam_role.firehose_full_logs (iam_firehose.tf)
#   - aws_s3_bucket.full_logs         (s3.tf)
#   - local.firehose_stream_names.full_logs (iam_ecs.tf)
#   - local.common_tags               (locals.tf)
#
# ストリーム名は IAM タスクロール (iam_ecs.tf) が参照する命名と一致させるため、
# local.firehose_stream_names.full_logs ("${local.prefix}-full-logs") を用いる。
# -----------------------------------------------------------------------------

resource "aws_kinesis_firehose_delivery_stream" "full_logs" {
  name        = local.firehose_stream_names.full_logs
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_full_logs.arn
    bucket_arn = aws_s3_bucket.full_logs.arn

    # 時刻ベースの動的プレフィックス (UTC)。全ログを raw/ 配下へ蓄積する。
    prefix = "raw/!{timestamp:yyyy/MM/dd/HH}/"

    # 配信失敗レコード (エラー出力) の退避先プレフィックス。
    error_output_prefix = "errors/!{firehose:error-output-type}/"

    # バッファリング設定 (シンプルかつ有効な値)。
    buffering_size     = 5
    buffering_interval = 300

    # 圧縮 (S3 蓄積コスト削減)。全ログを無加工 (絞り込みなし) で格納する。
    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled = false
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "firehose_full_logs_stream_name" {
  description = "full-logs Firehose 配信ストリーム名 (→ S3)"
  value       = aws_kinesis_firehose_delivery_stream.full_logs.name
}

output "firehose_full_logs_stream_arn" {
  description = "full-logs Firehose 配信ストリームの ARN"
  value       = aws_kinesis_firehose_delivery_stream.full_logs.arn
}
