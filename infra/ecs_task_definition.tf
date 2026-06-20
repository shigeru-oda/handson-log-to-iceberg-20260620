# -----------------------------------------------------------------------------
# ECS タスク定義 (app + FireLens Fluent Bit サイドカー) — task 17.2
# Req 2.3, 3.1, 3.2, 3.4
# -----------------------------------------------------------------------------
# 本ファイルでは、Log_Generator (app) コンテナと FireLens (Fluent Bit) ログ
# ルーターサイドカー (log_router) から成る ECS Fargate タスク定義を定義する。
#
# 設計書 (design.md / 「2. ECS タスク定義 / サービス」「3. FireLens_Router」) のとおり:
#   - app コンテナ        : logDriver = "awsfirelens" で stdout を FireLens へ流す (Req 3.2)
#                            環境変数 LOG_INTERVAL_MS を注入 (Req 2.3)
#   - log_router コンテナ : aws-for-fluent-bit イメージ + firelensConfiguration
#                            (type = fluentbit, config-file-value = /fluent-bit/etc/custom.conf)
#                            (Req 3.1, 3.4)
#                            custom.conf が参照する配信先名を環境変数で注入:
#                              FULL_LOGS_STREAM / ERROR_LOG_GROUP /
#                              S3TABLES_ICEBERG_STREAM / GLUE_ICEBERG_STREAM
#
# 既存リソース参照 (再宣言しない):
#   - aws_iam_role.ecs_task / aws_iam_role.ecs_task_execution        (iam_ecs.tf)
#   - aws_kinesis_firehose_delivery_stream.full_logs                 (firehose_full_logs.tf)
#   - aws_kinesis_firehose_delivery_stream.s3tables_iceberg          (firehose_s3tables.tf)
#   - aws_kinesis_firehose_delivery_stream.glue_iceberg              (firehose_glue.tf)
#   - aws_cloudwatch_log_group.errors                                (cloudwatch.tf)
#   - local.prefix / local.common_tags                              (locals.tf)
#   - var.aws_region                                                 (variables.tf)
#
# 注意 (Fluent Bit custom.conf の配置について):
#   firelensConfiguration の config-file-value = "/fluent-bit/etc/custom.conf" は、
#   本リポジトリの fluent-bit/custom.conf (task 16.1) を log_router イメージに
#   ベイクするか、ボリュームでマウントすることを前提とする。本ハンズオンでは
#   aws-for-fluent-bit ベースイメージに custom.conf を COPY したカスタムイメージを
#   var.fluent_bit_image に指定して利用すること (パスは上記固定値を期待する)。
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 変数宣言
# (variables.tf への同時編集による競合を避けるため、本タスクで追加する変数は
#  このファイル内で宣言する)
# -----------------------------------------------------------------------------
variable "log_interval_ms" {
  description = "Log_Generator のログ出力間隔 (ミリ秒)。app コンテナへ LOG_INTERVAL_MS として注入される (Req 2.3)。"
  type        = string
  default     = "1000"
}

variable "app_image" {
  description = "Log_Generator (app) コンテナイメージ。ECR のイメージ URI もしくはタグを指定する。"
  type        = string
  default     = "log-generator:latest"
}

variable "fluent_bit_image" {
  description = "FireLens (Fluent Bit) サイドカーのコンテナイメージ。custom.conf をベイクしたカスタムイメージの利用を推奨。"
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-for-fluent-bit:stable"
}

# -----------------------------------------------------------------------------
# ECS Fargate タスク定義
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  task_role_arn      = aws_iam_role.ecs_task.arn
  execution_role_arn = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    # -------------------------------------------------------------------------
    # 1) app コンテナ (Log_Generator)
    #    logDriver = awsfirelens により stdout を log_router (FireLens) へ転送する。
    # -------------------------------------------------------------------------
    {
      name      = "app"
      image     = var.app_image
      essential = true

      environment = [
        {
          name  = "LOG_INTERVAL_MS"
          value = var.log_interval_ms
        },
      ]

      # Req 3.2: アプリの stdout を FireLens 経由でルーティングする
      logConfiguration = {
        logDriver = "awsfirelens"
      }
    },

    # -------------------------------------------------------------------------
    # 2) log_router コンテナ (FireLens / Fluent Bit サイドカー)
    #    custom.conf (config-file-value) に従い severity ベースのルーティングを行う。
    #    custom.conf が参照する配信先名/ロググループ名を環境変数で注入する。
    # -------------------------------------------------------------------------
    {
      name      = "log_router"
      image     = var.fluent_bit_image
      essential = true

      firelensConfiguration = {
        type = "fluentbit"
        options = {
          "config-file-type"  = "file"
          "config-file-value" = "/fluent-bit/etc/custom.conf"
        }
      }

      # custom.conf が ${...} で参照する配信先を注入 (Req 3.4, 4.1, 4.2, 5.2, 6.3)
      environment = [
        {
          name  = "FULL_LOGS_STREAM"
          value = aws_kinesis_firehose_delivery_stream.full_logs.name
        },
        {
          name  = "ERROR_LOG_GROUP"
          value = aws_cloudwatch_log_group.errors.name
        },
        {
          name  = "S3TABLES_ICEBERG_STREAM"
          value = aws_kinesis_firehose_delivery_stream.s3tables_iceberg.name
        },
        {
          name  = "GLUE_ICEBERG_STREAM"
          value = aws_kinesis_firehose_delivery_stream.glue_iceberg.name
        },
      ]

      # log_router 自身の診断ログ。既存のエラーログ用ロググループを流用し、
      # firelens プレフィックスでストリームを分離する (タスク実行ロールの
      # ログ出力権限が errors ロググループに限定されているため再利用が安全)。
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.errors.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "firelens"
        }
      }
    },
  ])

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-app"
  })
}

# -----------------------------------------------------------------------------
# Outputs — ECS サービス定義 (task 17.3) が参照する
# -----------------------------------------------------------------------------
output "ecs_task_definition_arn" {
  description = "ECS タスク定義の ARN (リビジョン込み)"
  value       = aws_ecs_task_definition.app.arn
}

output "ecs_task_definition_family" {
  description = "ECS タスク定義のファミリー名"
  value       = aws_ecs_task_definition.app.family
}
