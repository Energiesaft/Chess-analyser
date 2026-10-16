# Deploy the versioned CloudFormation template and publish index1.2.html as the website entry point.
# This version bootstraps a dedicated S3 bucket for large CloudFormation templates.
# Historical files (the v3 script, YAML template, and index1.2.html) remain unchanged.

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Region = "us-east-1",

    [Parameter()]
    [string]$StackName = "schachformation"
)

$ErrorActionPreference = "Stop"
$previousPythonUtf8 = $env:PYTHONUTF8
$previousAwsCliFileEncoding = $env:AWS_CLI_FILE_ENCODING
$env:PYTHONUTF8 = "1"
$env:AWS_CLI_FILE_ENCODING = "UTF-8"

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
    $identityJson = & aws sts get-caller-identity --region $Region --output json
    if ($LASTEXITCODE -ne 0) { throw "Could not determine the current AWS identity." }
    $identityJson | Write-Host
    $identity = $identityJson | ConvertFrom-Json
    $accountId = [string]$identity.Account

    # The bootstrap bucket is independent of the application stack, avoiding a
    # circular dependency when the template itself exceeds CloudFormation's inline limit.
    $bootstrapBucket = "chess-analyser-cfn-templates-$accountId-$Region".ToLowerInvariant()
    Write-Host "Bootstrap template bucket: $bootstrapBucket"

    Write-Host "Checking whether the bootstrap bucket already exists..."
    & aws s3api head-bucket --bucket $bootstrapBucket --region $Region 2>$null
    $headBucketExitCode = $LASTEXITCODE

    if ($headBucketExitCode -ne 0) {
        Write-Host "Bucket not accessible; attempting to create it in $Region..."
        if ($Region -eq "us-east-1") {
            Invoke-Aws s3api create-bucket --bucket $bootstrapBucket --region $Region --output json
        }
        else {
            Invoke-Aws s3api create-bucket --bucket $bootstrapBucket --region $Region --create-bucket-configuration "LocationConstraint=$Region" --output json
        }

        # Keep the bootstrap bucket private and prevent public ACL/policy access.
        Invoke-Aws s3api put-public-access-block --bucket $bootstrapBucket --region $Region --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        Invoke-Aws s3api put-bucket-encryption --bucket $bootstrapBucket --region $Region --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}"
    }
    else {
        Write-Host "Using existing bootstrap bucket."
    }

    $templateKey = "cloudformation-templates/Schachformation1.7_SNS_IAM_Fix-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).yml"
    $templateUrl = "https://$bootstrapBucket.s3.$Region.amazonaws.com/$templateKey"

    Write-Host "Uploading CloudFormation template to s3://$bootstrapBucket/$templateKey ..."
    Invoke-Aws s3 cp $templatePath "s3://$bootstrapBucket/$templateKey" --content-type "text/yaml; charset=utf-8" --region $Region

    Write-Host "Validating CloudFormation template through S3..."
    Invoke-Aws cloudformation validate-template --template-url $templateUrl --region $Region --output json

    Write-Host "Deploying CloudFormation stack '$StackName' in '$Region'..."
    Invoke-Aws cloudformation deploy --template-file $templatePath --s3-bucket $bootstrapBucket --stack-name $StackName --capabilities CAPABILITY_IAM --region $Region --tags Project=Chess-analyser ManagedBy=CloudFormation

    $websiteBucket = (& aws cloudformation describe-stack-resources --stack-name $StackName --region $Region --query "StackResources[?LogicalResourceId=='WebsiteBucketV2'].PhysicalResourceId | [0]" --output text)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($websiteBucket) -or $websiteBucket -eq "None") {
        throw "Could not resolve the WebsiteBucketV2 physical resource from CloudFormation."
    }

    $uploadApiUrl = Get-StackOutput -OutputKey "UploadApiUrl"
    Write-Host "Using upload API: $uploadApiUrl"

    # Rewrite only a temporary deployment copy. Keep index1.2.html as historical source.
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
    Write-Host "Bootstrap bucket is retained for reuse: $bootstrapBucket"
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
    if ($null -eq $previousAwsCliFileEncoding) {
        Remove-Item Env:AWS_CLI_FILE_ENCODING -ErrorAction SilentlyContinue
    }
    else {
        $env:AWS_CLI_FILE_ENCODING = $previousAwsCliFileEncoding
    }
}
