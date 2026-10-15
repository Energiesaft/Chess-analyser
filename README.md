# Chess-analyser

AWS-native serverless portfolio project for processing chess move files and generating an SVG board. The project focuses on cloud infrastructure, event-driven processing, IAM, and repeatable deployment rather than a full chess engine.

## Architecture

- **Amazon S3 website bucket** serves the static frontend.
- **Amazon API Gateway + AWS Lambda** creates a short-lived presigned upload request and handles confirmation links.
- **Private Amazon S3 submission bucket** stores uploaded `.txt` and `.eml` files.
- **S3 event notification + Lambda** validates the upload and records submission state.
- **Amazon DynamoDB** stores submission and user data.
- **Amazon SNS** sends confirmation and analysis notifications.
- **AWS CloudFormation** provisions the resources from `Schachformation.yml`.

The repository on GitHub is the source of truth. GitHub Actions runs automated tests on pushes to `main`, pull requests targeting `main`, and manual workflow dispatches. It does not deploy automatically: the AWS sandbox credentials and resources are temporary, so a person must authenticate to the sandbox before deploying.

## Restore the application in an AWS sandbox

### Prerequisites

- An active AWS sandbox session with permission to create CloudFormation, IAM, Lambda, API Gateway, S3, DynamoDB, and SNS resources.
- AWS CLI v2 installed.
- PowerShell.
- Python 3.12 for running the repository tests locally.

### 1. Authenticate to AWS

Use the authentication method supplied by your sandbox. Confirm that the current credentials are valid and point to the intended account:

```powershell
aws sts get-caller-identity
```

Do not commit access keys, session tokens, account-specific bucket names, or other temporary credentials to this repository.

### 2. Run tests locally (optional)

From the repository root:

```powershell
python -m pip install -r schach_tests/requirements-dev.txt
$env:CLOUDFORMATION_TEMPLATE = (Resolve-Path .\Schachformation.yml).Path
python -m pytest -v schach_tests/tests/
```

GitHub Actions runs the same tests automatically. These tests check inline Lambda Python syntax and the accepted move-file format; they do not emulate AWS services or prove that the deployed integration works end to end.

### 3. Deploy the stack and website

From the repository root, run:

```powershell
.\scripts\deploy-sandbox.ps1
```

To use a different AWS region or stack name:

```powershell
.\scripts\deploy-sandbox.ps1 -Region us-east-1 -StackName schachformation
```

The script checks the active AWS identity, deploys `Schachformation.yml` through CloudFormation, reads the website bucket name from the stack outputs, and uploads `index.html` and `error.html`. It then prints the stack outputs, including the website URL and API URLs.

The first deployment can take several minutes. If CloudFormation reports a failure, inspect the stack's **Events** tab for the first resource that failed before retrying.

## Sandbox lifecycle and cost

This project is intended to be created when a demonstration is needed, not to run permanently. The sandbox may delete all resources and issue new temporary credentials when it resets. Re-authenticate and run the deployment script again after a reset.

When finished, delete the CloudFormation stack from the AWS console if you no longer need it and the sandbox allows deletion. Check that any S3 buckets are empty first; CloudFormation cannot delete a non-empty bucket. The sandbox's own expiry/reset process may also remove the resources.

## Repository layout

- `Schachformation.yml` — canonical infrastructure template.
- `scripts/deploy-sandbox.ps1` — repeatable PowerShell deployment script.
- `.github/workflows/tests.yml` — AWS-independent continuous integration.
- `schach_tests/` — test dependencies and automated tests.
- `index.html`, `error.html` — website entry points.

## Current scope and limitations

- The move-file checks validate coordinate-token format; they are not a complete legal-chess-move validator.
- Automated tests do not replace a live AWS integration test.
- A working live URL is available only while the sandbox resources exist.
