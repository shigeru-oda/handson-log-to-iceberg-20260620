# -----------------------------------------------------------------------------
# Common Locals - リソース命名規則
# -----------------------------------------------------------------------------

locals {
  # 共通プレフィックス: {project}-{environment}
  prefix = "${var.project}-${var.environment}"

  # 共通タグ
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
