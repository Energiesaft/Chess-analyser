# Deploy the latest versioned CloudFormation template and publish the static website.
# This version intentionally uses Schachformation1.7_SNS_IAM_Fix.yml.
# Prerequisites: AWS CLI v2, active sandbox credentials, and permission to create/update the stack.

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Region = "us-east-1",

    [Parameter()]
    [string]$StackName = "schachformation"
)

$ErrorActionPreference = "Stop"

# Force Python/AWS CLI to interpret UTF-8 text correctly on Windows.
# The CloudFormation template contains Unicode chess symbols in inline Lambda code.
$previousPythonUtf8 = $env:PYTHONUTF8
$env:PYTHONUTF8 = "1"

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)

    & aws @AwsArgs
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed (exit code $LASTEXITCODE): aws $($AwsArgs -join ' ')"
    }
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $templatePath = Join-Path $repoRoot "Schachformation1.7_SNS_IAM_Fix.yml"
    $indexPath = Join-Path $repoRoot "index.html"
    $errorPath = Join-Path $repoRoot "error.html"

    foreach ($path in @($templatePath, $indexPath, $errorPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required repository file is missing: $path"
        }
    }

    Write-Host "Template: $templatePath"
    Write-Host "Checking current AWS identity..."
    Invoke-Aws sts get-caller-identity --region $Region --output json

    Write-Host "Validating CloudFormation template..."
    Invoke-Aws cloudformation validate-template --template-body "file://$templatePath" --region $Region --output json

    Write-Host "Deploying CloudFormation stack '$StackName' in '$Region'..."
    Invoke-Aws cloudformation deploy --template-file $templatePath --stack-name $StackName --capabilities CAPABILITY_IAM --region $Region --tags Project=Chess-analyser ManagedBy=CloudFormation

    # The versioned template exports WebsiteURL but not WebsiteBucketName.
    # Resolve the physical bucket name from the CloudFormation stack resources.
    $websiteBucket = (& aws cloudformation describe-stack-resources --stack-name $StackName --region $Region --query "StackResources[?LogicalResourceId=='WebsiteBucketV2'].PhysicalResourceId | [0]" --output text)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($websiteBucket) -or $websiteBucket -eq "None") {
        throw "Could not resolve the WebsiteBucketV2 physical resource from CloudFormation."
    }

    Write-Host "Uploading index.html and error.html to s3://$websiteBucket ..."
    Invoke-Aws s3 cp $indexPath "s3://$websiteBucket/index.html" --content-type "text/html; charset=utf-8" --region $Region
    Invoke-Aws s3 cp $errorPath "s3://$websiteBucket/error.html" --content-type "text/html; charset=utf-8" --region $Region

    Write-Host ""
    Write-Host "Deployment finished. Stack outputs:"
    Invoke-Aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output table
    Write-Host ""
    Write-Host "Use the WebsiteURL output above to open the site."
}
finally {
    if ($null -eq $previousPythonUtf8) {
        Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
}
