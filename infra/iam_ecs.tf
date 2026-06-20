# -----------------------------------------------------------------------------
# IAM Roles for ECS (Task 14.1)
# -----------------------------------------------------------------------------
# 本ファイルでは ECS タスクが利用する 2 種類の IAM ロールを定義する。
#   1. タスク実行ロール (ecs_task_execution) — Req 3.4
#      ECR からのイメージ取得、起動時の CloudWatch Logs 出力に使用される。
#      ECS エージェント (Fargate プラットフォーム) が assume する。
#   2. タスクロール (ecs_task) — Req 3.4, 4.1
#      アプリ / FireLens サイドカーが実行時に利用する権限。
#      Firehose 配信ストリーム (3 本) への PutRecordBatch と、
#      エラーログ用 CloudWatch Logs 出力権限を持つ。
#
# 注意:
#   - data.aws_caller_identity.current / data.aws_region.current は s3.tf で
#     既に宣言済みのため、本ファイルでは再宣言せず参照のみ行う。
#   - Firehose 配信ストリーム (task 15.x) の Terraform リソースはまだ存在しない
#     可能性があるため、クロスファイル依存の競合を避ける目的で、ストリーム名から
#     ARN を組み立ててスコープする (resource 参照ではなく文字列構築)。
# -----------------------------------------------------------------------------

locals {
  # Firehose 配信ストリーム名 (task 15.x がこの命名に整合させること)。
  # 15.1: full-logs (→ S3), 15.2: s3tables-iceberg, 15.3: glue-iceberg
  firehose_stream_names = {
    full_logs = "${local.prefix}-full-logs"
    s3tables  = "${local.prefix}-s3tables-iceberg"
    glue      = "${local.prefix}-glue-iceberg"
  }

  # 上記ストリーム名から組み立てた配信ストリーム ARN 一覧。
  # task 15.x のリソース化前でも参照できるよう、アカウント ID / リージョンと
  # 既知のストリーム名から文字列で構築する。
  firehose_stream_arns = [
    for name in values(local.firehose_stream_names) :
    "arn:aws:firehose:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:deliverystream/${name}"
  ]
}

# -----------------------------------------------------------------------------
# 共通: assume-role ポリシードキュメント (ecs-tasks.amazonaws.com)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# -----------------------------------------------------------------------------
# 1. タスク実行ロール (ECR 取得 + 起動時ログ) — Req 3.4
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task_execution" {
  name               = "${local.prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-ecs-task-execution"
  })
}

# AWS マネージドポリシー: ECR pull / CloudWatch Logs への基本的な書き込み権限
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# 起動時ログ出力を明示的に許可 (logs:CreateLogStream / PutLogEvents)
data "aws_iam_policy_document" "ecs_task_execution_logs" {
  statement {
    sid    = "StartupLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.errors.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_logs" {
  name   = "${local.prefix}-ecs-task-execution-logs"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_execution_logs.json
}

# -----------------------------------------------------------------------------
# 2. タスクロール (Firehose PutRecordBatch + CloudWatch Logs 出力) — Req 3.4, 4.1
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task" {
  name               = "${local.prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-ecs-task"
  })
}

data "aws_iam_policy_document" "ecs_task" {
  # Firehose 配信ストリーム 3 本への PutRecordBatch (Req 4.2, 5.2, 6.3)
  statement {
    sid    = "FirehosePutRecordBatch"
    effect = "Allow"
    actions = [
      "firehose:PutRecordBatch",
      "firehose:PutRecord",
    ]
    resources = local.firehose_stream_arns
  }

  # FireLens (Fluent Bit) のエラーログ出力先 CloudWatch Logs (Req 4.1)
  statement {
    sid    = "CloudWatchLogsOutput"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      aws_cloudwatch_log_group.errors.arn,
      "${aws_cloudwatch_log_group.errors.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${local.prefix}-ecs-task"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task.json
}

# -----------------------------------------------------------------------------
# Outputs — ECS タスク定義 (task 17.2) が参照する
# -----------------------------------------------------------------------------
output "ecs_task_role_arn" {
  description = "ECS タスクロール ARN (アプリ / FireLens 実行時権限)"
  value       = aws_iam_role.ecs_task.arn
}

output "ecs_task_execution_role_arn" {
  description = "ECS タスク実行ロール ARN (ECR 取得 / 起動時ログ)"
  value       = aws_iam_role.ecs_task_execution.arn
}
