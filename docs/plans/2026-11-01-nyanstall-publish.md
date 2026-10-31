# nyanstall への取り込み用 reusable workflow と鍵束取得 action の追加

対象リポジトリ: `/home/server/github/workflows`（`tsuki-neko-com/workflows`、public）
設計仕様: `/home/server/github/nyanstall/docs/design/2026-10-31-nyanstall-design.md`（TASK-012、D-2、D-9、D-11、D-15、D-20）

> この計画は設計書の Task 12 だけを抜き出したものである。タスク番号は設計書の通し番号のまま（`### Task 12:`）にしてある。nyanstall リポの計画 `docs/plans/2026-10-31-nyanstall-core.md` も Task 3〜11 の番号を保っており、それに合わせた。タスク本文、受け入れ基準、検証コマンドは設計書から変えていない。

## 背景

nyanstall は、自作アプリ（akscrobble、nekosync、nekosonic）の配布物のバージョン管理と自己更新の共通基盤である。各アプリのリポでは release-please が GitHub Release を作る。その後、この計画で作る reusable workflow が Release asset を R2 へ上げ、ingest API に登録する。ワーカーは workflows リポしか見えないため、必要な仕様をここに写しておく。

### ホストとバケット

| 種別 | 名前 | 備考 |
| --- | --- | --- |
| 公開 API | `nyanstall.sukisuki.club` | 認証なしで manifest と実体を返す（D-14）。この計画では使わない |
| ingest API | `ingest.nyanstall.tsuki-neko.com` | Access app `nyanstall-ingest` で保護されている。Service Token が必須（D-2） |
| R2 バケット | `nyanstall` | 配信実体。キーは `apps/{app}/{version}/{filename}` |
| R2 バケット | `nyanstall-keys` | 署名鍵束。キーは `{app}/{purpose}.tar.age` |

ingest への呼び出しには、`CF-Access-Client-Id` と `CF-Access-Client-Secret` のヘッダーを付ける。Access を通ると、Worker は `Cf-Access-Jwt-Assertion` を検証する。JWT の `common_name`（Service Token の client ID）が、対象アプリの `apps.ingest_client_id` と一致する必要がある。Service Token はアプリのリポごとに分けてある（`nyanstall-ci-akscrobble`、`nyanstall-ci-nekosync`、`nyanstall-ci-nekosonic`）。

### 鍵束（nyanstall リポの `docs/keys.md` の要約）

- R2 バケット `nyanstall-keys` に、`{app}/{purpose}.tar.age` のキーで置く。旧世代は `{app}/history/{purpose}-{世代}.tar.age` に置く。
- `purpose` は `android-release`、`tauri-minisign`、`apple-developer-id`、`windows-authenticode` のどれか（D-9）。
- 各鍵束は tar でまとめ、age で CI 用と復旧用の 2 つの受信者へ暗号化してある。復号すると、keystore などの鍵素材と、パスワードを入れた環境ファイルが出てくる。
- CI 用 identity の秘密部分は GitHub secret `NYANSTALL_AGE_IDENTITY` にある。値を画面、ログ、リポへ出さない。復号では identity を一時ファイルへ書き、展開先を所有者だけが読める権限にする。nyanstall リポの `scripts/keys/unpack.sh` がこの手順の参考になる。ただし、workflows リポからは参照できないので、action の中に同じ手順を書く。
- 取得は `npx --yes wrangler@4 r2 object get "nyanstall-keys/{app}/{purpose}.tar.age" --remote --file <path>` で行う。

### GitHub secret（D-20、nyanstall リポの README）

アプリのリポごとに repository secret として登録する。GitHub Free の private リポでは org secret を使えないため、org secret にはしない。値はどこにも書かない。

| 名前 | 用途 |
| --- | --- |
| `NYANSTALL_CF_API_TOKEN` | 共用トークン `nyanstall-publish`（Account → Workers R2 Storage → Edit）。`nyanstall` への書き込みと `nyanstall-keys` からの読み取りに使う。R2 の権限は account 単位で、アプリ別に絞れない。そのため全アプリで同じ値を使う |
| `NYANSTALL_CF_ACCOUNT_ID` | wrangler の account 指定 |
| `NYANSTALL_ACCESS_CLIENT_ID` / `NYANSTALL_ACCESS_CLIENT_SECRET` | ingest 用の Service Token（アプリごと） |
| `NYANSTALL_AGE_IDENTITY` | 鍵束を復号する CI 用の age identity |

`nyanstall-publish.yml` の `on.workflow_call.secrets` で宣言するのは、上の 4 つ（`NYANSTALL_AGE_IDENTITY` 以外）だけである。`NYANSTALL_AGE_IDENTITY` は署名ビルドで使う。署名ビルドは caller 側のビルド job が行い、`actions/nyanstall-key` に input `age-identity` として渡す。publish は署名済みの Release asset を取り込むだけなので、鍵束を必要としない。

### workers.yml との関係

`nyanstall-publish.yml` は、既存の `workers.yml`（Cloudflare Workers の CI/CD）とは別物の reusable workflow である。`workers.yml` の inputs、secrets、self-test の smoke ジョブには手を入れない。`workers.yml` は `secrets: inherit` を前提にしていて、`on.workflow_call.secrets` を宣言していない。一方、`nyanstall-publish.yml` は secrets を明示宣言する。caller は `secrets: inherit` のままでも、個別に渡しても動く。

### `@v1` の運用（README「バージョニング（v1 可動タグ）」）

利用側は常に `@v1` を参照する。

- reusable workflow: `tsuki-neko-com/workflows/.github/workflows/nyanstall-publish.yml@v1`
- composite action: `tsuki-neko-com/workflows/actions/nyanstall-key@v1`

この追加は後方互換のある変更なので、`v2` は切らない。`main` へのマージ後、`self-test` が green であることを確かめてから `git tag -f v1 && git push -f origin v1` で `v1` を進める。同時に不変タグを作る。既存のタグは `v1.0`〜`v1.3` なので、次は `v1.4` になる。README へ追記する `@v1` の説明は、この既存の運用に合わせる。

### D-11 取り込み用 JSON（`nyanstall-artifacts.json`）

reusable workflow に渡す成果物の一覧である。Android では、reusable workflow が自動で 1 件だけ作る。Tauri では、ビルド job が作って Release asset として添付する。

```json
{
  "app": "nekosonic",
  "version": "0.3.0",
  "artifacts": [
    { "file": "Nekosonic_0.3.0_x64-setup.exe", "target": "windows", "arch": "x86_64", "kind": "nsis", "updater": true, "sig_file": "Nekosonic_0.3.0_x64-setup.exe.sig" },
    { "file": "Nekosonic.app.tar.gz", "target": "darwin", "arch": "aarch64", "kind": "app_tar_gz", "updater": true, "sig_file": "Nekosonic.app.tar.gz.sig" },
    { "file": "nekosonic_0.3.0_amd64.AppImage", "target": "linux", "arch": "x86_64", "kind": "appimage", "updater": true, "sig_file": "nekosonic_0.3.0_amd64.AppImage.sig" }
  ]
}
```

### D-15 ingest API（ホスト `ingest.nyanstall.tsuki-neko.com`、Access の Service Token 必須）

以下は設計書の D-15 をそのまま写したものである。

#### `GET /v1/ingest/{app}/releases/{version}`

- 200: 登録済み。本文は `{ "release_id": 12, "artifacts": [{ "filename": "…", "sha256": "…" }] }`。
- 404: 未登録。reusable workflow は、404 のときだけアップロードへ進む。

#### `POST /v1/ingest/{app}/releases`

```json
{
  "version": "1.0.3",
  "version_code": 1000003,
  "tag": "v1.0.3",
  "notes": "### Bug Fixes\n- …",
  "source_url": "https://github.com/kakeru-ikeda/akscrobble/releases/tag/v1.0.3",
  "published_at": "2026-11-02T10:00:00Z",
  "artifacts": [
    { "target": "android", "arch": "any", "kind": "apk", "updater": false,
      "filename": "akscrobble-1.0.3.apk",
      "r2_key": "apps/akscrobble/1.0.3/akscrobble-1.0.3.apk",
      "size": 1843200, "sha256": "9f2c…", "signature": null }
  ]
}
```

Worker が確認する順序。

1. JWT を検証する。`common_name` が `apps.ingest_client_id` と一致すること。`ingest_enabled = 1` であること。
2. 本文を Zod で検証する。
   - `r2_key` は `apps/{app}/{version}/{filename}` に一致すること。
   - Android アプリでは、`version_code` が必須であること。成果物は `kind = 'apk'` の 1 件だけであること。
   - Tauri アプリでは、`updater = true` の成果物に `signature` が必須であること。
3. R2 で各キーを `head` し、size が一致することを確認する。その後 `get` したストリームを `crypto.DigestStream('SHA-256')` に流して sha256 を照合する。
4. Android では、`version_code` がそのアプリの既存リリースの最大値より大きいこと。
5. 既に同じ version があり、成果物の sha256 の集合が完全に一致する場合は、200 `{"release_id":…, "created":false, "promoted":false}` を返す(冪等)。一致しない場合は、409 `version_conflict` を返す。
6. `releases`、`artifacts`、`audit_log` を 1 回の batch で INSERT する。`stable` の `auto_promote = 1` なら、`current_release_id` も更新する。
7. 201 `{"release_id":13, "created":true, "promoted":false}` を返す。

エラーは次のとおり。

- 401/403 `forbidden`
- 400 `invalid_body`
- 422 `object_missing` / `size_mismatch` / `sha256_mismatch` / `version_code_not_increasing`
- 409 `version_conflict`

## Goal

`tsuki-neko-com/workflows` に 2 つを追加する。1 つは、GitHub Release を nyanstall へ取り込む reusable workflow `nyanstall-publish.yml` である。もう 1 つは、署名鍵束を R2 から取って復号する composite action `actions/nyanstall-key` である。akscrobble、nekosync、nekosonic の caller は、これらを `@v1` で参照する。

## Non-goals

- `workers.yml`、`cloudflare-issue-closed.yml`、`scripts/sync-secrets.sh`、`fixtures/` の変更。
- secret を必要とする smoke 呼び出しを self-test に足すこと（ingest への接続を伴うため）。
- 各アプリのリポの caller（設計書の Task 13、17、23）。
- push、PR 作成、`v1` タグの移動、secret の登録（下記「オーケストレーターの手動作業」）。

## Design notes

- 設計判断は設計書の Task 12 と D-15、D-20 に従う。この計画では変更しない。
- 公開 API ではなく、ingest ホストだけを叩く。ingest は Access の内側にあり、Service Token のヘッダーを付ける。
- preflight の `GET` で 200 なら、成功としてスキップする。こうすると、同じ tag で再実行しても安全になる（Worker 側でも、sha256 の集合が一致すれば 200 を返す冪等性がある）。
- caller はユーザー個人アカウントのリポ（`kakeru-ikeda/*`）である。`tsuki-neko-com/workflows` は public なので、private の caller からも reusable workflow と composite action を参照できる（2026-11-01 に `gh repo view` で public を確認した）。

## 計画間の依存関係

- 上流（実運用に必要。ローカルの検証には不要）: nyanstall Task 7 の ingest API（nyanstall リポでマージ済み）。terraform-iac Task 1、2 の Access app `nyanstall-ingest`、共有 policy `nyanstall-ci-service-auth`、R2 バケット。
- 下流: 設計書の Task 13（akscrobble）、17（nekosync）、23（nekosonic）。この計画の成果物が push され、`v1` が進むまでは、各リポの caller が解決に失敗する。

## 未解決の質問

なし（設計書の質問 1〜4 は 2026-10-31 にユーザー回答済み）。

## 共通検証コマンド

```sh
actionlint
```

設計書のリポ別表（workflows は `actionlint`）に従う。Task 12 には、composite action の YAML 検証を加えたタスク別の Verify もある。

## オーケストレーターの手動作業（ワーカータスクではない）

1. ブランチ `feat/nyanstall-publish` から PR を作り、`main` へマージする。
2. `self-test` が green であることを確かめ、`git tag -f v1 && git push -f origin v1` と不変タグ `v1.4` を作る。
3. 共用の Cloudflare API トークン `nyanstall-publish`（Account → Workers R2 Storage → Edit）を Dashboard で作る。初回だけ行う。
4. Service Token をアプリごとに作り、terraform-iac の `nyanstall_ci_service_token_ids` に ID を足す（nyanstall README の手順）。
5. 各アプリのリポに、D-20 の 5 つの repository secret を登録する。`scripts/sync-secrets.sh` は `workers.yml` の caller と `CLOUDFLARE_*` だけを対象にしているので使えない。`gh secret set` で 1 件ずつ登録する。
6. 鍵束 `nyanstall-keys/{app}/{purpose}.tar.age` をアップロードする（nyanstall の `docs/keys.md`）。

### Task 12: workflows リポに nyanstall-publish.yml と nyanstall-key action を追加する

- 対象リポ: `tsuki-neko-com/workflows`
- Files to touch:
  - `.github/workflows/nyanstall-publish.yml`
  - `actions/nyanstall-key/action.yml`
  - `.github/workflows/self-test.yml`
  - `README.md`
- Files NOT to touch: `.github/workflows/workers.yml`、`.github/workflows/cloudflare-issue-closed.yml`、`scripts/sync-secrets.sh`、`fixtures/`
- New dependencies: none
- Steps:
  1. `actions/nyanstall-key/action.yml`(composite)を書く。
     - inputs: `app`、`purpose`、`out-dir`(既定 `${{ runner.temp }}/nyanstall-key`)、`api-token`、`account-id`、`age-identity`
     - 手順: age を入れる(Linux は apt、macOS は brew、Windows は公式のリリース zip)。`npx --yes wrangler@4 r2 object get "nyanstall-keys/${app}/${purpose}.tar.age" --remote --file` で取得する。identity を `umask 077` の一時ファイルへ書いて復号し、`out-dir` に展開する。identity の一時ファイルはすぐに削除する。
     - output: `dir`
     - 値を表示しない。`::add-mask::` は不要だが、`set -x` を使わない。
     - 後片付けとして、呼び出し側が最後に `rm -rf` するよう README に書く。
  2. `.github/workflows/nyanstall-publish.yml` を書く。`workers.yml` とは別の reusable workflow で、`on.workflow_call` で受ける。
     - inputs:
       - `app`(必須)
       - `tag`(必須)
       - `mode`(`android` か `tauri`、必須)
       - `asset-pattern`(android 用、既定 `*.apk`)
       - `version-code`(android では必須)
       - `ingest-url`(既定 `https://ingest.nyanstall.tsuki-neko.com`)
     - secrets を `on.workflow_call.secrets` で明示宣言する: `NYANSTALL_CF_API_TOKEN`、`NYANSTALL_CF_ACCOUNT_ID`、`NYANSTALL_ACCESS_CLIENT_ID`、`NYANSTALL_ACCESS_CLIENT_SECRET`。
     - permissions は `contents: read`。
     - 手順:
       1. secret が空なら、名前を挙げて失敗する。
       2. `gh release download "$tag"` で Release asset を取る(caller の GITHUB_TOKEN を使う)。android は `asset-pattern`、tauri は `nyanstall-artifacts.json` と、そこに列挙されたファイルを取る。
       3. version を tag から取る(`v` を除く)。
       4. preflight として `GET {ingest-url}/v1/ingest/{app}/releases/{version}` を `CF-Access-Client-Id` と `CF-Access-Client-Secret` のヘッダー付きで呼ぶ。200 ならスキップして成功で終わる。404 以外なら失敗する。
       5. 各ファイルについて、`sha256sum`、size、tauri の場合は `.sig` の中身を集め、`npx --yes wrangler@4 r2 object put "nyanstall/apps/{app}/{version}/{file}" --remote --file --content-type` でアップロードする。
       6. `jq` で D-15 の本文を作る(notes は `gh release view --json body`、source_url は Release の URL)。
       7. `POST` する。201 か 200 なら成功、それ以外は本文を表示して失敗する。
     - android では、APK がちょうど 1 つでなければ失敗する。xapk は対象外。
  3. `self-test.yml` は actionlint の対象になるので、変更は不要か確認する。secret を必要とする smoke 呼び出しは追加しない。ingest への接続を伴うため。
  4. `README.md` に、nyanstall-publish の caller 例、必要な secret(D-20)、Android と Tauri の違い、`@v1` の運用を追記する。
- Acceptance: `actionlint` が全 workflow で緑。composite action の YAML が有効(`python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' actions/nyanstall-key/action.yml` が成功)。
- Verify: `actionlint && python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' actions/nyanstall-key/action.yml`
