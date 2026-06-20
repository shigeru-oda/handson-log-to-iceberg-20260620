# -----------------------------------------------------------------------------
# ECS サービス (Fargate, desiredCount = 1) — task 17.3
# Req 2.1, 2.4
# -----------------------------------------------------------------------------
# Log_Generator タスクを Fargate 上で常駐稼働させる ECS サービスを定義する。
#
# 設計書 (design.md / 「2. ECS タスク定義 / サービス」) のとおり:
#   - launch_type  = "FARGATE"  (Req 2.1: Fargate 常駐)
#   - desired_count = 1          (Req 2.4: 常に 1 タスクを維持)
#   - network_configuration によりパブリックサブネット / SG を紐付け、
#     パブリック IP を割り当てて Firehose / CloudWatch Logs / ECR へ到達する。
#
# 自己修復 (Req 2.4):
#   ECS サービスは desired_count を常に満たすよう動作するため、タスクが異常終了
#   した場合でもスケジューラが自動的に新しいタスクを起動して 1 タスクを維持する。
#   追加のオーケストレーション設定は不要だが、ローリング更新時の挙動を明示するため
#   deployment 関連の設定も指定する。
#
# 既存リソース参照 (再宣言しない):
#   - aws_ecs_cluster.this                       (ecs_cluster.tf)
#   - aws_ecs_task_definition.app                (ecs_task_definition.tf)
#   - aws_subnet.public                          (network.tf)
#   - aws_security_group.fargate                 (network.tf)
#   - local.prefix / local.common_tags          (locals.tf)
# -----------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = "${local.prefix}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn

  # Req 2.1 / 2.4: Fargate 上で常に 1 タスクを維持する
  launch_type   = "FARGATE"
  desired_count = 1

  # ローリング更新時もサービス継続性を保つための配置設定。
  # 100% を下回らないよう min_healthy_percent を 100、新旧重複を許容するため
  # max_percent を 200 とする (タスク異常終了時の自己修復にも寄与)。
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # awsvpc ネットワークモードのタスクをパブリックサブネットに配置する。
  # assign_public_ip = true により NAT なしで AWS サービス (Firehose /
  # CloudWatch Logs / ECR) へ到達可能にする。
  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-service"
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "ecs_service_id" {
  description = "ECS サービス ID (ARN)"
  value       = aws_ecs_service.this.id
}

output "ecs_service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.this.name
}
