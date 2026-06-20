# -----------------------------------------------------------------------------
# Common Variables
# -----------------------------------------------------------------------------

variable "project" {
  description = "プロジェクト名プレフィックス (リソース命名に使用)"
  type        = string
  default     = "otel-log-pipeline"
}

variable "environment" {
  description = "環境名 (dev / stg / prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}
