$ErrorActionPreference = "Stop"

$historyOutput = & helm history $env:HELM_RELEASE --namespace $env:TARGET_NAMESPACE --output json
if ($LASTEXITCODE -ne 0) {
    throw "helm history failed with exit code $LASTEXITCODE"
}

$historyJson = ($historyOutput -join "`n") | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress
$runId = [Guid]::NewGuid().ToString("N").Substring(0, 12)
$configMapName = "helm-history-$runId"
$jobName = "helm-history-upload-$runId"

$configMapYaml = & kubectl create configmap $configMapName `
    --namespace $env:REPORT_NAMESPACE `
    "--from-literal=history.json=$historyJson" `
    --dry-run=client -o yaml
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create the Helm history ConfigMap manifest"
}

$configMapYaml | & kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    throw "Failed to save Helm history to a ConfigMap"
}

$cronJobJson = & kubectl get cronjob $env:UPLOAD_CRONJOB --namespace $env:REPORT_NAMESPACE -o json
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read uploader CronJob"
}
$cronJob = $cronJobJson | ConvertFrom-Json
$jobSpec = $cronJob.spec.jobTemplate.spec
$uploadContainer = $jobSpec.template.spec.containers | Where-Object { $_.name -eq "upload" }
if ($null -eq $uploadContainer) {
    throw "Uploader CronJob does not contain the expected upload container"
}

$uploadContainer.env = @($uploadContainer.env | Where-Object { $_.name -ne "HISTORY_CONFIGMAP" }) + @(
    @{ name = "HISTORY_CONFIGMAP"; value = $configMapName }
)
$job = @{
    apiVersion = "batch/v1"
    kind = "Job"
    metadata = @{
        name = $jobName
        namespace = $env:REPORT_NAMESPACE
    }
    spec = $jobSpec
}

$jobJson = ConvertTo-Json -InputObject $job -Depth 100 -Compress
$jobJson | & kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start the uploader Job"
}

Write-Output "Started $jobName for Helm release $env:HELM_RELEASE in $env:TARGET_NAMESPACE"
