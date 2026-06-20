# -----------------------------------------------------------------------------
# CloudWatch Logs - エラーログ用ロググループ
# -----------------------------------------------------------------------------
# Requirement 4.1: FireLens_Router が Error_Log を受け取ったとき CloudWatch Logs
# へ配信する。Fluent Bit (custom.conf) / ECS タスク定義 (16.1, 17.2) から
# 出力 (cloudwatch_logs_group_name) を介して参照される。

resource "aws_cloudwatch_log_group" "errors" {
  name              = "/ecs/${local.prefix}/errors"
  retention_in_days = 14

  tags = local.common_tags
}

output "cloudwatch_logs_group_name" {
  description = "エラーログ配信先の CloudWatch Logs ロググループ名 (Fluent Bit / ECS から参照)"
  value       = aws_cloudwatch_log_group.errors.name
}
