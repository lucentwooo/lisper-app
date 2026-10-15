#!/bin/bash
# One-time: create a self-signed codesigning cert "Lisper Dev" in the login keychain
# so macOS permission grants (Accessibility/Microphone) survive rebuilds.
set -euo pipefail
ID="Lisper Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -qF "\"$ID\""; then
  echo "'$ID' already exists"; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf"
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:lisper
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P lisper -T /usr/bin/codesign
# Trust it for code signing (will prompt for your password once)
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem" \
  || echo "Trust step failed — you can trust the cert manually in Keychain Access (Get Info > Trust > Code Signing: Always Trust)"
echo "Created '$ID'. Rebuild with scripts/build.sh."
