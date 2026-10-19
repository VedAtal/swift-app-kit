#!/usr/bin/env bash
#
# One-step install for a swift-app-kit app. Builds the app, installs it to ~/Applications, and launches it.
#
#   ./setup.sh               install the latest version from GitHub
#   ./setup.sh --local       install from this folder, including uncommitted changes
#   ./setup.sh --build-only  build build/<App>.app from this folder without installing
#   ./setup.sh --uninstall   remove the app, its data, settings, login item, and signing key
#
# Each app's own setup.sh (a copy of templates/setup.sh) runs this with APP_ROOT set to the app's
# folder, whose app.env says what to build. Installed apps carry a copy of this script and of
# app.env in Contents/Resources; "Update <App>" runs that copy, with no APP_ROOT.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${APP_ROOT:-}" ]]; then
  ROOT="$(cd "$APP_ROOT" && pwd)"
  CONFIG="$ROOT/app.env"
  cd "$ROOT"
else
  ROOT=""
  CONFIG="$SCRIPT_DIR/app.env"
fi
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG not found." >&2; exit 1; }

# app.env sets these. See templates/app.env.
APP_NAME="" BUNDLE_ID="" SYMBOL="" INSTALL_NOTES="" GLYPH=""
# shellcheck source=/dev/null
source "$CONFIG"
for var in APP_NAME BUNDLE_ID SYMBOL; do
  [[ -n "${!var}" ]] || { echo "error: $CONFIG doesn't set $var." >&2; exit 1; }
done
LOWER_NAME=$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
DATA_DIR="$HOME/Library/Application Support/$APP_NAME"
CACHE_DIR="$HOME/Library/Caches/$APP_NAME"  # holds the GitHub checkout that installs build from
LOG_DIR="$HOME/Library/Logs/$APP_NAME"

# macOS ties the Accessibility permission to the app's code signature. An ad-hoc signature
# changes with every build, which silently breaks the permission. So each app keeps a
# self-signed certificate in its own keychain and signs every build with it. The password only
# protects this throwaway key, which nothing outside this Mac uses.
KEYCHAIN="${SETUP_KEYCHAIN:-$HOME/Library/Keychains/$LOWER_NAME-codesign.keychain-db}"
KEYCHAIN_PASSWORD="$LOWER_NAME"
CERT_NAME="$APP_NAME Local Code Signing"
SIGN_ID="-"

# Colors only in a terminal. The "Update <App>" menu item runs this with output going to a log file.
if [[ -t 1 ]]; then
  BOLD=$'\033[1m' BLUE=$'\033[1;34m' YELLOW=$'\033[1;33m' RED=$'\033[1;31m' GREEN=$'\033[1;32m' RESET=$'\033[0m'
else
  BOLD="" BLUE="" YELLOW="" RED="" GREEN="" RESET=""
fi

step() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

require_project_folder() {
  [[ -n "$ROOT" && -f "$ROOT/Package.swift" ]] || die "$1 has to be run from the $APP_NAME project folder."
}

check_requirements() {
  [[ "$(uname)" == "Darwin" ]] || die "$APP_NAME only runs on macOS."
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  (( major >= 14 )) || die "$APP_NAME needs macOS 14 (Sonoma) or newer."
  if ! xcrun --find swift >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "Swift isn't installed. Finish installing the Command Line Tools in the window that just opened, then run ./setup.sh again."
  fi
}

# --- Code signing ---------------------------------------------------------------------------

create_signing_identity() {
  local tmp status=0
  tmp=$(mktemp -d)
  # /usr/bin/openssl (LibreSSL) on purpose: a Homebrew OpenSSL 3 writes .p12 files that
  # `security import` can't read.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$CERT_NAME" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -name "$CERT_NAME" -passout "pass:$LOWER_NAME" \
      -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/identity.p12" \
    && security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    && security set-keychain-settings "$KEYCHAIN" \
    && security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    && security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$LOWER_NAME" -T /usr/bin/codesign >/dev/null \
    && security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null \
    || status=1
  rm -rf "$tmp"
  return $status
}

# Sets SIGN_ID to the certificate's SHA-1, or leaves it as "-" (ad-hoc) if anything goes wrong.
ensure_signing_identity() {
  if [[ ! -f "$KEYCHAIN" ]]; then
    echo "    Creating a local code-signing certificate (one time)…"
    if ! create_signing_identity; then
      security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
      warn "Couldn't create a signing certificate. Using an ad-hoc signature, so you'll need to re-grant Accessibility after each rebuild."
      return 0
    fi
  fi
  # Custom keychains lock at logout, so unlock before every build.
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
  local id
  id=$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
       | awk -v name="\"$CERT_NAME\"" 'index($0, name) { print $2; exit }')
  if [[ -n "$id" ]]; then
    SIGN_ID="$id"
  else
    warn "Signing certificate not found in $KEYCHAIN. Using an ad-hoc signature."
  fi
}

# --- Build ----------------------------------------------------------------------------------

make_icon() {
  local icns="$BUILD_DIR/AppIcon.icns" iconset="$BUILD_DIR/AppIcon.iconset" glyph="${GLYPH:+$ROOT/$GLYPH}"
  # Reuse the last icon unless app.env, the glyph or the script that draws it has changed since.
  [[ "$icns" -nt "$SCRIPT_DIR/make-icon.swift" && "$icns" -nt "$CONFIG" && ( -z "$glyph" || "$icns" -nt "$glyph" ) ]] \
    && return 0
  rm -rf "$iconset"
  mkdir -p "$iconset"
  if swift "$SCRIPT_DIR/make-icon.swift" "$iconset" "${glyph:-$SYMBOL}" \
     && iconutil -c icns "$iconset" -o "$icns"; then
    rm -rf "$iconset"
  else
    rm -rf "$iconset"
    warn "Couldn't generate the app icon. Continuing without it."
  fi
}

write_info_plist() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- Menu bar only: no Dock icon, no app menu. -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- The menu bar icon (AppInfo.symbol). -->
	<key>AppSymbol</key>
	<string>$SYMBOL</string>
</dict>
</plist>
EOF
}

# git@github.com:owner/repo.git → https://github.com/owner/repo.git (other URLs unchanged).
# Updates download over HTTPS so they don't need your SSH key, which may have a passphrase.
https_url() {
  if [[ "$1" =~ ^git@([^:]+):(.+)$ ]] || [[ "$1" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    echo "https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo "$1"
  fi
}

# Records when and from which commit this build was made, and where updates come from. The menu
# shows the version, and "Update <App>" uses it to tell whether GitHub has anything newer.
record_build_info() {
  local plist="$1" commit repo
  plutil -insert AppBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist"
  if commit=$(git rev-parse HEAD 2>/dev/null); then
    # Uncommitted changes mean this build doesn't match any commit on GitHub.
    [[ -z "$(git status --porcelain 2>/dev/null)" ]] || commit+="-dirty"
    plutil -insert AppCommit -string "$commit" "$plist"
    plutil -insert AppCommitSubject -string "$(git log -1 --format=%s)" "$plist"
  fi
  if repo=$(git remote get-url origin 2>/dev/null); then
    plutil -insert AppRepositoryURL -string "$(https_url "$repo")" "$plist"
  fi
}

build_app() {
  step "Building ${APP_NAME}…"
  # The filter hides harmless linker warnings that only show up with the Command Line Tools.
  # It always succeeds, so with pipefail the status is swift's.
  local status=0
  swift build -c release --product "$APP_NAME" 2>&1 \
    | { grep --line-buffered -v "ld: warning: search path" || true; } || status=$?
  (( status == 0 )) || die "Build failed. See the errors above."
  local bin
  bin="$(swift build -c release --show-bin-path)/$APP_NAME"

  step "Assembling $APP_NAME.app…"
  [[ -z "$GLYPH" || -f "$ROOT/$GLYPH" ]] || die "app.env sets GLYPH to $GLYPH, but that file isn't in $ROOT."
  mkdir -p "$BUILD_DIR"
  make_icon
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$bin" "$APP/Contents/MacOS/$APP_NAME"
  write_info_plist "$APP/Contents/Info.plist"
  record_build_info "$APP/Contents/Info.plist"
  # The "Update <App>" menu item runs this bundled copy (in its default, install-from-GitHub mode).
  cp "$SCRIPT_DIR/setup.sh" "$APP/Contents/Resources/setup.sh"
  cp "$CONFIG" "$APP/Contents/Resources/app.env"
  if [[ -f "$BUILD_DIR/AppIcon.icns" ]]; then
    cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  fi
  if [[ -n "$GLYPH" ]]; then
    cp "$ROOT/$GLYPH" "$APP/Contents/Resources/Glyph.png"
  fi

  step "Signing…"
  ensure_signing_identity
  if [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --sign - "$APP"
  else
    codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" "$APP"
  fi
}

# --- Install from GitHub --------------------------------------------------------------------

# Where to download from: $SETUP_REPO if set, else this folder's origin. The "Update <App>" menu
# item sets $SETUP_REPO from the running app's Info.plist, because the copy of this script inside
# the app bundle isn't in a git checkout.
repository_url() {
  if [[ -n "${SETUP_REPO:-}" ]]; then
    echo "$SETUP_REPO"
    return 0
  fi
  local origin
  [[ -n "$ROOT" ]] || return 1
  origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null) || return 1
  https_url "$origin"
}

# Downloads GitHub's latest commit into a private checkout and runs that checkout's
# `setup.sh --local`, so the build always uses the newest build steps too. Does nothing if the
# installed app was already built from that commit. ("Update <App>" relies on this: when the
# script exits 0 and the app is still running, nothing needed installing.)
install_from_github() {
  local repo latest installed checkout="$CACHE_DIR/source"
  repo=$(repository_url) \
    || die "This folder has no GitHub remote to install from. Use ./setup.sh --local to install it as it is."
  export GIT_TERMINAL_PROMPT=0  # never wait on a password prompt nobody can see

  step "Checking ${repo}…"
  latest=$(git ls-remote "$repo" HEAD 2>/dev/null | cut -f1)
  [[ -n "$latest" ]] || die "Couldn't reach $repo."

  # Running from a project checkout that has work GitHub doesn't? Point out --local.
  if [[ -z "${SETUP_REPO:-}" ]] \
     && { [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]] \
          || [[ "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" != "$latest" ]]; }; then
    echo "    Note: this folder doesn't match GitHub. To install what's here instead, run ./setup.sh --local"
  fi

  installed=$(plutil -extract AppCommit raw "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$latest" == "$installed" ]]; then
    echo "$APP_NAME is already up to date (${latest:0:7})."
    exit 0
  fi

  step "Downloading ${latest:0:7}…"
  if [[ -d "$checkout/.git" ]]; then
    git -C "$checkout" remote set-url origin "$repo"
    git -C "$checkout" fetch --quiet origin HEAD
    # Nobody edits this checkout by hand, so make it match GitHub exactly. Build caches are
    # gitignored, so they survive and rebuilds stay fast.
    git -C "$checkout" reset --quiet --hard FETCH_HEAD
    git -C "$checkout" clean -fdq
  else
    rm -rf "$checkout"
    mkdir -p "$CACHE_DIR"
    git clone --quiet "$repo" "$checkout"
  fi

  exec /bin/bash "$checkout/setup.sh" --local
}

# --- Install / uninstall --------------------------------------------------------------------

# -a matters: macOS pgrep/pkill skip the processes that started them unless told otherwise, and
# when "Update <App>" runs this script, the process to quit is the one that started it.
stop_running_app() {
  pgrep -a -x "$APP_NAME" >/dev/null || return 0
  pkill -a -x "$APP_NAME" || true
  for _ in {1..50}; do
    pgrep -a -x "$APP_NAME" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -a -x "$APP_NAME" || true
}

install_app() {
  step "Installing to ${INSTALLED_APP}…"
  stop_running_app
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  ditto "$APP" "$INSTALLED_APP"
  if [[ "$SIGN_ID" == "-" ]]; then
    # An old Accessibility grant won't match the new ad-hoc signature. Clear it so macOS asks again.
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  step "Launching…"
  if [[ -n "${SETUP_FROM_APP:-}" ]]; then
    open "$INSTALLED_APP" --args --updated  # the new copy shows "<App> was updated"
  else
    open "$INSTALLED_APP"
  fi

  printf '\n%s✓ %s is running.%s %s\n\n' "$GREEN" "$APP_NAME" "$RESET" "$INSTALL_NOTES"
}

uninstall() {
  step "Uninstalling ${APP_NAME}…"
  stop_running_app
  if [[ -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME" ]]; then
    "$INSTALLED_APP/Contents/MacOS/$APP_NAME" --unregister-login-item || true
  fi
  rm -rf "$INSTALLED_APP" "$DATA_DIR" "$CACHE_DIR" "$LOG_DIR"
  [[ -z "$ROOT" ]] || rm -rf "$BUILD_DIR"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -f "$KEYCHAIN" ]]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
  fi
  echo "$APP_NAME has been removed."
}

case "${1:-}" in
  "")           check_requirements; install_from_github ;;
  --local)      require_project_folder --local; check_requirements; build_app; install_app ;;
  --build-only) require_project_folder --build-only; check_requirements; build_app; echo "Built $APP" ;;
  --uninstall)  uninstall ;;
  -h|--help)    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)            die "Unknown option: $1 (try --help)" ;;
esac
