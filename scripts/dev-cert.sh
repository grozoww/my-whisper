#!/usr/bin/env bash
#
# Creates a self-signed code-signing certificate named "OurWhisper Dev" in your login keychain.
#
# Why: macOS ties Accessibility permission to an app's code signature. Xcode's default ad-hoc
# signing produces a different signature on every build, so macOS treats each rebuild as a new
# app and silently drops the permission — dictation stops with no error at all. A stable
# self-signed identity fixes that: grant Accessibility once and it survives rebuilds.
#
# The certificate never leaves this machine and is not used for distribution.
# No sudo, and no password prompt.

set -euo pipefail

CERT_NAME="OurWhisper Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
VALID_DAYS=3650

# `find-identity -v` lists only *trusted* identities and this certificate is deliberately not
# trusted as a root, so it would never appear there. Without -v lists all matches, which is what
# codesign actually resolves against.
if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ '$CERT_NAME' already exists. Nothing to do."
  security find-identity -p codesigning | grep "$CERT_NAME"
  exit 0
fi

echo "Creating self-signed code-signing certificate '$CERT_NAME'..."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<'OPENSSL_CFG'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = OurWhisper Dev

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
OPENSSL_CFG

# /usr/bin/openssl explicitly, never whatever is first on PATH. A Homebrew OpenSSL 3 is common
# and its defaults differ from what Apple's Security framework accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days "$VALID_DAYS" -config "$WORK/cert.cnf" 2>/dev/null

echo "Importing into your login keychain..."

# The key and the certificate are imported as separate PEM files rather than bundled into a
# PKCS12. Going through PKCS12 is the usual recipe and it fails here: OpenSSL 3 writes p12
# containers with modern crypto that macOS rejects with the thoroughly misleading
# "MAC verification failed during PKCS12 import (wrong password?)".
#
# -A lets any application use this key without asking. That is what keeps the whole script
# prompt-free. It is a throwaway local certificate whose only power is signing your own debug
# builds, so the trade is worth it — do not use -A for a real Developer ID key.
security import "$WORK/key.pem"  -k "$KEYCHAIN" -A >/dev/null
security import "$WORK/cert.pem" -k "$KEYCHAIN" -A >/dev/null

if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  echo
  echo "✓ Done. '$CERT_NAME' is ready."
  security find-identity -p codesigning | grep "$CERT_NAME"
  echo
  echo "The CSSMERR_TP_NOT_TRUSTED note is expected and harmless. The certificate is not"
  echo "installed as a trusted root — codesign does not require that to sign with it, and"
  echo "leaving it untrusted avoids a password prompt and keeps your trust store clean."
  echo
  echo "Xcode should pick it up automatically. If it does not:"
  echo "  Target OurWhisper → Signing & Capabilities → Signing Certificate → $CERT_NAME"
else
  echo "✗ Import reported success but the identity is not visible to codesign."
  echo "  Open Keychain Access, look for '$CERT_NAME' under 'login', and check that both the"
  echo "  certificate and a matching private key are present."
  exit 1
fi
