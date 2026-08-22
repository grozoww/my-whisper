#!/usr/bin/env bash
#
# Creates the certificate that signs public releases, and hands it to GitHub Actions.
#
# Why this exists: macOS ties Accessibility permission to a code signing *requirement*, not to the
# app's bytes. Ad-hoc signing (`codesign --sign -`) produces the requirement
#
#     designated => cdhash H"e7c60c73…"
#
# which names one exact binary, so every release is a different app as far as macOS is concerned
# and the Accessibility grant silently stops applying — dictation just stops working after an
# update. Signing with a certificate instead produces
#
#     designated => identifier "com.grozoww.ourwhisper" and certificate leaf = H"5792c7a4…"
#
# which names the bundle id and the *certificate*. Every future release signed by the same
# certificate satisfies the requirement stored when the user first granted permission, so the
# grant survives updates. That is the entire point of this script.
#
# The certificate is self-signed. Apple is not involved, so this does nothing for notarization —
# downloads still need scripts/install.sh to clear the quarantine flag. It only fixes permission.
#
#   ./scripts/release-cert.sh                 create it, export it, print what to do next
#   ./scripts/release-cert.sh --set-secrets   ...and upload the secrets with `gh`
#   ./scripts/release-cert.sh --recreate      throw the current one away and make a new one
#
# LOSING THIS KEY IS NOT RECOVERABLE. It can be exported once, here, and not read back out of the
# login keychain afterwards — `security export` can only export a keychain's identities in bulk,
# and it refuses the whole batch if any one of them is non-extractable, which on a real login
# keychain is close to guaranteed. A release signed by a different certificate is a different app
# to macOS, and every user has to grant Accessibility again. Back the .p12 up somewhere you will
# still have it in five years.

set -euo pipefail
cd "$(dirname "$0")/.."

CERT_NAME="OurWhisper Release"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Ten years. There is no secure timestamp on this signature — Apple's timestamp server only
# vouches for real Developer ID certificates — so macOS checks the certificate against the clock
# every time it validates the app. The day this expires, every installed copy fails validation and
# loses its Accessibility grant, so do not shorten it.
VALID_DAYS=3650

SET_SECRETS=false
RECREATE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --set-secrets) SET_SECRETS=true; shift ;;
    --recreate)    RECREATE=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# MARK: - Refuse to silently replace a certificate people are already granted against

# `find-identity -v` lists only *trusted* identities, and a self-signed certificate is
# deliberately not installed as a trusted root, so it would never appear there. Without -v lists
# every match, which is what codesign actually resolves against.
if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  if [ "$RECREATE" = false ]; then
    cat >&2 <<ALREADY
'$CERT_NAME' already exists in your login keychain.

Its private key cannot be exported again from here, so there is no way to reproduce the .p12 from
this machine — restore it from the backup you took when you first ran this.

If that backup is gone, --recreate makes a new certificate. Be sure before you do: releases signed
by it are a different app to macOS, so every existing user loses their Accessibility permission
once and has to add OurWhisper back by hand.

  ./scripts/release-cert.sh --recreate
ALREADY
    exit 1
  fi

  echo "==> Deleting the existing '$CERT_NAME'"
  security delete-identity -c "$CERT_NAME" "$KEYCHAIN" >/dev/null
fi

# MARK: - Create

echo "==> Creating '$CERT_NAME'"

WORK="$(mktemp -d)"
STAGING_KEYCHAIN="$WORK/export.keychain"
STAGING_PASSWORD="$(uuidgen)"
cleanup() {
  security delete-keychain "$STAGING_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/cert.cnf" <<OPENSSL_CFG
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = $CERT_NAME

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

# MARK: - Export, from a keychain of its own
#
# The .p12 is written from a throwaway keychain containing nothing but this identity, and not from
# the login keychain, because `security export` works on a whole keychain at a time: asked for the
# login keychain's identities it walks every one of them and fails the entire export on the first
# key some other application marked non-extractable, with the unhelpful "The contents of this item
# cannot be retrieved."
#
# Key and certificate go in as separate PEM files rather than as a PKCS12. Building one with
# OpenSSL 3 and importing it is the obvious shortcut and it does not work: macOS rejects those
# containers with the thoroughly misleading "MAC verification failed during PKCS12 import (wrong
# password?)". Reading a p12 that `security export` wrote is fine, which is the direction CI needs.

P12="$WORK/ourwhisper-release.p12"
P12_PASSWORD="$(uuidgen)"

security create-keychain -p "$STAGING_PASSWORD" "$STAGING_KEYCHAIN"
security unlock-keychain -p "$STAGING_PASSWORD" "$STAGING_KEYCHAIN"
security import "$WORK/key.pem"  -k "$STAGING_KEYCHAIN" -A >/dev/null
security import "$WORK/cert.pem" -k "$STAGING_KEYCHAIN" -A >/dev/null
security export -k "$STAGING_KEYCHAIN" -t identities -f pkcs12 \
  -P "$P12_PASSWORD" -o "$P12" >/dev/null

# MARK: - Install it locally too
#
# So that a hand-run ./scripts/package.sh on this machine signs the same way CI does, rather than
# quietly producing an ad-hoc DMG.
#
# -A lets any application use this key without asking, which is what keeps this prompt-free — both
# here and every time codesign runs during a local package.sh. The same key is going into a GitHub
# secret anyway, so the marginal exposure is small; what actually protects it is that it never
# leaves your keychain and your backup.
security import "$WORK/key.pem"  -k "$KEYCHAIN" -A >/dev/null
security import "$WORK/cert.pem" -k "$KEYCHAIN" -A >/dev/null

security find-identity -p codesigning | grep -q "$CERT_NAME" || {
  echo "✗ Import reported success but the identity is not visible to codesign." >&2
  echo "  Open Keychain Access, look for '$CERT_NAME' under 'login', and check that both the" >&2
  echo "  certificate and a matching private key are present." >&2
  exit 1
}

echo
security find-identity -p codesigning | grep "$CERT_NAME"
echo
echo "The CSSMERR_TP_NOT_TRUSTED note is expected. The certificate is not installed as a trusted"
echo "root — codesign does not need that, and leaving it untrusted avoids a password prompt."

# MARK: - Hand it to GitHub
#
# Three secrets, and the same three a real Developer ID certificate would use. Swapping this for a
# paid Apple certificate later is a matter of replacing them and adding the notarization ones —
# scripts/package.sh reads the identity the same way either way.

# Moved out of $WORK, which the trap deletes on the way out. Left in a directory of its own rather
# than anywhere in the checkout: a private key in the working tree is one `git add -A` away from
# being public, and .gitignore is a weak thing to bet a non-recoverable key on.
KEEP="$(mktemp -d)"
mv "$P12" "$KEEP/ourwhisper-release.p12"
P12="$KEEP/ourwhisper-release.p12"
base64 < "$P12" > "$KEEP/ourwhisper-release.p12.base64"

if [ "$SET_SECRETS" = true ]; then
  command -v gh >/dev/null 2>&1 || { echo "✗ --set-secrets needs the GitHub CLI (brew install gh)." >&2; exit 1; }
  echo
  echo "==> Uploading secrets with gh"
  gh secret set MACOS_CERTIFICATE          < "$KEEP/ourwhisper-release.p12.base64"
  gh secret set MACOS_CERTIFICATE_PASSWORD --body "$P12_PASSWORD"
  gh secret set MACOS_SIGNING_IDENTITY     --body "$CERT_NAME"
  echo "✓ MACOS_CERTIFICATE, MACOS_CERTIFICATE_PASSWORD and MACOS_SIGNING_IDENTITY are set."
else
  echo
  echo "==> Set these three repository secrets"
  echo
  echo "  MACOS_CERTIFICATE            contents of $KEEP/ourwhisper-release.p12.base64"
  echo "  MACOS_CERTIFICATE_PASSWORD   $P12_PASSWORD"
  echo "  MACOS_SIGNING_IDENTITY       $CERT_NAME"
  echo
  echo "  With the GitHub CLI:"
  echo
  echo "    gh secret set MACOS_CERTIFICATE < $KEEP/ourwhisper-release.p12.base64"
  echo "    gh secret set MACOS_CERTIFICATE_PASSWORD --body '$P12_PASSWORD'"
  echo "    gh secret set MACOS_SIGNING_IDENTITY --body '$CERT_NAME'"
  echo
  echo "  Or re-run this script as: ./scripts/release-cert.sh --set-secrets"
fi

cat <<BACKUP

==> Back this up before you close this terminal

  $P12
  password: $P12_PASSWORD

  Put both in your password manager. This is the only time the key can be exported: it cannot be
  read back out of the login keychain later. Lose it and the next release has to be signed by a
  different certificate — which macOS treats as a different app, so every user loses their
  Accessibility grant once and has to add OurWhisper back by hand.

  Then delete the copy on disk:

    rm -rf $KEEP

BACKUP
