#!/usr/bin/env bash
#
# Installs a swift-app-kit app from GitHub without keeping a clone:
#
#   curl -fsSL https://raw.githubusercontent.com/VedAtal/swift-app-kit/main/scripts/install.sh | bash -s <app>
#
# <app> is the app's repo: "recall", or "owner/repo" outside VedAtal. It builds and installs the
# latest commit. After that, the app's "Update <App>" menu item keeps it current.
set -euo pipefail

# In a function, so `curl | bash` runs nothing until the whole script has downloaded.
main() {
  local repo="${1:-}"
  [[ -n "$repo" ]] || { echo "usage: … | bash -s <app>, for example bash -s recall" >&2; exit 1; }
  [[ "$repo" == */* ]] || repo="VedAtal/$repo"

  # Before git: on a fresh Mac, git is only a stub until the Command Line Tools are installed.
  if ! xcrun --find swift >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    echo "error: Swift isn't installed. Finish installing the Command Line Tools in the window that just opened, then run this again." >&2
    exit 1
  fi

  checkout=$(mktemp -d)  # global: the EXIT trap runs after main returns
  trap 'rm -rf "$checkout"' EXIT
  git clone --quiet --depth 1 "https://github.com/$repo.git" "$checkout" </dev/null \
    || { echo "error: Couldn't download https://github.com/$repo. Check the name and your internet connection." >&2; exit 1; }
  "$checkout/setup.sh" --local </dev/null
}

main "$@"
