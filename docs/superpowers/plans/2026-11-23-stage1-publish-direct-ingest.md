# 段階 1: nyanstall-publish の直接取り込み、beta と prerelease、台帳の composite action

- 日付: 2026-11-23
- 正本の設計: `tsuki-neko-com/nekosonic` の `docs/superpowers/specs/2026-11-23-release-and-test-distribution-design.md` (7.3 節、9.3 節、9.6 節、11 節の段階 1、13 節)
- 対象リポジトリ: `tsuki-neko-com/workflows` (このリポ)
- 依存: `tsuki-neko-com/nyanstall` の計画 `docs/superpowers/plans/2026-11-23-stage1-nyanstall-ledger.md`
  - この計画の「API 契約」は、nyanstall の計画の同名の節を写したものである。食い違った場合は nyanstall 側を正とする。
  - 実装 (Task 1〜5) は、ライブの API が無くても進められる。どのテストも dry-run と、偽の curl で行う。
  - **main への merge と `v1` の移動は、nyanstall の計画の Task 1〜12 が本番に deploy された後に行う** (末尾の手作業の節)。それより前に `v1` を進めると、caller が新しい入力を使ったときに、本番の nyanstall が 400 を返す。
- 範囲: 段階 1 だけ。nekosonic 側の caller (testing.yml など) は段階 2 で作る。

## 未解決の質問

ユーザーの判断が要る未決事項はない。以下はビルダー判断として決めた点である。

1. iOS の記録は `nyanstall-publish.yml` に `mode: ios` を足さず、Node に依存しない composite action `actions/nyanstall-ledger` で行う。理由は Design notes D-3 を参照。
2. 設計 9.6 にある入力 `product-version-id` は、`product-version` (版の文字列) に替える。nyanstall の台帳の API は、版の文字列で版を指す。

## 共通の検証コマンド (`--verify`)

```sh
bash scripts/verify.sh
```

- `scripts/verify.sh` は Task 1 で作る。actionlint (shellcheck との連携を含む) と、`actions/*/test.sh` を実行する。
- sdd-worker の実行例: `sdd-worker next docs/superpowers/plans/2026-11-23-stage1-publish-direct-ingest.md --verify 'bash scripts/verify.sh'`
- 最終的な正は、GitHub 上の `self-test.yml` (actionlint、smoke、smoke-subdir、この計画で足す dry-run のジョブ) である。オーケストレーターは、PR を push した後に、self-test が緑であることを確かめる。

## オーケストレーターの事前作業

1. 機能ブランチ `feat/stage1-publish-direct-ingest` を main から切る。
2. ローカルのツールを入れる (ワーカーのサンドボックスにはネットワークが無い): `brew install actionlint shellcheck`。self-test と同じく actionlint 1.7.7 以上を使う。`jq` と `curl` は入っている。
3. npm の依存は無い。ルートの `package.json` は self-test の fixture なので、変えない。

## Goal

- `nyanstall-publish.yml@v1` に入力を足す。足すのは、GitHub Release を経由しない直接取り込み (`source: artifact`)、`channel` (stable / beta)、prerelease を含む `version`、`git-sha` と `git-ref`、台帳との連携 (`product`、`product-version`)、`dry-run` である。
- 既存の caller の挙動を変えない。対象は nekosync (android、GitHub Release) と nekosonic desktop (tauri、GitHub Release、ジョブで `permissions: contents: read`) である。
- Node に依存しない composite action `actions/nyanstall-ledger` を足す。台帳の API を、bash、curl、jq で呼ぶ。self-hosted の Mac からも使えるようにする。
- self-test に、新しい入力の経路 (artifact の取り込み、beta、prerelease、台帳の action) を足す。smoke と smoke-subdir の 2 系統は、緑のまま保つ。

## Non-goals

- nyanstall の Worker の変更。これは nyanstall の計画で扱う。
- nekosonic、nekosync の caller の変更。
- v2 を切ること。この計画の変更は、すべて後方互換である。
- `workers.yml` の変更。
- 本番の nyanstall に対する結合テスト。self-test は dry-run だけで行う。

## Global Constraints (全タスク共通)

- **後方互換を守る。**
  - 既存の入力 (`app`、`tag`、`mode`、`asset-pattern`、`version-code`、`ingest-url`) の名前、型、既定値、意味を変えない。
  - `source` の既定値 (`github-release`) で新しい入力を何も指定しなかった場合、R2 のキー、ingest へ送る本文、HTTP の呼び出しの順序を、今と 1 バイトも変えない。新しい項目 (`channel`、`git_sha`、`git_ref`) は、入力が指定されたときか、`source: artifact` のときだけ本文に入れる。
  - `tag` が `v` で始まる、という検査は、`source: github-release` では残す。
- **権限を増やさない。** `nyanstall-publish.yml` の `permissions` は、`contents: read` だけのままにする。
  - nekosonic の caller は、ジョブで `permissions: contents: read` を指定している。reusable workflow が権限を 1 つでも足すと、caller が startup_failure になる。
  - 同じ run の artifact を `actions/download-artifact@v4` で取るのに、追加の権限は要らない (runtime token を使う)。実装の前に、action の README で確かめる。
- **secrets は `required: false` に変える** (dry-run の self-test が secret なしで呼べるようにするため)。
  - 既存の caller は、どれも 4 つの secret を明示して渡している。したがって、この変更は後方互換である。
  - 実行時の「空なら名指しして失敗する」検査は、`dry-run: false` のときに今までどおり行う。
- シークレットを、ログ、コマンドライン引数、ファイル (一時ファイルを除く) に出さない。Access のヘッダーは、`umask 077` で作った一時ファイルに書いて `curl -H @<file>` で渡す。trap で消す。新しく書くコードはこの形にする。既存の `nyanstall-publish.yml` の `-H "CF-Access-...: $VAR"` は、触る行だけ直す。
- `actions/nyanstall-ledger` のスクリプトは、macOS の `/bin/bash` (3.2) で動くようにする。連想配列、`${var,,}`、`mapfile`、GNU 固有の `stat -c`、`find -printf`、`sha256sum` を使わない。依存は `bash`、`curl`、`jq` だけにする。
- エンジンは `.git` に書き込まない。commit、push、タグの操作 (`v1` の移動) は行わない。
- 既存の書き方 (`set -euo pipefail`、`::error::` の出し方、英語の `description`) に合わせる。

## Review Focus (オーケストレーターが差分で見る点)

1. `source: github-release` の経路で、新しい入力を何も指定しない場合に、本文と R2 のキーが変わらないこと。`git diff` で、既存の分岐の中の変更を 1 行ずつ確かめる。
2. `permissions` が `contents: read` のままであること。
3. `secrets.*.required: false` にした後も、`dry-run: false` のときは、空の secret で必ず失敗すること。
4. dry-run のときに、`wrangler r2 object put` と ingest への HTTP を一度も呼ばないこと。
5. secret の値が、`echo`、`set -x`、コマンドライン引数に出ていないこと。
6. self-test の smoke と smoke-subdir の定義に差分が無いこと。

## Design notes

### D-1 直接取り込みは、同じ run の artifact から取る

- reusable workflow は、caller とは別のジョブ (別の runner) で動く。そのため、caller の作業ディレクトリのパスは渡せない。
- `source: artifact` では、caller が同じ run で `actions/upload-artifact@v4` に上げた artifact を、`artifact-name` で指定させる。publish の側は、`actions/download-artifact@v4` で `release-assets/` に展開する。
- 展開した後の処理は、今の GitHub Release の経路と同じにする。android は `*.apk` がちょうど 1 つ。tauri は `nyanstall-artifacts.json` と、そこに書かれたファイルと `.sig` である。
- 却下した案: `artifact-path` (パス渡し)。ジョブをまたげないので、使えない。

### D-2 版、タグ、チャネル

- `source: github-release` のとき、版は今までどおり `tag` から `v` を外して作る。
- `source: artifact` のとき、`version` は必須である。`tag` は任意の文字列 (例 `beta/0.2.14-beta.3`) でよい。`v` で始まる必要は無い。
- `version` の検証は、nyanstall と同じ規則にする: `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$`。
- `channel` は `stable` (既定) か `beta` である。stable なら prerelease を持たないこと、beta なら prerelease を持つことを、送る前に検査する。nyanstall 側も同じ検査をする。
- `source: artifact` のとき、本文の `notes` は入力の `notes` (既定は空) にする。`source_url` は入力の `source-url` にする。既定は `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}` である。`published_at` は実行時刻の UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`) にする。
- `git-sha` を省略した場合: `source: artifact` では `github.sha` を使う。`source: github-release` では本文に入れない (Global Constraints)。`git-ref` も同じ扱いで、既定は `github.ref_name` である。

### D-3 iOS の記録と台帳の操作は composite action にする

- iOS のビルドは self-hosted の Mac で行う。reusable workflow は `runs-on: ubuntu-latest` に固定されている。iOS の記録には使えない。
- composite action は、呼んだジョブの runner の上で動く。そのため、Mac からも Linux からも使える。
- 台帳の操作には、beta の N の払い出し、版の作成、OS 別の状態の更新、前回の成功の取得、iOS のビルド番号の払い出しがある。これらは段階 2 の nekosonic の workflow が、ジョブの途中で何度も呼ぶ。1 回で終わる reusable workflow より、step として呼べる action が合う。
- 却下した案: `nyanstall-publish.yml` に `mode: ios` を足す案。Mac の runner で動かせず、`ubuntu-latest` のジョブが 1 つ余計に増える。

### D-4 publish と台帳の連携

- `product` と `product-version` の両方が指定され、ingest が 201 か 200 を返した場合 (preflight で登録済みと分かった場合を含む)、publish は次を呼ぶ: `PATCH /v1/ingest/products/{product}/versions/{product-version}/targets/{app}`、本文 `{ "state": "published", "release_id": <id> }`。
- 片方だけが指定された場合は、入力の検査で失敗させる。
- 台帳の更新が失敗した場合は、ジョブを失敗させる。release は登録済みなので、再実行すると preflight の 200 の経路を通り、台帳の更新だけをやり直せる。

### D-5 dry-run

- `dry-run: true` のときは、次を行わない: secret の検査、R2 への put、preflight、ingest への POST、台帳の PATCH。
- その代わりに、組み立てた本文と、送るはずだった要求 (メソッドと URL) を、ログとジョブの outputs に出す。
- self-test は、outputs を jq で検査する。
- `source: github-release` の dry-run は self-test で扱わない。workflows のリポに検査用の Release を置かないためである。この経路は Review Focus 1 で担保する。

## API 契約 (nyanstall の計画の写し。こちらは参照用)

ホスト: `https://ingest.nyanstall.tsuki-neko.com`。どの呼び出しにも `CF-Access-Client-Id` と `CF-Access-Client-Secret` を付ける。エラーの本文は `{ "error": { "code", "message" } }` である。

### release の取り込み

- `GET /v1/ingest/{app}/releases/{version}` → 200 `{ release_id, artifacts, channel }` または 404。`version` に prerelease を受け付ける。
- `POST /v1/ingest/{app}/releases`
  - 本文は既存の項目に、次の任意の項目を足したものである: `channel` (`stable|beta`、既定 `stable`)、`git_sha` (40 桁の 16 進)、`git_ref` (1〜100 文字)。
  - ios の app では、`artifacts: []` で、`version_code` (払い出し済みのビルド番号) が必須である。
  - 応答: 201 `{ release_id, created: true, promoted }`、200 `{ release_id, created: false, promoted: false }`、409、422、400。

### 台帳 (接頭辞 `/v1/ingest/products/{product}`)

| ledger action の `command` | メソッドとパス | 本文 / クエリ | 成功時 |
|---|---|---|---|
| `next-beta` | `POST .../beta-numbers` | `{ "base_version": "0.2.14" }` | 201 `{ base_version, n, version }` |
| `create-version` | `POST .../versions` | `{ version, channel, git_sha, git_ref, tag, prs: [{ pr_number?, title?, url?, head_sha?, merged_sha }], targets: [{ app, state, reason?, base_sha?, build_meta? }] }` | 201 / 200 (同じ版、同じ sha) |
| `get-version` | `GET .../versions/{version}` | — | 200 (404 も正常な結果として返す) |
| `update-target` | `PATCH .../versions/{version}/targets/{app}` | `{ state, reason?, release_id?, build_meta? }` | 200 |
| `last-success` | `GET .../last-success?app={app}&channel={channel}` | — | 200 `{ found, version?, git_sha? }` |
| `ios-build-number` | `POST .../ios-build-numbers` | `{ app, version? }` | 201 `{ app, build_number }` |
| `pr-betas` | `GET .../prs/{pr_number}` | — | 200 `{ pr_number, betas: [...] }` |
| `record-ios-release` | `POST /v1/ingest/{app}/releases` | `{ version, version_code, tag, notes, source_url, published_at, channel, git_sha?, git_ref?, artifacts: [] }` | 201 / 200 |

- `state`: `skipped` / `pending` / `waiting` / `building` / `uploaded` / `published` / `failed`。
- `reason`: `skipped` のとき `no_change` / `disabled`、`waiting` のとき `queued` / `manual_required`、`failed` のとき自由な文字列、それ以外の state では無し。

---

### Task 1: ローカルの検証スクリプトを足す

- Files to touch: `scripts/verify.sh` (新規)
- Files NOT to touch: `.github/workflows/**`、`actions/**`、`package.json`、`fixtures/**`
- New dependencies: actionlint 1.7.7 以上、shellcheck (Homebrew。オーケストレーターが入れる)
- Interfaces: `bash scripts/verify.sh`。成功なら 0 で終わり、失敗なら非 0 で終わる。
- Steps:
  1. `set -euo pipefail` で書く。リポのルートへ `cd` する (`$(dirname "$0")/..`)。
  2. `actionlint` が PATH に無ければ、`brew install actionlint shellcheck` を案内して 1 で終わる。黙って飛ばさない。
  3. `actionlint -color` を実行する。
     - brew で入れた actionlint や shellcheck は、CI の docker イメージ (actionlint 1.7.7) より新しい場合がある。その差だけが原因で、既存の `.github/workflows/**` に指摘が出ることがある。このタスクでは `.github/workflows/**` を触れない。指摘の原因がバージョンの差だけなら、修正せずに report に書いて報告する。
  4. `actions/*/test.sh` を順に `bash` で実行する。1 つも無い場合は、何もせずに通す。
  5. `scripts/*.sh` と `actions/**/*.sh` に `bash -n` を実行する。
- Acceptance: 現在の main の内容で、`bash scripts/verify.sh` が 0 で終わる。
- Verify: `bash scripts/verify.sh`
- オーケストレーター向け: commit メッセージ案 `ci: ローカルの検証スクリプトを追加する`

### Task 2: nyanstall-publish に直接取り込み、チャネル、prerelease、dry-run を足す

- Files to touch:
  - `.github/workflows/nyanstall-publish.yml`
  - `.github/workflows/self-test.yml` (ジョブを足すだけ)
  - `fixtures/nyanstall/` (新規。self-test 用の偽の成果物を作るスクリプトか、小さなファイル)
- Files NOT to touch: `.github/workflows/workers.yml`、`self-test.yml` の既存のジョブ (`actionlint`、`smoke`、`smoke-subdir`)、`package.json`、`fixtures/subdir/**`、`actions/nyanstall-key/**`
- New dependencies: none (`actions/upload-artifact@v4` と `actions/download-artifact@v4` は GitHub の action である。ローカルへのインストールは要らない)
- Interfaces (`on.workflow_call.inputs` に足すもの。どれも `required: false`):

  | 入力 | 型 | 既定値 | 意味 |
  |---|---|---|---|
  | `source` | string | `github-release` | `github-release` か `artifact` |
  | `artifact-name` | string | `''` | `source: artifact` のときに必須。同じ run の artifact の名前 |
  | `version` | string | `''` | `source: artifact` のときに必須。prerelease を許す (D-2) |
  | `channel` | string | `stable` | `stable` か `beta` |
  | `git-sha` | string | `''` | D-2 |
  | `git-ref` | string | `''` | D-2 |
  | `notes` | string | `''` | `source: artifact` のときの notes |
  | `source-url` | string | `''` | `source: artifact` のときの source_url。空なら run の URL |
  | `dry-run` | boolean | `false` | D-5 |

  - `on.workflow_call.outputs`: `payload` (組み立てた本文の JSON を 1 行にしたもの)、`release-id` (dry-run では空)、`version`。ジョブの outputs から渡す。
  - `secrets` の 4 つを `required: false` にする (Global Constraints)。
- Steps:
  1. 入力の検査の step を広げる。
     - `source` の値、`channel` の値を検査する。
     - `source: artifact` のとき、`artifact-name` と `version` が必須である。`version` の形は D-2 で検査する。
     - チャネルと prerelease の対応を検査する。
     - `source: github-release` のとき、`version` が指定されていたら失敗させる (版は tag から作るため。誤用を防ぐ)。
     - secret の検査は `dry-run` が false のときだけ行う。
  2. 成果物を取る step を、`source` で分ける。`github-release` の分岐は、今の step の中身をそのまま使う。`artifact` の分岐は、`actions/download-artifact@v4` (`name: ${{ inputs.artifact-name }}`、`path: release-assets`) を `if:` 付きの別の step にして、その後に今と同じ数の検査 (APK がちょうど 1 つ、`nyanstall-artifacts.json` とファイルと `.sig` がある) を行う。
  3. publish の step を変える。
     - 版、notes、source_url、published_at の決め方を、`source` で分ける (D-2)。
     - 本文に `channel`、`git_sha`、`git_ref` を足す条件は、Global Constraints のとおりにする。
     - `dry-run` のときは、R2 の put、preflight、POST を行わない。本文を `$GITHUB_OUTPUT` の `payload` に書き、ログにも出す。
     - 新しく書く curl の呼び出しは、ヘッダーのファイル (`-H @file`) を使う。
  4. `self-test.yml` にジョブを足す。
     - `publish-fixtures`: 偽の APK (任意のバイト列で `selftest.apk`) と、tauri の一式 (`nyanstall-artifacts.json` に、更新用の nsis 1 つと `.sig`、更新用でない deb 1 つ) を作り、`upload-artifact@v4` で 2 つの artifact として上げる。
     - `publish-android-beta`: `uses: ./.github/workflows/nyanstall-publish.yml`、`needs: publish-fixtures`。`with:` は次のとおり: `app: selftest-android`、`mode: android`、`tag: beta/0.2.14-beta.1`、`source: artifact`、`artifact-name: <APK の artifact>`、`version: 0.2.14-beta.1`、`channel: beta`、`version-code: "201401"`、`dry-run: true`。secret は渡さない。
     - `publish-tauri-beta`: 同じ形の tauri 版。
     - `publish-assert`: 2 つの outputs を jq で検査する。検査する項目: `version`、`channel` (`beta`)、`git_sha` (40 桁)、`artifacts` の数と `r2_key` (`apps/<app>/0.2.14-beta.1/<file>`)、`sha256` (64 桁)、android の `version_code` (201401)、tauri の更新用の成果物の `signature` が null でないこと。
     - 新しいジョブも、`self-test.yml` の既存の `permissions` (`contents: read`、`packages: read`) の中で動くこと。
  5. `bash scripts/verify.sh` を通す。
- Acceptance:
  - actionlint が通る。
  - Review Focus 1〜4、6 を満たす。
  - `nyanstall-publish.yml` の `permissions` は `contents: read` だけである。
  - 新しい self-test のジョブは、PR の上で緑になる (オーケストレーターが push の後に確かめる)。
- Verify: `bash scripts/verify.sh`
- オーケストレーター向け: commit メッセージ案 `feat(nyanstall-publish): artifact からの直接取り込みと beta、prerelease、dry-run に対応する`

### Task 3: nyanstall-publish から台帳の OS 別の状態を更新する

- Files to touch:
  - `.github/workflows/nyanstall-publish.yml`
  - `.github/workflows/self-test.yml` (Task 2 のジョブの `with:` と、assert を広げるだけ)
- Files NOT to touch: `workers.yml`、`self-test.yml` の `actionlint`、`smoke`、`smoke-subdir`、`actions/**`
- New dependencies: none
- Interfaces:
  - 入力 `product` (string、既定 `''`)、`product-version` (string、既定 `''`) を足す。
  - outputs に `target-request` (dry-run のときに送るはずだった PATCH のメソッド、URL、本文の JSON) を足す。
- Steps:
  1. 入力の検査に、「`product` と `product-version` は両方を指定するか、両方を空にする」を足す。
  2. ingest が 201 か 200 を返した後、または preflight で登録済み (200) と分かった後に、D-4 の PATCH を送る。preflight の 200 の応答から `release_id` を読む。現在の preflight の分岐は `exit 0` で終わっているので、その後に台帳の更新ができるように構造を直す。`product` が空のときの挙動は今と同じにする。
  3. PATCH の応答が 200 でなければ、本文を出して失敗させる。
  4. dry-run では PATCH を送らず、`target-request` に出す。
  5. self-test の `publish-android-beta` に `product: selftest`、`product-version: 0.2.14-beta.1` を足す。assert で、`target-request` の URL が `/v1/ingest/products/selftest/versions/0.2.14-beta.1/targets/selftest-android` であることと、本文の `state` が `published` であることを確かめる。`publish-tauri-beta` には足さない (`product` を指定しない経路を残す)。
- Acceptance:
  - actionlint が通る。
  - `product` が空のときは、Task 2 の後と同じ挙動である。
  - Review Focus 1〜6 を満たす。
- Verify: `bash scripts/verify.sh`
- オーケストレーター向け: commit メッセージ案 `feat(nyanstall-publish): 取り込みの後に台帳の OS 別の状態を published にする`

### Task 4: 台帳を操作する composite action `actions/nyanstall-ledger` を足す

- Files to touch:
  - `actions/nyanstall-ledger/action.yml` (新規)
  - `actions/nyanstall-ledger/ledger.sh` (新規)
  - `actions/nyanstall-ledger/test.sh` (新規)
  - `.github/workflows/self-test.yml` (ジョブを足すだけ)
- Files NOT to touch: `.github/workflows/nyanstall-publish.yml`、`workers.yml`、`actions/nyanstall-key/**`、`self-test.yml` の既存のジョブ
- New dependencies: none
- Interfaces (`action.yml`):
  - inputs:
    - `command` (必須。API 契約の表の左の列の値)
    - `product`
    - `app`
    - `version`
    - `channel`
    - `pr-number`
    - `body` (JSON の文字列。`create-version`、`update-target`、`next-beta`、`ios-build-number`、`record-ios-release` で使う)
    - `ingest-url` (既定 `https://ingest.nyanstall.tsuki-neko.com`)
    - `access-client-id`
    - `access-client-secret`
    - `dry-run` (既定 `'false'`)
  - outputs:
    - `status`: HTTP の status。dry-run では `dry-run`
    - `response`: 応答の JSON を 1 行にしたもの。dry-run では送るはずだった要求 `{ method, url, body }`
  - `runs.using: composite`。step は 1 つで、`bash "$GITHUB_ACTION_PATH/ledger.sh"` を呼ぶ。入力は環境変数 (`LEDGER_COMMAND`、`LEDGER_PRODUCT`、…、`LEDGER_ACCESS_CLIENT_ID`、`LEDGER_ACCESS_CLIENT_SECRET`、`LEDGER_DRY_RUN`、`LEDGER_INGEST_URL`) で渡す。
- Steps:
  1. 先に `test.sh` を書く (赤)。
     - 一時ディレクトリに偽の `curl` を置き、PATH の先頭に入れる。偽の `curl` は、受け取った引数とヘッダーのファイルの中身を記録する。応答は環境変数 `FAKE_STATUS` と `FAKE_BODY` で返す。`--write-out '%{http_code}'` と `--output <file>` を解釈する。
     - `GITHUB_OUTPUT` は一時ファイルにする。
     - 各 `command` について、メソッド、URL、本文、outputs を確かめる。
     - 必須の入力が欠けていれば、非 0 で終わることを確かめる (例: `update-target` で `app` が無い)。
     - 2xx 以外では非 0 で終わり、`::error::` を出すことを確かめる。ただし `get-version` の 404 は 0 で終わり、`status=404` を出す。
     - dry-run では、curl を呼ばないことを確かめる。
     - secret の値が、stdout、stderr、偽の curl が記録した引数のどれにも現れないことを確かめる。ヘッダーのファイルの中にだけ現れること。
     - `body` が不正な JSON なら、送る前に失敗することを確かめる。
     - `test.sh` の中から `ledger.sh` を呼ぶときは、PATH の `bash` ではなく `"$BASH"` (test.sh を実行しているシェル自身) で呼ぶ。こうすると、`/bin/bash actions/nyanstall-ledger/test.sh` と実行したときに、ledger.sh も macOS の bash 3.2 で検査される。
  2. `ledger.sh` を実装する。
     - command からメソッドとパスへの対応は、API 契約の表のとおりにする。
     - パスに入れる値 (`product`、`app`、`version`、`pr-number`) は、`^[A-Za-z0-9._-]+$` に一致することを検査してから使う。
     - `body` は `jq -c .` で検証し、整形する。
     - ヘッダーのファイルは `umask 077` で作り、trap で消す。
  3. `self-test.yml` に `ledger-action` ジョブを足す。中身は 2 つの step である: `bash actions/nyanstall-ledger/test.sh` と、`uses: ./actions/nyanstall-ledger` を `command: next-beta`、`product: selftest`、`body: '{"base_version":"0.2.14"}'`、`dry-run: 'true'` で呼び、outputs の `status` が `dry-run` であることを確かめる step。
- Acceptance:
  - `bash actions/nyanstall-ledger/test.sh` と `/bin/bash actions/nyanstall-ledger/test.sh` が 0 で終わる。
  - actionlint が通る。
  - Review Focus 5 を満たす。
- Verify: `bash scripts/verify.sh && /bin/bash actions/nyanstall-ledger/test.sh`
- オーケストレーター向け: commit メッセージ案 `feat: 台帳を操作する composite action nyanstall-ledger を追加する`

### Task 5: README を更新する

- Files to touch: `README.md`
- Files NOT to touch: `.github/**`、`actions/**`、`scripts/**`
- New dependencies: none
- Steps:
  1. 「nyanstall への Release 公開」の節に、次を足す。
     - 新しい入力の表 (Task 2、Task 3)
     - `source: artifact` の caller の例 (同じ run で `upload-artifact@v4` に上げ、`needs` で publish を呼ぶ。beta で prerelease の例)
     - secret を `required: false` にした理由 (dry-run の self-test のため。dry-run でなければ今までどおり必須)
     - caller の `permissions` は `contents: read` で足りること
  2. 「nyanstall の台帳」の節を新しく作り、`actions/nyanstall-ledger` の入力と出力、`command` の一覧と使い方の例を書く。例は、beta の N の払い出し、版の作成、状態の更新、iOS のビルド番号、記録のみの iOS release である。
     - 依存は bash、curl、jq だけで、self-hosted の Mac でも動くこと
     - jq を Mac の runner に入れておく必要があること
  3. self-test の説明に、dry-run のジョブと ledger のジョブを足す。
  4. 「現在の次のタグ」の記述は、手作業の節で `v1.4` を作った後に、オーケストレーターが `v1.5` へ直す。このタスクでは変えない。
  5. シークレットの値も client ID の実値も書かない。
- Acceptance: README に、新しい入力、ledger action、self-test の説明がある。`bash scripts/verify.sh` が通る。
- Verify: `bash scripts/verify.sh`
- オーケストレーター向け: commit メッセージ案 `docs: nyanstall-publish の新しい入力と台帳の action を README に書く`

---

## main への merge と v1 の移動 (オーケストレーターとオーナーの手作業。エンジンには実行させない)

前提: nyanstall の計画の「本番適用」の D (deploy) まで終わっていて、本番の ingest が prerelease、beta、台帳の API を受け付ける状態にある。

1. PR を push し、self-test の全部のジョブ (`actionlint`、`smoke`、`smoke-subdir`、`publish-*`、`ledger-action`) が緑であることを確かめる。
2. main へ squash merge する。main の上で self-test が緑になるのを待つ。
3. 戻すときのために、今の `v1` が指す sha を控える: `git rev-parse v1`。
4. README の手順に従って `v1` を進め、不変タグ `v1.4` を作る: `git tag -f v1 && git push -f origin v1`、`git tag v1.4 && git push origin v1.4`。README の「現在の次のタグ」を `v1.5` に直し、別の commit にする。
5. 既存の caller の確認: nekosync と nekosonic の次のリリースで、publish のジョブが今までどおり通ることを確かめる。待てない場合は、caller の release workflow に `workflow_dispatch` があれば、既存のタグを渡して再実行する。preflight で登録済み (200) と分かるので、何も書き込まずに終わる。
6. 戻し方: 既存の caller が壊れた場合は、`v1` を 3 で控えた sha に戻す (`git tag -f v1 <sha> && git push -f origin v1`)。これで、全部の caller が即座に元に戻る。`v1.4` は消さずに残す。原因を直した後、もう一度 4 から行う。
