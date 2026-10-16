# Secure, review-first deployment for the Chess-analyser AWS sandbox.
# New version: does not modify v3/v4, the CloudFormation template, or index1.2.html.
# Signing this script does not replace reviewing it first.

[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$Region = "us-east-1",
    [ValidatePattern('^[a-zA-Z][-a-zA-Z0-9]*$')]
    [string]$StackName = "schachformation"
)

$ErrorActionPreference = "Stop"
$oldPythonUtf8 = $env:PYTHONUTF8
$oldAwsEncoding = $env:AWS_CLI_FILE_ENCODING
$tempIndex = $null
$templateKey = $null
$changeSetName = $null
$changeSetCreated = $false
$changeSetExecuted = $false
$env:PYTHONUTF8 = "1"
$env:AWS_CLI_FILE_ENCODING = "UTF-8"

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$AwsArgs)
    $output = & aws @AwsArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "AWS CLI failed ($code): aws $($AwsArgs -join ' ')" }
    return $output
}
function Get-AwsJson {
    param([Parameter(Mandatory = $true)][string[]]$AwsArgs)
    $raw = Invoke-Aws -AwsArgs $AwsArgs
    try { return ($raw -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "AWS CLI returned invalid JSON: aws $($AwsArgs -join ' ')" }
}
function Confirm-Exact {
    param([string]$Prompt, [string]$Expected)
    $answer = Read-Host "$Prompt (type '$Expected' to continue)"
    if ($answer -cne $Expected) { throw "Confirmation did not match. Stopping without proceeding." }
}
function Test-BucketSecurity {
    param([string]$Bucket)
    $pab = Get-AwsJson -AwsArgs @("s3api","get-public-access-block","--bucket",$Bucket,"--region",$Region,"--output","json")
    $cfg = $pab.PublicAccessBlockConfiguration
    if (-not ($cfg.BlockPublicAcls -and $cfg.IgnorePublicAcls -and $cfg.BlockPublicPolicy -and $cfg.RestrictPublicBuckets)) {
        throw "Bootstrap bucket '$Bucket' does not have all four Block Public Access settings enabled. Refusing to upload."
    }
    $enc = Get-AwsJson -AwsArgs @("s3api","get-bucket-encryption","--bucket",$Bucket,"--region",$Region,"--output","json")
    $encrypted = $false
    foreach ($rule in @($enc.ServerSideEncryptionConfiguration.Rules)) {
        if ($rule.ApplyServerSideEncryptionByDefault.SSEAlgorithm -in @("AES256","aws:kms")) { $encrypted = $true }
    }
    if (-not $encrypted) { throw "Bootstrap bucket '$Bucket' has no recognized default server-side encryption. Refusing to upload." }
}

try {
    $root = Split-Path -Parent $PSScriptRoot
    $template = Join-Path $root "Schachformation1.8.yml"
    $indexSource = Join-Path $root "index1.2.html"
    $errorSource = Join-Path $root "error.html"
    $tempIndex = Join-Path $env:TEMP ("chess-index-" + [guid]::NewGuid().ToString("N") + ".html")
    foreach ($file in @($template,$indexSource,$errorSource)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required file is missing: $file" }
    }

    Write-Host ([Environment]::NewLine + "=== Deployment preflight ===") -ForegroundColor Cyan
    Write-Host "Template: $template"
    Write-Host "Frontend source: $indexSource (published as index.html)"
    Write-Host "Region: $Region; stack: $StackName"
    Write-Host "This script does not change PowerShell ExecutionPolicy or install software."

    $identity = Get-AwsJson -AwsArgs @("sts","get-caller-identity","--region",$Region,"--output","json")
    $account = [string]$identity.Account
    if ($account -notmatch '^\d{12}$') { throw "Unexpected AWS account ID; stopping." }
    Write-Host "Active AWS account: $account"
    Write-Host "Caller ARN: $($identity.Arn)"
    Confirm-Exact -Prompt "Confirm the AWS account you intend to modify" -Expected $account

    $bootstrap = "chess-analyser-cfn-templates-$account-$Region".ToLowerInvariant()
    if ($bootstrap.Length -gt 63) { throw "Generated S3 bucket name exceeds 63 characters." }
    Write-Host "Bootstrap bucket: $bootstrap"

    # A failed HEAD may mean denied access, wrong region, or missing bucket.
    # Try create once; any failure aborts rather than silently assuming absence.
    & aws s3api head-bucket --bucket $bootstrap --region $Region 2>$null
    $headCode = $LASTEXITCODE
    if ($headCode -eq 0) {
        Test-BucketSecurity -Bucket $bootstrap
    } else {
        Write-Host "HEAD check failed; attempting one create. If access is denied, the script will stop."
        if ($Region -eq "us-east-1") {
            Invoke-Aws -AwsArgs @("s3api","create-bucket","--bucket",$bootstrap,"--region",$Region,"--output","json") | Out-Host
        } else {
            Invoke-Aws -AwsArgs @("s3api","create-bucket","--bucket",$bootstrap,"--region",$Region,"--create-bucket-configuration","LocationConstraint=$Region","--output","json") | Out-Host
        }
        Invoke-Aws -AwsArgs @("s3api","put-public-access-block","--bucket",$bootstrap,"--region",$Region,"--public-access-block-configuration","BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true") | Out-Host
        Invoke-Aws -AwsArgs @("s3api","put-bucket-encryption","--bucket",$bootstrap,"--region",$Region,"--server-side-encryption-configuration",'{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}') | Out-Host
        Test-BucketSecurity -Bucket $bootstrap
    }

    $templateKey = "cloudformation-templates/Schachformation1.8-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).yml"
    $templateUrl = "https://$bootstrap.s3.$Region.amazonaws.com/$templateKey"
    Write-Host "Uploading versioned template to s3://$bootstrap/$templateKey"
    Invoke-Aws -AwsArgs @("s3","cp",$template,"s3://$bootstrap/$templateKey","--content-type","text/yaml; charset=utf-8","--region",$Region) | Out-Host
    Invoke-Aws -AwsArgs @("cloudformation","validate-template","--template-url",$templateUrl,"--region",$Region,"--output","json") | Out-Host

    $isUpdate = $false
    & aws cloudformation describe-stacks --stack-name $StackName --region $Region --output json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $isUpdate = $true
        $stack = Get-AwsJson -AwsArgs @("cloudformation","describe-stacks","--stack-name",$StackName,"--region",$Region,"--output","json")
        $status = [string]$stack.Stacks[0].StackStatus
        Write-Host "Existing stack status: $status"
        if ($status -match 'IN_PROGRESS|REVIEW_IN_PROGRESS|ROLLBACK_FAILED|UPDATE_FAILED|DELETE_FAILED') {
            throw "Stack status '$status' is not a safe starting point. Inspect it in AWS Console first."
        }
    }

    $changeSetName = "review-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
    $type = if ($isUpdate) { "UPDATE" } else { "CREATE" }
    Write-Host "Creating a CloudFormation change set ($type). The stack will not be changed until approval."
    Invoke-Aws -AwsArgs @("cloudformation","create-change-set","--stack-name",$StackName,"--change-set-name",$changeSetName,"--change-set-type",$type,"--template-url",$templateUrl,"--capabilities","CAPABILITY_IAM","--region",$Region,"--tags","Project=Chess-analyser","ManagedBy=CloudFormation","--output","json") | Out-Host
    $changeSetCreated = $true
    # Poll instead of using the AWS waiter: a valid no-op change set can end in FAILED
    # with a "no changes" reason, which the waiter would otherwise treat as an opaque error.
    $cs = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Seconds 2
        $cs = Get-AwsJson -AwsArgs @("cloudformation","describe-change-set","--stack-name",$StackName,"--change-set-name",$changeSetName,"--region",$Region,"--output","json")
        if ($cs.Status -in @("CREATE_COMPLETE","FAILED")) { break }
    }
    if ($null -eq $cs -or $cs.Status -notin @("CREATE_COMPLETE","FAILED")) {
        throw "Timed out waiting for change set creation. Inspect change set '$changeSetName' in AWS Console."
    }

    if ($cs.Status -ne "CREATE_COMPLETE") {
        if ($cs.StatusReason -match "didn't contain changes|No updates are to be performed") {
            Write-Host "No stack changes detected. Nothing will be executed."
            return
        }
        throw "Change set is not ready: $($cs.Status) - $($cs.StatusReason)"
    }

    Write-Host ([Environment]::NewLine + "=== PROPOSED CLOUDFORMATION CHANGES ===") -ForegroundColor Yellow
    $rows = @($cs.Changes | ForEach-Object {
        [pscustomobject]@{
            Action = $_.ResourceChange.Action
            LogicalResourceId = $_.ResourceChange.LogicalResourceId
            ResourceType = $_.ResourceChange.ResourceType
            Replacement = $_.ResourceChange.Replacement
            Scope = (@($_.ResourceChange.Scope) -join ",")
        }
    })
    $rows | Format-Table -AutoSize | Out-Host
    $dangerous = @($rows | Where-Object { $_.Action -eq "Remove" -or $_.Replacement -eq "True" -or $_.Replacement -eq "Conditional" })
    if ($dangerous.Count -gt 0) {
        Write-Host "WARNING: removals/replacements are proposed. Inspect these resources in AWS Console before approving." -ForegroundColor Red
        $dangerous | Format-Table -AutoSize | Out-Host
        Confirm-Exact -Prompt "To continue despite removals/replacements, type the change set name" -Expected $changeSetName
    }
    Write-Host "Full change-set details: AWS CloudFormation console, stack $StackName, change set $changeSetName"
    Write-Host "Uploaded template is retained for audit: s3://$bootstrap/$templateKey"
    Confirm-Exact -Prompt "After reviewing the change set, type the stack name to execute it" -Expected $StackName

    Invoke-Aws -AwsArgs @("cloudformation","execute-change-set","--stack-name",$StackName,"--change-set-name",$changeSetName,"--region",$Region) | Out-Host
    $changeSetExecuted = $true
    if ($type -eq "CREATE") {
        Invoke-Aws -AwsArgs @("cloudformation","wait","stack-create-complete","--stack-name",$StackName,"--region",$Region) | Out-Host
    } else {
        Invoke-Aws -AwsArgs @("cloudformation","wait","stack-update-complete","--stack-name",$StackName,"--region",$Region) | Out-Host
    }

    $resources = Get-AwsJson -AwsArgs @("cloudformation","describe-stack-resources","--stack-name",$StackName,"--region",$Region,"--output","json")
    $website = @($resources.StackResources | Where-Object { $_.LogicalResourceId -eq "WebsiteBucketV2" })
    if ($website.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$website[0].PhysicalResourceId)) {
        throw "Could not uniquely resolve WebsiteBucketV2; frontend upload skipped."
    }
    $stackOut = Get-AwsJson -AwsArgs @("cloudformation","describe-stacks","--stack-name",$StackName,"--region",$Region,"--output","json")
    $apiOut = @($stackOut.Stacks[0].Outputs | Where-Object { $_.OutputKey -eq "UploadApiUrl" })
    if ($apiOut.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$apiOut[0].OutputValue)) {
        throw "UploadApiUrl output is missing; frontend upload skipped."
    }
    # UploadApiUrl already contains /prod/upload in the CloudFormation outputs.
    $uploadApiUrl = ([string]$apiOut[0].OutputValue).TrimEnd('/')
    if ($uploadApiUrl -notmatch '^https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com/prod/upload
    Invoke-Aws -AwsArgs @("cloudformation","describe-stacks","--stack-name",$StackName,"--region",$Region,"--query","Stacks[0].Outputs[*].[OutputKey,OutputValue]","--output","table") | Out-Host
    Write-Host "Deployment completed. No AWS resources were automatically deleted."
    Write-Host "Retained template: s3://$bootstrap/$templateKey"
}
catch {
    Write-Error $_
    if ($changeSetCreated -and -not $changeSetExecuted -and $changeSetName) {
        Write-Warning "Unexecuted change set may remain: $changeSetName. It was not automatically deleted."
    }
    if ($templateKey) { Write-Warning "Template object may remain for audit: $templateKey" }
    throw
}
finally {
    if ($tempIndex -and (Test-Path -LiteralPath $tempIndex)) {
        Remove-Item -LiteralPath $tempIndex -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $oldPythonUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $oldPythonUtf8 }
    if ($null -eq $oldAwsEncoding) { Remove-Item Env:AWS_CLI_FILE_ENCODING -ErrorAction SilentlyContinue } else { $env:AWS_CLI_FILE_ENCODING = $oldAwsEncoding }
}
) {
        throw "UploadApiUrl has an unexpected format: $uploadApiUrl"
    }

    $html = [System.IO.File]::ReadAllText($indexSource,[System.Text.Encoding]::UTF8)
    $pattern = 'https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com/prod/upload'
    if (-not [regex]::IsMatch($html,$pattern)) { throw "Expected API Gateway /prod/upload URL not found in index1.2.html; refusing to publish." }
    $html = [regex]::Replace($html,$pattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $uploadApiUrl })
    [System.IO.File]::WriteAllText($tempIndex,$html,[System.Text.UTF8Encoding]::new($false))

    $bucket = [string]$website[0].PhysicalResourceId
    Write-Host "Publishing index1.2.html as index.html to s3://$bucket with API $uploadApiUrl"
    Invoke-Aws -AwsArgs @("s3","cp",$tempIndex,"s3://$bucket/index.html","--content-type","text/html; charset=utf-8","--region",$Region) | Out-Host
    if ((Test-Path -LiteralPath $errorSource -PathType Leaf) -and (Get-Item -LiteralPath $errorSource).Length -gt 0) {
        Invoke-Aws -AwsArgs @("s3","cp",$errorSource,"s3://$bucket/error.html","--content-type","text/html; charset=utf-8","--region",$Region) | Out-Host
    } else {
        Write-Warning "error.html is empty or missing; skipping optional error page upload."
    }
    $head = Get-AwsJson -AwsArgs @("s3api","head-object","--bucket",$bucket,"--key","index.html","--region",$Region,"--output","json")
    if ([long]$head.ContentLength -le 0) { throw "Frontend verification failed: s3://$bucket/index.html is empty." }
    Write-Host "Frontend upload verified ($($head.ContentLength) bytes)." -ForegroundColor Green
    Invoke-Aws -AwsArgs @("cloudformation","describe-stacks","--stack-name",$StackName,"--region",$Region,"--query","Stacks[0].Outputs[*].[OutputKey,OutputValue]","--output","table") | Out-Host
    Write-Host "Deployment completed. No AWS resources were automatically deleted."
    Write-Host "Retained template: s3://$bootstrap/$templateKey"
}
catch {
    Write-Error $_
    if ($changeSetCreated -and -not $changeSetExecuted -and $changeSetName) {
        Write-Warning "Unexecuted change set may remain: $changeSetName. It was not automatically deleted."
    }
    if ($templateKey) { Write-Warning "Template object may remain for audit: $templateKey" }
    throw
}
finally {
    if ($tempIndex -and (Test-Path -LiteralPath $tempIndex)) {
        Remove-Item -LiteralPath $tempIndex -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $oldPythonUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $oldPythonUtf8 }
    if ($null -eq $oldAwsEncoding) { Remove-Item Env:AWS_CLI_FILE_ENCODING -ErrorAction SilentlyContinue } else { $env:AWS_CLI_FILE_ENCODING = $oldAwsEncoding }
}
