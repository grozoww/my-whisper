#!/usr/bin/env bash
#
# Creates a self-signed code-signing certificate named "OurWhisper Dev" in your login keychain.
#
# Why: macOS ties Accessibility permission to an app's code signature. Xcode's default ad-hoc
# signing produces a different signature on every build, so macOS treats each rebuild as a new
# app and silently drops the permission — dictation stops with no error. A stable self-signed
# identity fixes that: you grant Accessibility once and it survives rebuilds.
#
# The certificate never leaves this machine and is not used for distribution.
# No sudo required. You will be asked for your login password by macOS itself.

set -euo pipefail

CERT_NAME="OurWhisper Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
VALID_DAYS=3650

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ '$CERT_NAME' already exists. Nothing to do."
  echo
  security find-identity -v -p codesigning | grep "$CERT_NAME"
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

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days "$VALID_DAYS" -config "$WORK/cert.cnf" 2>/dev/null

openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout pass: 2>/dev/null

echo "Importing into your login keychain..."
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo
echo "macOS will now ask for your login password — twice."
echo "  1. to trust this certificate for code signing"
echo "  2. to let codesign use its key without prompting on every build"
echo

security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null

echo
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Done. '$CERT_NAME' is ready."
  security find-identity -v -p codesigning | grep "$CERT_NAME"
  echo
  echo "Xcode should pick it up automatically. If it does not, set it manually:"
  echo "  Target OurWhisper → Signing & Capabilities → Signing Certificate → $CERT_NAME"
else
  echo "✗ The certificate was created but is not showing as a valid signing identity."
  echo "  Open Keychain Access, find '$CERT_NAME' under 'login', and set"
  echo "  Trust → Code Signing to 'Always Trust'."
  exit 1
fi
