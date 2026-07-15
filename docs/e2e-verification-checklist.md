# 手動 E2E 検証チェックリスト

Spec: `ecs-otel-log-pipeline` / Task 19.2
関連要件: 4.1, 4.2, 4.3, 5.2, 6.3

本書は、Terraform でインフラをデプロイし、Amazon Elastic Container Service (Amazon ECS) Fargate 上の Log_Generator を一定時間
稼働させた後に、ログパイプラインが要件どおり機能していることを **手動で** 確認する
ための End-to-End (E2E) チェックリストである。各項目にはチェックボックス (`[ ]`)、
実行する具体的コマンド、および **期待結果** を記載する。

検証で確認する 3 つの最終状態:

1. **Amazon Simple Storage Service (Amazon S3) (full-logs バケット)** に **全 severity (TRACE〜FATAL)** のログが蓄積される (Req 4.2, 4.3)。
2. **Amazon CloudWatch Logs (errors ロググループ)** には **ERROR / FATAL のみ** が現れる (Req 4.1)。
3. **Amazon S3 Tables Iceberg テーブル** と **AWS Glue Iceberg テーブル** を Amazon Athena でクエリすると、
   行として存在するのは **エラーログ (severity_number >= 17) のみ** である (Req 5.2, 6.3)。

---

## 0. 前提と環境変数

リージョンは **ap-northeast-1 (東京)** 固定。リソース名は Terraform の `local.prefix`
(= `${var.project}-${var.environment}` = **`otel-log-pipeline-dev`**) から導出される。
実際の値は `terraform output` で確認すること (以下のコマンドはプレースホルダを使用)。

```bash
# infra/ ディレクトリで Terraform output から実値を取得して環境変数へ設定する
cd infra

export AWS_REGION=ap-northeast-1
export PREFIX="otel-log-pipeline-dev"

# Amazon S3 / Amazon CloudWatch / Amazon Data Firehose / Iceberg のリソース名 (terraform output 由来)
export FULL_LOGS_BUCKET=$(terraform output -raw full_logs_bucket_name)
export GLUE_ICEBERG_BUCKET=$(terraform output -raw glue_iceberg_bucket_name)
export ERROR_LOG_GROUP=$(terraform output -raw cloudwatch_logs_group_name)            # /ecs/otel-log-pipeline-dev/errors

export FULL_LOGS_STREAM=$(terraform output -raw firehose_full_logs_stream_name)        # otel-log-pipeline-dev-full-logs
export S3TABLES_STREAM=$(terraform output -raw firehose_s3tables_iceberg_stream_name)  # otel-log-pipeline-dev-s3tables-iceberg
export GLUE_STREAM=$(terraform output -raw firehose_glue_iceberg_stream_name)          # otel-log-pipeline-dev-glue-iceberg

# Amazon S3 Tables Iceberg (マネージド) のカタログ識別子
export S3TABLES_NAMESPACE=$(terraform output -raw s3tables_namespace)                  # otel_log_pipeline_dev
export S3TABLES_TABLE=$(terraform output -raw s3tables_table_name)                     # error_logs
export S3TABLES_BUCKET_ARN=$(terraform output -raw s3tables_bucket_arn)

# AWS Glue Iceberg (セルフマネージド)
export GLUE_DATABASE=$(terraform output -raw glue_database_name)                       # otel_log_pipeline_dev_logs
export GLUE_TABLE=$(terraform output -raw glue_iceberg_table_name)                     # errors

# Amazon ECS
export ECS_CLUSTER=$(terraform output -raw ecs_cluster_name)                           # otel-log-pipeline-dev-cluster
export ECS_SERVICE=$(terraform output -raw ecs_service_name)                           # otel-log-pipeline-dev-service
```

導出されるリソース名 (参考 / `local.prefix = otel-log-pipeline-dev`):

| 種別 | 名前 (例) |
| --- | --- |
| Amazon S3 full-logs バケット | `otel-log-pipeline-dev-full-logs-<account_id>-ap-northeast-1` |
| Amazon S3 AWS Glue Iceberg データ実体バケット | `otel-log-pipeline-dev-glue-iceberg-<account_id>-ap-northeast-1` |
| Amazon CloudWatch Logs ロググループ | `/ecs/otel-log-pipeline-dev/errors` |
| Amazon Data Firehose full-logs ストリーム | `otel-log-pipeline-dev-full-logs` |
| Amazon Data Firehose s3tables-iceberg ストリーム | `otel-log-pipeline-dev-s3tables-iceberg` |
| Amazon Data Firehose glue-iceberg ストリーム | `otel-log-pipeline-dev-glue-iceberg` |
| Amazon S3 Tables バケット / namespace / table | `otel-log-pipeline-dev-s3tables` / `otel_log_pipeline_dev` / `error_logs` |
| AWS Glue database / table | `otel_log_pipeline_dev_logs` / `errors` |
| Amazon ECS クラスタ / サービス | `otel-log-pipeline-dev-cluster` / `otel-log-pipeline-dev-service` |

- [ ] **0-1. AWS CLI / 認証情報の確認**
  ```bash
  aws sts get-caller-identity
  aws configure get region   # もしくは AWS_REGION=ap-northeast-1 を確認
  ```
  期待結果: 想定アカウント ID が表示され、リージョンが `ap-northeast-1` であること。

---

## 1. デプロイ

### 1-1. アプリイメージのビルドとプッシュ (Amazon ECR)

`infra/ecs_task_definition.tf` の `var.app_image` (デフォルト `log-generator:latest`) に
指定するイメージを Amazon Elastic Container Registry (Amazon ECR) にプッシュする。Amazon ECR リポジトリは本 Terraform では作成していない
ため、未作成なら手動作成する。アプリの Dockerfile は `app/Dockerfile` (Linux/amd64 向け
マルチステージビルド)。

- [ ] **1-1-1. Amazon ECR リポジトリの作成 (初回のみ)**
  ```bash
  export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  export ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.ap-northeast-1.amazonaws.com"

  aws ecr describe-repositories --repository-names log-generator --region ap-northeast-1 \
    || aws ecr create-repository --repository-name log-generator --region ap-northeast-1
  ```
  期待結果: `log-generator` リポジトリが存在する。

- [ ] **1-1-2. ログイン・ビルド・プッシュ (app)**
  ```bash
  aws ecr get-login-password --region ap-northeast-1 \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"

  # app/ をビルドコンテキストとして app/Dockerfile を使用 (Linux/amd64)
  docker build --platform linux/amd64 -t "${ECR_REGISTRY}/log-generator:latest" ./app
  docker push "${ECR_REGISTRY}/log-generator:latest"
  ```
  期待結果: イメージが `${ECR_REGISTRY}/log-generator:latest` としてプッシュされる。

### 1-2. カスタム Fluent Bit イメージのビルドとプッシュ (FireLens)

`infra/ecs_task_definition.tf` の `var.fluent_bit_image` には、`fluent-bit/custom.conf` を
`aws-for-fluent-bit` ベースイメージの `/fluent-bit/etc/custom.conf` にベイクした
カスタムイメージを指定する (タスク定義は `config-file-value=/fluent-bit/etc/custom.conf`
を期待する)。

- [ ] **1-2-1. カスタム Fluent Bit イメージ用 Dockerfile を用意**
  例 (`fluent-bit/Dockerfile`):
  ```dockerfile
  FROM public.ecr.aws/aws-observability/aws-for-fluent-bit:stable
  COPY custom.conf /fluent-bit/etc/custom.conf
  ```

- [ ] **1-2-2. Amazon ECR リポジトリ作成・ビルド・プッシュ (fluent-bit)**
  ```bash
  aws ecr describe-repositories --repository-names custom-fluent-bit --region ap-northeast-1 \
    || aws ecr create-repository --repository-name custom-fluent-bit --region ap-northeast-1

  docker build --platform linux/amd64 -t "${ECR_REGISTRY}/custom-fluent-bit:latest" ./fluent-bit
  docker push "${ECR_REGISTRY}/custom-fluent-bit:latest"
  ```
  期待結果: `custom-fluent-bit:latest` がプッシュされる。

### 1-3. Terraform でインフラをデプロイ

- [ ] **1-3-1. init / validate / plan / apply**
  ```bash
  cd infra
  terraform init
  terraform validate
  terraform plan \
    -var="app_image=${ECR_REGISTRY}/log-generator:latest" \
    -var="fluent_bit_image=${ECR_REGISTRY}/custom-fluent-bit:latest" \
    -var="log_interval_ms=1000"
  terraform apply \
    -var="app_image=${ECR_REGISTRY}/log-generator:latest" \
    -var="fluent_bit_image=${ECR_REGISTRY}/custom-fluent-bit:latest" \
    -var="log_interval_ms=1000"
  ```
  期待結果: `apply` が成功し、Amazon VPC/サブネット/セキュリティグループ、Amazon ECS クラスタ・サービス・タスク定義、
  Amazon Data Firehose 3 ストリーム、Amazon S3 バケット 2 種、Amazon CloudWatch ロググループ、Amazon S3 Tables テーブル、
  AWS Glue database/table、AWS IAM ロール群が作成される。
  > 注意: ローカルステートにはロック機構がない (Req 7.4)。複数人で同時に `apply` しない
  > こと。

- [ ] **1-3-2. Amazon ECS サービスが稼働中であることを確認**
  ```bash
  aws ecs describe-services \
    --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
    --region ap-northeast-1 \
    --query 'services[0].{desired:desiredCount,running:runningCount,status:status}'
  ```
  期待結果: `desired=1`、`running=1`、`status=ACTIVE`。タスクが起動し、`LOG_INTERVAL_MS`
  間隔で OTel ログを出力し続けている状態。

- [ ] **1-3-3. 蓄積待ち**
  Amazon Data Firehose のバッファリング (full-logs は最大 300 秒 / Iceberg は 60〜300 秒) を考慮し、
  **最低 10〜15 分** 程度アプリを稼働させてから以降の検証を行う。

---

## 2. 検証 (1): Amazon S3 full-logs バケットに全 severity が蓄積される

関連要件: **4.2 (全ログを Amazon S3 へ)**, **4.3 (severity による絞り込みなし)**

Amazon Data Firehose `full-logs` ストリームは `raw/!{timestamp:yyyy/MM/dd/HH}/` プレフィックス
(UTC) で GZIP 圧縮された JSON Lines を配信する。

- [ ] **2-1. raw/ プレフィックス配下にオブジェクトが存在する**
  ```bash
  aws s3 ls "s3://${FULL_LOGS_BUCKET}/raw/" --recursive --region ap-northeast-1 | head -50
  # 時刻プレフィックス例 (UTC): raw/2026/06/20/12/
  ```
  期待結果: `raw/YYYY/MM/DD/HH/` 配下に 1 つ以上のオブジェクトが存在する。

- [ ] **2-2. オブジェクトをダウンロードして中身を確認**
  ```bash
  # 最新オブジェクトのキーを 1 つ取得してダウンロード
  KEY=$(aws s3api list-objects-v2 --bucket "$FULL_LOGS_BUCKET" --prefix "raw/" \
        --region ap-northeast-1 --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
  aws s3 cp "s3://${FULL_LOGS_BUCKET}/${KEY}" /tmp/full-logs-sample.gz --region ap-northeast-1
  gunzip -c /tmp/full-logs-sample.gz | head -20
  ```
  期待結果: OTel Log Data Model 形式の JSON Lines (`timestamp` / `severityNumber` /
  `severityText` / `body` / `resource` / `attributes` を含む) が確認できる。

- [ ] **2-3. 全 severity (TRACE〜FATAL) が含まれることを確認**
  ```bash
  # ダウンロードしたサンプル (複数オブジェクトを取得するとより確実) から severityText を集計
  gunzip -c /tmp/full-logs-sample.gz \
    | python3 -c "import sys,json,collections; c=collections.Counter(json.loads(l)['severityText'] for l in sys.stdin if l.strip()); print(dict(c))"
  ```
  期待結果: `TRACE`/`DEBUG`/`INFO`/`WARN`/`ERROR`/`FATAL` のうち複数 (理想的には全て) の
  severity が出現する。**ERROR/FATAL 以外の非エラーログも必ず含まれている** こと
  (= severity で絞り込まれていない / Req 4.3)。サンプルが少なく一部 severity が出ない
  場合は、複数オブジェクトを取得するか稼働時間を延ばして再確認する。

---

## 3. 検証 (2): Amazon CloudWatch Logs (errors) に ERROR/FATAL のみが現れる

関連要件: **4.1 (Error_Log を Amazon CloudWatch Logs へ)**

Fluent Bit は `error.*` タグ (severityNumber >= 17) のレコードのみを `cloudwatch_logs`
出力で `/ecs/otel-log-pipeline-dev/errors` ロググループ (stream prefix `ecs-`) へ配信する。

- [ ] **3-1. ロググループとログストリームの存在を確認**
  ```bash
  aws logs describe-log-streams \
    --log-group-name "$ERROR_LOG_GROUP" \
    --region ap-northeast-1 \
    --order-by LastEventTime --descending \
    --query 'logStreams[].logStreamName'
  ```
  期待結果: `ecs-...` で始まるログストリームが 1 つ以上存在する。

- [ ] **3-2. 直近のログイベントを取得して severity を確認**
  ```bash
  # 過去 1 時間のイベントを取得 (start-time はミリ秒エポック)
  START=$(( ( $(date +%s) - 3600 ) * 1000 ))
  aws logs filter-log-events \
    --log-group-name "$ERROR_LOG_GROUP" \
    --region ap-northeast-1 \
    --start-time "$START" \
    --query 'events[].message' --output text | head -20
  ```
  期待結果: 出力されるレコードは **ERROR または FATAL のみ** (`severityNumber >= 17` /
  `severityText` が `ERROR` または `FATAL`)。

- [ ] **3-3. 非エラーログが存在しないことを確認 (ネガティブ検証)**
  ```bash
  # INFO / WARN / DEBUG / TRACE が CloudWatch に流れていないことを確認
  aws logs filter-log-events \
    --log-group-name "$ERROR_LOG_GROUP" \
    --region ap-northeast-1 \
    --start-time "$START" \
    --filter-pattern '?INFO ?WARN ?DEBUG ?TRACE' \
    --query 'length(events)'
  ```
  期待結果: `0` (非エラーレベルのレコードは Amazon CloudWatch Logs に存在しない)。
  > 補足: `firelens` プレフィックスのストリームには log_router 自身の診断ログが入る
  > 場合がある。アプリログの検証では `ecs-` プレフィックスのストリームを対象とすること。

---

## 4. 検証 (3): Iceberg テーブル (Amazon S3 Tables / AWS Glue) にエラーログのみが存在する

関連要件: **5.2 (Error_Log を Amazon S3 Tables Iceberg へ)**, **6.3 (Error_Log を AWS Glue Iceberg へ)**

Amazon Athena (エンジン v3) でクエリする。事前に Amazon Athena のクエリ結果出力先 Amazon S3 を設定しておく
こと (ワークグループのデフォルト or 下記の `--result-configuration`)。**出力先バケットは
通常の Amazon S3 バケットであること** (アカウントリージョナルネームスペースバケット
`[prefix]-[account]-[region]-an` を出力先にすると、Amazon S3 Tables クエリで
`MissingNamespaceHeader` エラーになる場合がある)。

> **前提: AWS Lake Formation 権限**
> アカウントで AWS Lake Formation が有効な場合、クエリを実行する IAM/IAM Identity Center (SSO) ロールに
> AWS Glue セルフマネージド側・Amazon S3 Tables 側それぞれの AWS Lake Formation `SELECT`/`DESCRIBE`
> 権限が付与されていないと `COLUMN_NOT_FOUND` 等で失敗する。README
> 「ステップ 4」内の **「5) Athena でクエリするロールへ SELECT を付与」**を参照し、
> 検証を実行するロールへ事前に付与しておくこと (AWS Glue 側は `athena_query_role_arns`
> による Terraform 管理も可能。Amazon S3 Tables 側は provider 制約により CLI 付与のみ)。

```bash
# Amazon Athena クエリ結果の出力先 (full-logs バケットを流用)
export ATHENA_OUTPUT="s3://${FULL_LOGS_BUCKET}/athena-results/"

# 簡易ヘルパー: クエリを実行し結果が出るまで待って表示する
run_athena() {
  local sql="$1"; local catalog="${2:-AwsDataCatalog}"; local db="${3:-}"
  local qid
  qid=$(aws athena start-query-execution \
        --region ap-northeast-1 \
        --query-string "$sql" \
        ${catalog:+--query-execution-context Catalog="$catalog"${db:+,Database="$db"}} \
        --result-configuration "OutputLocation=${ATHENA_OUTPUT}" \
        --query QueryExecutionId --output text)
  echo "QueryExecutionId=$qid"
  while :; do
    st=$(aws athena get-query-execution --region ap-northeast-1 --query-execution-id "$qid" \
         --query 'QueryExecution.Status.State' --output text)
    [ "$st" = "SUCCEEDED" -o "$st" = "FAILED" -o "$st" = "CANCELLED" ] && break
    sleep 2
  done
  echo "State=$st"
  aws athena get-query-results --region ap-northeast-1 --query-execution-id "$qid" \
    --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
}
```

### 4-A. AWS Glue Iceberg テーブル (セルフマネージド)

データベース `otel_log_pipeline_dev_logs` / テーブル `errors` (`AwsDataCatalog`)。

- [ ] **4-A-1. 行数とエラーのみ条件を確認**
  ```bash
  run_athena "SELECT count(*) AS total,
                     count_if(severity_number >= 17) AS error_rows,
                     count_if(severity_number < 17) AS non_error_rows
              FROM \"${GLUE_DATABASE}\".\"${GLUE_TABLE}\";"
  ```
  期待結果: `total > 0` かつ `error_rows = total` かつ `non_error_rows = 0`
  (= エラーログのみが行として存在)。

- [ ] **4-A-2. severity 分布を確認**
  ```bash
  run_athena "SELECT severity_text, severity_number, count(*) AS cnt
              FROM \"${GLUE_DATABASE}\".\"${GLUE_TABLE}\"
              GROUP BY severity_text, severity_number
              ORDER BY severity_number;"
  ```
  期待結果: `ERROR` (17) と `FATAL` (21) のみが現れる。`INFO`/`WARN` 等は出現しない。

- [ ] **4-A-3. サンプル行とネスト列 (JSON 文字列カラム) を確認**
  ```bash
  run_athena "SELECT event_time, severity_text, body, resource_json, attributes_json
              FROM \"${GLUE_DATABASE}\".\"${GLUE_TABLE}\"
              ORDER BY event_time DESC LIMIT 5;"
  ```
  期待結果: `resource_json` / `attributes_json` が JSON 文字列として保持され、
  カラム名はすべて小文字 (`event_time`, `severity_number`, `severity_text`, `body`,
  `resource_json`, `attributes_json`, `ingest_date`)。

### 4-B. Amazon S3 Tables Iceberg テーブル (マネージド)

Amazon S3 Tables は AWS Glue Data Catalog 上の **federated カタログ `s3tablescatalog/<テーブルバケット名>`**
として現れるが、Amazon Athena のデータカタログ一覧 (`list-data-catalogs`) には独立したカタログとして
登録されない。実体は常に **`AwsDataCatalog` 配下のサブカタログ**として扱われるため、SQL 上は
**`"<catalog>"."<namespace>"."<table>"` の 3 階層パス**で参照する必要がある。

> **重要 (要件と実際の挙動の違い)**
> Amazon Athena クエリエディタで「データソース」に `s3tablescatalog/otel-log-pipeline-dev-s3tables`、
> 「データベース」に `otel_log_pipeline_dev` を選んで `FROM "error_logs"` のように 1 階層で
> 実行すると、クエリ結果の出力先バケットとの組み合わせによっては
> `MissingNamespaceHeader: ... x-amz-bucket-namespace header` のような Amazon S3 側エラーになる場合が
> ある (特にクエリ結果出力先が「アカウントリージョナルネームスペース」バケット
> `[prefix]-[account]-[region]-an` の場合)。**カタログは `AwsDataCatalog` に統一し、3 階層パス
> で FROM 句にカタログ名を含める**方法が確実。
>
> 事前準備: Amazon Data Firehose 配信ロールおよび検証で使うロールに、Amazon S3 Tables 側 (federated カタログ) の
> AWS Lake Formation 権限が付与済みであること (README 「Lake Formation 権限の事前付与」手順
> 3・5 参照)。また Amazon Athena のワークグループのクエリ結果出力先が通常の (account regional
> namespace ではない) Amazon S3 バケットであること。

```bash
# Amazon S3 Tables への 3 階層パス参照 (CLI からも同様に使う)
export S3TABLES_TABLE_PATH="\"s3tablescatalog/${S3TABLES_BUCKET}\".\"${S3TABLES_NAMESPACE}\".\"${S3TABLES_TABLE}\""
```

- [ ] **4-B-1. 行数とエラーのみ条件を確認**
  ```bash
  run_athena "SELECT count(*) AS total,
                     count_if(severity_number >= 17) AS error_rows,
                     count_if(severity_number < 17) AS non_error_rows
              FROM ${S3TABLES_TABLE_PATH};" "AwsDataCatalog"
  ```
  コンソールで実行する場合は、データソース/データベースの選択に関わらず、クエリの
  `FROM` 句に必ずカタログ名を含めた 3 階層パスを書く:
  ```sql
  SELECT count(*) AS total,
         count_if(severity_number >= 17) AS error_rows,
         count_if(severity_number < 17) AS non_error_rows
  FROM "s3tablescatalog/otel-log-pipeline-dev-s3tables"."otel_log_pipeline_dev"."error_logs";
  ```
  期待結果: `total > 0` かつ `error_rows = total` かつ `non_error_rows = 0`。

- [ ] **4-B-2. severity 分布を確認**
  ```sql
  SELECT severity_text, severity_number, count(*) AS cnt
  FROM "s3tablescatalog/otel-log-pipeline-dev-s3tables"."otel_log_pipeline_dev"."error_logs"
  GROUP BY severity_text, severity_number
  ORDER BY severity_number;
  ```
  期待結果: `ERROR` (17) と `FATAL` (21) のみ。非エラーログは存在しない。

- [ ] **4-B-3. AWS Glue 側との整合 (両ターゲット等価性) を確認**
  期待結果: Amazon S3 Tables Iceberg と AWS Glue Iceberg の両テーブルで、エラーログのみが行として
  存在し、カラム構成 (小文字スキーマ) と severity 分布が論理的に一致する (Req 5.x/6.x の
  両方式比較)。

---

## 5. 総合判定

- [ ] **5-1.** Amazon S3 full-logs に全 severity が蓄積されている (検証 1 / Req 4.2, 4.3)。
- [ ] **5-2.** Amazon CloudWatch Logs (errors) に ERROR/FATAL のみが現れる (検証 2 / Req 4.1)。
- [ ] **5-3.** Amazon S3 Tables Iceberg テーブルにエラーログのみが行として存在する (検証 3 / Req 5.2)。
- [ ] **5-4.** AWS Glue Iceberg テーブルにエラーログのみが行として存在する (検証 3 / Req 6.3)。

すべてチェックできれば、ステージ 1 (Amazon S3 / Amazon CloudWatch) とステージ 2 (Amazon S3 Tables / AWS Glue
Iceberg) のルーティングと蓄積が要件どおり機能していることを確認できたことになる。

---

## 6. トラブルシューティングの観点

- **Amazon S3 / Amazon CloudWatch / Iceberg にデータが出ない**: Amazon Data Firehose バッファリング待ち時間が
  経過しているか、Amazon ECS タスクが `RUNNING` か、タスクロールに `firehose:PutRecordBatch` /
  Amazon CloudWatch Logs 権限があるかを確認する。
- **Iceberg テーブルにデータが出ない / 配信失敗**: Amazon Data Firehose の配信失敗レコードは
  バックアップ Amazon S3 (`firehose-s3tables-iceberg-errors/` や glue-iceberg バケットの
  `errors/`) に退避される。レコードのキー名が小文字カラムスキーマ
  (`event_time` 等) と一致しているか (スキーママッピング) を確認する。
- **Amazon CloudWatch に非エラーが混入**: Fluent Bit の `rewrite_tag` ルール
  (`$severityNumber ^(1[7-9]|2[0-4])$`) と各 OUTPUT の `Match` を確認する。
- **後片付け**: 検証完了後は `terraform destroy` で課金リソース (Amazon Data Firehose / Amazon ECS / Amazon S3 Tables
  等) を削除する。Amazon S3 バケットにオブジェクトが残っていると destroy が失敗するため、
  必要に応じて中身を空にしてから実行する。
