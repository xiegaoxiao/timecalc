# 生成自签名代码签名测试证书（M4 发布资产演练）。
#
# 产出：
#   build/signing/TimeCalcTestSigningCert.pfx  （含私钥，密码见下方 CERT_PASSWORD）
#   build/signing/timecalc-test.cer             （公钥证书，可导入系统信任测试）
#
# 说明：
# - 该证书仅用于本机发布演练与本地安装验证（Windows SmartScreen 仍可能提示，
#   因为不是受信任 CA 签发）。正式发布渠道要求 Authenticode 签名时，需改用
#   受信任代码签名证书（如 DigiCert/GlobalSign），本脚本流程不变。
# - build/ 目录已在 .gitignore 中，证书与私钥不会进入版本库。
#
# 用法（Git Bash / PowerShell）：
#   powershell -ExecutionPolicy Bypass -File tool/create_signing_cert.ps1
# 生成的 PFX 密码打印到控制台，供 tool/release.sh 的 CERT_PASSWORD 使用。

$ErrorActionPreference = 'Stop'

$outDir = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'build\signing'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$pfxPath = Join-Path $outDir 'TimeCalcTestSigningCert.pfx'
$cerPath = Join-Path $outDir 'timecalc-test.cer'

# 固定密码：仅用于本地测试证书，不属于真实密钥（生产签名私钥不落仓库）。
$password = 'TimeCalcTest2026!'
$securePassword = ConvertTo-SecureString -String $password -Force -AsPlainText

$cert = New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject 'CN=TimeCalc Test Signing, O=TimeCalc' `
  -KeyExportPolicy Exportable `
  -KeyUsage DigitalSignature `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -NotAfter (Get-Date).AddYears(3)

Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePassword | Out-Null
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

Write-Host ''
Write-Host '== 自签名代码签名证书已生成 =='
Write-Host "PFX:  $pfxPath"
Write-Host "CER:  $cerPath"
Write-Host "PFX 密码（供 tool/release.sh 的 CERT_PASSWORD 使用）: $password"
Write-Host ''
Write-Host '验证签名（signtool verify）需在 release.sh 中自动完成；'
Write-Host '如需在系统信任中测试，可右键导入 CER（仅建议测试环境）。'
