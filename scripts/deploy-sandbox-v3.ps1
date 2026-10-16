# Deploy the versioned CloudFormation template and publish index1.2.html as the website entry point.
# The API Gateway URL is read from CloudFormation and injected into the deployed HTML,
# so the frontend does not keep using a stale API ID from an earlier sandbox session.

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Region = "us-east-1",

    [Parameter()]
    [string]$StackName = "schachformation"
)

$ErrorActionPreference = "Stop"
$previousPythonUtf8 = $env:PYTHONUTF8
$env:PYTHONUTF8 = "1"

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    & aws @AwsArgs
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed (exit code $LASTEXITCODE): aws $($AwsArgs -join ' ')"
    }
}

function Get-StackOutput {
    param([string]$OutputKey)
    $value = & aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[?OutputKey=='$OutputKey'].OutputValue | [0]" --output text
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value) -or $value -eq "None") {
        throw "Could not read CloudFormation output '$OutputKey' from stack '$StackName'."
    }
    return $value.Trim()
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $templatePath = Join-Path $repoRoot "Schachformation1.7_SNS_IAM_Fix.yml"
    $indexPath = Join-Path $repoRoot "index1.2.html"
    $errorPath = Join-Path $repoRoot "error.html"
    $deployIndexPath = Join-Path $env:TEMP ("chess-index-" + [guid]::NewGuid().ToString("N") + ".html")

    foreach ($path in @($templatePath, $indexPath, $errorPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required repository file is missing: $path"
        }
    }

    Write-Host "CloudFormation template: $templatePath"
    Write-Host "Website source: $indexPath (deployed as index.html)"
    Write-Host "Checking current AWS identity..."
    Invoke-Aws sts get-caller-identity --region $Region --output json

    Write-Host "Validating CloudFormation template..."
    Invoke-Aws cloudformation validate-template --template-body "file://$templatePath" --region $Region --output json

    Write-Host "Deploying CloudFormation stack '$StackName' in '$Region'..."
    Invoke-Aws cloudformation deploy --template-file $templatePath --stack-name $StackName --capabilities CAPABILITY_IAM --region $Region --tags Project=Chess-analyser ManagedBy=CloudFormation

    $websiteBucket = (& aws cloudformation describe-stack-resources --stack-name $StackName --region $Region --query "StackResources[?LogicalResourceId=='WebsiteBucketV2'].PhysicalResourceId | [0]" --output text)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($websiteBucket) -or $websiteBucket -eq "None") {
        throw "Could not resolve the WebsiteBucketV2 physical resource from CloudFormation."
    }

    $uploadApiUrl = Get-StackOutput -OutputKey "UploadApiUrl"
    Write-Host "Using upload API: $uploadApiUrl"

    # index1.2.html uses the API, but its URL is hard-coded to an earlier API Gateway ID.
    # Replace that URL in a temporary deployment copy only; keep the historical source untouched.
    $html = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
    $apiUrlPattern = 'https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com/prod/upload'
    if (-not [regex]::IsMatch($html, $apiUrlPattern)) {
        throw "Could not find the expected hard-coded API URL in index1.2.html; refusing to deploy a potentially broken frontend."
    }
    $html = [regex]::Replace($html, $apiUrlPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $uploadApiUrl })
    [System.IO.File]::WriteAllText($deployIndexPath, $html, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Uploading index1.2.html as s3://$websiteBucket/index.html ..."
    Invoke-Aws s3 cp $deployIndexPath "s3://$websiteBucket/index.html" --content-type "text/html; charset=utf-8" --region $Region
    Invoke-Aws s3 cp $errorPath "s3://$websiteBucket/error.html" --content-type "text/html; charset=utf-8" --region $Region

    Write-Host ""
    Write-Host "Deployment finished. Stack outputs:"
    Invoke-Aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output table
    Write-Host ""
    Write-Host "The deployed index.html is based on index1.2.html and uses the API URL from this stack."
}
finally {
    if ($deployIndexPath -and (Test-Path -LiteralPath $deployIndexPath)) {
        Remove-Item -LiteralPath $deployIndexPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previousPythonUtf8) {
        Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
}
