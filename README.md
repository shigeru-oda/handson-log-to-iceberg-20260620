# handson-log-to-iceberg

ECS Fargate 上の Go 製ダミー OTel ログジェネレーターが出力するログを、FireLens (Fluent Bit) で severity ごとに振り分け、Amazon Data Firehose 経由で S3 / CloudWatch Logs / Apache Iceberg (S3 Tables・Glue) へ配信・蓄積するハンズオンです。インフラはすべて Terraform (`infra/`) で構築します。リージョンは **ap-northeast-1 (東京)** を対象とします。

## リポジトリ構成

| パス | 内容 |
| --- | --- |
| `app/` | Go 製ダミー OTel ログジェネレーター + マルチステージ `Dockerfile` |
| `fluent-bit/custom.conf` | FireLens (Fluent Bit) の severity ベースルーティング設定 |
| `infra/` | Terraform 構成一式 (VPC / ECS / Firehose / S3 / S3 Tables / Glue / IAM など) |
| `infra/verify.sh` | Terraform 構成のスナップショット静的検証スクリプト |
| `docs/e2e-verification-checklist.md` | デプロイ後の手動 E2E 検証チェックリスト |

## アーキテクチャ概要

- **ステージ 1**: 全ログ → S3 (full-logs)、ERROR/FATAL → CloudWatch Logs
- **ステージ 2**: ERROR/FATAL → S3 Tables Iceberg (マネージド) と Glue Iceberg (セルフマネージド) の両方式へ並行配信

severity による振り分けは Fluent Bit の `rewrite_tag` で行われ、両ステージは排他ではなく同時に成立します。

## Infrastructure (Terraform)

Terraform 構成は `infra/` ディレクトリに配置されています。

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
# Git と Docker
sudo dnf install -y git docker

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

# --- 3) カスタム Fluent Bit イメージ (custom.conf をベイク) のビルド & プッシュ ---
cat > fluent-bit/Dockerfile <<'DOCKER'
FROM public.ecr.aws/aws-observability/aws-for-fluent-bit:stable
COPY custom.conf /fluent-bit/etc/custom.conf
DOCKER
sudo docker build --platform linux/amd64 -t "${ECR_REGISTRY}/custom-fluent-bit:latest" ./fluent-bit
sudo docker push "${ECR_REGISTRY}/custom-fluent-bit:latest"

# --- 4) Terraform でインフラをデプロイ ---
cd infra
terraform init
terraform validate
terraform apply \
  -var="app_image=${ECR_REGISTRY}/log-generator:latest" \
  -var="fluent_bit_image=${ECR_REGISTRY}/custom-fluent-bit:latest" \
  -var="log_interval_ms=1000"
```

デプロイ後の動作確認 (S3 に全 severity が蓄積される / CloudWatch に ERROR・FATAL のみ / Iceberg テーブルにエラーログのみ) は **`docs/e2e-verification-checklist.md`** のチェックリストに沿って実施してください。

## ステップ 5: 後片付け

課金リソースを残さないよう、検証が終わったら必ず削除します。

```bash
# 1) Terraform で作成した AWS リソースを削除 (EC2 内 infra/ ディレクトリで)
cd ~/handson-log-to-iceberg/infra
terraform destroy \
  -var="app_image=${ECR_REGISTRY}/log-generator:latest" \
  -var="fluent_bit_image=${ECR_REGISTRY}/custom-fluent-bit:latest"
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
