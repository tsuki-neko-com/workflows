# tsuki-neko-com/workflows 共通 reusable workflow の構築

対象リポジトリ: `/home/server/github/workflows`（将来 `tsuki-neko-com/workflows` として public 公開）
設計仕様: `/home/server/github/ameownt/docs/superpowers/specs/2026-08-02-org-shared-ci-cd-design.md`（§4, §5, §6, §8）

## 計画間の依存関係

本計画は 3 本の計画のうち **1 本目**であり、他の 2 本より先に完了させる必要がある。

1. **本計画** `/home/server/github/workflows/docs/plans/2026-08-02-workers-reusable-workflow.md`
2. `/home/server/github/ameownt/docs/plans/2026-08-02-adopt-shared-ci.md`
3. `/home/server/github/nekotune/docs/plans/2026-08-02-adopt-shared-ci.md`

理由: 2 と 3 の caller は `tsuki-neko-com/workflows/.github/workflows/workers.yml@v1` を参照する。
本計画の成果物が push され `v1` タグが作成されるまで、2 と 3 の CI は解決に失敗する。
ローカルの検証コマンド（`npm run lint` / `npm run typecheck` / `vitest`）は GitHub 上の
ワークフロー解決に依存しないため、2 と 3 の**ワーカー作業自体**は本計画完了前でも実行できるが、
**PR を作って CI を green にする段階**は本計画の完了後でなければならない。

## Goal

`tsuki-neko-com/workflows` リポジトリに、Cloudflare Workers リポジトリ共通の
reusable workflow（`on: workflow_call`）と、その自己検証用ワークフロー・最小 fixture・
README を作成する。各利用リポジトリは 10〜12 行の caller のみを持つ状態にする。

## Non-goals

- 実際の GitHub へのリポジトリ作成、push、`v1` タグ作成（オーケストレーターが手動で実施）。
- org secrets（`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`）の登録（仕様 §9 Step 1。GitHub の Web UI 作業）。
- preview / staging デプロイ、ロールバック自動化、Environment 承認ゲート（仕様 §13）。
- `tsuki-neko-com/.github` リポジトリの作成と starter workflow 化（仕様 §13）。

## Design notes

- **workers.yml は 1 本にまとめる**（仕様 §4.1）。CI 用と deploy 用に分けると `verify` → `deploy`
  の順序保証を各リポの caller に書く責任が戻り、共通化の効果が薄れる。
- **inputs は 3 つのみ**（`node-version` / `d1-database` / `deploy-enabled`、仕様 §4.2）。
  コマンド内容は inputs で受け取らず、npm script 規約（仕様 §5）で固定する。
- **secrets は `workflow_call.secrets` に `required: false` で明示宣言する**。
  仕様 §4.2 は「`secrets: inherit` で受ける」としており、caller 側は `secrets: inherit` のままだが、
  reusable workflow 側で宣言しておかないと actionlint が未定義 secret 参照として指摘する可能性がある。
  `required: false` 宣言と `secrets: inherit` は併用可能で、caller の記述は仕様どおり変わらない。
  self-test のダミー caller のように secret が未設定の環境でもワークフローが失敗しない利点もある。
- **actionlint は公式 Docker コンテナアクション `docker://rhysd/actionlint:1.7.7` を使う**（バージョン固定）。
  採用しなかった案: (a) リリースバイナリを curl で取得するインストールスクリプト方式 —
  ネットワーク経路と検証手順が増える。(b) `latest` タグ — 上流更新で突然 CI が赤くなる。
  Docker コンテナアクションは Linux ランナー（`ubuntu-latest`）でのみ動作するが、
  本ワークフローは `ubuntu-latest` 固定なので問題にならない。
- **ローカルには actionlint バイナリが無い**ため、ワーカーの検証ゲートは
  「PyYAML による YAML 構文パース」＋「fixture の `npm run ci`」に限定する。
  actionlint による静的検査は GitHub 上の `self-test.yml` に委ねる（仕様 §11 の表と同じ役割分担）。
- **fixture の `build` は意図的に未定義**にする（仕様 §8）。`has-build` 判定が false 側へ倒れる経路を
  self-test で同時に検証するため。

## 未解決の質問

なし。

## 共通検証コマンド

`sdd-worker` の `--verify` に渡す値（全タスク共通）:

```
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]; print('yaml ok')" && npm run ci
```

- python3 3.x + PyYAML 6.0.1 はローカルで利用可能（確認済み）。
- Task 1 で `package.json` を作成するため、Task 1 以降は `npm run ci` が成功する。
- 依存パッケージのインストールは不要（fixture は依存ゼロ）。

## オーケストレーターの手動作業（ワーカータスクではない）

全タスク完了後に、以下を上から順に実施する。

1. GitHub に public リポジトリ `tsuki-neko-com/workflows` を作成し、`main` を push する。
2. `self-test.yml` が green であることを確認する（actionlint エラー 0、ダミー caller の
   `verify` が成功、`deploy` がスキップされる）。
3. `git tag v1 && git push origin v1` および不変タグ `git tag v1.0 && git push origin v1.0`（仕様 §12）。
4. org secrets（`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`）を登録する（仕様 §9 Step 1）。

---

### Task 1: self-test 用の最小 fixture と .gitignore を作成する

対応: TASK-001

- Files to touch:
  - `/home/server/github/workflows/package.json`（新規）
  - `/home/server/github/workflows/package-lock.json`（新規）
  - `/home/server/github/workflows/.gitignore`（新規）
- Files NOT to touch: `/home/server/github/workflows/.github/**`, `/home/server/github/workflows/docs/**`
- New dependencies: none（fixture は依存ゼロ。`npm install` は実行しない）
- Steps:
  1. `/home/server/github/workflows/package.json` を以下の内容で新規作成する。

     ```json
     {
       "name": "workflows",
       "version": "0.0.0",
       "private": true,
       "description": "self-test fixture for the reusable workflow. Not a real project.",
       "scripts": {
         "ci": "echo \"self-test fixture: ci ok\"",
         "deploy": "echo \"self-test fixture: deploy ok\""
       }
     }
     ```

     `scripts.build` は**定義しない**（`has-build` 判定の false 経路を self-test で検証するため）。
     `scripts.migrate:remote` も定義しない（ダミー caller は `d1-database: ""` で呼ぶためスキップされる）。
  2. `/home/server/github/workflows/package-lock.json` を以下の内容で新規作成する
     （`npm ci` に必須。依存ゼロでも lockfile が要る）。

     ```json
     {
       "name": "workflows",
       "version": "0.0.0",
       "lockfileVersion": 3,
       "requires": true,
       "packages": {
         "": {
           "name": "workflows",
           "version": "0.0.0"
         }
       }
     }
     ```
  3. `/home/server/github/workflows/.gitignore` を以下の 1 行の内容で新規作成する。

     ```
     node_modules/
     ```
- Acceptance:
  - `npm ci` がリポジトリルートで exit 0 で終了する。
  - `npm run ci` が exit 0 で終了し、標準出力に `self-test fixture: ci ok` を含む。
  - `npm run deploy` が exit 0 で終了し、標準出力に `self-test fixture: deploy ok` を含む。
  - `npm pkg get scripts.build` の出力が厳密に `{}` である。
  - `.gitignore` の内容が `node_modules/` の 1 行である。
- Verify:

  ```
  cd /home/server/github/workflows && npm ci && npm run ci && npm run deploy && test "$(npm pkg get scripts.build)" = "{}" && python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]; print('yaml ok')"
  ```

---

### Task 2: reusable workflow 本体 workers.yml を作成する

対応: TASK-002

- Files to touch: `/home/server/github/workflows/.github/workflows/workers.yml`（新規）
- Files NOT to touch: `/home/server/github/workflows/package.json`, `/home/server/github/workflows/package-lock.json`, `/home/server/github/workflows/.github/workflows/self-test.yml`
- New dependencies: none
- Steps:
  1. `/home/server/github/workflows/.github/workflows/workers.yml` を以下の内容そのままで新規作成する。

     ```yaml
     name: Workers CI/CD

     on:
       workflow_call:
         inputs:
           node-version:
             description: "Node.js version passed to actions/setup-node"
             type: string
             required: false
             default: "22"
           d1-database:
             description: "Cloudflare D1 database name. An empty string skips the migration step"
             type: string
             required: false
             default: ""
           deploy-enabled:
             description: "Set to false to skip the deploy job entirely"
             type: boolean
             required: false
             default: true
         secrets:
           CLOUDFLARE_API_TOKEN:
             required: false
           CLOUDFLARE_ACCOUNT_ID:
             required: false

     permissions:
       contents: read

     concurrency:
       group: ${{ github.workflow }}-${{ github.ref }}
       cancel-in-progress: ${{ github.event_name == 'pull_request' }}

     jobs:
       verify:
         runs-on: ubuntu-latest
         steps:
           - uses: actions/checkout@v4
           - uses: actions/setup-node@v4
             with:
               node-version: ${{ inputs.node-version }}
               cache: npm
           - name: Install dependencies
             run: npm ci
           - name: Detect build script
             id: has-build
             run: |
               if [ "$(npm pkg get scripts.build)" = "{}" ]; then
                 echo "value=false" >> "$GITHUB_OUTPUT"
               else
                 echo "value=true" >> "$GITHUB_OUTPUT"
               fi
           - name: Build
             if: steps.has-build.outputs.value == 'true'
             run: npm run build
           - name: Verify
             run: npm run ci

       deploy:
         needs: verify
         if: >-
           needs.verify.result == 'success'
           && inputs.deploy-enabled
           && github.event_name == 'push'
           && github.ref == 'refs/heads/main'
         runs-on: ubuntu-latest
         steps:
           - uses: actions/checkout@v4
           - uses: actions/setup-node@v4
             with:
               node-version: ${{ inputs.node-version }}
               cache: npm
           - name: Install dependencies
             run: npm ci
           - name: Detect build script
             id: has-build
             run: |
               if [ "$(npm pkg get scripts.build)" = "{}" ]; then
                 echo "value=false" >> "$GITHUB_OUTPUT"
               else
                 echo "value=true" >> "$GITHUB_OUTPUT"
               fi
           - name: Build
             if: steps.has-build.outputs.value == 'true'
             run: npm run build
           - name: Apply D1 migrations
             if: inputs.d1-database != ''
             run: npm run migrate:remote
             env:
               CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
               CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
           - name: Deploy
             run: npm run deploy
             env:
               CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
               CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
     ```

  2. インデントは 2 スペース、行末の余分な空白なし、末尾に改行 1 つで保存する。
- Acceptance:
  - ファイルが PyYAML で `yaml.safe_load` でき、例外を出さない。
  - `on.workflow_call.inputs` のキーが `node-version` / `d1-database` / `deploy-enabled` の 3 つちょうどである。
  - `node-version` の default が文字列 `"22"`、`d1-database` の default が空文字列、
    `deploy-enabled` の型が boolean で default が true である。
  - トップレベル `permissions` が `{contents: read}` である。
  - `jobs` のキーが `verify` と `deploy` の 2 つちょうどで、`deploy.needs` が `verify` である。
  - `deploy` job の `if` 文字列が `needs.verify.result == 'success'`、`inputs.deploy-enabled`、
    `github.event_name == 'push'`、`github.ref == 'refs/heads/main'` の 4 条件すべてを含む。
  - `verify` job に Cloudflare 認証用の `env`（`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`）が
    一切現れない（`verify` job の YAML 断片に文字列 `CLOUDFLARE_` が 0 回出現する）。
  - `deploy` job の `Apply D1 migrations` ステップの `if` が `inputs.d1-database != ''` である。
  - 両 job に `id: has-build` のステップと `if: steps.has-build.outputs.value == 'true'` の
    `Build` ステップが存在する。
- Verify:

  ```
  cd /home/server/github/workflows && python3 -c "
  import yaml
  d = yaml.safe_load(open('.github/workflows/workers.yml'))
  c = d[True] if True in d else d['on']
  wc = c['workflow_call']
  assert sorted(wc['inputs']) == ['d1-database', 'deploy-enabled', 'node-version'], wc['inputs']
  assert wc['inputs']['node-version']['default'] == '22'
  assert wc['inputs']['d1-database']['default'] == ''
  assert wc['inputs']['deploy-enabled']['type'] == 'boolean' and wc['inputs']['deploy-enabled']['default'] is True
  assert d['permissions'] == {'contents': 'read'}
  assert sorted(d['jobs']) == ['deploy', 'verify']
  assert d['jobs']['deploy']['needs'] == 'verify'
  cond = d['jobs']['deploy']['if']
  for t in [\"needs.verify.result == 'success'\", 'inputs.deploy-enabled', \"github.event_name == 'push'\", \"github.ref == 'refs/heads/main'\"]:
      assert t in cond, t
  assert 'CLOUDFLARE_' not in yaml.dump(d['jobs']['verify'])
  steps = d['jobs']['deploy']['steps']
  assert any(s.get('name') == 'Apply D1 migrations' and s.get('if') == \"inputs.d1-database != ''\" for s in steps)
  for j in ('verify', 'deploy'):
      ss = d['jobs'][j]['steps']
      assert any(s.get('id') == 'has-build' for s in ss)
      assert any(s.get('name') == 'Build' and s.get('if') == \"steps.has-build.outputs.value == 'true'\" for s in ss)
  print('workers.yml ok')
  " && npm run ci
  ```

---

### Task 3: 自己検証ワークフロー self-test.yml を作成する

対応: TASK-003

- Files to touch: `/home/server/github/workflows/.github/workflows/self-test.yml`（新規）
- Files NOT to touch: `/home/server/github/workflows/.github/workflows/workers.yml`, `/home/server/github/workflows/package.json`, `/home/server/github/workflows/package-lock.json`
- New dependencies: none（actionlint は GitHub Actions 上で Docker コンテナアクションとして実行される。ローカルへのインストールは不要かつ禁止）
- Steps:
  1. `/home/server/github/workflows/.github/workflows/self-test.yml` を以下の内容そのままで新規作成する。

     ```yaml
     name: Self test

     on:
       pull_request:
       push:
         branches: [main]

     permissions:
       contents: read

     jobs:
       actionlint:
         runs-on: ubuntu-latest
         steps:
           - uses: actions/checkout@v4
           - name: Lint workflow files
             uses: docker://rhysd/actionlint:1.7.7
             with:
               args: -color

       smoke:
         uses: ./.github/workflows/workers.yml
         with:
           node-version: "22"
           d1-database: ""
           deploy-enabled: false
         secrets: inherit
     ```

  2. インデントは 2 スペース、末尾に改行 1 つで保存する。
- Acceptance:
  - ファイルが PyYAML で `yaml.safe_load` でき、例外を出さない。
  - `jobs` のキーが `actionlint` と `smoke` の 2 つちょうどである。
  - `actionlint` job に `uses` が `docker://rhysd/actionlint:1.7.7`（`latest` ではない固定タグ）の
    ステップが存在し、その `with.args` が `-color` である。
  - `smoke` job の `uses` が `./.github/workflows/workers.yml` である。
  - `smoke` job の `with` が `node-version: "22"`、`d1-database: ""`、`deploy-enabled: false` の
    3 キーちょうどで、`secrets` が `inherit` である。
  - トリガーが `pull_request` と `push`（`branches: [main]`）の 2 つである。
- Verify:

  ```
  cd /home/server/github/workflows && python3 -c "
  import yaml
  d = yaml.safe_load(open('.github/workflows/self-test.yml'))
  c = d[True] if True in d else d['on']
  assert set(c) == {'pull_request', 'push'}, c
  assert c['push']['branches'] == ['main']
  assert sorted(d['jobs']) == ['actionlint', 'smoke']
  al = d['jobs']['actionlint']['steps']
  st = [s for s in al if s.get('uses', '').startswith('docker://rhysd/actionlint:')]
  assert len(st) == 1 and st[0]['uses'] == 'docker://rhysd/actionlint:1.7.7', st
  assert st[0]['with']['args'] == '-color'
  sm = d['jobs']['smoke']
  assert sm['uses'] == './.github/workflows/workers.yml'
  assert sm['with'] == {'node-version': '22', 'd1-database': '', 'deploy-enabled': False}, sm['with']
  assert sm['secrets'] == 'inherit'
  print('self-test.yml ok')
  " && python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]; print('yaml ok')" && npm run ci
  ```

---

### Task 4: README.md を作成する

対応: TASK-004

- Files to touch: `/home/server/github/workflows/README.md`（新規）
- Files NOT to touch: `/home/server/github/workflows/.github/**`, `/home/server/github/workflows/package.json`, `/home/server/github/workflows/package-lock.json`, `/home/server/github/workflows/docs/**`
- New dependencies: none
- Steps:
  1. `/home/server/github/workflows/README.md` を新規作成し、以下の 6 つの見出しセクションを
     この順序で日本語で記述する。
     - `# tsuki-neko-com/workflows` — このリポジトリの目的（Workers リポジトリ共通の
       reusable workflow を 1 箇所に集約する）を 3 行以内で述べる。
     - `## 使い方（貼り付け用 caller）` — 各リポジトリの `.github/workflows/ci.yml` に貼る
       以下のコードブロックをそのまま載せる。`d1-database` はリポジトリごとに書き換えること、
       D1 を使わない場合は `d1-database` 行ごと削除することを本文に書く。

       ````
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
       ````

     - `## inputs` — `node-version`（string / default `"22"`）、`d1-database`
       （string / default `""`、空ならマイグレーションをスキップ）、
       `deploy-enabled`（boolean / default `true`）の 3 行の表。
     - `## npm script 規約` — 仕様 §5 の表と同じ内容の表を載せる。列は
       「script」「意味」「未定義時の扱い」。行は `build` / `lint` / `fix` / `typecheck` /
       `ci` / `deploy` / `migrate:remote` の 7 行。表の下に「`deploy` に `build` を含めない
       （ワークフローが `build` → `migrate:remote` → `deploy` の順序を制御するため。
       含めると二重ビルドになる）」を明記する。
     - `## biome.json マスター` — 仕様 §7.3 の最終形（`files.includes` による
       `worker-configuration.d.ts` 除外を含む）を JSON コードブロックで載せる。内容は以下と厳密に一致させる。

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

       あわせて、`@biomejs/biome` 2.5.x を各リポの devDependency に入れること、
       Biome 公式 GitHub Action は使わないこと（手元と CI で同一コマンドにするため）、
       初回適用時は整形コミットを単独に分離し `.git-blame-ignore-revs` に SHA を登録して
       `git config blame.ignoreRevsFile .git-blame-ignore-revs` を実行することを本文に書く。
     - `## バージョニング（v1 可動タグ）` — 仕様 §8 の運用を書く。
       利用側は常に `@v1` を参照すること、後方互換のある変更は `main` マージ後に
       `git tag -f v1 && git push -f origin v1` で進めること、`v1` を動かすたびに
       `v1.<n>` 形式の不変タグも打つこと、互換を壊す変更のときだけ `v2` を切り
       移行完了まで `v1` を残すこと、`v1` を動かす前に必ず `self-test` が green であることを
       確認すること、壊れた場合は `v1` を直前の SHA へ戻せば全リポが即時復旧すること。
  2. 見出しレベルは上記のとおり（`#` を 1 つ、`##` を 5 つ）とする。
- Acceptance:
  - `README.md` が存在し、`# tsuki-neko-com/workflows`、`## 使い方（貼り付け用 caller）`、
    `## inputs`、`## npm script 規約`、`## biome.json マスター`、
    `## バージョニング（v1 可動タグ）` の 6 見出しをこの順序で含む。
  - README 中に文字列 `tsuki-neko-com/workflows/.github/workflows/workers.yml@v1` が
    1 回以上出現する。
  - README 中に `"$schema": "https://biomejs.dev/schemas/2.5.6/schema.json"` と
    `"includes": ["**", "!worker-configuration.d.ts"]` が出現する。
  - README 中に `migrate:remote`、`git tag -f v1`、`blame.ignoreRevsFile` が出現する。
  - README に `TBD` / `TODO` の文字列が出現しない。
- Verify:

  ```
  cd /home/server/github/workflows && python3 -c "
  t = open('README.md', encoding='utf-8').read()
  heads = ['# tsuki-neko-com/workflows', '## 使い方（貼り付け用 caller）', '## inputs', '## npm script 規約', '## biome.json マスター', '## バージョニング（v1 可動タグ）']
  pos = -1
  for h in heads:
      i = t.find(h)
      assert i > pos, h
      pos = i
  for s in ['tsuki-neko-com/workflows/.github/workflows/workers.yml@v1', '\"\$schema\": \"https://biomejs.dev/schemas/2.5.6/schema.json\"', '\"includes\": [\"**\", \"!worker-configuration.d.ts\"]', 'migrate:remote', 'git tag -f v1', 'blame.ignoreRevsFile']:
      assert s in t, s
  assert 'TBD' not in t and 'TODO' not in t
  print('README ok')
  " && python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]; print('yaml ok')" && npm run ci
  ```
