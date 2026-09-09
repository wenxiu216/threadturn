#!/bin/zsh
# 生成一个本机自签名的代码签名证书「轮到谁 Dev」，导入登录钥匙串。
# 只需跑一次。之后 build.sh 会自动用它签名，重打包不再丢辅助功能权限。
set -e
NAME="Rally Dev"
if security find-identity -v -p codesigning | grep -q "$NAME"; then echo "证书已存在：$NAME"; exit 0; fi
T=$(mktemp -d)
cat > "$T/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$T/ext.cnf" -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/cert.p12" -passout pass:whoseturn -legacy 2>/dev/null || openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/cert.p12" -passout pass:whoseturn
security import "$T/cert.p12" -k ~/Library/Keychains/login.keychain-db -P whoseturn -T /usr/bin/codesign -T /usr/bin/security
# 让 codesign 免弹窗使用这把私钥（会要一次登录密码）
security set-key-partition-list -S apple-tool:,apple: -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
# 信任这张证书用于代码签名（会弹一次系统密码框）
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$T/cert.pem"
rm -rf "$T"
echo "完成。之后运行 ./build.sh 即可。"
