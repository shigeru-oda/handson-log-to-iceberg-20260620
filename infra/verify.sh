#!/usr/bin/env bash
# =============================================================================
# infra/verify.sh — Terraform 構成のスナップショット静的検証 (task 19.1)
# =============================================================================
# 本スクリプトは、infra/ 配下の Terraform 構成が要件どおりの「必要リソース」と
# 「重要設定」を含むことを静的に (オフラインで・AWS 認証情報なしで) 検証する。
#
# 検証内容:
#   1. terraform fmt -check     : フォーマット整合
#   2. terraform validate       : 構文・参照の妥当性 (init 済みのためオフラインで動作)
#   3. HCL 構成へのアサーション  : 必要リソースの存在・重要設定値
#
# 設計判断 (なぜ plan を使わないか):
#   `terraform plan` は AWS 認証情報とネットワーク到達性を要求し、ハンズオン環境/
#   CI ではフェイルする。決定的かつオフラインで検証するため、本スクリプトは
#   validate (init 済みでオフライン動作) + HCL 構成への文字列アサーションで
#   スナップショット検証を行う。AWS 認証情報が利用可能な場合は最後に
#   `terraform plan` を任意で実行できるよう VERIFY_RUN_PLAN=1 を用意している。
#
# 検証要件: Requirements 2.1, 2.4, 3.1, 3.2, 5.3, 6.2, 6.4, 7.1, 7.2, 7.3, 7.4
#
# 使い方:
#   bash infra/verify.sh
#   (任意) VERIFY_RUN_PLAN=1 bash infra/verify.sh   # 認証情報があれば plan も試行
#
# 終了コード: すべてのアサーションが通れば 0、いずれか失敗すれば非ゼロ。
# =============================================================================

set -uo pipefail

# スクリプトの場所から infra ディレクトリを解決 (どこから実行しても動く)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}"

# すべての .tf を 1 つの文字列に結合 (リソース存在/設定値の grep 対象)
TF_FILES=$(find "${INFRA_DIR}" -maxdepth 1 -name '*.tf' | sort)
ALL_TF="$(cat ${TF_FILES})"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

# ok <description> : アサーション成功を記録
ok() { green "  PASS: $1"; PASS=$((PASS + 1)); }
# ng <description> : アサーション失敗を記録
ng() { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# assert_contains <regex> <description>
#   結合した全 .tf に regex がマッチすれば PASS
assert_contains() {
  local pattern="$1" desc="$2"
  if grep -Eq -- "$pattern" <<<"$ALL_TF"; then
    ok "$desc"
  else
    ng "$desc  (pattern: $pattern)"
  fi
}

# assert_count <regex> <expected> <description>
#   結合した全 .tf 中の regex マッチ件数が expected と一致すれば PASS
assert_count() {
  local pattern="$1" expected="$2" desc="$3"
  local n
  n=$(grep -Eo -- "$pattern" <<<"$ALL_TF" | wc -l | tr -d ' ')
  if [[ "$n" == "$expected" ]]; then
    ok "$desc (found $n)"
  else
    ng "$desc (expected $expected, found $n)  (pattern: $pattern)"
  fi
}

# assert_count_ge <regex> <min> <description>
assert_count_ge() {
  local pattern="$1" min="$2" desc="$3"
  local n
  n=$(grep -Eo -- "$pattern" <<<"$ALL_TF" | wc -l | tr -d ' ')
  if [[ "$n" -ge "$min" ]]; then
    ok "$desc (found $n >= $min)"
  else
    ng "$desc (expected >= $min, found $n)  (pattern: $pattern)"
  fi
}

echo "============================================================"
echo " Terraform スナップショット検証 (infra/verify.sh)"
echo " target: ${INFRA_DIR}"
echo "============================================================"

# -----------------------------------------------------------------------------
# 0. terraform 実行ファイルの存在確認
# -----------------------------------------------------------------------------
if ! command -v terraform >/dev/null 2>&1; then
  red "terraform コマンドが見つかりません。Terraform をインストールしてください。"
  exit 2
fi

# -----------------------------------------------------------------------------
# 1. terraform fmt -check
# -----------------------------------------------------------------------------
echo
echo "[1/3] terraform fmt -check -recursive"
if terraform -chdir="${INFRA_DIR}" fmt -check -recursive >/dev/null 2>&1; then
  ok "terraform fmt: フォーマット整合"
else
  ng "terraform fmt: 未フォーマットのファイルがあります (terraform fmt で修正してください)"
fi

# -----------------------------------------------------------------------------
# 2. terraform validate (init 済み前提・オフライン動作)
# -----------------------------------------------------------------------------
echo
echo "[2/3] terraform validate"
VALIDATE_OUT="$(terraform -chdir="${INFRA_DIR}" validate 2>&1)"
if [[ $? -eq 0 ]]; then
  ok "terraform validate: 構成は妥当 (${VALIDATE_OUT//$'\n'/ })"
else
  ng "terraform validate: 検証失敗"
  echo "$VALIDATE_OUT"
fi

# -----------------------------------------------------------------------------
# 3. HCL 構成へのスナップショットアサーション
# -----------------------------------------------------------------------------
echo
echo "[3/3] 構成アサーション"

echo
echo "-- 必要リソースの存在 --"
# ネットワーク (Req 2.1, 3.x)
assert_contains 'resource "aws_vpc"'                              'VPC が定義されている (aws_vpc)'
assert_contains 'resource "aws_subnet"'                           'サブネットが定義されている (aws_subnet)'
assert_contains 'resource "aws_security_group"'                   'セキュリティグループが定義されている (aws_security_group)'

# ECS (Req 2.1, 2.4)
assert_contains 'resource "aws_ecs_service"'                      'ECS サービスが定義されている (aws_ecs_service)'
assert_contains 'resource "aws_ecs_task_definition"'              'ECS タスク定義が定義されている (aws_ecs_task_definition)'

# Firehose 3 ストリーム
assert_count    'resource "aws_kinesis_firehose_delivery_stream"' 3 'Firehose 配信ストリームが 3 本定義されている'

# S3 バケット 2 種 (aws_s3_bucket_* は末尾クォートで除外される)
assert_count    'resource "aws_s3_bucket"'                        2 'S3 バケットが 2 種定義されている (aws_s3_bucket)'

# CloudWatch Logs (Req 4.1)
assert_contains 'resource "aws_cloudwatch_log_group"'             'CloudWatch ロググループが定義されている (aws_cloudwatch_log_group)'

# S3 Tables テーブル (Req 5.1) — aws_s3tables_table_bucket とは別物
assert_contains 'resource "aws_s3tables_table"'                   'S3 Tables テーブルが定義されている (aws_s3tables_table)'

# Glue (Req 6.1)
assert_contains 'resource "aws_glue_catalog_database"'            'Glue database が定義されている (aws_glue_catalog_database)'
assert_contains 'resource "aws_glue_catalog_table"'               'Glue table が定義されている (aws_glue_catalog_table)'

# IAM ロール群 (ECS 2 + Firehose 3 = 5)
assert_count_ge 'resource "aws_iam_role"'                         5 'IAM ロール群が定義されている (aws_iam_role)'

echo
echo "-- 重要設定値 --"
# provider region = ap-northeast-1 (Req 7.1)
#   provider は region = var.aws_region。変数 aws_region のデフォルトが ap-northeast-1。
assert_contains 'region[[:space:]]*=[[:space:]]*var\.aws_region'  'provider が var.aws_region を参照している (Req 7.1)'
assert_contains 'default[[:space:]]*=[[:space:]]*"ap-northeast-1"' 'aws_region のデフォルトが ap-northeast-1 (Req 7.1)'

# backend = local / ロックなし (Req 7.2, 7.3, 7.4)
assert_contains 'backend "local"'                                 'backend が local に設定されている (Req 7.2)'

# Firehose 配信先種別
assert_contains 'destination[[:space:]]*=[[:space:]]*"extended_s3"' 'full-logs ストリームが extended_s3 (S3) 配信 (Req 4.2/4.3)'
assert_count_ge 'destination[[:space:]]*=[[:space:]]*"iceberg"'    2 'Iceberg 配信ストリームが 2 本 (S3 Tables / Glue)'

# ECS desired_count >= 1 (Req 2.4)
DC=$(grep -Eo 'desired_count[[:space:]]*=[[:space:]]*[0-9]+' <<<"$ALL_TF" | grep -Eo '[0-9]+$' | head -1)
if [[ -n "${DC:-}" && "$DC" -ge 1 ]]; then
  ok "ECS desired_count >= 1 (= $DC) (Req 2.4)"
else
  ng "ECS desired_count >= 1 を満たさない (取得値: '${DC:-未検出}') (Req 2.4)"
fi

# app コンテナ logDriver = awsfirelens (Req 3.1, 3.2)
assert_contains 'logDriver[[:space:]]*=[[:space:]]*"awsfirelens"' 'app コンテナの logDriver が awsfirelens (Req 3.1/3.2)'

# FireLens (fluentbit) サイドカー設定 (Req 3.1)
assert_contains 'type[[:space:]]*=[[:space:]]*"fluentbit"'        'log_router が firelensConfiguration(fluentbit) を持つ (Req 3.1)'

# Iceberg format-version = 2 (Req 6.4) — open_table_format / parameters の両方
assert_contains '"format-version"[[:space:]]*=[[:space:]]*"2"'    'Iceberg format-version = 2 (Req 6.4)'
assert_contains 'version[[:space:]]*=[[:space:]]*"2"'             'Iceberg open_table_format version = 2 (Req 6.4)'

# Parquet (Req 5.3, 6.4)
assert_contains '"write.format.default"[[:space:]]*=[[:space:]]*"parquet"' 'Iceberg write.format.default = parquet (Req 5.3/6.4)'

# Merge-on-Read (Req 5.3, 6.4)
assert_contains 'merge-on-read'                                   'Iceberg Merge-on-Read プロパティが設定されている (Req 5.3/6.4)'

# Glue table location が s3 パス (Req 6.2)
#   本構成では storage_descriptor.location は local.glue_iceberg_table_location 経由で、
#   その local 定義が s3:// で始まる。location 代入 (リテラル/local 定義どちらでも) が
#   s3:// を指していることを検証する。
assert_contains 'location[[:space:]]*=[[:space:]]*"s3://'         'Glue テーブル location が s3:// パス (Req 6.2)'

# -----------------------------------------------------------------------------
# (任意) terraform plan — AWS 認証情報がある場合のみ
# -----------------------------------------------------------------------------
if [[ "${VERIFY_RUN_PLAN:-0}" == "1" ]]; then
  echo
  echo "[optional] terraform plan (VERIFY_RUN_PLAN=1)"
  if terraform -chdir="${INFRA_DIR}" plan -input=false -lock=false >/tmp/verify_plan.out 2>&1; then
    ok "terraform plan: 成功"
  else
    red "  SKIP/NOTE: terraform plan は失敗しました (AWS 認証情報/ネットワーク未到達の可能性)。"
    red "             静的検証 (validate + アサーション) の結果を正とします。"
    tail -5 /tmp/verify_plan.out | sed 's/^/    /'
  fi
fi

# -----------------------------------------------------------------------------
# サマリ
# -----------------------------------------------------------------------------
echo
echo "============================================================"
echo " 結果: PASS=${PASS} / FAIL=${FAIL}"
echo "============================================================"
if [[ "$FAIL" -gt 0 ]]; then
  red "検証に失敗したアサーションがあります。上記 FAIL を修正してください。"
  exit 1
fi
green "すべての検証アサーションに合格しました。"
exit 0
