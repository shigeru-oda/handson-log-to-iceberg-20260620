# handson-log-to-iceberg

ECS Fargate 上の Go 製ダミー OTel ログジェネレーターが出力するログを、FireLens (Fluent Bit) で severity ごとに振り分け、Amazon Data Firehose 経由で S3 / CloudWatch Logs / Apache Iceberg (S3 Tables・Glue) へ配信・蓄積するハンズオンです。インフラはすべて Terraform (`infra/`) で構築します。リージョンは **ap-northeast-1 (東京)** を対象とします。

## リポジトリ構成

| パス | 内容 |
| --- | --- |
| `app/` | Go 製ダミー OTel ログジェネレーター + マルチステージ `Dockerfile` |
| `fluent-bit/` | FireLens (Fluent Bit) 設定。`custom.conf` (severity ベースルーティング)、`parsers.conf` (アプリ JSON を `log` から展開する parser)、`iceberg_transform.lua` (Iceberg 向けスキーマ整形)、`Dockerfile` (これらをベイクするカスタムイメージ) |
| `infra/` | Terraform 構成一式 (VPC / ECS / Firehose / S3 / S3 Tables / Glue / IAM など) |
| `infra/verify.sh` | Terraform 構成のスナップショット静的検証スクリプト |
| `docs/e2e-verification-checklist.md` | デプロイ後の手動 E2E 検証チェックリスト |

## アーキテクチャ概要

- **ステージ 1**: 全ログ → S3 (full-logs)、ERROR/FATAL → CloudWatch Logs
- **ステージ 2**: ERROR/FATAL → S3 Tables Iceberg (マネージド) と Glue Iceberg (セルフマネージド) の両方式へ並行配信

severity による振り分けは Fluent Bit で行われ、両ステージは排他ではなく同時に成立します。FireLens はアプリの JSON を `log` フィールドに文字列で渡すため、まず parser (`parsers.conf`) でトップレベルへ展開し、`rewrite_tag` で `severityText` が `ERROR`/`FATAL` のレコードに `error.*` タグを付与します (文字列フィールドで判定する点に注意。整数の `severityNumber` は `rewrite_tag` の正規表現にマッチしません)。Iceberg 配信向けには、さらに Lua (`iceberg_transform.lua`) で小文字フラットスキーマ (`event_time` / `severity_number` / `severity_text` / `body` / `resource_json` / `attributes_json` / `ingest_date`) へ整形します。

## Infrastructure (Terraform)

Terraform 構成は `infra/` ディレクトリに配置されています。

> **必要バージョン**
> Terraform `>= 1.5`、AWS provider `~> 6.4` (`hashicorp/aws`)。S3 Tables テーブルのスキーマ
> 定義 (`aws_s3tables_table` の `metadata { iceberg { schema { … } } }`) は provider v6.4 で
> 追加されたため必須です。これにより S3 Tables テーブルの Iceberg メタデータ
> (`metadata_location`) が作成時に初期化され、Firehose の Iceberg 配信が成立します
> (未定義だと Athena が `missing [metadata_location]` で失敗します)。

### ステート管理

本プロジェクトは Terraform のローカルバックエンドを使用しています。

> **運用制約: 同時実行の禁止**
>
> ローカルバックエンドは自動ロック機構や同時アクセスの検知・防止機能を提供しません。
> 複数のオペレーターが同時に `terraform apply` / `terraform plan` を実行すると、
> ステートファイルの破損やリソースの不整合が発生する可能性があります。
>
> **必ず一人ずつ順番に Terraform コマンドを実行してください。**

### ローカルでの使い方

```bash
cd infra
terraform init
terraform plan
terraform apply
```

---

# 作業用 EC2 インスタンス上でハンズオンを実行する

ローカル環境に Terraform / Go / Docker を導入せず、AWS 内に作成した **作業用 EC2 インスタンス** の中でハンズオン (イメージのビルド & プッシュ、`terraform apply`、検証) を完結させる手順です。

> **なぜ EC2 を使うのか**
> - コンテナのビルド対象は `linux/amd64` です。**x86_64 の EC2** 上で実行すればエミュレーションなしでネイティブにビルドできます。
> - 必要なツール (Go / Docker / Terraform / AWS CLI) を 1 台に閉じ込められ、後片付けが容易です。
> - 接続は **SSM Session Manager** を使うため、SSH キーや受信ポート (22番) の開放が不要です。

## 全体の流れ

1. EC2 用の IAM ロール (インスタンスプロファイル) を作成する
2. 作業用 EC2 を作成する (方法A: コンソール / 方法B: AWS CLI)
3. SSM Session Manager で EC2 に接続する
4. EC2 内に必要ツールをインストールする
5. リポジトリを取得し、ハンズオンを実行する
6. 後片付け (EC2・IAM・AWS リソースの削除)

## 前提

- AWS アカウントを保有し、対象リージョンは **ap-northeast-1**。
- AWS CLI で作成する場合は、手元の端末に AWS CLI v2 が設定済み (`aws sts get-caller-identity` が成功する) であること。
- EC2 / IAM を作成できる権限を持つこと。

## ステップ 0: EC2 用 IAM ロール (インスタンスプロファイル) の作成

作業用 EC2 はハンズオンの全 AWS リソース (VPC・ECS・Firehose・S3・S3 Tables・Glue・**IAM ロール** など) を Terraform で作成します。そのため EC2 には十分な権限が必要です。

> **重要 (権限について)**
> 本ハンズオンは IAM ロールも作成するため、`PowerUserAccess` では不足します。簡便さを優先し、ここでは **`AdministratorAccess`** を付与します。これは非常に広い権限です。**ハンズオン専用とし、完了後は必ず削除してください** (本番運用では最小権限へ絞ること)。
> あわせて、SSM Session Manager 接続のために **`AmazonSSMManagedInstanceCore`** を付与します。

### 方法B (AWS CLI) で作成する場合の IAM 準備

```bash
# 1) EC2 が assume できる信頼ポリシーでロールを作成
cat > /tmp/ec2-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

aws iam create-role \
  --role-name handson-iceberg-ec2-role \
  --assume-role-policy-document file:///tmp/ec2-trust.json

# 2) 必要な管理ポリシーをアタッチ (ハンズオン専用・完了後に削除)
aws iam attach-role-policy \
  --role-name handson-iceberg-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws iam attach-role-policy \
  --role-name handson-iceberg-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# 3) インスタンスプロファイルを作成しロールを登録
aws iam create-instance-profile \
  --instance-profile-name handson-iceberg-ec2-profile

aws iam add-role-to-instance-profile \
  --instance-profile-name handson-iceberg-ec2-profile \
  --role-name handson-iceberg-ec2-role
```

> 方法A (コンソール) で作成する場合は、この IAM ロールはコンソールのウィザード内 (もしくは IAM コンソール) で作成します。手順はステップ 1 の方法A内に記載します。

## ステップ 1: 作業用 EC2 の作成

推奨スペック: **Amazon Linux 2023 / x86_64 / t3.large (2 vCPU・8 GB) / gp3 30 GB**。Docker ビルドと Terraform を快適に動かすため t3.large 程度を推奨します。

### 方法A: マネジメントコンソールで作成

1. AWS マネジメントコンソールで **リージョンを「アジアパシフィック (東京) ap-northeast-1」** に切り替える。
2. **EC2** サービス → 左メニュー **インスタンス** → **インスタンスを起動** をクリック。
3. **名前とタグ**: 名前に `handson-iceberg-builder` を入力。
4. **アプリケーションおよび OS イメージ (AMI)**: **Amazon Linux** → **Amazon Linux 2023 (64 ビット x86)** を選択。
5. **インスタンスタイプ**: `t3.large` を選択。
6. **キーペア (ログイン)**: SSM で接続するため **「キーペアなしで続行」** を選択 (SSH は使いません)。
7. **ネットワーク設定**: 既定の VPC / サブネットでよい。**「パブリック IP の自動割り当て」を有効** にする (SSM エンドポイント到達のため)。セキュリティグループは **受信ルール不要** (デフォルトのまま。送信は全許可でよい)。
8. **ストレージを設定**: ルートボリュームを **30 GiB / gp3** に変更。
9. **高度な詳細** を展開:
   - **IAM インスタンスプロファイル**: `handson-iceberg-ec2-profile` を選択。
     - まだ無い場合は、別タブの **IAM コンソール → ロール → ロールを作成** で「信頼されたエンティティ = AWS のサービス / ユースケース = EC2」を選び、`AdministratorAccess` と `AmazonSSMManagedInstanceCore` をアタッチして `handson-iceberg-ec2-role` を作成すると、同名のインスタンスプロファイルが自動生成されます。作成後、上の選択肢に表示されます。
   - **メタデータのバージョン**: 「V2 のみ (トークン必須)」を推奨。
10. 右側の概要を確認し **インスタンスを起動**。
11. インスタンスの **ステータスチェック** が 2/2 になり、SSM の **「マネージドインスタンス」** に登録される (数分かかる) まで待つ。

### 方法B: AWS CLI で作成

ステップ 0 (CLI) でインスタンスプロファイルを作成済みであることが前提です。

```bash
export AWS_REGION=ap-northeast-1

# 1) 最新の Amazon Linux 2023 (x86_64) AMI ID を SSM パブリックパラメータから取得
AMI_ID=$(aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
echo "AMI_ID=$AMI_ID"

# 2) 既定 VPC のデフォルトサブネットを 1 つ取得
SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)
echo "SUBNET_ID=$SUBNET_ID"

# 3) EC2 を起動 (キーペアなし / SSM 接続 / パブリック IP 付与 / gp3 30GB)
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type t3.large \
  --iam-instance-profile Name=handson-iceberg-ec2-profile \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=handson-iceberg-builder}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "INSTANCE_ID=$INSTANCE_ID"

# 4) 起動完了を待機
aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
echo "EC2 is ready: $INSTANCE_ID"
```

> SSM Session Manager で接続するには、インスタンスが SSM エンドポイント (443番) へ到達できる必要があります。上記はパブリックサブネット + パブリック IP 構成のため、デフォルトのアウトバウンド全許可で到達できます。

## ステップ 2: EC2 へ接続する (SSM Session Manager)

手元の端末に Session Manager プラグインが必要です (未導入の場合は「Session Manager plugin」でインストール)。

```bash
# 方法B では $INSTANCE_ID をそのまま利用。方法A の場合はコンソールでインスタンス ID を確認して指定。
aws ssm start-session --region ap-northeast-1 --target "$INSTANCE_ID"
```

接続後はデフォルトで `ssm-user` になります。以降のコマンドは EC2 内で実行します (必要に応じて `sudo` を使用)。

> コンソールから接続する場合: EC2 → インスタンスを選択 → **接続** → **セッションマネージャー** タブ → **接続**。

## ステップ 3: EC2 内に必要ツールをインストールする

Amazon Linux 2023 には AWS CLI v2 と SSM Agent が同梱されています。Git / Docker / Go / Terraform を導入します。

```bash
# Git と Docker、jq (Lake Formation 設定の JSON 編集に使用)
sudo dnf install -y git docker jq

# Docker を起動 (以降の docker コマンドはすべて sudo を付けて実行する)
sudo systemctl enable --now docker

# Go (公式 tarball / バージョンは go.mod の go 1.25 系に合わせる)
GO_VERSION=1.25.5
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
export PATH=$PATH:/usr/local/go/bin

# Terraform (HashiCorp 公式 dnf リポジトリ)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform

# バージョン確認
aws --version
git --version
sudo docker --version
go version
terraform version
```

> Docker はグループ設定 (`usermod` + 再接続) を省略し、**`docker` コマンドは常に `sudo` を付けて実行**します。`docker login` を `sudo` で行うと認証情報は `/root/.docker/config.json` に保存されるため、以降の `docker build` / `docker push` も同じく `sudo` で実行してください (sudo と非 sudo を混在させないこと)。

## ステップ 4: リポジトリを取得してハンズオンを実行する

```bash
# 作業ディレクトリへ
cd ~

# リポジトリを取得 (このリポジトリの URL を指定)
git clone https://github.com/shigeru-oda/handson-log-to-iceberg-20260620.git handson-log-to-iceberg
cd handson-log-to-iceberg

# アカウント ID / レジストリを変数化
export AWS_REGION=ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- 1) ECR リポジトリ作成 & ログイン ---
aws ecr describe-repositories --repository-names log-generator --region "$AWS_REGION" \
  || aws ecr create-repository --repository-name log-generator --region "$AWS_REGION"
aws ecr describe-repositories --repository-names custom-fluent-bit --region "$AWS_REGION" \
  || aws ecr create-repository --repository-name custom-fluent-bit --region "$AWS_REGION"

aws ecr get-login-password --region "$AWS_REGION" \
  | sudo docker login --username AWS --password-stdin "$ECR_REGISTRY"

# --- 2) アプリイメージのビルド & プッシュ (linux/amd64) ---
sudo docker build --platform linux/amd64 -t "${ECR_REGISTRY}/log-generator:latest" ./app
sudo docker push "${ECR_REGISTRY}/log-generator:latest"

# --- 3) カスタム Fluent Bit イメージ (custom.conf 等をベイク) のビルド & プッシュ ---
# fluent-bit/Dockerfile はリポジトリに含まれており、custom.conf に加えて
# "log" 文字列の JSON 展開用 parser (parsers.conf) と、Iceberg スキーマ整形用の
# Lua スクリプト (iceberg_transform.lua) を /fluent-bit/etc/ へ COPY する。
sudo docker build --platform linux/amd64 -t "${ECR_REGISTRY}/custom-fluent-bit:latest" ./fluent-bit
sudo docker push "${ECR_REGISTRY}/custom-fluent-bit:latest"

# --- 4) Terraform でインフラをデプロイ ---
cd infra
terraform init
terraform validate
# イメージは既定で「実行アカウント/リージョンの ECR」から自動解決される
# (リポジトリ名 log-generator / custom-fluent-bit、タグ latest)。
# そのため通常は -var でのイメージ指定は不要。
terraform apply
```

> **イメージ URI を明示したい場合 (任意)**
> 別リポジトリ名・別タグ・別レジストリのイメージを使う場合のみ、以下のように上書きできます。
> ```bash
> terraform apply \
>   -var="app_image=${ECR_REGISTRY}/log-generator:latest" \
>   -var="fluent_bit_image=${ECR_REGISTRY}/custom-fluent-bit:latest" \
>   -var="log_interval_ms=1000"
> ```
> 関連変数: `app_repository_name` (既定 `log-generator`) / `fluent_bit_repository_name` (既定 `custom-fluent-bit`) / `image_tag` (既定 `latest`)。
> なお、レジストリ名を含まないタグだけ (例: `log-generator:latest`) を指定すると Docker Hub と解釈されて pull に失敗するため、上書きする場合は必ず完全な ECR URI を指定すること。

> **Lake Formation が有効なアカウントでの追加手順 (重要)**
> アカウントで AWS Lake Formation が有効化され Glue Data Catalog を統制している場合、上の `terraform apply` は権限エラーで失敗します。その場合は次の「Lake Formation 権限の事前付与」を実施してから再度 `terraform apply` してください。

### Lake Formation 権限の事前付与 (Lake Formation 有効アカウントのみ)

本ハンズオンの Iceberg 配信先 (S3 Tables / Glue セルフマネージド) は Glue Data Catalog 上のテーブルです。アカウントで **Lake Formation が Data Catalog を統制している**場合、IAM 権限だけでは Firehose や Terraform がテーブルへアクセスできず、`terraform apply` が以下のようなエラーで失敗します。

- `Insufficient Lake Formation permission(s): Required Describe on otel_log_pipeline_dev_logs` (Glue データベース読み取り時)
- `Role ... is not authorized to perform: glue:GetTable ...` (Firehose ストリーム作成時)

`AdministratorAccess` ロールでも Lake Formation の権限は別管理です。以下を実施してから (再) `terraform apply` してください。

#### 共通変数

```bash
export AWS_REGION=ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 命名はデフォルト (project=otel-log-pipeline / environment=dev) に基づく
S3TABLES_BUCKET=otel-log-pipeline-dev-s3tables
NAMESPACE=otel_log_pipeline_dev
S3TABLES_TABLE=error_logs
FIREHOSE_S3TABLES_ROLE=arn:aws:iam::${ACCOUNT_ID}:role/otel-log-pipeline-dev-firehose-s3tables-iceberg
S3TABLES_CATALOG=${ACCOUNT_ID}:s3tablescatalog/${S3TABLES_BUCKET}
```

#### 1) 実行ロールを Lake Formation 管理者に追加 (既存管理者は保持)

`put-data-lake-settings` は管理者一覧を全置換するため、既存の管理者を残したまま自分を追記します。

```bash
# 現在の管理者を確認
aws lakeformation get-data-lake-settings --region "$AWS_REGION" \
  --query 'DataLakeSettings.DataLakeAdmins'

# 実行中の SSO ロール (例: AdministratorAccess) の実体 ARN を取得
MYROLE=$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'AWSReservedSSO_AWSAdministratorAccess')].Arn" \
  --output text)
echo "$MYROLE"

# 既存設定を保持しつつ DataLakeAdmins に自分を追記して反映
aws lakeformation get-data-lake-settings --region "$AWS_REGION" \
  | jq --arg r "$MYROLE" '.DataLakeSettings | .DataLakeAdmins += [{"DataLakePrincipalIdentifier":$r}]' \
  > /tmp/lf-settings.json
aws lakeformation put-data-lake-settings --region "$AWS_REGION" \
  --data-lake-settings file:///tmp/lf-settings.json

# 反映確認 (既存 + 自分の 2 つになる)
aws lakeformation get-data-lake-settings --region "$AWS_REGION" \
  --query 'DataLakeSettings.DataLakeAdmins'
```

> コンソールでも可: Lake Formation → Administration → Administrative roles and tasks → Data lake administrators に実行ロールを追加 (既存は残す)。

#### 2) S3 Tables の namespace / table を先に作成

S3 Tables への grant は対象テーブルが存在している必要があるため、該当リソースだけ先に作成します。

```bash
cd infra
terraform init
terraform apply \
  -target=aws_s3tables_table_bucket.iceberg \
  -target=aws_s3tables_namespace.iceberg \
  -target=aws_s3tables_table.error_logs
```

#### 3) Firehose ロールへ S3 Tables (federated カタログ) の権限を付与

S3 Tables は `s3tablescatalog/<bucket>` という federated サブカタログとして Glue に現れます。Terraform の `aws_lakeformation_permissions` は `catalog_id` をアカウント ID (12桁) に限定しこの形式を扱えないため、ここだけ CLI で付与します。

```bash
# database (= namespace) に DESCRIBE
aws lakeformation grant-permissions --region "$AWS_REGION" \
  --principal DataLakePrincipalIdentifier="$FIREHOSE_S3TABLES_ROLE" \
  --permissions DESCRIBE \
  --resource "{\"Database\":{\"CatalogId\":\"$S3TABLES_CATALOG\",\"Name\":\"$NAMESPACE\"}}"

# table に ALL (最小化する場合は DESCRIBE SELECT INSERT ALTER)
aws lakeformation grant-permissions --region "$AWS_REGION" \
  --principal DataLakePrincipalIdentifier="$FIREHOSE_S3TABLES_ROLE" \
  --permissions ALL \
  --resource "{\"Table\":{\"CatalogId\":\"$S3TABLES_CATALOG\",\"DatabaseName\":\"$NAMESPACE\",\"Name\":\"$S3TABLES_TABLE\"}}"
```

付与確認 (Principal 指定時は Resource も必須):

```bash
aws lakeformation list-permissions --region "$AWS_REGION" \
  --principal DataLakePrincipalIdentifier="$FIREHOSE_S3TABLES_ROLE" \
  --resource "{\"Database\":{\"CatalogId\":\"$S3TABLES_CATALOG\",\"Name\":\"$NAMESPACE\"}}" \
  --query 'PrincipalResourcePermissions[].Permissions'   # => [["DESCRIBE"]]

aws lakeformation list-permissions --region "$AWS_REGION" \
  --principal DataLakePrincipalIdentifier="$FIREHOSE_S3TABLES_ROLE" \
  --resource "{\"Table\":{\"CatalogId\":\"$S3TABLES_CATALOG\",\"DatabaseName\":\"$NAMESPACE\",\"Name\":\"$S3TABLES_TABLE\"}}" \
  --query 'PrincipalResourcePermissions[].Permissions'   # => [["ALL"]]
```

> Glue セルフマネージド側 (database `otel_log_pipeline_dev_logs` / table `errors`) の Firehose ロールへの grant は Terraform (`infra/lakeformation.tf`) で管理されるため CLI 付与は不要です。手順1で実行ロールが Lake Formation 管理者になっていれば、次の `terraform apply` 時に自動で付与されます。

#### 4) 残りをデプロイ

```bash
# イメージは既定で実行アカウント/リージョンの ECR から自動解決されるため -var は不要。
terraform apply
```

#### 5) Athena でクエリするロールへ SELECT を付与 (Lake Formation 有効アカウントのみ)

Lake Formation が完全管理モード (`CreateTableDefaultPermissions` が空) の場合、Data Lake 管理者であっても **テーブルデータへの SELECT は自動付与されません**。この状態で Athena から Iceberg テーブルを検索すると、次のエラーになります。

```
COLUMN_NOT_FOUND: line 1:8: Relation contains no accessible columns
```

これはスキーマ欠落ではなく、クエリ実行ロールがどの列にも SELECT 実効権限を持たない (SELECT が grant option にしか無い) ために全列がフィルタされる症状です。クエリを実行するロールへ SELECT / DESCRIBE を付与します。

```bash
# クエリを実行する IAM/SSO ロールの ARN を指定する。
# 例: SSO の AdministratorAccess ロールの実体 ARN を取得
QUERY_ROLE=$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'AWSReservedSSO_AWSAdministratorAccess')].Arn" \
  --output text)
echo "$QUERY_ROLE"

# Glue セルフマネージド側 (database otel_log_pipeline_dev_logs / table errors) へ付与
aws lakeformation grant-permissions --region "$AWS_REGION" \
  --principal DataLakePrincipalIdentifier="$QUERY_ROLE" \
  --permissions SELECT DESCRIBE \
  --resource '{"Table":{"DatabaseName":"otel_log_pipeline_dev_logs","Name":"errors"}}'

# 付与確認 (実効 Permissions に SELECT / DESCRIBE が入る)
aws lakeformation list-permissions --region "$AWS_REGION" \
  --principal DataLakePrincipalIdentifier="$QUERY_ROLE" \
  --resource '{"Table":{"DatabaseName":"otel_log_pipeline_dev_logs","Name":"errors"}}' \
  --query 'PrincipalResourcePermissions[].Permissions'
```

> **Terraform で恒久管理する場合 (任意)**
> 上記 CLI 付与は `terraform destroy` → `apply` で失われる。クエリ用ロールへの付与を
> Terraform で管理したい場合は、`infra/lakeformation.tf` の変数
> `athena_query_role_arns` に ARN を渡して apply する (Glue セルフマネージド側 table へ
> SELECT/DESCRIBE、database へ DESCRIBE を付与)。空 (既定) なら何も付与しない。
> ```bash
> terraform apply \
>   -var='athena_query_role_arns=["'"$QUERY_ROLE"'"]'
> ```
> S3 Tables 側 (federated カタログ) は provider 制約により Terraform では扱えないため、
> 下記 CLI 付与を引き続き使用する。

> S3 Tables 側 (namespace `otel_log_pipeline_dev` / table `error_logs`) も Athena で検索したい場合は、federated カタログ ID を指定して同様に付与します。
> ```bash
> aws lakeformation grant-permissions --region "$AWS_REGION" \
>   --principal DataLakePrincipalIdentifier="$QUERY_ROLE" \
>   --permissions SELECT DESCRIBE \
>   --resource "{\"Table\":{\"CatalogId\":\"$S3TABLES_CATALOG\",\"DatabaseName\":\"$NAMESPACE\",\"Name\":\"$S3TABLES_TABLE\"}}"
> ```

デプロイ後の動作確認 (S3 に全 severity が蓄積される / CloudWatch に ERROR・FATAL のみ / Iceberg テーブルにエラーログのみ) は **`docs/e2e-verification-checklist.md`** のチェックリストに沿って実施してください。

## ステップ 5: 後片付け

課金リソースを残さないよう、検証が終わったら必ず削除します。

```bash
# 1) Terraform で作成した AWS リソースを削除 (EC2 内 infra/ ディレクトリで)
cd ~/handson-log-to-iceberg/infra
terraform destroy
# S3 バケットにオブジェクトが残っていると destroy が失敗するため、必要なら中身を空にしてから再実行

# 2) ECR リポジトリの削除 (任意)
aws ecr delete-repository --repository-name log-generator --force --region ap-northeast-1
aws ecr delete-repository --repository-name custom-fluent-bit --force --region ap-northeast-1
```

作業用 EC2 と IAM の削除 (手元の端末から / 方法B で作成した場合):

```bash
# EC2 の終了
aws ec2 terminate-instances --region ap-northeast-1 --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --region ap-northeast-1 --instance-ids "$INSTANCE_ID"

# インスタンスプロファイル / ロールの削除
aws iam remove-role-from-instance-profile \
  --instance-profile-name handson-iceberg-ec2-profile --role-name handson-iceberg-ec2-role
aws iam delete-instance-profile --instance-profile-name handson-iceberg-ec2-profile
aws iam detach-role-policy --role-name handson-iceberg-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam detach-role-policy --role-name handson-iceberg-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name handson-iceberg-ec2-role
```

> コンソールで作成した場合は、EC2 コンソールからインスタンスを **終了 (Terminate)**、IAM コンソールからロール / インスタンスプロファイルを削除してください。

## 補足

- **AdministratorAccess は広範な権限** です。ハンズオン専用とし、完了後は必ず削除してください。
- ローカルバックエンドのステートはこの EC2 上 (`infra/` 配下) に保存されます。EC2 を終了するとステートも失われるため、**先に `terraform destroy` を実行** してから EC2 を終了してください。
- Graviton (arm64) の EC2 を使う場合は、`docker build --platform linux/amd64` がエミュレーションとなりビルドが遅くなります。本ハンズオンでは **x86_64 インスタンス** を推奨します。
