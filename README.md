# tsuki-neko-com/workflows

Cloudflare Workers リポジトリで共通利用する reusable workflow を 1 箇所に集約するリポジトリです。
各利用リポジトリは最小限の caller から共通の検証・デプロイ手順を呼び出せます。

## 使い方（貼り付け用 caller）

各リポジトリの `.github/workflows/ci.yml` に以下を貼り付けてください。`d1-database` はリポジトリごとのデータベース名に書き換え、D1 を使わない場合は `d1-database` の行ごと削除してください。

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  ci:
    uses: tsuki-neko-com/workflows/.github/workflows/workers.yml@v1
    with:
      node-version: "22"
      d1-database: ameownt
    secrets: inherit
```

## シークレット（必須）

利用リポジトリごとに、以下 2 つを **repository secret** として登録してください。**登録しないとデプロイは必ず失敗します。**

登録は `scripts/sync-secrets.sh` で一括同期できます（後述の [シークレットの一括同期](#シークレットの一括同期) 参照）。

**organization secret は使えません。** GitHub Free プランでは organization secret を参照できるのが public リポジトリだけで、private リポジトリでは実行時に空文字が渡ります。org の secret 一覧や `gh api repos/{owner}/{repo}/actions/organization-secrets` には「共有済み」と表示されるため正常に見えますが、ジョブからは読めません。org を Team プラン以上へ上げるか、リポジトリを public にすれば org secret へ一本化できます。

caller 側の `secrets: inherit` はリポジトリ secret でもそのまま機能するので、貼り付ける caller の内容は変わりません。

`deploy` job は最初にこの 2 つが空でないか検査し、空なら原因を名指しして即座に失敗します。

必要な Cloudflare API トークンのスコープは「Edit Cloudflare Workers」テンプレートに加えて **Account → D1 → Edit** と **Account → Queues → Edit**。カスタムドメインを使う場合は Zone → Workers ルート → Edit を対象ゾーンに効かせてください。

## シークレットの一括同期

org 内の caller リポジトリを自動検出し、`CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を repository secret として配布します。トークンをローテーションしたときは env ファイルを書き換えて再実行するだけで、全対象リポジトリへ反映できます。

### 事前準備

認証情報ファイルはこのリポジトリの外（`~/.config/tsuki-neko/`）に置いてください。保険として `.gitignore` に `*.env` を入れてあり、誤ってリポジトリ内へ置いてもコミット対象になりません。

`~/.config/tsuki-neko/cloudflare.env` を作成します。

```sh
mkdir -p ~/.config/tsuki-neko
cat > ~/.config/tsuki-neko/cloudflare.env <<'EOF'
CLOUDFLARE_API_TOKEN=<token>
CLOUDFLARE_ACCOUNT_ID=<account id>
EOF
chmod 600 ~/.config/tsuki-neko/cloudflare.env
```

パーミッションが `600` でない場合、スクリプトは実行を拒否します。別のファイルを使う場合は、環境変数 `TSUKI_NEKO_ENV_FILE` でパスを指定できます。

### 使い方

```sh
./scripts/sync-secrets.sh --dry-run   # 対象リポジトリの確認のみ
./scripts/sync-secrets.sh             # 全 caller リポジトリへ同期
./scripts/sync-secrets.sh ameownt     # 特定リポジトリだけ
```

`.github/workflows/ci.yml` に `tsuki-neko-com/workflows/.github/workflows/workers.yml@` を含むリポジトリだけが対象で、archived リポジトリは除外されます。該当しないリポジトリは `[skip]` と表示されます。引数指定時にこの判定を飛ばす場合は `--force` を使います。

| オプション | 意味 |
|---|---|
| `--dry-run` | secret を登録せず、対象リポジトリだけを確認する |
| `--force` | 引数で指定したリポジトリの caller 判定を省略する |
| `--org <org>` | 対象 organization を指定する（既定: `tsuki-neko-com`） |
| `--help` | ヘルプを表示する |

事前に `gh auth login` を実行し、`gh` を認証済みにしてください。未認証の場合、スクリプトは同期を開始する前に停止します。

トークンの値は標準出力・標準エラーへ一切表示されません。

### スクリプトを使わずに 1 件ずつ登録する場合

```sh
gh secret set CLOUDFLARE_API_TOKEN --repo tsuki-neko-com/<repo>
gh secret set CLOUDFLARE_ACCOUNT_ID --repo tsuki-neko-com/<repo>
```

## inputs

| input | 型 | default | 意味 |
|---|---|---|---|
| `node-version` | string | `"22"` | `actions/setup-node` に渡す Node バージョン |
| `d1-database` | string | `""` | D1 データベース名。空ならマイグレーションをスキップ |
| `deploy-enabled` | boolean | `true` | `false` なら `deploy` job を実行しない |
| `working-directory` | string | `"."` | npm コマンドを実行するディレクトリ。Worker がサブディレクトリにあり、かつ root の npm workspaces に含まれていない場合に指定する |
| `npm-registry-scope` | string | `""` | GitHub Packages で配布している npm scope（例: `@tsuki-neko-com`）。空でなければ npm を `npm.pkg.github.com` に対して認証する |

この workflow は `packages: read` を要求します。再利用ワークフローは caller の権限を
超えられないため、**caller 側で `permissions:` を明示している場合は `packages: read`
を必ず含めてください**。含めないと job が 1 つも起動せず `startup_failure` になります
（ログが残らないので原因が分かりにくい）。`permissions:` を書いていない caller は
既定の token 権限で動くため、追記は不要です。

`npm-registry-scope` の認証には `secrets.GITHUB_TOKEN` を使うので、追加の secret 登録は
不要です。

## npm script 規約

| script | 意味 | 未定義時の扱い |
|---|---|---|
| `build` | デプロイ成果物の生成 | ステップをスキップ |
| `lint` | `biome ci .` | `ci` から呼ばれる |
| `fix` | `biome check --write .` | 手元専用（CI からは呼ばれない） |
| `typecheck` | `tsc --noEmit`（UI があれば UI 分も） | `ci` から呼ばれる |
| `ci` | `npm run lint && npm run typecheck && vitest run && wrangler deploy --dry-run` | **必須**。無ければ CI 失敗 |
| `deploy` | `wrangler deploy` のみ（`build` を含めない） | deploy 有効時は必須 |
| `migrate:remote` | `wrangler d1 migrations apply <db> --remote` | `d1-database` が空ならスキップ |

`deploy` に `build` を含めないでください。ワークフローが `build` → `migrate:remote` → `deploy` の順序を制御するため、含めると二重ビルドになります。

## biome.json マスター

各リポジトリの devDependency に `@biomejs/biome` 2.5.x を追加してください。手元と CI で同一コマンドを使うため、Biome 公式 GitHub Action は使いません。

```json
{
  "$schema": "https://biomejs.dev/schemas/2.5.6/schema.json",
  "vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
  "files": { "ignoreUnknown": false, "includes": ["**", "!worker-configuration.d.ts"] },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2 },
  "linter": { "enabled": true, "rules": { "preset": "recommended" } },
  "javascript": { "formatter": { "quoteStyle": "double" } },
  "assist": { "enabled": true, "actions": { "source": { "organizeImports": "on" } } }
}
```

初回適用時は整形コミットを単独に分離し、その SHA を `.git-blame-ignore-revs` に登録してください。その後、各開発環境で `git config blame.ignoreRevsFile .git-blame-ignore-revs` を実行します。

`biome.json` に JSON コメントを書いてはいけません。コメントがあると Biome が設定を
正しく読まず、`vcs.useIgnoreFile` による `.gitignore` の除外が効かなくなり、`dist/` などの
ビルド成果物まで検査対象に入ります。ルールの重大度を変えた理由などは、リポジトリの
README 側に書いてください。

## Cloudflare issue の自動 Resolved

[hissue](https://github.com/tsuki-neko-com/hissue) が Cloudflare Workers Issues から起票した GitHub issue (ラベル `cloudflare-issue`) が閉じられたとき、対応する Cloudflare の Workers issue のステータスを変更し、結果を issue にコメントします。

- `completed` などで閉じた場合は `resolved`、`not_planned` で閉じた場合は `ignored` にします。
- API は Workers Observability の Modify an issue (`PATCH /accounts/{account_id}/workers/observability/issues/{issueId}`) です。人間向けの API リファレンスの目次にはありませんが、[cloudflare/api-schemas](https://github.com/cloudflare/api-schemas) に定義されています。
- `CLOUDFLARE_API_TOKEN` に **Workers Observability: Edit** が必要です。
- API が失敗した場合は、dashboard で手動変更を促すコメントにフォールバックします。

hissue の `REPO_MAP` に登録したリポジトリに、`.github/workflows/cloudflare-issue-closed.yml` として以下を貼り付けてください。caller に `permissions: issues: write` と `secrets: inherit` が必要です。

```yaml
name: Cloudflare issue closed
on:
  issues:
    types: [closed]
permissions:
  issues: write
jobs:
  resolve:
    uses: tsuki-neko-com/workflows/.github/workflows/cloudflare-issue-closed.yml@v1
    secrets: inherit
```

Cloudflare issue ID と dashboard へのリンクは、hissue が issue 本文の先頭に置くマーカーから取り出します。形式は `<!-- hissue:key=cf:<issueId> worker=<workerName> dashboard=<URL または -> -->` で固定です。

## バージョニング（v1 可動タグ）

利用側は常に `@v1` を参照します。後方互換のある変更は `main` へのマージ後、まず `self-test` が green であることを確認し、`git tag -f v1 && git push -f origin v1` で `v1` を進めてください。`v1` を動かすたびに `v1.<n>` 形式の不変タグも作成します。

互換性を壊す変更のときだけ `v2` を切り、利用側の移行が完了するまで `v1` を残します。問題が起きた場合は `v1` を直前の SHA へ戻すことで、すべての利用リポジトリを即時復旧できます。

## nyanstall への Release 公開

アプリの Release asset を nyanstall の R2 と ingest API に登録する reusable workflow です。caller は `.github/workflows/nyanstall-publish.yml` から呼び出します。

```yaml
name: Publish to nyanstall
on:
  release:
    types: [published]
jobs:
  publish:
    uses: tsuki-neko-com/workflows/.github/workflows/nyanstall-publish.yml@v1
    with:
      app: akscrobble
      tag: ${{ github.event.release.tag_name }}
      mode: android
      version-code: "1000003"
    secrets: inherit
```

`NYANSTALL_CF_API_TOKEN`、`NYANSTALL_CF_ACCOUNT_ID`、`NYANSTALL_ACCESS_CLIENT_ID`、`NYANSTALL_ACCESS_CLIENT_SECRET` を各アプリの repository secret に登録してください。Access token はアプリごとの Service Token を使います。Android は `version-code` が必須で、Release に `*.apk` に一致する APK がちょうど 1 つ必要です。Tauri は `mode: tauri` とし、Release asset に `nyanstall-artifacts.json` と各項目のファイルを添付します。updater 対象には署名ファイルも必要です。

### 直接取り込みと追加 inputs

| input | 既定値 | 意味 |
|---|---|---|
| `source` | `github-release` | `github-release` または同じ run の `artifact` |
| `artifact-name` | 空 | `source: artifact` で必須の artifact 名 |
| `version` | 空 | artifact では必須。GitHub Release では指定せず、`tag` の先頭の `v` を除いた値を使う |
| `channel` | `stable` | `stable` または `beta`。stable は通常版、beta は prerelease が必要 |
| `git-sha` / `git-ref` | 空 | ソースの commit SHA / ref。artifact では省略時に `github.sha` / `github.ref_name` を使う |
| `notes` | 空 | artifact の release notes |
| `source-url` | 空 | artifact の参照 URL。省略時はこの Actions run の URL |
| `product` / `product-version` | 空 | 両方指定すると公開後に台帳の対象 app を `published` に更新する |
| `dry-run` | `false` | `true` なら送信せず payload と要求を出力する |

版は `1.2.3` または `1.2.3-beta.1` の形式です。GitHub Release では `tag` を `v` で始めます。artifact では `tag` に `beta/0.2.14-beta.1` のような文字列を使えます。`dry-run` は R2 へのアップロード、preflight、ingest、台帳更新を行いません。workflow の outputs は `payload`、`version`、`release-id`、dry-run の台帳 PATCH を表す `target-request` です。

次の例では同じ run の build job が APK をアップロードし、publish job がそれを取り込みます。caller の権限は `contents: read` で足ります。

```yaml
name: Publish beta
on: workflow_dispatch
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: ./build-android.sh
      - uses: actions/upload-artifact@v4
        with:
          name: android-beta
          path: dist/*.apk
  publish:
    needs: build
    uses: tsuki-neko-com/workflows/.github/workflows/nyanstall-publish.yml@v1
    with:
      app: my-android-app
      mode: android
      tag: beta/0.2.14-beta.1
      source: artifact
      artifact-name: android-beta
      version: 0.2.14-beta.1
      channel: beta
      version-code: "201401"
    secrets: inherit
```

4 つの secret は dry-run の self-test が secret なしで呼べるよう workflow 定義上 `required: false` です。実際の公開では従来どおりすべて必須で、空なら実行時に失敗します。

署名ビルドで鍵束が必要な場合は composite action を呼び出します。復号した鍵素材は job の最後に削除してください。

```yaml
- uses: tsuki-neko-com/workflows/actions/nyanstall-key@v1
  id: keys
  with:
    app: akscrobble
    purpose: android-release
    api-token: ${{ secrets.NYANSTALL_CF_API_TOKEN }}
    account-id: ${{ secrets.NYANSTALL_CF_ACCOUNT_ID }}
    age-identity: ${{ secrets.NYANSTALL_AGE_IDENTITY }}
- name: Remove signing keys
  if: always()
  run: rm -rf "${{ steps.keys.outputs.dir }}"
```

## nyanstall の台帳

`tsuki-neko-com/workflows/actions/nyanstall-ledger@v1` は呼び出し元の runner で動く composite action です。依存は bash、curl、jq のみで、self-hosted Mac でも動きます。Mac の runner には事前に jq をインストールしてください。通常の呼び出しには Access の client ID と secret が必要です。

| input | 意味 |
|---|---|
| `command` | 必須。下表の操作 |
| `product` | 台帳の product 識別子（`record-ios-release` 以外で必須） |
| `app` | 対象 app（操作に応じて必須） |
| `version` | 対象の product version（`get-version`、`update-target` で必須） |
| `channel` | `last-success` のチャネル |
| `pr-number` | `pr-betas` の PR 番号 |
| `body` | POST / PATCH に渡す JSON |
| `ingest-url` | API の base URL。既定は `https://ingest.nyanstall.tsuki-neko.com` |
| `access-client-id` / `access-client-secret` | Cloudflare Access の認証情報。dry-run 以外で必須 |
| `dry-run` | 既定 `false`。`true` で HTTP を送らず要求を返す |

outputs は `status`（HTTP status、または `dry-run`）と `response`（コンパクトな JSON 応答、dry-run では `method`、`url`、`body` を含む要求）です。`get-version` の 404 は正常な結果として返されます。

| command | 操作 | 必要な主な入力 |
|---|---|---|
| `next-beta` | beta 番号を払い出す | `product`, `body` (`base_version`) |
| `create-version` | 版を作成する | `product`, `body` |
| `get-version` | 版を取得する | `product`, `version` |
| `update-target` | app の状態を更新する | `product`, `version`, `app`, `body` |
| `last-success` | 前回成功した版を取得する | `product`, `app`, `channel` |
| `ios-build-number` | iOS ビルド番号を払い出す | `product`, `body` (`app`, 任意で `version`) |
| `pr-betas` | PR に関連する beta を取得する | `product`, `pr-number` |
| `record-ios-release` | artifact のない iOS release を記録する | `app`, `body` |

例えば、次の各 step に `access-client-id: ${{ secrets.NYANSTALL_ACCESS_CLIENT_ID }}` と `access-client-secret: ${{ secrets.NYANSTALL_ACCESS_CLIENT_SECRET }}` を `with` に追加して使います。応答の値は `steps.<id>.outputs.response` を `fromJSON` で参照できます。

```yaml
- id: beta
  uses: tsuki-neko-com/workflows/actions/nyanstall-ledger@v1
  with:
    command: next-beta
    product: my-product
    body: '{"base_version":"0.2.14"}'
    access-client-id: ${{ secrets.NYANSTALL_ACCESS_CLIENT_ID }}
    access-client-secret: ${{ secrets.NYANSTALL_ACCESS_CLIENT_SECRET }}
- id: version
  uses: tsuki-neko-com/workflows/actions/nyanstall-ledger@v1
  with:
    command: create-version
    product: my-product
    body: >-
      {"version":"0.2.14-beta.1","channel":"beta","git_sha":"0123456789abcdef0123456789abcdef01234567","git_ref":"main","tag":"beta/0.2.14-beta.1","prs":[],"targets":[{"app":"my-ios-app","state":"pending"}]}
    access-client-id: ${{ secrets.NYANSTALL_ACCESS_CLIENT_ID }}
    access-client-secret: ${{ secrets.NYANSTALL_ACCESS_CLIENT_SECRET }}
- uses: tsuki-neko-com/workflows/actions/nyanstall-ledger@v1
  with:
    command: update-target
    product: my-product
    version: 0.2.14-beta.1
    app: my-ios-app
    body: '{"state":"building"}'
    access-client-id: ${{ secrets.NYANSTALL_ACCESS_CLIENT_ID }}
    access-client-secret: ${{ secrets.NYANSTALL_ACCESS_CLIENT_SECRET }}
- id: ios-number
  uses: tsuki-neko-com/workflows/actions/nyanstall-ledger@v1
  with:
    command: ios-build-number
    product: my-product
    body: '{"app":"my-ios-app","version":"0.2.14-beta.1"}'
    access-client-id: ${{ secrets.NYANSTALL_ACCESS_CLIENT_ID }}
    access-client-secret: ${{ secrets.NYANSTALL_ACCESS_CLIENT_SECRET }}
- uses: tsuki-neko-com/workflows/actions/nyanstall-ledger@v1
  with:
    command: record-ios-release
    app: my-ios-app
    body: >-
      {"version":"0.2.14-beta.1","version_code":${{ fromJSON(steps.ios-number.outputs.response).build_number }},"tag":"beta/0.2.14-beta.1","notes":"","source_url":"https://example.com/build","published_at":"2026-11-23T00:00:00Z","channel":"beta","artifacts":[]}
    access-client-id: ${{ secrets.NYANSTALL_ACCESS_CLIENT_ID }}
    access-client-secret: ${{ secrets.NYANSTALL_ACCESS_CLIENT_SECRET }}
```

実際の利用では払い出された `version`、commit SHA、日時、URL をビルドの値に置き換えてください。状態には `skipped`、`pending`、`waiting`、`building`、`uploaded`、`published`、`failed` を使います。

## self-test

`self-test.yml` は actionlint と既存の `smoke`、`smoke-subdir` に加え、Android と Tauri の artifact を beta の dry-run で公開し、payload と台帳 PATCH の要求を検査します。`ledger-action` job は ledger のテストと action の dry-run 出力を検査します。

後方互換のある変更を main へマージした後、`self-test` の green を確認してから `v1` を進め、不変タグも作成します（現在の次のタグは `v1.4`）。
