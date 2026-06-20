# -----------------------------------------------------------------------------
# Network (VPC / Subnets / Internet Gateway / Security Group)
# -----------------------------------------------------------------------------
# Fargate タスクが Firehose / CloudWatch Logs / ECR へ到達できるように、
# パブリックサブネット + インターネットゲートウェイ + パブリック IP 自動割当で構成する。
# (本ハンズオンでは NAT Gateway を使わず、最もシンプルなパブリックサブネット方式を採用)
#
# サブネットはマルチ AZ (ap-northeast-1a / ap-northeast-1c) に配置する。
# セキュリティグループはインバウンド不要 (公開ポートなし)、アウトバウンドは 443 (HTTPS) のみ許可。
# -----------------------------------------------------------------------------

locals {
  # VPC / サブネットの CIDR 設計
  vpc_cidr = "10.0.0.0/16"

  # マルチ AZ パブリックサブネット (AZ 名はリージョン変数から導出)
  public_subnets = {
    a = {
      cidr = "10.0.1.0/24"
      az   = "${var.aws_region}a"
    }
    c = {
      cidr = "10.0.2.0/24"
      az   = "${var.aws_region}c"
    }
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-igw"
  })
}

# -----------------------------------------------------------------------------
# Public Subnets (multi-AZ)
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-public-${each.key}"
  })
}

# -----------------------------------------------------------------------------
# Public Route Table (-> Internet Gateway)
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security Group (Fargate tasks)
# -----------------------------------------------------------------------------
# インバウンド: 不要 (常駐バッチ的な構成のため公開ポートなし)
# アウトバウンド: 443 (HTTPS) のみ許可 -> Firehose / CloudWatch Logs / ECR へ到達
# -----------------------------------------------------------------------------
resource "aws_security_group" "fargate" {
  name        = "${local.prefix}-fargate-sg"
  description = "Security group for Fargate tasks (egress HTTPS only)"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-fargate-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.fargate.id
  description       = "Allow outbound HTTPS to AWS services (Firehose / CloudWatch / ECR)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# Outputs (consumed by ECS service - task 17.3)
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID 一覧 (マルチ AZ)"
  value       = [for s in aws_subnet.public : s.id]
}

output "fargate_security_group_id" {
  description = "Fargate タスク用セキュリティグループ ID"
  value       = aws_security_group.fargate.id
}
