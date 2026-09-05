#!/usr/bin/env bash
# check-consistency.sh — human-on-the-loop フレームワーク文書の機械的整合チェック
#
# 対象: skills/hotl/SKILL.md, skills/hotl/playbooks/*.md, skills/hotl/templates/*,
#       skills/hotl-pm/SKILL.md, README.md, PRINCIPLES.md, install.sh
# 目的: ファイル間の相互参照（パス・見出し・phase 名・state フィールド・ID 記法・
#       テンプレートのガイドコメント残存）を、AI レビュアーの目視ではなく決定論的に検査する。
#       PRINCIPLES.md「フレームワーク自体の変更プロセス」手順2 として実行される。
#
# スコープについての注記:
#   - plans/ 配下は意図的に対象外にする。plans/ は実行手順書ではなく設計メモであり、
#     保留機能（例: state.json の `lock` フィールド）や plans/ 専用の ID 接頭辞（`B-n`）など
#     現行の規約と異なる語彙を含む。ここを対象にすると誤検知の温床になる。
#   - CLAUDE.md も対象外（本スクリプトが検査すべき「手順書」としてタスクが明示した一覧に
#     含まれていない。プロジェクト運用メモであり playbook ではない）。
#
# 既知の見逃し（誤検知ゼロを優先した結果。AI レビュアーの目視に委ねる）:
#   - 終端語を伴わない引用（例: 02「要件定義中の再開」、上記「人間向け文面の共通規則」）。
#     終端語なしで拾うと本文中の言い回しを節名と誤判定するため対象外にしている。
#     **節を参照するときは終端語（節／の手順／に従う／の書式 等）を付けて書くこと**。
#   - 他ファイルの番号付き手順への参照（例: reporting.md から 05 の「手順4-3」）。
#     2c は 05-development.md 内の自己参照のみを走査する。
#
# 依存: POSIX shell 相当の grep / sed / awk のみ（GNU 拡張・jq・python 不使用）。
#       macOS の BSD grep/sed で動作確認済み。
#
# 使い方: ./scripts/check-consistency.sh [--verbose]
#   終了コード: FAIL が1件でもあれば 1、WARN のみ／全 OK なら 0
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. セットアップ
# ---------------------------------------------------------------------------

# 起動パスが symlink でも実体のディレクトリを解決する（macOS の readlink には
# -f が無い版があるため手動で辿る）
_self="$0"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in
    /*) _self="$_link" ;;
    *)  _self="$(dirname "$_self")/$_link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
  esac
done

# 文字列処理を安定させるため、**ロケールを C に固定する**。
# 理由: (1) 多バイト文字（「（」「：」等）をブラケット式 [...] に直接書くと非 UTF-8
# ロケールで1バイトずつ解釈され文字列が壊れる（本スクリプトはブラケット式を使わず
# 代替 (a|b) で書くことで回避している）。(2) 逆に UTF-8 ロケールでは macOS 標準の
# bash 3.2 のパーサが `$var` の直後に多バイト文字が続くコードを誤解析し
# 「name<ゴミ>: unbound variable」で異常終了する。呼び出し側の LANG に依存して
# 落ちたり落ちなかったりするのを避けるため、ここで明示的に C へ固定する。
export LC_ALL=C
export LANG=C

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hotl-consistency.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TOTAL=0
FAILN=0
WARNN=0

# result LEVEL "message"
result() {
  TOTAL=$((TOTAL + 1))
  case "$1" in
    FAIL)
      FAILN=$((FAILN + 1))
      printf 'FAIL %s\n' "$2"
      ;;
    WARN)
      WARNN=$((WARNN + 1))
      printf 'WARN %s\n' "$2"
      ;;
    OK)
      if $VERBOSE; then
        printf 'OK   %s\n' "$2"
      fi
      ;;
  esac
}

# grep/sed が「マッチ0件」で非ゼロ終了しても set -e で落ちないようにするラッパ
sgrep() { grep "$@" || true; }

# ---------------------------------------------------------------------------
# 対象ファイル一覧
# ---------------------------------------------------------------------------

TARGET_MD_FILES="
skills/hotl/SKILL.md
skills/hotl-pm/SKILL.md
skills/hotl/playbooks/01-hearing.md
skills/hotl/playbooks/02-requirements.md
skills/hotl/playbooks/03-specification.md
skills/hotl/playbooks/04-design.md
skills/hotl/playbooks/05-development.md
skills/hotl/playbooks/checklist-code.md
skills/hotl/playbooks/checklist-requirements.md
skills/hotl/playbooks/checklist-security.md
skills/hotl/playbooks/reporting.md
skills/hotl/templates/design.md
skills/hotl/templates/requirements.md
skills/hotl/templates/spec.md
skills/hotl/templates/tasks.md
README.md
PRINCIPLES.md
"

# skills/ 配下の非テンプレート .md（チェック6・ID 記法チェックのスコープ）
SKILLS_NON_TEMPLATE_MD="
skills/hotl/SKILL.md
skills/hotl-pm/SKILL.md
skills/hotl/playbooks/01-hearing.md
skills/hotl/playbooks/02-requirements.md
skills/hotl/playbooks/03-specification.md
skills/hotl/playbooks/04-design.md
skills/hotl/playbooks/05-development.md
skills/hotl/playbooks/checklist-code.md
skills/hotl/playbooks/checklist-requirements.md
skills/hotl/playbooks/checklist-security.md
skills/hotl/playbooks/reporting.md
"

# 全対象（install.sh を含む。パス参照チェック用）
ALL_TARGET_FILES="$TARGET_MD_FILES
install.sh"

for f in $ALL_TARGET_FILES; do
  if [ ! -f "$ROOT/$f" ]; then
    result FAIL "対象ファイルが見つかりません: $f（対象ファイル一覧そのものが古くなっている可能性）"
  fi
done

echo "==== 1. パス参照の存在確認 ===="

# playbooks/xxx・templates/xxx（skills/hotl/ からの相対パス）と、
# skills/hotl(-pm)/... のフルパス参照を集め、実在を確認する。
# `playbooks/...` `templates/...` のような省略記法（プレースホルダ）は除外する。
for f in $ALL_TARGET_FILES; do
  matches="$(sgrep -noE '(skills/hotl(-pm)?/[A-Za-z0-9_./-]+|playbooks/[A-Za-z0-9_.-]+|templates/[A-Za-z0-9_.-]+)' "$ROOT/$f")"
  [ -z "$matches" ] && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    ref="${line#*:}"
    case "$ref" in
      playbooks/...|templates/...)
        continue
        ;;
      playbooks/*)
        candidate="skills/hotl/$ref"
        ;;
      templates/*)
        candidate="skills/hotl/$ref"
        ;;
      *)
        candidate="$ref"
        ;;
    esac
    if [ -e "$ROOT/$candidate" ]; then
      result OK "$f:$lineno: 参照先が存在する: $ref"
    else
      result FAIL "$f:$lineno: 参照先が存在しない: \`$ref\`（解決先: $candidate）"
    fi
  done <<EOF
$matches
EOF
done

echo "==== 0. ファイル接頭辞の解決（2a・2b 共通） ===="

# 参照の直前に「05」「hotl-pm/SKILL.md」「reporting.md」等のファイル・スキル名の
# 指定がある場合、その参照は自ファイル∪hotl SKILL.md の和ではなく**指定された
# ファイルの集合だけ**で照合する（指定が無ければ従来どおり）。
# detect_scope() はこの判定を Step N 参照（2a）と「XXX」節参照（2b）の両方から
# 共有で使う。スコープコードと実ファイルの対応は scope_path() に一本化する。
in_set() {
  # $1=needle $2=space separated haystack
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

scope_path() {
  case "$1" in
    PM) echo "skills/hotl-pm/SKILL.md" ;;
    HOTL) echo "skills/hotl/SKILL.md" ;;
    P01) echo "skills/hotl/playbooks/01-hearing.md" ;;
    P02) echo "skills/hotl/playbooks/02-requirements.md" ;;
    P03) echo "skills/hotl/playbooks/03-specification.md" ;;
    P04) echo "skills/hotl/playbooks/04-design.md" ;;
    P05) echo "skills/hotl/playbooks/05-development.md" ;;
    RPT) echo "skills/hotl/playbooks/reporting.md" ;;
    CKCODE) echo "skills/hotl/playbooks/checklist-code.md" ;;
    CKREQ) echo "skills/hotl/playbooks/checklist-requirements.md" ;;
    CKSEC) echo "skills/hotl/playbooks/checklist-security.md" ;;
    REQMD) echo "skills/hotl/templates/requirements.md" ;;
    SPECMD) echo "skills/hotl/templates/spec.md" ;;
    DESIGNMD) echo "skills/hotl/templates/design.md" ;;
    TASKSMD) echo "skills/hotl/templates/tasks.md" ;;
    RDME) echo "README.md" ;;
    PRIN) echo "PRINCIPLES.md" ;;
    *) echo "" ;;
  esac
}

# scope_path() が返す全スコープコード（2b のファイル別見出しプール構築で使う）
ALL_SCOPE_CODES="PM HOTL P01 P02 P03 P04 P05 RPT CKCODE CKREQ CKSEC REQMD SPECMD DESIGNMD TASKSMD RDME PRIN"

steps_of_file() {
  # $1 = ルートからの相対パス（空文字なら集合も空）
  [ -z "$1" ] && return 0
  sgrep -oE '^## Step [0-9]+' "$ROOT/$1" | sgrep -oE '[0-9]+' | tr '\n' ' '
}

cat > "$WORK/file_scope.awk" <<'AWK_EOF'
# 直前の文脈 (pre = 参照より前のテキスト) から、参照先ファイルを特定できる
# 「ファイル接頭辞」があるかどうかを判定する共有関数。無ければ "DEFAULT"。
# 接頭辞とバックティック/空白/「の」の間には多少のゆらぎを許容する。
# hotl-pm 系の判定を先に行うのは、"hotl-pm SKILL.md" のような表記が
# 後段の bare "SKILL.md" 判定にも誤ってマッチしてしまうのを防ぐため。
function detect_scope(pre) {
  # 「SKILL.md Step 4 の「イテレーション」」のように、ファイル名と参照の間に
  # Step 番号が挟まる形も同じファイル指定として扱う
  sub(/[ \t]*Step[ \t]*[0-9]+(-[0-9]+)?[ \t]*(の[ \t]*)?$/, "", pre)
  if (pre ~ /(hotl-pm(\/|[ \t])SKILL\.md|hotl-pm)`?[ \t]*(の[ \t]*)?$/) return "PM"
  if (pre ~ /PM`?[ \t]*(の[ \t]*)?$/) return "PM"
  if (pre ~ /(^|[^0-9])01`?[ \t]*(の[ \t]*)?$/) return "P01"
  if (pre ~ /(^|[^0-9])02`?[ \t]*(の[ \t]*)?$/) return "P02"
  if (pre ~ /(^|[^0-9])03`?[ \t]*(の[ \t]*)?$/) return "P03"
  if (pre ~ /(^|[^0-9])04`?[ \t]*(の[ \t]*)?$/) return "P04"
  if (pre ~ /(^|[^0-9])05`?[ \t]*(の[ \t]*)?$/) return "P05"
  if (pre ~ /reporting\.md`?[ \t]*(の[ \t]*)?$/) return "RPT"
  if (pre ~ /checklist-code\.md`?[ \t]*(の[ \t]*)?$/) return "CKCODE"
  if (pre ~ /checklist-requirements\.md`?[ \t]*(の[ \t]*)?$/) return "CKREQ"
  if (pre ~ /checklist-security\.md`?[ \t]*(の[ \t]*)?$/) return "CKSEC"
  if (pre ~ /requirements\.md`?[ \t]*(の[ \t]*)?$/) return "REQMD"
  if (pre ~ /spec\.md`?[ \t]*(の[ \t]*)?$/) return "SPECMD"
  if (pre ~ /design\.md`?[ \t]*(の[ \t]*)?$/) return "DESIGNMD"
  if (pre ~ /tasks\.md`?[ \t]*(の[ \t]*)?$/) return "TASKSMD"
  if (pre ~ /README\.md`?[ \t]*(の[ \t]*)?$/) return "RDME"
  if (pre ~ /PRINCIPLES\.md`?[ \t]*(の[ \t]*)?$/) return "PRIN"
  if (pre ~ /hotl[ \t]SKILL\.md`?[ \t]*(の[ \t]*)?$/) return "HOTL"
  if (pre ~ /hotl`?[ \t]*(の[ \t]*)?$/) return "HOTL"
  if (pre ~ /SKILL\.md`?[ \t]*(の[ \t]*)?$/) return "HOTL"
  return "DEFAULT"
}
AWK_EOF

echo "==== 2a. 見出し相互参照: Step N（ファイル指定があればそのファイルのみ、無ければ自ファイル∪hotl SKILL.md） ===="

# 各ファイルの "## Step N" 見出し番号集合（ファイル指定が無い参照のデフォルト判定用）
skill_steps="$(steps_of_file skills/hotl/SKILL.md)"
pm_steps="$(steps_of_file skills/hotl-pm/SKILL.md)"
dev_steps="$(steps_of_file skills/hotl/playbooks/05-development.md)"

cat > "$WORK/step_scope.awk" <<'AWK_EOF'
# 行内の "Step N" 参照ごとに、直前の文脈から参照先ファイルのスコープを
# detect_scope() で判定し、行番号・番号・スコープ・元の表記を tab 区切りで出す。
{
  line = $0
  rest = line
  base = 0
  while (match(rest, /Step[ ]?[0-9]+/)) {
    mstart = RSTART; mlen = RLENGTH
    stepref = substr(rest, mstart, mlen)
    numpart = stepref
    gsub(/[^0-9]/, "", numpart)
    abs_start = base + mstart
    pre = substr(line, 1, abs_start - 1)
    scope = detect_scope(pre)
    print FNR "\t" numpart "\t" scope "\t" stepref
    base = base + mstart + mlen - 1
    rest = substr(rest, mstart + mlen)
  }
}
AWK_EOF

for f in $TARGET_MD_FILES; do
  matches="$(awk -f "$WORK/file_scope.awk" -f "$WORK/step_scope.awk" "$ROOT/$f" || true)"
  [ -z "$matches" ] && continue
  case "$f" in
    skills/hotl-pm/SKILL.md) default_allowed="$pm_steps $skill_steps" ;;
    skills/hotl/playbooks/05-development.md) default_allowed="$dev_steps $skill_steps" ;;
    *) default_allowed="$skill_steps" ;;
  esac
  while IFS="$(printf '\t')" read -r lineno n scope ref; do
    [ -z "$lineno" ] && continue
    if [ "$scope" = "DEFAULT" ]; then
      allowed="$default_allowed"
      note=""
    else
      scoped_path="$(scope_path "$scope")"
      allowed="$(steps_of_file "$scoped_path")"
      note="（${scoped_path:-指定先不明} 指定）"
    fi
    if in_set "$n" "$allowed"; then
      result OK "$f:$lineno: \`$ref\`$note は実在する見出しを指す"
    else
      result FAIL "$f:$lineno: \`$ref\`$note に対応する見出しが見つからない（既知の Step 番号: ${allowed:-なし}）"
    fi
  done <<EOF
$matches
EOF
done

echo "==== 2b. 見出し相互参照: 「XXX」節／の手順／に従う／の書式（quoted section name） ===="

# 見出しプール: 対象 Markdown ファイルの "## " 見出しと、"- **XXX**:" 形式の
# 強調ラベル（本フレームワークで「節」相当として頻用される記法）を集める。
# 見出しコアは "（"/"(" より前を使う（例: "## 非機能（性能と…）" -> "非機能"）。
# 見出しに "Step N: " が付く場合（例: "## Step 4: 状態読み込みと整合性チェック"）は、
# 剥がした版もプールに加える。「状態読み込みと整合性チェック」節のように Step 番号
# を省いた引用が偽 FAIL になるのを防ぐため（引用側にも Step 接頭辞を許す必要は無い
# ため、引用側の剥がし処理は不要）。
# 「この節」「同節」「該当節」等の代名詞的参照はここでは解決できないため対象外
# （散文で言い換えられた節名の一致は PRINCIPLES.md が「機械チェックでは
# 捕まらないもの」として明示的にレビュアーへ委ねている）。
#
# ファイル別プール: 「05「完了」」のように参照の直前にファイル・スキル名の指定が
# あれば、その参照は全ファイル横断のプールではなく**そのファイル自身の見出し／
# ラベルだけ**で照合する（同名の節が複数ファイルに存在するときの見逃しを防ぐ）。
# scope_path() が返す全スコープはちょうど対象ファイル一覧と1対1に対応するため、
# 全スコープ分のファイル別プールを作れば、その和集合がそのまま従来の全体プールになる。
build_pool_of() {
  # $1 = ルートからの相対パス
  {
    sgrep -E '^#{1,6} ' "$ROOT/$1" | sed -E 's/^#{1,6} //'
    sgrep -E '^[ 	]*-[ ]+\*\*[^*]+\*\*' "$ROOT/$1" | sed -E 's/^[ 	]*-[ ]+\*\*//; s/\*\*.*$//'
  } \
    | sed -E 's/(（|\().*$//' \
    | sed -E 's/[[:space:]]*(:|：)[[:space:]]*$//' \
    | sed -E 's/[[:space:]]+$//' \
    | awk '{ print; s = $0; n = sub(/^Step [0-9]+:[ ]*/, "", s); if (n > 0 && s != "") print s }' \
    | sort -u
}

POOL="$WORK/heading_pool.txt"
: > "$POOL"
for sc in $ALL_SCOPE_CODES; do
  scoped_path="$(scope_path "$sc")"
  build_pool_of "$scoped_path" > "$WORK/pool_$sc.txt"
  cat "$WORK/pool_$sc.txt" >> "$POOL"
done
sort -u -o "$POOL" "$POOL"

# 「XXX」節／の手順／に従う／の書式 の抽出は正規表現の1発マッチに頼らない。
# 理由: 「.{1,20}」節 のような貪欲マッチは、同じ行に複数の「...」対がある場合に
# 最初の「から最後の」節までを一つに merge してしまうことがあり（POSIX ERE の
# leftmost-longest）、かといって否定ブラケット `[^」]` は多バイト文字をブラケット式
# に入れることになり C ロケールで文字列を破壊する（本スクリプト冒頭の注記）。
# そこで awk の index()/substr() で終端記法の出現ごとに直前の最も近い「を手動で
# 探す」処理を書く。「と」節等はいずれも3バイトの UTF-8 文字だが、awk（macOS 標準
# の one-true-awk）の index()/substr() はバイト単位で動作するため、バイト長を
# 明示して境界を計算する。開き括弧の直前テキストは detect_scope() に渡し、
# ファイル指定の有無を判定する。
# 検査していない記法: 「05「完了」」のように終端語（節／の手順等）を伴わない
# 裸の「ファイル接頭辞 + 引用」は対象外にした。実測すると「hotl-pm/SKILL.md の
# 「同一ターン内で続行」」のように、節名ではなく単なる引用フレーズが同じ形に
# 現れるため、終端語なしで拾うと誤検知（本文中の言い回しをプール不在で FAIL に
# する）が生じる。終端語を伴わない参照はレビュアーの目視に委ねる。
cat > "$WORK/quote_extract.awk" <<'AWK_EOF'
BEGIN {
  nsuf = 0
  suf[nsuf++] = "」節"
  suf[nsuf++] = "」の手順"
  suf[nsuf++] = "」に従う"
  suf[nsuf++] = "」の書式"
  # 実在の参照で使われている終端語（改名時に見逃しが出ていたもの）
  suf[nsuf++] = "」項目"
  suf[nsuf++] = "」参照"
  suf[nsuf++] = "」を出す"
  suf[nsuf++] = "」に従い"
  suf[nsuf++] = "」の ⚠️"
  suf[nsuf++] = "」の ⏸"
  suf[nsuf++] = "」で報告"
  suf[nsuf++] = "」の未実施手順"
  suf[nsuf++] = "」が定める"
  suf[nsuf++] = "」の最終報告"
}
{
  line = $0
  for (si = 0; si < nsuf; si++) {
    marker = suf[si]
    mlen_b = length(marker)
    pos = 1
    while (1) {
      rest = substr(line, pos)
      idx = index(rest, marker)
      if (idx == 0) break
      abs_end = pos + idx - 1
      prefix = substr(line, 1, abs_end - 1)
      last_open = 0
      p2 = 1
      while (1) {
        rest2 = substr(prefix, p2)
        idx2 = index(rest2, "「")
        if (idx2 == 0) break
        last_open = p2 + idx2 - 1
        p2 = last_open + 1
      }
      if (last_open > 0) {
        namestart = last_open + 3
        namelen = abs_end - namestart
        if (namelen > 0) {
          name = substr(line, namestart, namelen)
          pre = substr(line, 1, last_open - 1)
          scope = detect_scope(pre)
          # 節見出しではなく「文面の例」を引用したもの（例: 「前回どこまで／今から何を」）
          # を除外する。節名に全角スラッシュ・句点・「例:」は現れない。
          if (index(name, "／") > 0 || index(name, "。") > 0 || index(name, "例:") > 0) {
            pos = abs_end + mlen_b
            continue
          }
          print FNR "\t" name "\t" scope
        }
      }
      pos = abs_end + mlen_b
    }
  }
}
AWK_EOF

for f in $TARGET_MD_FILES; do
  matches="$(awk -f "$WORK/file_scope.awk" -f "$WORK/quote_extract.awk" "$ROOT/$f" || true)"
  [ -z "$matches" ] && continue
  while IFS="$(printf '\t')" read -r lineno name scope; do
    [ -z "$lineno" ] && continue
    # 見出し側と同じ正規化（"（"/"(" 以降を切り落とす）を引用名にも適用する。
    # 例: 「判断に迷ったら（執筆時の原則）」節 は見出し「## 判断に迷ったら（執筆時の原則）」
    # を指しており、プールには括弧を落としたコア名で入っている
    core="$(printf '%s' "$name" | sed -E 's/(（|\().*$//')"
    if [ "$scope" = "DEFAULT" ]; then
      pool_file="$POOL"
      note=""
    else
      scoped_path="$(scope_path "$scope")"
      pool_file="$WORK/pool_$scope.txt"
      note="（${scoped_path:-指定先不明} 指定）"
    fi
    if [ "$scope" = "DEFAULT" ]; then
      # ファイル指定が無い参照は、まず自ファイルの見出しで照合する。
      # 他ファイルにだけ同名の見出しがある場合を OK にすると、自ファイルの
      # 見出しを改名しても他ファイルの同名ラベルに救われて見逃す。
      own_pool="$WORK/pool_own_$(printf '%s' "$f" | tr '/.' '__').txt"
      [ -f "$own_pool" ] || build_pool_of "$f" > "$own_pool"
      if grep -qxF "$core" "$own_pool"; then
        result OK "$f:$lineno: 「$name」 に対応する見出し／強調ラベルが自ファイルに存在する"
      elif grep -qxF "$core" "$POOL"; then
        result WARN "$f:$lineno: 「$name」 は自ファイルに無く、他ファイルの見出しと一致している（参照先を明示するか、自ファイルの見出しを確認）"
      else
        result FAIL "$f:$lineno: 「$name」 に対応する見出し／強調ラベルが見つからない"
      fi
    elif grep -qxF "$core" "$pool_file"; then
      result OK "$f:$lineno: 「$name」$note に対応する見出し／強調ラベルが存在する"
    else
      result FAIL "$f:$lineno: 「$name」$note に対応する見出し／強調ラベルが見つからない"
    fi
  done <<EOF
$matches
EOF
done

echo "==== 2c. 手順N の自己参照（05-development.md の番号付き手順） ===="

# 05-development.md には "## 手順N" のような見出しは存在せず、"## " 見出しの
# 節内に現れる番号付きリスト（例: 0. / 1. / 1.5. / 2. / 3. / 4. とその下の
# 入れ子リスト 1. / 2. / 3.）を「手順N」「手順N-M」の形で自己参照している。
# 見出し節ごとにスコープを区切ってマーカー集合を作り、各参照の主番号 N が
# 同じ節内の番号付きリストに実在するか、ハイフン付きの副番号 M が同じ節内の
# （入れ子を問わない）番号付きリストのどこかに実在するかを検査する。
# 節をまたぐ厳密な親子対応までは検査しない（複数の番号付きリストが同じ節に
# 同居する場合、どちらの子リストかまでは判定しない）。誤検知を避けるための
# 意図的な緩さ。
cat > "$WORK/tejun.awk" <<'AWK_EOF'
{
  n++
  lines[n] = $0
}
END {
  sec = 0
  for (i = 1; i <= n; i++) {
    if (lines[i] ~ /^## /) {
      sec++
      h = lines[i]
      sub(/^##[ \t]*/, "", h)
      gsub(/\*/, "", h)
      secname[sec] = h
    }
    linesec[i] = sec
    line = lines[i]
    if (match(line, /^[ \t]*[0-9]+(\.[0-9]+)?\./)) {
      m = substr(line, RSTART, RLENGTH)
      gsub(/^[ \t]*/, "", m)
      sub(/\.$/, "", m)
      markers[sec SUBSEP m] = 1
    }
  }
  for (i = 1; i <= n; i++) {
    line = lines[i]
    rest = line
    while (match(rest, /手順[0-9]+(\.[0-9]+)?(-[0-9]+)?/)) {
      ref = substr(rest, RSTART, RLENGTH)
      s = linesec[i]
      # 参照の直前が 「<節名>」の … なら、その節の番号集合で照合する
      # （節をまたぐ参照を自節の番号で誤って OK にしないため）
      abs_start = (length(line) - length(rest)) + RSTART
      pre = substr(line, 1, abs_start - 1)
      if (length(pre) >= 6 && substr(pre, length(pre) - 5) == "」の") {
        inner = substr(pre, 1, length(pre) - 6)
        lo = 0
        q = 1
        while (1) {
          r2 = substr(inner, q)
          i2 = index(r2, "「")
          if (i2 == 0) break
          lo = q + i2 - 1
          q = lo + 1
        }
        if (lo > 0) {
          nm = substr(inner, lo + 3)
          for (k = 1; k <= sec; k++) {
            if (nm != "" && index(secname[k], nm) > 0) { s = k; break }
          }
        }
      }
      body = ref
      sub(/^手順/, "", body)
      main = body
      subp = ""
      p = index(body, "-")
      if (p > 0) {
        main = substr(body, 1, p - 1)
        subp = substr(body, p + 1)
      }
      mainok = ((s SUBSEP main) in markers)
      subok = 1
      if (subp != "") subok = ((s SUBSEP subp) in markers)
      status = "OK"
      if (!mainok || !subok) status = "FAIL"
      print status "\t" i "\t" ref
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
}
AWK_EOF

tejun_out="$(awk -f "$WORK/tejun.awk" "$ROOT/skills/hotl/playbooks/05-development.md" || true)"
if [ -n "$tejun_out" ]; then
  while IFS="$(printf '\t')" read -r status lineno ref; do
    [ -z "$status" ] && continue
    f="skills/hotl/playbooks/05-development.md"
    if [ "$status" = "OK" ]; then
      result OK "$f:$lineno: $ref は同じ節内の番号付き手順に対応する"
    else
      result FAIL "$f:$lineno: $ref に対応する番号付き手順が同じ節内に見つからない"
    fi
  done <<EOF
$tejun_out
EOF
fi

echo "==== 3. phase 名の集合一致 ===="

# 正: SKILL.md Step 5 の phase -> playbook 対応表（実行時にルーティングを
# 決める唯一の表）。ここから正準集合を導出し、README のフェーズ遷移図
# （mermaid）・playbook 中の "phase: \`x\`" 記法・templates/state.json の
# 初期値を突き合わせる。
canon="$(awk '
  /^## Step 5:/ { insec = 1; next }
  /^## Step 6:/ { insec = 0 }
  insec && /^\| [a-z_]+ \|/ {
    line = $0
    sub(/^\| /, "", line)
    sub(/ \|.*/, "", line)
    print line
  }
' "$ROOT/skills/hotl/SKILL.md" | tr '\n' ' ')"

if [ -z "$canon" ]; then
  result FAIL "SKILL.md Step 5 の phase 対応表から正準 phase 集合を抽出できなかった（表の書式が変わった可能性）"
else
  result OK "正準 phase 集合を SKILL.md Step 5 の対応表から抽出: $canon"
fi

# README のフェーズ遷移図（mermaid stateDiagram-v2）。
# README には複数の ```mermaid ブロック（状態遷移図と実行アーキテクチャ図）があるため、
# "stateDiagram-v2" を含むブロックだけを取り出す（他方の flowchart ブロックの
# ノード名・矢印記法を誤って phase 名として拾わないようにするため）。
mermaid_block="$(awk '
  /```mermaid/ { infence = 1; buf = ""; next }
  infence && /```/ { infence = 0; if (buf ~ /stateDiagram-v2/) printf "%s", buf; next }
  infence { buf = buf $0 "\n" }
' "$ROOT/README.md")"
mermaid_states="$(printf '%s\n' "$mermaid_block" \
  | sgrep -E '^[ 	]*[A-Za-z_]+ --> [A-Za-z_]+' \
  | sed -E 's/^[ 	]*([A-Za-z_]+) --> ([A-Za-z_]+).*/\1\n\2/' \
  | sort -u)"

if [ -z "$mermaid_states" ]; then
  result WARN "README.md の mermaid stateDiagram-v2 から phase 名を抽出できなかった（図の書式が変わった可能性。手動確認を推奨）"
else
  mermaid_states_flat="$(printf '%s' "$mermaid_states" | tr '\n' ' ')"
  while IFS= read -r st; do
    [ -z "$st" ] && continue
    if in_set "$st" "$canon"; then
      result OK "README mermaid の状態 '$st' は正準 phase 集合に含まれる"
    else
      result FAIL "README mermaid の状態 '$st' は SKILL.md Step 5 の phase 集合に無い未知の phase 名"
    fi
  done <<EOF
$mermaid_states
EOF
  for p in $canon; do
    if in_set "$p" "$mermaid_states_flat"; then
      result OK "正準 phase '$p' は README mermaid で使用されている"
    else
      result WARN "正準 phase '$p' が README.md のフェーズ遷移図に一度も現れない（図の説明漏れの可能性）"
    fi
  done
fi

# playbook / SKILL.md 中の phase 言及。旧来の "phase: `x`" だけでなく、以下の
# 代表的な記法もカバーする:
#   STRONG（バッククォート語の位置が文脈上ほぼ確実に phase 値）:
#     ・phase が `x`（`hearing` / `awaiting_approval` のような "/" 連鎖も含む）
#     ・`phase` が `x`（`phase` 自体がバッククォート付きの場合も同様）
#     ・phase を `x` に
#     ・phase: `x` / phase： `x` / 次 phase: `x`
#   WEAK（"のとき"・"フェーズ" は phase 以外の語にも多用されるため、正準集合に
#   近い〔レーベンシュタイン距離2以下の〕未知語のときだけ WARN にする。無関係語
#   まで拾って誤検知を出さないことを優先する）:
#     ・`x` のとき
#     ・`x` フェーズ
# STRONG で見つかった位置は WEAK 側の重複検出から除外する（`phase が \`x\` のとき`
# のように両方にマッチしうるため、二重報告を避ける）。
# 検査していない記法: 「不具合報告は同項目のただし書きで `development`」のように
# phase・が/を/のとき・フェーズのいずれとも直接結びつかない裸のバッククォート語は
# 対象外にした（文脈が phase 値なのか他の識別子なのか機械的に確実な判定ができない
# ため。誤検知を避けることを優先する）。
cat > "$WORK/phase_scan.awk" <<'AWK_EOF'
{
  line = $0
  delete seen
  scan_chain(line, "(`phase`|phase)[ \t]*が[ \t]*(`[a-zA-Z_]+`[ \t]*/[ \t]*)*`[a-zA-Z_]+`", "STRONG")
  scan_chain(line, "(`phase`|phase)[ \t]*を[ \t]*`[a-zA-Z_]+`[ \t]*に", "STRONG")
  scan_chain(line, "(phase:|phase：)[ ]?`[a-zA-Z_]+`", "STRONG")
  scan_chain(line, "`[a-zA-Z_]+`[ \t]*のとき", "WEAK")
  scan_chain(line, "`[a-zA-Z_]+`[ \t]*フェーズ", "WEAK")
}

function scan_chain(line, re, cat,    rest, base, mstart, mlen, chunk, abs0) {
  rest = line
  base = 0
  while (match(rest, re)) {
    mstart = RSTART; mlen = RLENGTH
    chunk = substr(rest, mstart, mlen)
    abs0 = base + mstart - 1
    extract_tokens(chunk, abs0, cat)
    base = base + mstart + mlen - 1
    rest = substr(rest, mstart + mlen)
  }
}

function extract_tokens(chunk, baseabs, cat,    r, b, ms, ml, tok, abspos, key) {
  r = chunk; b = 0
  while (match(r, /`[a-zA-Z_]+`/)) {
    ms = RSTART; ml = RLENGTH
    tok = substr(r, ms + 1, ml - 2)
    abspos = baseabs + b + ms - 1
    key = abspos
    # `phase` 自体（アンカーがバッククォート付きの場合の当のトークン）は
    # phase の値ではないので対象外にする
    if (tok != "phase" && !(key in seen)) {
      print cat "\t" FNR "\t" tok
      seen[key] = 1
    }
    b = b + ms + ml - 1
    r = substr(r, ms + ml)
  }
}
AWK_EOF

cat > "$WORK/levenshtein.awk" <<'AWK_EOF'
function lev(a, b,    la, lb, i, j, cost, ca, cb, d1, d2, d3, m,   prev, cur) {
  la = length(a); lb = length(b)
  for (j = 0; j <= lb; j++) prev[j] = j
  for (i = 1; i <= la; i++) {
    cur[0] = i
    ca = substr(a, i, 1)
    for (j = 1; j <= lb; j++) {
      cb = substr(b, j, 1)
      cost = (ca == cb) ? 0 : 1
      d1 = prev[j] + 1
      d2 = cur[j - 1] + 1
      d3 = prev[j - 1] + cost
      m = d1
      if (d2 < m) m = d2
      if (d3 < m) m = d3
      cur[j] = m
    }
    for (j = 0; j <= lb; j++) prev[j] = cur[j]
  }
  return prev[lb]
}
BEGIN {
  n = split(canon, arr, " ")
  best = 999
  for (i = 1; i <= n; i++) {
    d = lev(tok, arr[i])
    if (d < best) best = d
  }
  print best
}
AWK_EOF

# WEAK 判定のあいまい度合いの閾値（正準集合とのレーベンシュタイン距離）
PHASE_CLOSE_THRESHOLD=2

for f in $TARGET_MD_FILES; do
  matches="$(awk -f "$WORK/phase_scan.awk" "$ROOT/$f" || true)"
  [ -z "$matches" ] && continue
  while IFS="$(printf '\t')" read -r cat lineno val; do
    [ -z "$cat" ] && continue
    if in_set "$val" "$canon"; then
      result OK "$f:$lineno: phase \`$val\` は正準 phase 集合に含まれる"
    elif [ "$cat" = "STRONG" ]; then
      result FAIL "$f:$lineno: phase \`$val\` は SKILL.md Step 5 の phase 集合に無い未知の phase 名"
    else
      dist="$(awk -v tok="$val" -v canon="$canon" -f "$WORK/levenshtein.awk" </dev/null)"
      if [ "$dist" -le "$PHASE_CLOSE_THRESHOLD" ]; then
        result WARN "$f:$lineno: \`$val\` は phase 名に近いが正準集合に無い（文脈が曖昧なため WARN。typo の可能性を確認）"
      fi
      # 正準集合から離れた語は phase 文脈と断定できないため報告しない（誤検知回避）
    fi
  done <<EOF
$matches
EOF
done

# templates/state.json の初期 phase 値
state_phase="$(sgrep -oE '"phase": "[a-z_]+"' "$ROOT/skills/hotl/templates/state.json" | head -1 | sed -E 's/"phase": "([a-z_]+)"/\1/')"
if [ -n "$state_phase" ]; then
  if in_set "$state_phase" "$canon"; then
    result OK "templates/state.json の初期 phase 値 '$state_phase' は正準 phase 集合に含まれる"
  else
    result FAIL "templates/state.json の初期 phase 値 '$state_phase' は未知の phase 名"
  fi
else
  result WARN "templates/state.json から phase 値を抽出できなかった"
fi

# --- 3b. 人間向けフェーズラベル表の網羅 --------------------------------------
# reporting.md の「用語」規則は phase 名を人間向けラベルに置き換える表を持つ。
# ここから phase が抜けると、人間向け文面に内部用語がそのまま漏れる。
label_line="$(sgrep -n 'フェーズ名は次のラベルで書く' "$ROOT/skills/hotl/playbooks/reporting.md" | head -1)"
if [ -z "$label_line" ]; then
  result FAIL "skills/hotl/playbooks/reporting.md: フェーズ名のラベル表が見つからない"
else
  label_lineno="${label_line%%:*}"
  label_text="$(sed -n "${label_lineno}p" "$ROOT/skills/hotl/playbooks/reporting.md")"
  for ph in $canon; do
    if printf '%s' "$label_text" | grep -q "$ph="; then
      result OK "reporting.md:$label_lineno: phase \`$ph\` の人間向けラベルがある"
    else
      result FAIL "reporting.md:$label_lineno: phase \`$ph\` の人間向けラベルが表に無い（人間向け文面に内部用語が漏れる）"
    fi
  done
fi

echo "==== 3c. 対応記録の語彙（reporting.md の列挙が正） ===="

# playbook 側で使う 対応記録「X」 の X が reporting.md「対応の記録」の列挙にあるか。
# 監査の未処理判定は語の一致で行われるため、語彙のドリフトは実害になる。
# ブラケット式 [^」] は C ロケールで壊れるので awk の index/substr で切り出す。
cat > "$WORK/vocab_extract.awk" <<'AWK_EOF'
{
  line = $0
  while (1) {
    p = index(line, "対応記録「")
    if (p == 0) break
    rest = substr(line, p + length("対応記録「"))
    q = index(rest, "」")
    if (q == 0) break
    print substr(rest, 1, q - 1)
    line = substr(rest, q + 1)
  }
}
AWK_EOF

vocab_line="$(sgrep -n '対応の記録' "$ROOT/skills/hotl/playbooks/reporting.md" | head -1)"
if [ -z "$vocab_line" ]; then
  result FAIL "skills/hotl/playbooks/reporting.md: 「対応の記録」の語彙定義が見つからない"
else
  vocab_no="${vocab_line%%:*}"
  sed -n "${vocab_no}p" "$ROOT/skills/hotl/playbooks/reporting.md" \
    | sed -E 's/^.*結果（//' \
    | tr '/' '\n' \
    | sed -E 's/〔.*$//; s/）.*$//; s/\*\*//g; s/^[ \t]+//; s/[ \t]+$//' \
    | grep -v '^$' > "$WORK/vocab.txt"
  for f in $SKILLS_NON_TEMPLATE_MD; do
    uses="$(awk -f "$WORK/vocab_extract.awk" "$ROOT/$f" | sort -u)"
    [ -z "$uses" ] && continue
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      # trail の行は「対応: <語>」の形なので、接頭辞が付いた書き方も同じ語として扱う
      ubare="${u#対応: }"
      if grep -qxF "$ubare" "$WORK/vocab.txt"; then
        result OK "$f: 対応記録「$u」は reporting.md の語彙にある"
      else
        result WARN "$f: 対応記録「$u」が reporting.md の語彙一覧に無い（語彙のドリフト）"
      fi
    done <<EOF2
$uses
EOF2
  done
fi

echo "==== 4. state.json フィールド参照 ===="

# templates/state.json をインデント幅で簡易パースし、
# (a) 厳密なドット記法パス集合（例: approval.approved）と
# (b) 深さを問わない葉キー名の集合（curated なあいまいでない名前だけを後で使う）
# を作る。フル JSON パーサではないが、この固定フォーマットのテンプレートに対しては
# 十分に正確（2 スペース/4 スペースインデント運用が前提）。
STATE_JSON="$ROOT/skills/hotl/templates/state.json"

dotted_paths="$(awk '
  /^  "[a-zA-Z0-9_]+":/ {
    line = $0
    sub(/^  "/, "", line); sub(/".*/, "", line)
    key = line
    print key
    parent = key
    next
  }
  /^    "[a-zA-Z0-9_]+":/ {
    line = $0
    sub(/^    "/, "", line); sub(/".*/, "", line)
    key = line
    print parent "." key
    next
  }
' "$STATE_JSON")"

DOTTED_PATHS_FILE="$WORK/dotted_paths.txt"
printf '%s\n' "$dotted_paths" > "$DOTTED_PATHS_FILE"

# 保留機能のフィールド（`lock`）は plans/ にのみ現れる想定であり、plans/ は
# そもそも本スクリプトの走査対象に含めていないため、ここで特別扱いする必要はない。

# 曖昧さの低い（他の意味に読めない）裸のフィールド名だけを bare 参照チェックの対象にする。
# `phase` `repo` `project` `approval` `artifacts` 等の一般的な単語は、フィールド名以外の
# 意味でも頻出するため、裸のバックティック単体では判定しない（誤検知回避を優先）。
# ドット記法（例: `approval.approved`）で明示された場合のみそれらも検査する。
# 注: 裸のフィールド名は「この名前が出てきたら state.json に在るはず」を確かめるだけで、
#     `approved_byx` のような typo は列に無いので 0 件マッチとなり素通りする（検査数が
#     1 減るだけ）。バッククォート付きのドット記法（検査4 の本体）と違い、裸の語を網羅的に
#     疑うと誤検知が増えるための設計上の限界。
BARE_CURATED="approved_by approved_at document_sha256 phase_history created_at updated_at hearing_notes"

for f in $TARGET_MD_FILES; do
  # ドット記法（末尾が .md/.json/.sh のファイル名参照は除外）
  matches="$(sgrep -noE '`[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)+`' "$ROOT/$f")"
  if [ -n "$matches" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      lineno="${line%%:*}"
      ref="${line#*:}"
      tok="$(printf '%s' "$ref" | tr -d '`')"
      case "$tok" in
        *.md|*.json|*.sh) continue ;;
      esac
      # `state.phase` のような "state." 接頭辞は state.json 自体を指す変数名で
      # あって state.json 内のキーではないため、照合前に剥がす
      # （`state.approval.approved` → `approval.approved`）。
      lookup_tok="$tok"
      case "$lookup_tok" in
        state.*) lookup_tok="${lookup_tok#state.}" ;;
      esac
      if grep -qxF "$lookup_tok" "$DOTTED_PATHS_FILE"; then
        result OK "$f:$lineno: state フィールド \`$tok\` は state.json に実在する"
      else
        # 根のキーが state.json のトップレベルに無いドット付き識別子は、state の
        # フィールド参照ではない可能性が高い（例: git config の `user.name`）。
        # 根が実在する場合のみ「パスの誤り」と断定して FAIL、そうでなければ WARN。
        root_tok="${lookup_tok%%.*}"
        if grep -qxF "$root_tok" "$DOTTED_PATHS_FILE"; then
          result FAIL "$f:$lineno: state フィールド \`$tok\` が templates/state.json に見つからない"
        else
          result WARN "$f:$lineno: \`$tok\` は state.json のキーではない（state 参照なら誤り、他の識別子なら無視してよい）"
        fi
      fi
    done <<EOF
$matches
EOF
  fi

  # 曖昧さの低い裸のフィールド名
  matches2="$(sgrep -noE "\`($(printf '%s' "$BARE_CURATED" | tr ' ' '|'))\`" "$ROOT/$f")"
  if [ -n "$matches2" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      lineno="${line%%:*}"
      ref="${line#*:}"
      tok="$(printf '%s' "$ref" | tr -d '`')"
      if grep -qxE "(^|.*\.)$tok\$" "$DOTTED_PATHS_FILE"; then
        result OK "$f:$lineno: state フィールド \`$tok\` は state.json に実在する"
      else
        result FAIL "$f:$lineno: state フィールド \`$tok\` が templates/state.json に見つからない"
      fi
    done <<EOF
$matches2
EOF
  fi
done

echo "==== 5. ID 記法（R-n / NR-n / S-n / T-n / L-n 以外の接頭辞） ===="

# B-n は plans/ 専用の ID（保留機能の設計メモ）であり、本スクリプトの走査対象
# （skills/ + README/PRINCIPLES/install.sh）には plans/ を含めていないので、
# ここに出てくる時点で誤用の可能性が高い。
ALLOWED_ID_PREFIXES="R NR S T L"
for f in $SKILLS_NON_TEMPLATE_MD; do
  matches="$(sgrep -noE '\b[A-Z]{1,4}-[0-9]+\b' "$ROOT/$f")"
  [ -z "$matches" ] && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    ref="${line#*:}"
    prefix="${ref%%-*}"
    if in_set "$prefix" "$ALLOWED_ID_PREFIXES"; then
      result OK "$f:$lineno: ID \`$ref\` は許可された接頭辞"
    elif sed -n "${lineno}p" "$ROOT/$f" | grep -q 'plans/'; then
      # 同じ行が plans/ のパスを明示していれば、plans/ 側の ID の正当な外部参照
      result OK "$f:$lineno: ID \`$ref\` は plans/ への明示参照"
    else
      result WARN "$f:$lineno: ID \`$ref\` は想定外の接頭辞（許可: R-n/NR-n/S-n/T-n/L-n。plans/ の ID を参照するならパスを明記する）"
    fi
  done <<EOF
$matches
EOF
done
# templates/*.md（記法の定義元）も同じ規約に従うはずなので合わせて検査する
for f in skills/hotl/templates/design.md skills/hotl/templates/requirements.md skills/hotl/templates/spec.md skills/hotl/templates/tasks.md; do
  matches="$(sgrep -noE '\b[A-Z]{1,4}-[0-9]+\b' "$ROOT/$f")"
  [ -z "$matches" ] && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    ref="${line#*:}"
    prefix="${ref%%-*}"
    if in_set "$prefix" "$ALLOWED_ID_PREFIXES"; then
      result OK "$f:$lineno: ID \`$ref\` は許可された接頭辞"
    elif sed -n "${lineno}p" "$ROOT/$f" | grep -q 'plans/'; then
      # 同じ行が plans/ のパスを明示していれば、plans/ 側の ID の正当な外部参照
      result OK "$f:$lineno: ID \`$ref\` は plans/ への明示参照"
    else
      result WARN "$f:$lineno: ID \`$ref\` は想定外の接頭辞（許可: R-n/NR-n/S-n/T-n/L-n。plans/ の ID を参照するならパスを明記する）"
    fi
  done <<EOF
$matches
EOF
done

echo "==== 6. テンプレートのガイドコメント残存 ===="

# skills/**/*.md の非テンプレートファイルに生の <!-- ... --> が残っていないか。
# ただしバッククォートで囲まれた表記（例: `<!-- ... -->` として記法そのものを
# 説明している箇所）は残存コメントではないので対象外にする
# （直前の文字がバッククォートかどうかで判定）。
for f in $SKILLS_NON_TEMPLATE_MD; do
  matches="$(sgrep -n '<!--' "$ROOT/$f")"
  [ -z "$matches" ] && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    content="${line#*:}"
    if printf '%s' "$content" | grep -qE '`<!--'; then
      result OK "$f:$lineno: <!-- はバッククォートで囲まれた記法の説明であり残存コメントではない"
    else
      result WARN "$f:$lineno: 生の <!-- ... --> がテンプレート以外のファイルに残っている可能性"
    fi
  done <<EOF
$matches
EOF
done

echo "==== サマリ ===="
echo "検査数: $TOTAL  FAIL: $FAILN  WARN: $WARNN"

if [ "$FAILN" -gt 0 ]; then
  exit 1
fi
exit 0
