#!/usr/bin/env bash
# human-on-the-loop: hotl スキルをターゲットにインストールする
#   ./install.sh --target <path> [--pm] [--link] [--force]
#     --target  Claude Code プロジェクトのルート、または（--pm 時）ワークスペース（プロジェクト群を置く親フォルダ。ここに .claude/skills/ が作られる）
#     --pm      hotl-pm（マルチプロジェクトの旗振り役）も併せてインストールする
#     --link    コピーの代わりに symlink を張る（フレームワーク開発中の反映用）
#     --force   既存インストールを確認なしで上書きする（更新・非対話実行用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
LINK=false
FORCE=false
PM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; [[ -n "$TARGET" && "$TARGET" != --* ]] || { echo "Error: --target にはパスが必要です" >&2; exit 1; }; shift 2 ;;
    --pm)     PM=true; shift ;;
    --link)   LINK=true; shift ;;
    --force)  FORCE=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: ./install.sh --target <path> [--pm] [--link] [--force]" >&2
  exit 1
fi
if [[ ! -d "$TARGET" ]]; then
  echo "Error: target not found: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

install_skill() {
  local name="$1"
  local src="$ROOT/skills/$name"
  local dest="$TARGET/.claude/skills/$name"

  # 既に同じ symlink が張られていれば no-op
  if $LINK && [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    echo "既にリンク済み: $dest -> $src"
    return 0
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if $FORCE; then
      rm -rf "$dest"
    elif [[ -t 0 ]]; then
      read -r -p "既に存在します: $dest — 上書きしますか？ [y/N] " ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "スキップしました: $name"; return 0; }
      rm -rf "$dest"
    else
      echo "Error: 既に存在します: $dest — 非対話実行では --force を付けてください。" >&2
      exit 1
    fi
  fi

  mkdir -p "$(dirname "$dest")"
  if $LINK; then
    ln -s "$src" "$dest"
    echo "Linked: $dest -> $src"
  else
    cp -R "$src" "$dest"
    echo "Installed: $dest"
  fi
}

install_skill hotl
$PM && install_skill hotl-pm

cat <<'EOS'

次のステップ:
  - プロジェクトで Claude Code のセッションを開き「新しいアプリを作りたい」等で hotl が起動します
  - 既存プロジェクトの再開は「続きから」「開発を進めて」
  - --pm 導入時: ワークスペースでセッションを開き「状況を教えて」「◯◯を進めて」で hotl-pm が采配します
EOS
