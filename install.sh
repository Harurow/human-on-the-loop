#!/usr/bin/env bash
# human-on-the-loop: hotl スキルをターゲットにインストールする
#   ./install.sh --target <path> [--link] [--force]
#     --target  Claude Code プロジェクトのルート、または nanoclaw の groups/<group> ディレクトリ
#     --link    コピーの代わりに symlink を張る（フレームワーク開発中の反映用）
#     --force   既存インストールを確認なしで上書きする（更新・非対話実行用）
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/skills/hotl"
TARGET=""
LINK=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; [[ -n "$TARGET" ]] || { echo "Error: --target にはパスが必要です" >&2; exit 1; }; shift 2 ;;
    --link)   LINK=true; shift ;;
    --force)  FORCE=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: ./install.sh --target <path> [--link] [--force]" >&2
  exit 1
fi
if [[ ! -d "$TARGET" ]]; then
  echo "Error: target not found: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

# nanoclaw グループ判定: groups/ 配下にあり CLAUDE.md を持つ
if [[ "$TARGET" == */groups/* && -f "$TARGET/CLAUDE.md" ]]; then
  DEST="$TARGET/skills/hotl"
  if $LINK; then
    echo "Error: nanoclaw グループへの --link は不可（コンテナが symlink 先を解決できない）。コピーで入れ直してください。" >&2
    exit 1
  fi
else
  DEST="$TARGET/.claude/skills/hotl"
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
  if $FORCE; then
    rm -rf "$DEST"
  elif [[ -t 0 ]]; then
    read -r -p "既に存在します: $DEST — 上書きしますか？ [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "中止しました。"; exit 0; }
    rm -rf "$DEST"
  else
    echo "Error: 既に存在します: $DEST — 非対話実行では --force を付けてください。" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$DEST")"
if $LINK; then
  ln -s "$SRC" "$DEST"
  echo "Linked: $DEST -> $SRC"
else
  cp -R "$SRC" "$DEST"
  echo "Installed: $DEST"
fi

cat <<'EOS'

次のステップ:
  - Claude Code: プロジェクトでセッションを開き「新しいアプリを作りたい」等で hotl が起動します
  - nanoclaw: コンテナ再起動後、Discord で「新しいアプリを作りたい」と送ってください
  - 既存プロジェクトの再開は「続きから」「開発を進めて」
EOS
