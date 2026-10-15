# Deploy the CloudFormation stack and publish the static website.
# Prerequisites: AWS CLI v2, valid sandbox credentials, and permission to create the stack.

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Region = "us-east-1",

    [Parameter()]
    [string]$StackName = "schachformation"
)

$ErrorActionPreference = "Stop"

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    & aws @AwsArgs
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed (exit code $LASTEXITCODE): aws $($AwsArgs -join ' ')"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot "Schachformation.yml"
$indexPath = Join-Path $repoRoot "index.html"
$errorPath = Join-Path $repoRoot "error.html"

foreach ($path in @($templatePath, $indexPath, $errorPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required repository file is missing: $path"
    }
}

Write-Host "Checking current AWS identity..."
Invoke-Aws sts get-caller-identity --region $Region --output json

Write-Host "Deploying CloudFormation stack '$StackName' in '$Region'..."
Invoke-Aws cloudformation deploy --template-file $templatePath --stack-name $StackName --capabilities CAPABILITY_IAM --region $Region --tags Project=Chess-analyser ManagedBy=CloudFormation

$bucketName = (& aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[?OutputKey=='WebsiteBucketName'].OutputValue | [0]" --output text)

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($bucketName) -or $bucketName -eq "None") {
    throw "Could not read WebsiteBucketName from CloudFormation outputs."
}

Write-Host "Uploading index.html and error.html to s3://$bucketName ..."
Invoke-Aws s3 cp $indexPath "s3://$bucketName/index.html" --content-type "text/html; charset=utf-8" --region $Region
Invoke-Aws s3 cp $errorPath "s3://$bucketName/error.html" --content-type "text/html; charset=utf-8" --region $Region

Write-Host ""
Write-Host "Deployment finished. Stack outputs:"
Invoke-Aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output table

Write-Host ""
Write-Host "To open the website, use the WebsiteURL output above."
