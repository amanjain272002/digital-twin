param(
    [string]$Environment = "dev",
    [string]$ProjectName = "twin"
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ProjectRoot = Split-Path $PSScriptRoot -Parent

$TerraformExe = Join-Path $PSScriptRoot "terraform.exe"
$TerraformPath = Join-Path $ProjectRoot "terraform"
$BackendPath = Join-Path $ProjectRoot "backend"
$FrontendPath = Join-Path $ProjectRoot "frontend"

# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "           TWIN DEPLOYMENT" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Project      : $ProjectName" -ForegroundColor Cyan
Write-Host "Environment  : $Environment" -ForegroundColor Cyan
Write-Host "Project Root : $ProjectRoot" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# VALIDATE ENVIRONMENT
# ============================================================

$ValidEnvironments = @(
    "dev",
    "test",
    "prod"
)

if ($ValidEnvironments -notcontains $Environment) {
    throw "Invalid environment '$Environment'. Use dev, test, or prod."
}

# ============================================================
# VALIDATE TERRAFORM
# ============================================================

if (-not (Test-Path $TerraformExe)) {
    throw "Terraform executable not found: $TerraformExe"
}

Write-Host "Terraform:" -ForegroundColor Yellow

& $TerraformExe --version

if ($LASTEXITCODE -ne 0) {
    throw "Terraform failed to run."
}

# ============================================================
# VALIDATE AWS CLI
# ============================================================

Write-Host ""
Write-Host "Checking AWS CLI..." -ForegroundColor Yellow

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI was not found."
}

aws --version

if ($LASTEXITCODE -ne 0) {
    throw "AWS CLI failed."
}

# ============================================================
# VALIDATE AWS IDENTITY
# ============================================================

Write-Host ""
Write-Host "Checking AWS credentials..." -ForegroundColor Yellow

$AwsAccountId = (
    aws sts get-caller-identity `
        --query Account `
        --output text
).Trim()

$AwsArn = (
    aws sts get-caller-identity `
        --query Arn `
        --output text
).Trim()

if ([string]::IsNullOrWhiteSpace($AwsAccountId)) {
    throw "Unable to determine AWS account."
}

Write-Host "AWS Account : $AwsAccountId" -ForegroundColor Cyan
Write-Host "AWS Identity: $AwsArn" -ForegroundColor Cyan

# ============================================================
# VALIDATE UV
# ============================================================

Write-Host ""
Write-Host "Checking uv..." -ForegroundColor Yellow

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "uv was not found."
}

uv --version

if ($LASTEXITCODE -ne 0) {
    throw "uv failed."
}

# ============================================================
# VALIDATE NODE
# ============================================================

Write-Host ""
Write-Host "Checking Node.js..." -ForegroundColor Yellow

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js was not found."
}

node --version

if ($LASTEXITCODE -ne 0) {
    throw "Node.js failed."
}

# ============================================================
# VALIDATE NPM
# ============================================================

Write-Host ""
Write-Host "Checking npm..." -ForegroundColor Yellow

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm was not found."
}

npm --version

if ($LASTEXITCODE -ne 0) {
    throw "npm failed."
}

# ============================================================
# 1. BUILD LAMBDA
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  1. BUILDING LAMBDA" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $BackendPath)) {
    throw "Backend directory not found: $BackendPath"
}

Set-Location $BackendPath

Write-Host "Running backend deployment script..." -ForegroundColor Yellow

uv run deploy.py

if ($LASTEXITCODE -ne 0) {
    throw "Lambda package creation failed."
}

$LambdaZip = Join-Path $BackendPath "lambda-deployment.zip"

if (-not (Test-Path $LambdaZip)) {
    throw "Lambda ZIP was not created: $LambdaZip"
}

Write-Host ""
Write-Host "Lambda package created successfully." -ForegroundColor Green
Write-Host "ZIP: $LambdaZip" -ForegroundColor Cyan

Set-Location $ProjectRoot

# ============================================================
# 2. TERRAFORM
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  2. TERRAFORM INFRASTRUCTURE" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $TerraformPath)) {
    throw "Terraform directory not found: $TerraformPath"
}

Set-Location $TerraformPath

# ============================================================
# TERRAFORM INIT
# ============================================================

Write-Host "Terraform init..." -ForegroundColor Yellow

& $TerraformExe init -input=false

if ($LASTEXITCODE -ne 0) {
    throw "Terraform init failed."
}

# ============================================================
# TERRAFORM FORMAT
# ============================================================

Write-Host ""
Write-Host "Terraform format..." -ForegroundColor Yellow

& $TerraformExe fmt -recursive

if ($LASTEXITCODE -ne 0) {
    throw "Terraform format failed."
}

# ============================================================
# TERRAFORM VALIDATE
# ============================================================

Write-Host ""
Write-Host "Terraform validate..." -ForegroundColor Yellow

& $TerraformExe validate

if ($LASTEXITCODE -ne 0) {
    throw "Terraform validation failed."
}

# ============================================================
# TERRAFORM WORKSPACE
# ============================================================

Write-Host ""
Write-Host "Selecting Terraform workspace..." -ForegroundColor Yellow

$WorkspaceList = & $TerraformExe workspace list

$WorkspaceExists = $false

foreach ($Workspace in $WorkspaceList) {

    $CleanWorkspace = $Workspace.Trim().TrimStart("*").Trim()

    if ($CleanWorkspace -eq $Environment) {
        $WorkspaceExists = $true
        break
    }
}

if (-not $WorkspaceExists) {

    Write-Host "Creating workspace: $Environment" -ForegroundColor Yellow

    & $TerraformExe workspace new $Environment

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create Terraform workspace: $Environment"
    }

}
else {

    Write-Host "Selecting workspace: $Environment" -ForegroundColor Yellow

    & $TerraformExe workspace select $Environment

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to select Terraform workspace: $Environment"
    }
}

# ============================================================
# TERRAFORM.TFVARS
# ============================================================

$TerraformTfvars = Join-Path $TerraformPath "terraform.tfvars"

Write-Host ""
Write-Host "Checking Terraform variables..." -ForegroundColor Yellow

if (-not (Test-Path $TerraformTfvars)) {

    throw "terraform.tfvars was not found: $TerraformTfvars"

}

Write-Host "Using:" -ForegroundColor Green
Write-Host $TerraformTfvars -ForegroundColor Cyan

# ============================================================
# TERRAFORM APPLY
# ============================================================

Write-Host ""
Write-Host "Applying Terraform..." -ForegroundColor Yellow
Write-Host ""

# terraform.tfvars is automatically loaded by Terraform.
#
# We explicitly pass project_name and environment so the
# command-line parameters override those values if present.
#
# No dev.tfvars/prod.tfvars is used.

& $TerraformExe apply `
    -var="project_name=$ProjectName" `
    -var="environment=$Environment" `
    -auto-approve

if ($LASTEXITCODE -ne 0) {
    throw "Terraform apply failed."
}

# ============================================================
# 3. TERRAFORM OUTPUTS
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  3. TERRAFORM OUTPUTS" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

function Get-TerraformOutput {
    param(
        [string]$Name
    )

    $Result = & $TerraformExe output -raw $Name 2>$null

    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    if ($null -eq $Result) {
        return ""
    }

    return $Result.Trim()
}

$ApiUrl = Get-TerraformOutput "api_gateway_url"
$ChatUrl = Get-TerraformOutput "chat_url"
$HealthUrl = Get-TerraformOutput "health_url"
$FrontendBucket = Get-TerraformOutput "s3_frontend_bucket"
$FrontendUrl = Get-TerraformOutput "frontend_url"
$LambdaFunctionName = Get-TerraformOutput "lambda_function_name"
$BedrockModel = Get-TerraformOutput "bedrock_model_id"
$AwsRegion = Get-TerraformOutput "aws_region"

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    throw "Could not retrieve Terraform output: api_gateway_url"
}

if ([string]::IsNullOrWhiteSpace($ChatUrl)) {
    throw "Could not retrieve Terraform output: chat_url"
}

if ([string]::IsNullOrWhiteSpace($HealthUrl)) {
    throw "Could not retrieve Terraform output: health_url"
}

if ([string]::IsNullOrWhiteSpace($FrontendBucket)) {
    throw "Could not retrieve Terraform output: s3_frontend_bucket"
}

if ([string]::IsNullOrWhiteSpace($FrontendUrl)) {
    throw "Could not retrieve Terraform output: frontend_url"
}

if ([string]::IsNullOrWhiteSpace($LambdaFunctionName)) {
    throw "Could not retrieve Terraform output: lambda_function_name"
}

if ([string]::IsNullOrWhiteSpace($BedrockModel)) {
    throw "Could not retrieve Terraform output: bedrock_model_id"
}

if ([string]::IsNullOrWhiteSpace($AwsRegion)) {
    $AwsRegion = "us-east-1"
}

Write-Host "AWS Region      : $AwsRegion" -ForegroundColor Cyan
Write-Host "Bedrock Model   : $BedrockModel" -ForegroundColor Cyan
Write-Host ""

Write-Host "API Gateway     : $ApiUrl" -ForegroundColor Cyan
Write-Host "Chat URL        : $ChatUrl" -ForegroundColor Cyan
Write-Host "Health URL      : $HealthUrl" -ForegroundColor Cyan
Write-Host "Frontend URL    : $FrontendUrl" -ForegroundColor Cyan
Write-Host "Frontend Bucket : $FrontendBucket" -ForegroundColor Cyan
Write-Host "Lambda          : $LambdaFunctionName" -ForegroundColor Cyan

# ============================================================
# 4. BUILD FRONTEND
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  4. BUILDING FRONTEND" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $FrontendPath)) {
    throw "Frontend directory not found: $FrontendPath"
}

Set-Location $FrontendPath

# ============================================================
# CREATE .env.production
# ============================================================

$EnvFile = Join-Path $FrontendPath ".env.production"

Write-Host "Creating .env.production..." -ForegroundColor Yellow

"NEXT_PUBLIC_API_URL=$ApiUrl" |
    Out-File `
        $EnvFile `
        -Encoding utf8 `
        -Force

Write-Host "NEXT_PUBLIC_API_URL=$ApiUrl" -ForegroundColor Green

# ============================================================
# NPM INSTALL
# ============================================================

Write-Host ""
Write-Host "Installing frontend dependencies..." -ForegroundColor Yellow

npm install

if ($LASTEXITCODE -ne 0) {
    throw "npm install failed."
}

# ============================================================
# NPM BUILD
# ============================================================

Write-Host ""
Write-Host "Building frontend..." -ForegroundColor Yellow

npm run build

if ($LASTEXITCODE -ne 0) {
    throw "Frontend build failed."
}

# ============================================================
# 5. UPLOAD FRONTEND
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  5. UPLOADING FRONTEND" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

$OutPath = Join-Path $FrontendPath "out"

if (-not (Test-Path $OutPath)) {
    throw "Frontend output directory not found: $OutPath"
}

Write-Host "Uploading frontend to:" -ForegroundColor Yellow
Write-Host "s3://$FrontendBucket/" -ForegroundColor Cyan
Write-Host ""

aws s3 sync `
    $OutPath `
    "s3://$FrontendBucket/" `
    --delete

if ($LASTEXITCODE -ne 0) {
    throw "Frontend upload failed."
}

Write-Host ""
Write-Host "Frontend uploaded successfully." -ForegroundColor Green

# ============================================================
# 6. TEST API
# ============================================================

Set-Location $ProjectRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  6. TESTING API" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

# ============================================================
# TEST HEALTH
# ============================================================

Write-Host "Testing /health endpoint..." -ForegroundColor Yellow

try {

    $HealthResponse = Invoke-RestMethod `
        -Uri $HealthUrl `
        -Method GET

    Write-Host ""
    Write-Host "Health response:" -ForegroundColor Green

    $HealthResponse |
        ConvertTo-Json -Depth 10 |
        Write-Host

}
catch {

    Write-Host ""
    Write-Host "WARNING: /health failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ErrorDetails.Message) {

        Write-Host ""
        Write-Host "Server response:" -ForegroundColor Yellow
        Write-Host $_.ErrorDetails.Message -ForegroundColor White

    }
}

# ============================================================
# TEST CHAT
# ============================================================

Write-Host ""
Write-Host "Testing /chat endpoint..." -ForegroundColor Yellow

try {

    $ChatBody = @{
        message = "Hello. Reply with exactly: API_TEST_OK"
    } | ConvertTo-Json -Compress

    $ChatResponse = Invoke-RestMethod `
        -Uri $ChatUrl `
        -Method POST `
        -ContentType "application/json" `
        -Body $ChatBody

    Write-Host ""
    Write-Host "Chat response:" -ForegroundColor Green

    $ChatResponse |
        ConvertTo-Json -Depth 10 |
        Write-Host

    if ($ChatResponse.response -match "API_TEST_OK") {

        Write-Host ""
        Write-Host "CHAT TEST PASSED." -ForegroundColor Green

    }
    else {

        Write-Host ""
        Write-Host "CHAT REQUEST SUCCEEDED." -ForegroundColor Green
        Write-Host "Response did not exactly match API_TEST_OK." -ForegroundColor Yellow

    }

}
catch {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "CHAT API TEST FAILED" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red

    Write-Host ""
    Write-Host "Exception:" -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor White

    if ($_.ErrorDetails.Message) {

        Write-Host ""
        Write-Host "Server response:" -ForegroundColor Yellow
        Write-Host $_.ErrorDetails.Message -ForegroundColor White

    }

    Write-Host ""
    Write-Host "Infrastructure deployment completed," -ForegroundColor Yellow
    Write-Host "but the chat endpoint returned an error." -ForegroundColor Yellow

    Write-Host ""
    Write-Host "Lambda function:" -ForegroundColor Cyan
    Write-Host $LambdaFunctionName -ForegroundColor White

    Write-Host ""
    Write-Host "CloudWatch logs:" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "aws logs tail /aws/lambda/$LambdaFunctionName --follow --region $AwsRegion" -ForegroundColor White
}

# ============================================================
# FINAL
# ============================================================

Set-Location $ProjectRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "       DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Environment    : $Environment" -ForegroundColor Cyan
Write-Host "Project        : $ProjectName" -ForegroundColor Cyan
Write-Host "AWS Region     : $AwsRegion" -ForegroundColor Cyan
Write-Host "Bedrock Model  : $BedrockModel" -ForegroundColor Cyan
Write-Host ""

Write-Host "Frontend URL   : $FrontendUrl" -ForegroundColor Cyan
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
Write-Host "Chat URL       : $ChatUrl" -ForegroundColor Cyan
Write-Host "Health URL     : $HealthUrl" -ForegroundColor Cyan
Write-Host "S3 Bucket      : $FrontendBucket" -ForegroundColor Cyan
Write-Host "Lambda         : $LambdaFunctionName" -ForegroundColor Cyan

Write-Host ""
Write-Host "CloudFront     : DISABLED" -ForegroundColor DarkYellow
Write-Host "ACM            : DISABLED" -ForegroundColor DarkYellow
Write-Host "Route53        : DISABLED" -ForegroundColor DarkYellow

Write-Host ""
Write-Host "Deployment finished." -ForegroundColor Green
Write-Host ""
