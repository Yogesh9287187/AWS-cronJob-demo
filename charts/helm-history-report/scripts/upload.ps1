$ErrorActionPreference = "Stop"

$configMapJson = & kubectl get configmap $env:HISTORY_CONFIGMAP --namespace $env:REPORT_NAMESPACE -o json
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read Helm history ConfigMap $env:HISTORY_CONFIGMAP"
}
$configMap = $configMapJson | ConvertFrom-Json
$historyJson = $configMap.data.'history.json'
if ([string]::IsNullOrWhiteSpace($historyJson)) {
    throw "Helm history ConfigMap does not contain history.json"
}

$historyPath = Join-Path ([System.IO.Path]::GetTempPath()) "$($env:HISTORY_CONFIGMAP).json"
Set-Content -Path $historyPath -Value $historyJson -Encoding utf8NoBOM
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$objectKey = "helm-history/$env:TARGET_NAMESPACE/$env:HELM_RELEASE/$timestamp-$env:HISTORY_CONFIGMAP.json"

& aws s3 cp $historyPath "s3://$env:S3_BUCKET/$objectKey" --region $env:AWS_REGION --sse AES256
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload Helm history to S3"
}

& kubectl delete configmap $env:HISTORY_CONFIGMAP --namespace $env:REPORT_NAMESPACE --ignore-not-found=true
if ($LASTEXITCODE -ne 0) {
    throw "Uploaded report but failed to clean up its ConfigMap"
}

Write-Output "Uploaded s3://$env:S3_BUCKET/$objectKey"
