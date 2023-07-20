# A PHP app on Cloud Run

PHP アプリケーションを開発し、[Cloud Run](https://cloud.google.com/run?hl=ja) にホストするまでのサンプルです。

以下 Google Cloud の [Cloud Shell](https://cloud.google.com/shell?hl=ja) を前提にしていますが  
Docker が利用できる環境であれば、ある程度は場所を選ばず実行できる想定です。

## 1. コードの取得・エディタの起動

```sh
git clone https://github.com/pottava/php-cloud-run.git
```

Google Cloud 上でチュートリアルを実行する場合は  
https://shell.cloud.google.com/ から Cloud Shell Editor を起動、  
ターミナルを開き、以下のコマンドで Editor のワークスペースを再設定します。

```sh
cloudshell workspace php-cloud-run
```

## 2. PHP アプリケーションの起動・確認

[Docker Compose](https://docs.docker.com/compose/) を利用し、  
開発場必要になるソフトウェアを関連づけて一気に起動します。

```sh
docker compose up
```

正常に起動するとログは以下のような行が出力されます。

```log
..
web  | /docker-entrypoint.sh: Configuration complete; ready for start up
..
app  | [05-Jul-2023 09:21:37] NOTICE: ready to handle connections
```

ローカルで作業している場合は http://localhost:8080 を開き、  
Cloud Shell 上であれば画面の右上の「Web Preview」から「Preview on port 8080」を選び、  
ブラウザ越しにアプリケーションが正常に動作していることを確認します。

## 3. ソースコードの変更・反映

ソースコードを書き換えてみます。

```sh
cat << EOF >> src/index.php
phpinfo();
EOF
```

ブラウザをリロードして、表示内容が変わったことを確認してみましょう。

## 4. コンテナのビルド

Docker compose では `run` という起動コマンドが内部的にコンテナをビルドしてくれていました。  
しかし遠隔の環境でアプリケーションを起動するためには事前にビルドしておく必要があります。

Google Cloud でアプリケーションのテストやビルドを行うための Cloud Build と、  
成果物を管理することのできる Artifact Registry を有効化（使える状態に）しましょう。  
（Google Cloud では利用するサービスごとに、まずは "API の有効化" が必要です）

```sh
gcloud services enable compute.googleapis.com run.googleapis.com \
    cloudbuild.googleapis.com artifactregistry.googleapis.com
```

[Artifact Registry](https://cloud.google.com/artifact-registry?hl=ja) にリポジトリ（成果物置き場）を作り

```sh
gcloud artifacts repositories create my-apps --repository-format "docker" \
    --location "asia-northeast1" --description "Containerized apps"
```

[Cloud Build](https://cloud.google.com/build?hl=ja) を使ってアプリケーションをビルドしてみましょう！  
どうやってビルドしているかは設定ファイル (conf/cloud-build.yaml) を確認してみてください。

```sh
gcloud builds submit --config conf/cloud-build.yaml --region 'asia-northeast1' --substitutions SHORT_SHA=test
```

## 5. Cloud Run へのデプロイ

ビルドしたアプリケーションを Cloud Run に載せてみましょう。  
以下のコマンドで PHP アプリケーションをデプロイしてみます。

```sh
sed -e "s/PROJECT_ID/$( gcloud config get-value project )/g" conf/cloud-run.yaml \
    | sed -e "s/COMMIT_SHA/test/g" > cloud-run.yaml
gcloud run services replace cloud-run.yaml --region 'asia-northeast1'
```

外部からのアクセスを許可しつつ

```sh
gcloud run services add-iam-policy-binding my-svc --region "asia-northeast1" \
    --member "allUsers" --role "roles/run.invoker"
```

アクセスするためのホスト名を取得してみましょう。

```sh
gcloud run services describe my-svc --region 'asia-northeast1' --format 'value(status.url)'
```

## 6. git によるバージョン管理

[Cloud Source Repositories (CSR)](https://cloud.google.com/source-repositories?hl=ja) を使ってソースコードをバージョン管理してみます。  
まずは API を有効化し、リポジトリを作りましょう。

```sh
gcloud services enable sourcerepo.googleapis.com
gcloud source repos create my-svc
```

作ったリポジトリにはブラウザからもアクセスできます。  
https://source.cloud.google.com/repos

以下のコマンドでリモート リポジトリを追加し、コードを転送してみましょう。

```sh
git config --global credential.https://source.developers.google.com.helper gcloud.sh
git remote add google https://source.developers.google.com/p/$( gcloud config get-value project )/r/my-svc
git push --all google
```

## 7. CI/CD の自動化

まずは Cloud Build が内部的に利用する[サービス アカウント](https://cloud.google.com/iam/docs/service-account-overview?hl=ja)に権限を付与します。

```sh
export project_id=$( gcloud config get-value project )
export project_number=$(gcloud projects describe ${project_id} \
    --format="value(projectNumber)")
gcloud projects add-iam-policy-binding "${project_id}" \
    --member "serviceAccount:${project_number}@cloudbuild.gserviceaccount.com" \
    --role "roles/run.developer"
```

コードが push されたらコンテナにビルドし、Cloud Run にデプロイされるようにしてみましょう。  
まずは CSR への push により Cloud Build で指定の処理が実行されるよう設定します。

```sh
gcloud builds triggers create cloud-source-repositories --region "asia-northeast1" \
    --repo "my-svc" --branch-pattern "main" --build-config "conf/cloud-build.yaml"
```

Cloud Build の設定に Cloud Run へのデプロイを追加し

```sh
cat << EOF >> conf/cloud-build.yaml

- name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
  entrypoint: /bin/sh
  args:
  - '-c'
  - |
     sed "s/PROJECT_ID/\${PROJECT_ID}/g" conf/cloud-run.yaml | \\
     sed "s/COMMIT_SHA/\${SHORT_SHA}/g" > cloud-run.yaml

- name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
  entrypoint: gcloud
  args: ['run', 'services', 'replace', 'cloud-run.yaml', '--region', 'asia-northeast1']
EOF
```

CSR に変更したコードを push してみましょう。

```sh
git add . && git commit -m 'Automate deployment' && git push google main
```

## 8. データベースの利用

一度 `Ctrl + C` でいったん Docker compose を停止し、MySQL を入れた設定に書き換えます。

```sh
patch conf/app.Dockerfile diff/app.Dockerfile.diff
patch compose.yml diff/compose.yml.diff
patch src/index.php diff/index.php.diff
```

改めて、ビルドオプションをつけて Docker compose でアプリを起動しつつ、

```sh
docker compose up --build
```

別のターミナルからデータベースにデータを入れてみましょう。

```sh
sudo apt-get install -y mysql-client
mysql -h 127.0.0.1 -u user -ppass -D app -e "CREATE TABLE colors (id MEDIUMINT NOT NULL AUTO_INCREMENT, name CHAR(32) NOT NULL, PRIMARY KEY (id));"
mysql -h 127.0.0.1 -u user -ppass -D app -e "INSERT INTO colors (name) VALUES ('White'),('Black'),('Gray');"
```

ブラウザをリロードします。データベースの内容は表示されたでしょうか？

## 9. Cloud SQL の起動

サービスを有効化し、データベース・インスタンスを作り、ましょう。

```sh
gcloud services enable sqladmin.googleapis.com
gcloud sql instances create mysql --region "asia-northeast1" \
    --database-version "MYSQL_5_7" --tier "db-f1-micro"
gcloud sql users set-password root --instance "my-sql" \
    --host '%' --password 'Pa$$w0rd'
gcloud sql users create user --password pass --instance "my-sql"
gcloud sql databases create app --instance "my-sql"
```

[Cloud SQL Auth Proxy]() を利用して、リモートから IAM 認証による接続を試します。  
ツール用の認証を通し、ツールのインストール & 起動してみましょう。

```sh
gcloud auth application-default login
curl -o cloud-sql-proxy https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.4.0/cloud-sql-proxy.linux.amd64
chmod +x cloud-sql-proxy
./cloud-sql-proxy --address 0.0.0.0 --port 1234 "${project_id}:asia-northeast1:my-sql"
```

ターミナルをもう一つ起動し  
クラウド上の MySQL にアクセス、ローカル同様のシード値を投入してみます。

```sh
mysql -h 127.0.0.1 -P 1234 -u root -p -D app
mysql> CREATE TABLE colors (id MEDIUMINT NOT NULL AUTO_INCREMENT, name CHAR(32) NOT NULL, PRIMARY KEY (id));
mysql> INSERT INTO colors (name) VALUES ('White'),('Black'),('Gray');
mysql> SELECT * FROM colors;
mysql> exit
```

## 10. Cloud Run からの Cloud SQL 接続

[Secret Manager](https://cloud.google.com/secret-manager?hl=ja) を使い、データベースへの接続情報を安全に管理しましょう。  

```sh
cat << EOF > mysql-secrets.json
{
  "DB_HOST": "$( gcloud sql instances describe my-sql --format 'value(ipAddresses[0].ipAddress)' ):3306",
  "DB_NAME": "app",
  "DB_USER": "user",
  "DB_PASSWORD": "pass"
}
EOF
gcloud services enable secretmanager.googleapis.com
gcloud secrets create mysql-secrets --replication-policy "automatic" \
    --data-file mysql-secrets.json
rm -f mysql-secrets.json
```

Cloud Run から Cloud SQL に接続を許可するためのサービス アカウントを作り、必要な権限を設定します。

```sh
gcloud iam service-accounts create my-svc \
    --display-name "My service's SA" \
    --description "Service Account for Secret Manager & Cloud SQL client"
gcloud secrets add-iam-policy-binding mysql-secrets \
    --member "serviceAccount:my-svc@${project_id}.iam.gserviceaccount.com" \
    --role roles/secretmanager.secretAccessor
gcloud projects add-iam-policy-binding "${project_id}" \
    --member "serviceAccount:my-svc@${project_id}.iam.gserviceaccount.com" \
    --role "roles/cloudsql.client"
```

Cloud Build が Cloud Run に渡すサービス アカウントを扱えるよう、権限を追加します。

```sh
gcloud iam service-accounts add-iam-policy-binding \
    my-svc@${project_id}.iam.gserviceaccount.com \
    --member "serviceAccount:${project_number}@cloudbuild.gserviceaccount.com" \
    --role "roles/iam.serviceAccountUser"
```

Cloud SQL に接続するための Cloud Run 設定を多少変更します。

```sh
patch conf/cloud-run.yaml diff/cloud-run.yaml.diff
```

変更したコードをデプロイしてみましょう。

```sh
git add . && git commit -m 'Automate deployment' && git push google main
```
