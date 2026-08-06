#!/usr/bin/env bash
# TimeCalc Windows 发布脚本（M4：便携 zip + 自签名演练）。
#
# 流程：
#   1. 从 pubspec.yaml 读取版本号；
#   2. flutter build windows --release；
#   3. 用自签名测试证书签名 timecalc.exe（signtool，PFX 密码取环境变量
#      CERT_PASSWORD；签名失败给出提示但不阻断，便携版仍可交付）；
#   4. signtool verify 验证签名（仅当已签名时）；
#   5. 整理发布目录 build/release/timecalc-v<ver>-windows-x64/（exe + dlls +
#      data + LICENSE + CHANGELOG），zip 打包，生成 SHA256SUMS。
#
# 前置：已运行 tool/create_signing_cert.ps1 生成证书，并导出 CERT_PASSWORD：
#   CERT_PASSWORD='<pfx 密码>' tool/release.sh
#
# 在 Git Bash 下运行。

set -euo pipefail
cd "$(dirname "$0")/.."

# ---- 版本 ----
version=$(sed -n 's/^version: *\([0-9][0-9.]*\)+.*/\1/p' pubspec.yaml | head -n1)
if [ -z "$version" ]; then
  echo "无法从 pubspec.yaml 读取版本号" >&2
  exit 1
fi
echo "== TimeCalc v${version} 构建 =="

# ---- 构建 ----
flutter build windows --release
build_dir="build/windows/x64/runner/Release"
if [ ! -f "$build_dir/timecalc.exe" ]; then
  echo "构建产物缺失：$build_dir/timecalc.exe" >&2
  exit 1
fi

# ---- 签名（自签名测试证书）----
signtool=""
for base in "/c/Program Files (x86)/Windows Kits/10/bin" "/c/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0"; do
  if [ -x "$base/x64/signtool.exe" ]; then
    signtool="$base/x64/signtool.exe"
    break
  fi
done

pfx="build/signing/TimeCalcTestSigningCert.pfx"
signed=false
if [ -n "$signtool" ] && [ -f "$pfx" ] && [ -n "${CERT_PASSWORD:-}" ]; then
  echo "== 签名 timecalc.exe =="
  # 时间戳服务器不可达时签名仍成功（不阻断），但会在 stderr 提示。
  # 注：Git Bash 的 MSYS 会把以 / 开头的参数当作路径转换，signtool 的
  # /fd /f /p /tr /td 等旗标需写为 //fd 等双斜杠形式（MSYS 会还原为单斜杠）。
  "$signtool" sign //fd SHA256 //f "$pfx" //p "$CERT_PASSWORD" \
    //tr http://timestamp.digicert.com //td SHA256 \
    "$build_dir/timecalc.exe" 2>&1 | sed 's/^/  /'
  echo "== 验证签名 =="
  "$signtool" verify //pa //v "$build_dir/timecalc.exe" 2>&1 | sed 's/^/  /' || true
  # 自签名证书不在受信任根存储中，verify 会报「根证书不受信任」——这是
  # 预期结果（对应 SmartScreen 仍可能提示）；签名本身已由 SignTool 的
  # 「Successfully signed」确认，时间戳也已校验证书链。
  signed=true
else
  echo "== 跳过签名 =="
  echo "  （未找到 signtool，或证书/密码未提供：pfx=$pfx CERT_PASSWORD 为空）"
fi

# ---- 整理发布目录 ----
release_root="build/release"
dir_name="timecalc-v${version}-windows-x64"
out_dir="$release_root/$dir_name"
rm -rf "$out_dir"
mkdir -p "$out_dir"

cp "$build_dir/timecalc.exe" "$out_dir/"
cp "$build_dir"/*.dll "$out_dir/" 2>/dev/null || true
cp -r "$build_dir/data" "$out_dir/"
cp LICENSE "$out_dir/"
cp CHANGELOG.md "$out_dir/"
cp README.md "$out_dir/"
echo "（自签名测试证书演练，非受信 CA）" > "$out_dir/SIGNING-NOTE.txt"

# ---- zip 打包 + SHA256 ----
# Git Bash 无 zip 命令且 GNU tar 不支持 zip 格式；用 Windows 自带
# PowerShell Compress-Archive 打包（zip 入口为发布目录自身）。
zip_path="$release_root/${dir_name}.zip"
rm -f "$zip_path"
powershell -NoProfile -Command \
  "Compress-Archive -Path '$(pwd -W)/$release_root/$dir_name' -DestinationPath '$(pwd -W)/$zip_path' -Force"

(
  cd "$release_root"
  # zip 整体校验和。
  sha256sum "${dir_name}.zip" > SHA256SUMS
  # 目录内文件逐项校验清单（便于单文件哈希核验）。
  # 路径按发布根目录相对路径写入，`sha256sum -c SHA256SUMS` 在根目录直接可验。
  # GNU sha256sum 输出为 `hash *file`，用 awk 给文件名加目录前缀。
  (cd "$dir_name" && sha256sum timecalc.exe *.dll data/* 2>/dev/null | sort) \
    | awk -v d="$dir_name/" '{if ($2 ~ /^\*/) print $1 " *" d substr($2,2); else print $1 "  " d $2}' \
    >> SHA256SUMS
)

echo ""
echo "== 发布资产就绪 =="
echo "  目录：$out_dir"
echo "  zip ：$zip_path"
echo "  sha256：$release_root/SHA256SUMS"
echo "  签名：$([ "$signed" = true ] && echo '已签名（自签名测试证书）' || echo '未签名')"
echo ""
echo "校验示例：sha256sum -c $release_root/SHA256SUMS"
