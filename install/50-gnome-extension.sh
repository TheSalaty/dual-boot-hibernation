#!/usr/bin/env bash
# Module: GNOME power-menu extension. Sourced by install.sh.
# shellcheck disable=SC2154  # variables come from install.sh

banner "GNOME power-menu extension"
ext_ok=yes
EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
DIST_DIR="$HERE/gnome-extension/dist/$EXT_UUID"

# Find a packaged release zip shipped next to the installer, if any.
EXT_ZIP=""
for z in "$HERE"/*.shell-extension.zip; do [ -e "$z" ] && { EXT_ZIP="$z"; break; }; done

# Copy a fully built extension directory into place and compile its schema.
install_ext_from_dir() {
    rm -rf "$EXT_DIR"
    mkdir -p "$EXT_DIR"
    cp -a "$1"/. "$EXT_DIR"/
    [ -d "$EXT_DIR/schemas" ] && glib-compile-schemas "$EXT_DIR/schemas" >/dev/null 2>&1 || true
}

if [ -n "$EXT_ZIP" ] && command -v gnome-extensions >/dev/null; then
    step "Installing packaged extension ($(basename "$EXT_ZIP"))…"
    gnome-extensions install --force "$EXT_ZIP" >/dev/null 2>&1 \
        && ok "installed from zip" || { err "gnome-extensions install failed"; ext_ok=no; }
elif [ -d "$DIST_DIR" ]; then
    step "Installing pre-built extension from gnome-extension/dist/…"
    install_ext_from_dir "$DIST_DIR"; ok "installed from dist"
elif command -v npm >/dev/null; then
    step "Building the extension from source (npm ci && npm run build)…"
    if ( cd "$HERE" && npm ci >/dev/null 2>&1 && npm run build >/dev/null 2>&1 ) && [ -d "$DIST_DIR" ]; then
        install_ext_from_dir "$DIST_DIR"; ok "built and installed"
    else
        err "npm build failed"; ext_ok=no
    fi
else
    warn "No release zip, no gnome-extension/dist/, and npm is not installed."
    warn "Build it with 'npm run pack' (needs Node) or download the release zip,"
    warn "then re-run — the rest of the setup is unaffected."
    ext_ok=skip
fi

if [ "$ext_ok" = yes ]; then
    # The extension had another UUID before the rename; both together double
    # the menu entries.
    OLD_EXT_DIR="$HOME/.local/share/gnome-shell/extensions/hibernate-windows@salaty"
    if [ -d "$OLD_EXT_DIR" ]; then
        rm -rf "$OLD_EXT_DIR"
        ok "removed the old extension (hibernate-windows@salaty)"
    fi
    ok "Extension installed."
    record "GNOME extension" "OK-RELOGIN" "Log out/in, then: gnome-extensions enable $EXT_UUID"
elif [ "$ext_ok" = skip ]; then
    record "GNOME extension" "SKIP" "build/pack the extension (npm run pack), then re-run"
else
    record "GNOME extension" "FAIL" "README.md → GNOME extension"
fi
