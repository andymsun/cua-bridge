#!/bin/bash
# Explicit, one-time local setup. Trust applies to code signing only, not TLS.
set -euo pipefail
NAME='CUA Local Development'
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "\"$NAME\""; then
  printf '%s\n' "$NAME already exists; kept unchanged."
  exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  printf '%s\n' 'A certificate with this name exists but is not a valid signing identity. Inspect it in Keychain Access; not replacing it.' >&2
  exit 1
fi
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cua-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -subj "/CN=$NAME/" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -addext 'basicConstraints=critical,CA:false' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning'
# The transient container is private and deleted on exit; the key lives in login Keychain.
export CUA_P12_PASSWORD="$(openssl rand -hex 32)"
openssl pkcs12 -export -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -passout env:CUA_P12_PASSWORD -out "$WORK/identity.p12"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$CUA_P12_PASSWORD" -T /usr/bin/codesign
unset CUA_P12_PASSWORD
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
printf '%s\n' 'Local signing identity ready. Privacy permissions remain controlled by macOS and the user.'
