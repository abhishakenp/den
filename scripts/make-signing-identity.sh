#!/bin/zsh
# Creates, once, a persistent self-signed code-signing identity "den Local Signing" in the login
# keychain. scripts/bundle.sh signs with it when present, so den.app's designated requirement
# (certificate leaf + bundle id) stays the same across rebuilds and macOS keeps Keychain and TCC
# grants. Without it, bundle.sh ad-hoc signs, and the requirement is the cdhash of each build.
# Idempotent: does nothing when the identity already exists. Never asks for a password; the two
# optional steps that need one (trust, key partition list) are printed for you to run by hand.
set -euo pipefail
NAME="den Local Signing"
KC="$HOME/Library/Keychains/login.keychain-db"

hash_of() { security find-identity -p codesigning "$KC" | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }' }

print_manual_steps() {
  local cert=$1
  echo "Optional, run by hand (each asks for your login password):"
  echo "  trust it for code signing (find-identity -v then lists it as valid):"
  echo "    security add-trusted-cert -r trustRoot -p codeSign -k $KC $cert"
  echo "  let Apple tools use the key without a Keychain prompt (only if codesign ever prompts):"
  echo "    security set-key-partition-list -S apple-tool:,apple: -s -l \"$NAME\" $KC"
}

if [[ -n "$(hash_of)" ]]; then
  echo "identity \"$NAME\" already exists ($(hash_of)); nothing to do"
  security find-identity -v -p codesigning "$KC" | grep -qF "\"$NAME\"" ||
    print_manual_steps "\"$HOME/Library/Application Support/den/den-local-signing.cer\""
  exit 0
fi

# LibreSSL's PKCS#12 defaults are what `security import` reads; OpenSSL 3 needs -legacy.
OPENSSL=/usr/bin/openssl
LEGACY=()
$OPENSSL version | grep -q '^OpenSSL 3' && LEGACY=(-legacy)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
$OPENSSL req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PW=$($OPENSSL rand -hex 16)
$OPENSSL pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PW"
# -T: codesign may use the private key without an access prompt.
security import "$TMP/id.p12" -k "$KC" -f pkcs12 -P "$PW" -T /usr/bin/codesign >/dev/null

h=$(hash_of)
[[ -n $h ]] || { echo "import finished but \"$NAME\" is not a code-signing identity"; exit 1; }
CERT="$HOME/Library/Application Support/den/den-local-signing.cer"
mkdir -p "${CERT:h}"
cp "$TMP/cert.pem" "$CERT"
echo "created identity \"$NAME\" ($h) in $KC"
echo "certificate saved to $CERT"
echo "codesign signs with it untrusted; scripts/bundle.sh picks it up automatically."
print_manual_steps "\"$CERT\""
