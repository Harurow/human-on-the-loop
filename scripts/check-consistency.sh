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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
  esac
done

# 多バイト文字（日本語の「（」「：」等）をブラケット式 [...] の中に直接書くと、
# ロケールが C（非 UTF-8）の環境では 1 バイトずつバラして解釈され、文字列を
# 破壊することがある（例: s/[（(].*$// が「テスト可能性」を「テス�」に壊す）。
# 対策として、本スクリプトでは多バイト文字を含む文字クラス [...] を一切使わず、
# 必ず代替 (a|b) で書く（これはロケールに依存せず正しく動く）。
#
# 意図的に LC_ALL を UTF-8 ロケールへ変更しない: macOS 標準の /bin/bash は
# 3.2（GPLv3 回避のため凍結）であり、UTF-8 ロケール下でこのスクリプトのように
# 変数展開の直後に多バイト文字（「」等）が続くコードを実行すると、bash 自身の
# パーサが変数名の終端を誤検出し「name�: unbound variable」のように壊れる
# 既知の不具合がある。ブラケット式を避ける対策だけで C ロケールのままでも
# 文字列破壊は起きないため、LC_ALL は変更しない方が安全。

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

echo "==== 2a. 見出し相互参照: Step N（SKILL.md / hotl-pm / 05-development 各見出し） ===="

# 各ファイルの "## Step N" 見出し番号集合を取る
skill_steps="$(sgrep -oE '^## Step [0-9]+' "$ROOT/skills/hotl/SKILL.md" | sgrep -oE '[0-9]+' | tr '\n' ' ')"
pm_steps="$(sgrep -oE '^## Step [0-9]+' "$ROOT/skills/hotl-pm/SKILL.md" | sgrep -oE '[0-9]+' | tr '\n' ' ')"
dev_steps="$(sgrep -oE '^## Step [0-9]+' "$ROOT/skills/hotl/playbooks/05-development.md" | sgrep -oE '[0-9]+' | tr '\n' ' ')"

in_set() {
  # $1=needle $2=space separated haystack
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

for f in $TARGET_MD_FILES; do
  matches="$(sgrep -noE 'Step[ ]?[0-9]+' "$ROOT/$f")"
  [ -z "$matches" ] && continue
  case "$f" in
    skills/hotl-pm/SKILL.md) allowed="$pm_steps $skill_steps" ;;
    skills/hotl/playbooks/05-development.md) allowed="$dev_steps $skill_steps" ;;
    *) allowed="$skill_steps" ;;
  esac
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    ref="${line#*:}"
    n="$(printf '%s' "$ref" | sgrep -oE '[0-9]+')"
    if in_set "$n" "$allowed"; then
      result OK "$f:$lineno: Step $n は実在する見出しを指す"
    else
      result FAIL "$f:$lineno: \`$ref\` に対応する見出しが見つからない（既知の Step 番号: $allowed）"
    fi
  done <<EOF
$matches
EOF
done

echo "==== 2b. 見出し相互参照: 「XXX」節（quoted section name） ===="

# 見出しプール: 対象 Markdown ファイルの "## " 見出しと、"- **XXX**:" 形式の
# 強調ラベル（本フレームワークで「節」相当として頻用される記法）を集める。
# 見出しコアは "（"/"(" より前を使う（例: "## 非機能（性能と…）" -> "非機能"）。
# 「この節」「同節」「該当節」等の代名詞的参照はここでは解決できないため対象外
# （散文で言い換えられた節名の一致は PRINCIPLES.md が「機械チェックでは
# 捕まらないもの」として明示的にレビュアーへ委ねている）。
POOL="$WORK/heading_pool.txt"
: > "$POOL"
for f in $TARGET_MD_FILES; do
  sgrep -E '^#{1,6} ' "$ROOT/$f" | sed -E 's/^#{1,6} //'
  sgrep -E '^[ 	]*-[ ]+\*\*[^*]+\*\*' "$ROOT/$f" | sed -E 's/^[ 	]*-[ ]+\*\*//; s/\*\*.*$//'
done \
  | sed -E 's/(（|\().*$//' \
  | sed -E 's/[[:space:]]*(:|：)[[:space:]]*$//' \
  | sed -E 's/[[:space:]]+$//' \
  | sort -u > "$POOL"

# 「XXX」節 の抽出は正規表現の1発マッチに頼らない。理由: 「.{1,20}」節 のような
# 貪欲マッチは、同じ行に複数の「...」対がある場合に最初の「から最後の」節までを
# 一つに merge してしまうことがあり（POSIX ERE の leftmost-longest）、かといって
# 否定ブラケット `[^」]` は多バイト文字をブラケット式に入れることになり C ロケールで
# 文字列を破壊する（本スクリプト冒頭の注記）。そこで awk の index()/substr() で
# 「各」節」出現ごとに直前の最も近い「を手動で探す」処理を書く。「と」節はいずれも
# 3 バイトの UTF-8 文字だが、awk（macOS 標準の one-true-awk）の index()/substr() は
# バイト単位で動作するため、バイト長を明示して境界を計算する。
cat > "$WORK/quote_extract.awk" <<'AWK_EOF'
{
  line = $0
  pos = 1
  while (1) {
    rest = substr(line, pos)
    idx = index(rest, "」節")
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
      if (namelen > 0) print FNR "\t" substr(line, namestart, namelen)
    }
    pos = abs_end + 6
  }
}
AWK_EOF

for f in $TARGET_MD_FILES; do
  matches="$(awk -f "$WORK/quote_extract.awk" "$ROOT/$f" || true)"
  [ -z "$matches" ] && continue
  while IFS="$(printf '\t')" read -r lineno name; do
    [ -z "$lineno" ] && continue
    # 見出し側と同じ正規化（"（"/"(" 以降を切り落とす）を引用名にも適用する。
    # 例: 「判断に迷ったら（執筆時の原則）」節 は見出し「## 判断に迷ったら（執筆時の原則）」
    # を指しており、プールには括弧を落としたコア名で入っている
    core="$(printf '%s' "$name" | sed -E 's/(（|\().*$//')"
    if grep -qxF "$core" "$POOL"; then
      result OK "$f:$lineno: 「$name」節に対応する見出し／強調ラベルが存在する"
    else
      result FAIL "$f:$lineno: 「$name」節に対応する見出し／強調ラベルが見つからない"
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
    if (lines[i] ~ /^## /) sec++
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

# playbook / SKILL.md 中の "phase: `x`" 記法
for f in $TARGET_MD_FILES; do
  matches="$(sgrep -noE '(phase: |phase： |phase )`[a-z_]+`' "$ROOT/$f")"
  [ -z "$matches" ] && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lineno="${line%%:*}"
    ref="${line#*:}"
    val="$(printf '%s' "$ref" | sed -E 's/.*`([a-z_]+)`.*/\1/')"
    if in_set "$val" "$canon"; then
      result OK "$f:$lineno: phase \`$val\` は正準 phase 集合に含まれる"
    else
      result FAIL "$f:$lineno: phase \`$val\` は SKILL.md Step 5 の phase 集合に無い未知の phase 名"
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
      if grep -qxF "$tok" "$DOTTED_PATHS_FILE"; then
        result OK "$f:$lineno: state フィールド \`$tok\` は state.json に実在する"
      else
        result FAIL "$f:$lineno: state フィールド \`$tok\` が templates/state.json に見つからない"
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
