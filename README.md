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

## バージョニング（v1 可動タグ）

利用側は常に `@v1` を参照します。後方互換のある変更は `main` へのマージ後、まず `self-test` が green であることを確認し、`git tag -f v1 && git push -f origin v1` で `v1` を進めてください。`v1` を動かすたびに `v1.<n>` 形式の不変タグも作成します。

互換性を壊す変更のときだけ `v2` を切り、利用側の移行が完了するまで `v1` を残します。問題が起きた場合は `v1` を直前の SHA へ戻すことで、すべての利用リポジトリを即時復旧できます。
