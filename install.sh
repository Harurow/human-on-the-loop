#!/usr/bin/env bash
# human-on-the-loop: hotl スキルをターゲットプロジェクトにインストールする
#   ./install.sh --target <path> [--link] [--force]
#     --target  Claude Code プロジェクトのルート（.claude/skills/hotl に配置される）
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
DEST="$TARGET/.claude/skills/hotl"

# 既に同じ symlink が張られていれば no-op
if $LINK && [[ -L "$DEST" && "$(readlink "$DEST")" == "$SRC" ]]; then
  echo "既にリンク済み: $DEST -> $SRC"
  exit 0
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
  - プロジェクトで Claude Code のセッションを開き「新しいアプリを作りたい」等で hotl が起動します
  - 既存プロジェクトの再開は「続きから」「開発を進めて」
EOS
