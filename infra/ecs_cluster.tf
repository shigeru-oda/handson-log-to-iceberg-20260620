# -----------------------------------------------------------------------------
# ECS Cluster (Fargate)
# -----------------------------------------------------------------------------
# Log_Generator を常駐サービスとして稼働させるための Fargate 用 ECS クラスタ。
# キャパシティプロバイダとして FARGATE / FARGATE_SPOT を関連付ける。
# (タスク定義・サービスは task 17.2 / 17.3 で別ファイルに定義する)
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${local.prefix}-cluster"

  # Container Insights は本ハンズオンでは無効 (コスト抑制)
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-cluster"
  })
}

# -----------------------------------------------------------------------------
# Capacity Providers (Fargate)
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}

# -----------------------------------------------------------------------------
# Outputs (ECS サービス定義 task 17.3 で参照)
# -----------------------------------------------------------------------------
output "ecs_cluster_id" {
  description = "ECS クラスタ ID"
  value       = aws_ecs_cluster.this.id
}

output "ecs_cluster_arn" {
  description = "ECS クラスタ ARN"
  value       = aws_ecs_cluster.this.arn
}

output "ecs_cluster_name" {
  description = "ECS クラスタ名"
  value       = aws_ecs_cluster.this.name
}
