#!/bin/sh
# GitHub Actions 用の署名 secret を用意する。
#   scripts/setup-ci-signing.sh create              App Store Connect API で Developer ID Application 証明書を作成し、
#                                                   p12 化して secret 登録、ローカルのログインキーチェーンにも導入する
#   scripts/setup-ci-signing.sh export "<identity>" キーチェーンの既存 identity (部分一致) を p12 化して secret 登録する
#   scripts/setup-ci-signing.sh notary              公証用 secret (App Store Connect API キー) を登録する
# 必要な環境変数 (create / notary): ASC_KEY_ID, ASC_ISSUER, ASC_KEY_PATH (~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${CCCU_REPO:-frodo821/cccu}"
WORK="$(mktemp -d)"; chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
P12PASS="$(openssl rand -hex 16)"

set_p12_secrets() {   # $1 = p12 path
  base64 < "$1" | tr -d '\n' | gh secret set DEVELOPER_ID_P12 -R "$REPO"
  printf '%s' "$P12PASS" | gh secret set DEVELOPER_ID_P12_PASSWORD -R "$REPO"
  echo "[signing] secrets DEVELOPER_ID_P12 / DEVELOPER_ID_P12_PASSWORD set on $REPO"
}

case "${1:-}" in
  create)
    : "${ASC_KEY_ID:?}" "${ASC_ISSUER:?}" "${ASC_KEY_PATH:?}"
    openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/devid.key" -out "$WORK/devid.csr" -subj "/CN=cccu Developer ID" >/dev/null 2>&1
    node "$ROOT/scripts/asc.mjs" create "$WORK/devid.csr" "$WORK/devid.cer"
    openssl x509 -inform DER -in "$WORK/devid.cer" -out "$WORK/devid.pem"
    curl -fsSL -o "$WORK/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
    openssl x509 -inform DER -in "$WORK/DeveloperIDG2CA.cer" -out "$WORK/ca.pem"
    openssl pkcs12 -export -inkey "$WORK/devid.key" -in "$WORK/devid.pem" -certfile "$WORK/ca.pem" -name "Developer ID Application" -out "$WORK/devid.p12" -passout "pass:$P12PASS"
    set_p12_secrets "$WORK/devid.p12"
    security import "$WORK/devid.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
    security import "$WORK/DeveloperIDG2CA.cer" -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
    echo "[signing] identity imported into the login keychain:"; security find-identity -v -p codesigning | grep 'Developer ID Application' || true
    ;;
  export)
    NAME="${2:?identity name substring}"
    # キーチェーンからは identity をまとめてしか書き出せないので、いったん全部書き出して該当ペアだけ p12 に組み直す
    security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -P "$P12PASS" -o "$WORK/all.p12"
    openssl pkcs12 -in "$WORK/all.p12" -passin "pass:$P12PASS" -nodes -out "$WORK/all.pem" >/dev/null 2>&1
    python3 - "$WORK" "$NAME" <<'PY'
import re, subprocess, sys
work, name = sys.argv[1], sys.argv[2]
pem = open(f"{work}/all.pem").read()
# PEM を「鍵」と「証明書」のブロックに分け、friendlyName / subject が一致する証明書とそれに対応する鍵を選ぶ
blocks = re.findall(r"(Bag Attributes.*?)(-----BEGIN (?:PRIVATE KEY|CERTIFICATE)-----.*?-----END (?:PRIVATE KEY|CERTIFICATE)-----)", pem, re.S)
certs = [(a, b) for a, b in blocks if "BEGIN CERTIFICATE" in b and name in a]
if not certs: sys.exit(f"no certificate matching {name!r} in keychain export")
attrs, cert = certs[0]
m = re.search(r"localKeyID: ([0-9A-F ]+)", attrs)
kid = m.group(1).strip() if m else None
keys = [(a, b) for a, b in blocks if "PRIVATE KEY" in b and (kid is None or kid in a)]
if not keys: sys.exit("no private key for that certificate")
open(f"{work}/one.pem", "w").write(keys[0][1] + "\n" + cert + "\n")
print("[signing] selected:", re.search(r"friendlyName: (.*)", attrs).group(1))
PY
    openssl pkcs12 -export -in "$WORK/one.pem" -name "$NAME" -out "$WORK/one.p12" -passout "pass:$P12PASS"
    set_p12_secrets "$WORK/one.p12"
    ;;
  notary)
    : "${ASC_KEY_ID:?}" "${ASC_ISSUER:?}" "${ASC_KEY_PATH:?}"
    gh secret set NOTARY_KEY_P8 -R "$REPO" < "$ASC_KEY_PATH"
    printf '%s' "$ASC_KEY_ID" | gh secret set NOTARY_KEY_ID -R "$REPO"
    printf '%s' "$ASC_ISSUER" | gh secret set NOTARY_KEY_ISSUER -R "$REPO"
    echo "[signing] notarization secrets set on $REPO"
    ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
