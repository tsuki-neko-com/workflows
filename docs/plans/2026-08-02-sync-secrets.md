# Cloudflare 認証情報のリポジトリ secret 一括配布スクリプト

## Goal

`tsuki-neko-com` org の Cloudflare Workers リポジトリへ、`CLOUDFLARE_API_TOKEN` と
`CLOUDFLARE_ACCOUNT_ID` を repository secret として一括登録する
`scripts/sync-secrets.sh` を `tsuki-neko-com/workflows` に追加する。
トークンをローテーションしたときは、手元の env ファイルを 1 箇所書き換えて
再実行するだけで、全リポジトリへ行き渡る状態にする。

## Non-goals

- Cloudflare API トークンそのものの発行（Cloudflare ダッシュボード作業。必要なスコープは
  README の「シークレット（必須）」節に記載済み）。
- 新規リポジトリのブートストラップ（caller の `.github/workflows/ci.yml` や
  `biome.json` の設置）。本スクリプトは既存 caller を検出するだけで、書き込まない。
- organization secret の登録。GitHub Free プランでは private リポジトリから参照できないため、
  採用しない。
- トークンの暗号化保管（1Password / age / gh CLI の秘密ストア等）。平文ファイル +
  パーミッション `600` の強制で運用すると決定済み。

## Design notes

### 保管場所

トークンは平文ファイル `~/.config/tsuki-neko/cloudflare.env` に置く。形式は
`KEY=VALUE` の 2 行:

```
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ACCOUNT_ID=...
```

環境変数 `TSUKI_NEKO_ENV_FILE` で別パスを指定できる（テストや複数アカウント用）。
スクリプトはこのファイルのパーミッションが `600` であることを実行時に検証し、
グループ/他者に読める状態なら実行を拒否する。

**却下した代替案**: 暗号化保管（age / sops）。鍵管理の手間が増えるうえ、
復号した平文は結局プロセスに渡る。単一利用者・単一マシンの運用では `600` の平文で十分と判断。
`gh secret set` の対話入力も却下（ローテーション時に 2 リポジトリ × 2 件を手打ちする現状の手作業を
なくすことが目的のため）。

### env ファイルの読み方

`source` / `.` で読み込まない。任意コード実行を避けるため、行単位で正規表現マッチして
`CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` の 2 キーだけを取り出す。
空行と `#` で始まる行は無視する。値を囲む一重/二重引用符が 1 組あれば取り除く。
知らないキーは無視し、エラーにしない。

### 対象リポジトリの判定

引数なしのとき、`gh repo list` で org のリポジトリを列挙し、archived を除外したうえで、
`.github/workflows/ci.yml` が存在し、その内容に固定文字列
`tsuki-neko-com/workflows/.github/workflows/workers.yml@` を含むものだけを対象とする。
これにより、共通 reusable workflow を使っていないリポジトリへ誤ってトークンを配らない。

引数でリポジトリ名を渡した場合も同じ caller 判定を行い、非該当なら `[skip]` として扱う。
`--force` を付けたときだけ判定を省略して強制登録する。

**却下した代替案**: 対象リポジトリ名をスクリプト内にハードコードした配列で持つ。
リポジトリが増えるたびにこのリポジトリを編集する必要があり、
「今後増える」という前提に合わないため却下。

### 値の秘匿

- `set -x` を使わない。
- トークンの値を `echo` / `printf` で標準出力・標準エラーへ出さない。ログにも残さない。
- `gh secret set` へはコマンドライン引数（`--body`）ではなく標準入力で渡す。
  引数に置くと同一ホストの他プロセスから `ps` で見えるため。
  `printf '%s' "$value" | gh secret set NAME --repo "$ORG/$repo"` の形にする。

### 処理順序（重要）

引数解析 → env ファイル検証 → `gh auth status` → 対象リポジトリ解決 → 同期。
env ファイル検証を `gh auth status` より前に置くことで、ネットワークのない環境でも
env ファイル起因のエラー分岐を検証できる。この順序は TASK-001 の受け入れ基準が前提とする。

### 共通の検証コマンド

すべてのタスクで以下を使用する（`--verify` に渡す値）。ローカルに shellcheck が無いため、
シェルスクリプトの静的検査は `bash -n` による構文検査とする。

```sh
for f in .github/workflows/*.yml; do [ -e "$f" ] || continue; python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" || exit 1; done; for s in scripts/*.sh; do [ -e "$s" ] || continue; bash -n "$s" || exit 1; done; npm run ci
```

### ネットワークについて

実装ワーカーはネットワークのないサンドボックスで動く。そのため受け入れ基準を
「ワーカーが実行して判定できるもの（オフライン）」と
「オーケストレーターがレビュー時に実行して判定するもの（`gh` 認証とネットワークが必要）」に
明示的に分けて記述する。ワーカーは前者だけを実行すればよい。

---

### Task 1: scripts/sync-secrets.sh を作成する

- Files to touch:
  - `/home/server/github/workflows/scripts/sync-secrets.sh`（新規作成、実行ビット付き `755`）
- Files NOT to touch:
  - `/home/server/github/workflows/README.md`（TASK-002 で扱う）
  - `/home/server/github/workflows/.gitignore`（TASK-003 で扱う）
  - `/home/server/github/workflows/.github/workflows/**`
  - `/home/server/github/workflows/package.json`、`package-lock.json`
  - `~/.config/tsuki-neko/**`（実在する本番 env ファイルを読み書き・作成しない）
- New dependencies: none（bash / coreutils / `gh` のみ。npm パッケージの追加なし）

- Steps:

  1. `scripts/` ディレクトリを作成し、`scripts/sync-secrets.sh` を新規作成する。
     1 行目は `#!/usr/bin/env bash`、2 行目は `set -euo pipefail`。
     ファイル冒頭にコメントで用途と使い方を 5 行程度で書く。作成後 `chmod 755` する。

  2. 定数を定義する。

     - `DEFAULT_ORG="tsuki-neko-com"`
     - `DEFAULT_ENV_FILE="${HOME}/.config/tsuki-neko/cloudflare.env"`
     - `CALLER_PATH=".github/workflows/ci.yml"`
     - `CALLER_MARKER="tsuki-neko-com/workflows/.github/workflows/workers.yml@"`
     - 同期対象キーの配列 `SECRET_KEYS=(CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID)`

  3. ヘルパー関数を定義する。いずれもトークンの値を出力しないこと。

     - `log()` — 引数を標準出力へ 1 行出す。
     - `err()` — 引数を標準エラーへ `error: ` 接頭辞付きで 1 行出す。
     - `die()` — `err "$@"` のあと `exit 1`。
     - `usage()` — 使用法を標準出力へ出す。内容は下記 4 の書式に一致させる。

  4. 引数を解析する。受け付けるのは以下だけで、未知のオプション（`-` で始まる引数）は
     `die` する。

     ```
     usage: sync-secrets.sh [--dry-run] [--force] [--org <org>] [--help] [repo ...]
     ```

     - `--dry-run` — `DRY_RUN=1`。`gh secret set` を一切実行しない。
     - `--force` — `FORCE=1`。caller 判定をスキップする。引数でリポジトリ名を
       1 つ以上指定した場合にのみ意味を持つ。リポジトリ名を指定せずに `--force` が
       渡されたら `die "--force requires at least one repository name"`。
     - `--org <org>` — 対象 org を上書きする。値が無ければ `die`。
     - `-h` / `--help` — `usage` を出して `exit 0`。
     - それ以外の引数は対象リポジトリ名として配列 `REPOS` に積む。
       `owner/name` 形式で渡された場合は `/` 以降だけを取り出して使う。

  5. env ファイルを検証・読み込む関数 `load_env_file()` を実装する。
     この処理は `gh auth status` より **前** に呼ぶこと。

     - `ENV_FILE="${TSUKI_NEKO_ENV_FILE:-$DEFAULT_ENV_FILE}"`。
     - ファイルが存在しなければ `die "credential file not found: ${ENV_FILE}"` と、
       期待する形式（`CLOUDFLARE_API_TOKEN=...` / `CLOUDFLARE_ACCOUNT_ID=...`）および
       `chmod 600 "${ENV_FILE}"` を促す補足行を標準エラーへ出す。メッセージには
       必ず `${ENV_FILE}` の実パスを含める。
     - パーミッションを取得する。`stat -c '%a' "$ENV_FILE"` を試し、失敗したら
       `stat -f '%Lp' "$ENV_FILE"` にフォールバックする。どちらも失敗したら `die`。
       取得値が `600` でなければ
       `die "credential file ${ENV_FILE} has mode <mode>; expected 600. run: chmod 600 ${ENV_FILE}"`。
       メッセージには文字列 `600` と `${ENV_FILE}` を必ず含める。
     - ファイルを 1 行ずつ読み、`^[[:space:]]*#` と空行を飛ばす。
       `^[[:space:]]*(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID)=(.*)$` にマッチする行から
       値を取り出し、前後の空白を除去し、値全体が `"..."` または `'...'` で
       囲まれていれば引用符 1 組だけ剥がす。取り出した値はグローバル変数
       `SECRET_VALUE_CLOUDFLARE_API_TOKEN` / `SECRET_VALUE_CLOUDFLARE_ACCOUNT_ID` に入れる
       （`declare -g` または連想配列 `declare -A SECRET_VALUES` のいずれかを使う）。
     - 読み込み後、`SECRET_KEYS` の各キーについて、未設定なら
       `die "missing key ${key} in ${ENV_FILE}"`、空文字なら
       `die "empty value for ${key} in ${ENV_FILE}"`。エラーメッセージに値を含めない。

  6. `gh` の存在と認証を確認する関数 `check_gh()` を実装する。

     - `command -v gh >/dev/null 2>&1` が偽なら
       `die "gh CLI not found. install GitHub CLI first."`。
     - `gh auth status >/dev/null 2>&1` が偽なら
       `die "gh is not authenticated. run: gh auth login"`。
       `--dry-run` でもこの検査は行い、失敗時は終了する。

  7. 対象リポジトリを解決する関数 `resolve_repos()` を実装する。

     - `REPOS` が空のとき、次のコマンドで org のリポジトリ名を列挙する。

       ```sh
       gh repo list "$ORG" --limit 200 --json name,isArchived \
         --jq '.[] | select(.isArchived | not) | .name'
       ```

       結果を `REPOS` 配列へ読み込む。0 件なら
       `die "no repositories found in org ${ORG}"`。
       この経路では `--force` は効かない（4 で弾いている）。
     - `REPOS` が非空（引数指定）のときは、その配列をそのまま使う。

  8. caller 判定関数 `has_caller()` を実装する。引数はリポジトリ名。

     ```sh
     gh api -H "Accept: application/vnd.github.raw" \
       "repos/${ORG}/${repo}/contents/${CALLER_PATH}" 2>/dev/null \
       | grep -qF "$CALLER_MARKER"
     ```

     成功なら 0、`ci.yml` が無い/マーカーを含まない場合は非 0 を返す。
     `set -e` に巻き込まれないよう `if has_caller "$repo"; then` の形で呼ぶ。

  9. メインループを実装する。`ok_count` / `skip_count` / `fail_count` を 0 で初期化し、
     `REPOS` の各要素について次を行う。

     - `FORCE` が 0 のとき `has_caller` を呼ぶ。偽なら
       `log "[skip] ${repo}: no caller for ${CALLER_MARKER%@} in ${CALLER_PATH}"` を出し、
       `skip_count` を増やして次へ。
     - `DRY_RUN=1` なら
       `log "[dry-run] ${repo}: would set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID"` を出し、
       `ok_count` を増やして次へ。`gh secret set` は呼ばない。
     - それ以外は `SECRET_KEYS` の各キーについて

       ```sh
       printf '%s' "$value" | gh secret set "$key" --repo "${ORG}/${repo}" >/dev/null
       ```

       を実行する。値は `--body` などの引数に置かない。
       1 件でも失敗したらそのリポジトリは失敗扱いとし、
       `log "[fail] ${repo}: failed to set ${key}"`（値は出さない）を出して
       `fail_count` を増やし、そのリポジトリの残りのキーは処理しない。
       全キー成功なら `log "[ok] ${repo}: set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID"` を出し、
       `ok_count` を増やす。

  10. 最後に集計行を出す。

      ```
      summary: ok=<n> skip=<n> fail=<n>
      ```

      `--dry-run` のときは末尾に ` (dry-run: no secrets were written)` を付ける。
      `fail_count` が 1 以上なら `exit 1`、それ以外は `exit 0`。

  11. スクリプト内のどこにも `set -x` / `set -v` を書かない。
      トークン値を含む変数を `log` / `err` / `echo` / `printf` の**表示**用途で使わない
      （`gh secret set` への標準入力としての `printf '%s'` のみ許可）。

- Acceptance:

  **A. ワーカーが実行して判定する（オフラインで完結）**

  1. `bash -n scripts/sync-secrets.sh` が終了コード 0。
  2. `test -x scripts/sync-secrets.sh` が真（実行ビットが立っている）。
  3. `grep -n 'set -x' scripts/sync-secrets.sh` が何も一致しない（終了コード 1）。
  4. `grep -n -- '--body' scripts/sync-secrets.sh` が何も一致しない
     （トークンをコマンドライン引数へ置いていない）。
  5. env ファイル不在時に非ゼロ終了し、メッセージにパスが含まれる。

     ```sh
     TSUKI_NEKO_ENV_FILE=/nonexistent/dir/cloudflare.env ./scripts/sync-secrets.sh --dry-run > /tmp/out.txt 2>&1; echo "exit=$?"
     grep -q '/nonexistent/dir/cloudflare.env' /tmp/out.txt
     ```

     終了コードが 0 以外、かつ `grep` が一致すること。
  6. パーミッション `644` の一時 env ファイルを指すと非ゼロ終了し、メッセージに `600` が含まれる。

     ```sh
     d=$(mktemp -d); printf 'CLOUDFLARE_API_TOKEN=DUMMY_TOKEN_VALUE_DO_NOT_USE\nCLOUDFLARE_ACCOUNT_ID=DUMMY_ACCOUNT_VALUE_DO_NOT_USE\n' > "$d/cf.env"; chmod 644 "$d/cf.env"
     TSUKI_NEKO_ENV_FILE="$d/cf.env" ./scripts/sync-secrets.sh --dry-run > /tmp/out.txt 2>&1; echo "exit=$?"
     grep -q '600' /tmp/out.txt
     ```

     終了コードが 0 以外、かつ `grep` が一致すること。
  7. パーミッション `600` だがキーが欠けている env ファイルでは非ゼロ終了し、
     メッセージに欠けているキー名 `CLOUDFLARE_ACCOUNT_ID` が含まれる。

     ```sh
     d=$(mktemp -d); printf 'CLOUDFLARE_API_TOKEN=DUMMY_TOKEN_VALUE_DO_NOT_USE\n' > "$d/cf.env"; chmod 600 "$d/cf.env"
     TSUKI_NEKO_ENV_FILE="$d/cf.env" ./scripts/sync-secrets.sh --dry-run > /tmp/out.txt 2>&1; echo "exit=$?"
     grep -q 'CLOUDFLARE_ACCOUNT_ID' /tmp/out.txt
     ```

  8. 値が空の env ファイルでは非ゼロ終了する。

     ```sh
     d=$(mktemp -d); printf 'CLOUDFLARE_API_TOKEN=\nCLOUDFLARE_ACCOUNT_ID=DUMMY_ACCOUNT_VALUE_DO_NOT_USE\n' > "$d/cf.env"; chmod 600 "$d/cf.env"
     TSUKI_NEKO_ENV_FILE="$d/cf.env" ./scripts/sync-secrets.sh --dry-run; echo "exit=$?"
     ```

     終了コードが 0 以外であること。
  9. **値の漏洩がない**。正しい形式・`600` のダミー env ファイルを指して実行した場合、
     ネットワーク不通で `gh auth status` に失敗して終了しても、
     標準出力・標準エラーのどこにもダミー値が現れない。

     ```sh
     d=$(mktemp -d); printf 'CLOUDFLARE_API_TOKEN=DUMMY_TOKEN_VALUE_DO_NOT_USE\nCLOUDFLARE_ACCOUNT_ID=DUMMY_ACCOUNT_VALUE_DO_NOT_USE\n' > "$d/cf.env"; chmod 600 "$d/cf.env"
     TSUKI_NEKO_ENV_FILE="$d/cf.env" ./scripts/sync-secrets.sh --dry-run > /tmp/out.txt 2>&1 || true
     grep -q 'DUMMY_TOKEN_VALUE_DO_NOT_USE' /tmp/out.txt; echo "leak_grep_exit=$?"
     ```

     `grep` が一致しない（`leak_grep_exit=1`）こと。
  10. `./scripts/sync-secrets.sh --help` が終了コード 0 で、出力に
      `--dry-run`、`--force`、`--org` の 3 つがすべて現れる。
  11. `./scripts/sync-secrets.sh --unknown-option` が非ゼロ終了する。
  12. リポジトリ名を指定せずに `--force` を渡すと非ゼロ終了し、メッセージに `--force` が含まれる。

  **B. オーケストレーターがレビュー時に実行して判定する（`gh` 認証とネットワークが必要）**

  13. ダミー値の一時 env ファイル（`600`）を指して
      `TSUKI_NEKO_ENV_FILE="$d/cf.env" ./scripts/sync-secrets.sh --dry-run` を実行すると、
      終了コード 0 で、出力に `[dry-run] ameownt:` と `[dry-run] nekotune:` の両方が現れ、
      最終行が `summary: ok=2 skip=... fail=0 (dry-run: no secrets were written)` の形式である
      （`skip` の件数は org 内の非 caller リポジトリ数に依存するため値は問わない）。
      同じ出力にダミー値 `DUMMY_TOKEN_VALUE_DO_NOT_USE` が現れない。
  14. 上記 `--dry-run` の実行前後で
      `gh secret list --repo tsuki-neko-com/ameownt` の出力（`UPDATED` 列を含む）が
      変化しない。
  15. 本物の `~/.config/tsuki-neko/cloudflare.env` を使って `--dry-run` なしで実行すると
      終了コード 0、`[ok] ameownt:` と `[ok] nekotune:` が出力され、
      その後の `gh secret list --repo tsuki-neko-com/ameownt` に
      `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` が並び、`UPDATED` が当日になる。

- Verify:

  ```sh
  for f in .github/workflows/*.yml; do [ -e "$f" ] || continue; python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" || exit 1; done; for s in scripts/*.sh; do [ -e "$s" ] || continue; bash -n "$s" || exit 1; done; npm run ci
  ```

  加えて、上記 Acceptance A の 1〜12 を手元で実行し、すべて期待どおりであることを確認する。

---

### Task 2: README にシークレット同期の節を追加し「シークレット（必須）」節を書き換える

- Files to touch:
  - `/home/server/github/workflows/README.md`
- Files NOT to touch:
  - `/home/server/github/workflows/scripts/sync-secrets.sh`（TASK-001 で完成済み。挙動を変えない）
  - `/home/server/github/workflows/.gitignore`
  - `/home/server/github/workflows/.github/workflows/**`
- New dependencies: none

- Steps:

  1. 既存の「## シークレット（必須）」節を書き換える。冒頭の
     「利用リポジトリごとに、以下 2 つを **repository secret** として登録してください。
     **登録しないとデプロイは必ず失敗します。**」という文と、続く
     「**organization secret は使えません。**」以降の段落、`deploy` job の空値検査の説明、
     Cloudflare API トークンのスコープの説明は、そのまま残す。
     変更するのは「登録方法」の提示順だけとする。

  2. 手作業の 2 行（`gh secret set CLOUDFLARE_API_TOKEN --repo ...` /
     `gh secret set CLOUDFLARE_ACCOUNT_ID --repo ...`）を節の先頭から外し、
     代わりに「登録は `scripts/sync-secrets.sh` で一括同期できます（後述の
     [シークレットの一括同期](#シークレットの一括同期) 参照）」という 1 行の案内を置く。
     外した 2 行は、新設する「一括同期」節の末尾に
     「スクリプトを使わずに 1 件ずつ登録する場合」という小見出し付きの代替手順として残す。

  3. `## シークレット（必須）` 節の直後に `## シークレットの一括同期` 節を新設し、
     以下をこの順で書く。

     - 目的の 1 段落: org 内の caller リポジトリを自動検出し、
       `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を repository secret として配布する。
       トークンをローテーションしたときは env ファイルを書き換えて再実行するだけでよい。
     - 事前準備: `~/.config/tsuki-neko/cloudflare.env` を作る手順。

       ```sh
       mkdir -p ~/.config/tsuki-neko
       cat > ~/.config/tsuki-neko/cloudflare.env <<'EOF'
       CLOUDFLARE_API_TOKEN=<token>
       CLOUDFLARE_ACCOUNT_ID=<account id>
       EOF
       chmod 600 ~/.config/tsuki-neko/cloudflare.env
       ```

       パーミッションが `600` でないとスクリプトは実行を拒否すること、
       `TSUKI_NEKO_ENV_FILE` で別パスを指定できることを明記する。
     - 使い方:

       ```sh
       ./scripts/sync-secrets.sh --dry-run   # 対象リポジトリの確認のみ
       ./scripts/sync-secrets.sh             # 全 caller リポジトリへ同期
       ./scripts/sync-secrets.sh ameownt     # 特定リポジトリだけ
       ```

     - 対象判定の説明: `.github/workflows/ci.yml` に
       `tsuki-neko-com/workflows/.github/workflows/workers.yml@` を含むリポジトリだけが対象で、
       archived リポジトリは除外される。該当しないリポジトリは `[skip]` と表示される。
       引数指定時に判定を飛ばしたい場合は `--force` を使う。
     - オプション表（`| オプション | 意味 |` の 2 列）: `--dry-run`、`--force`、
       `--org <org>`（既定 `tsuki-neko-com`）、`--help` の 4 行。
     - 前提: `gh` が認証済みであること（`gh auth login`）。未認証なら実行前に停止する。
     - 注意書き: トークンの値は標準出力・標準エラーへ一切表示されない。
     - 「スクリプトを使わずに 1 件ずつ登録する場合」小見出しと、手順 2 で外した
       `gh secret set` の 2 行。

  4. 新設節の見出しレベルは既存に合わせて `##` とし、README 全体の見出し順序は
     「使い方（貼り付け用 caller）」→「シークレット（必須）」→「シークレットの一括同期」→
     「inputs」→ 以降既存のまま、とする。

- Acceptance:

  1. `grep -c '^## シークレットの一括同期$' README.md` が `1`。
  2. `grep -q 'scripts/sync-secrets.sh' README.md` が真。
  3. `grep -q 'TSUKI_NEKO_ENV_FILE' README.md` が真。
  4. `grep -q 'chmod 600 ~/.config/tsuki-neko/cloudflare.env' README.md` が真。
  5. `grep -q -- '--dry-run' README.md` が真、`grep -q -- '--force' README.md` が真。
  6. `gh secret set CLOUDFLARE_API_TOKEN` の記述が README になお 1 箇所以上存在する
     （代替手順として残っている）: `grep -q 'gh secret set CLOUDFLARE_API_TOKEN' README.md`。
  7. `grep -q '^## inputs$' README.md` が真、かつ `## シークレットの一括同期` の行番号が
     `## inputs` の行番号より小さい。
  8. 既存記述が失われていない: `grep -q 'organization secret は使えません' README.md` と
     `grep -q 'Edit Cloudflare Workers' README.md` がいずれも真。
  9. README に実トークンらしき文字列を書き込んでいない:
     `grep -nE '^CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)=[^<]' README.md` が何も一致しない。

- Verify:

  ```sh
  for f in .github/workflows/*.yml; do [ -e "$f" ] || continue; python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" || exit 1; done; for s in scripts/*.sh; do [ -e "$s" ] || continue; bash -n "$s" || exit 1; done; npm run ci
  ```

  加えて上記 Acceptance 1〜9 の `grep` を実行し、すべて期待どおりであることを確認する。

---

### Task 3: .gitignore に *.env を追加し README に 1 行注記する

- Files to touch:
  - `/home/server/github/workflows/.gitignore`
  - `/home/server/github/workflows/README.md`
- Files NOT to touch:
  - `/home/server/github/workflows/scripts/sync-secrets.sh`
  - `/home/server/github/workflows/.github/workflows/**`
  - `/home/server/github/workflows/package.json`、`package-lock.json`
- New dependencies: none

- Steps:

  1. `.gitignore` の末尾に `*.env` を 1 行追加する。既存の `node_modules/` と `.sdd/` の
     行は変更しない。最終的な `.gitignore` は次の 3 行になる。

     ```
     node_modules/
     .sdd/
     *.env
     ```

  2. README の「シークレットの一括同期」節の「事前準備」の直後に、次の主旨の 1 行を追加する。

     > 認証情報ファイルはこのリポジトリの外（`~/.config/tsuki-neko/`）に置いてください。
     > 保険として `.gitignore` に `*.env` を入れてあり、誤ってリポジトリ内へ置いても
     > コミット対象になりません。

- Acceptance:

  1. `grep -qx '\*\.env' .gitignore` が真。
  2. `grep -qx 'node_modules/' .gitignore` と `grep -qx '\.sdd/' .gitignore` がいずれも真
     （既存行が消えていない）。
  3. リポジトリ直下に置いた `.env` 系ファイルが無視される。

     ```sh
     printf 'CLOUDFLARE_API_TOKEN=DUMMY_TOKEN_VALUE_DO_NOT_USE\n' > cloudflare.env
     git check-ignore -q cloudflare.env; echo "ignored_exit=$?"
     rm -f cloudflare.env
     ```

     `ignored_exit=0`（無視される）であり、確認後にこの一時ファイルを必ず削除すること。
  4. `git status --porcelain` に `cloudflare.env` が現れない（手順 3 の一時ファイル作成中に
     確認する。確認後は削除済みであること）。
  5. `grep -q '\*\.env' README.md` が真（README に注記が入っている）。
  6. 変更後も `.gitignore` が `*.env` によって `.github/` 配下のファイルを無視していない:
     `git check-ignore -q .github/workflows/workers.yml` が非ゼロ終了する。

- Verify:

  ```sh
  for f in .github/workflows/*.yml; do [ -e "$f" ] || continue; python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" || exit 1; done; for s in scripts/*.sh; do [ -e "$s" ] || continue; bash -n "$s" || exit 1; done; npm run ci
  ```

  加えて上記 Acceptance 1〜6 を実行し、すべて期待どおりであることを確認する。
