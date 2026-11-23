#!/usr/bin/env bash
# Prints what to paste into GitHub -> Settings -> Secrets and variables ->
# Actions, so EVERY build is signed with the SAME key and Android updates
# the app in place (no more uninstall).
#
# Usage:  bash tool/print-signing-secrets.sh path/to/streambox-release.keystore
# Reads only the file you point it at; prints locally, sends nothing.
set -euo pipefail
KS="${1:?usage: $0 path/to/streambox-release.keystore}"
[ -f "$KS" ] || { echo "No such file: $KS" >&2; exit 1; }
echo
echo "Create these 4 repository secrets (name -> value):"
echo
echo "ANDROID_KEYSTORE_BASE64"
if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w0 "$KS"; else base64 "$KS" | tr -d '\n'; fi
echo; echo
echo "ANDROID_KEYSTORE_PASSWORD  -> the store password from android/keystore-passwords.txt"
echo "ANDROID_KEY_ALIAS          -> the key alias from the same file"
echo "ANDROID_KEY_PASSWORD       -> the key password from the same file"
echo
if command -v keytool >/dev/null 2>&1; then
  echo "This keystore's fingerprint (every release must show this same SHA-256):"
  keytool -list -keystore "$KS" 2>/dev/null | grep -i "sha-256\|SHA256" || echo "(run: keytool -list -v -keystore $KS)"
fi
