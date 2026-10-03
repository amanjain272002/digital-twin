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

# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "           TWIN DESTROY" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
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
# PRODUCTION SAFETY
# ============================================================

if ($Environment -eq "prod") {

    Write-Host "========================================" -ForegroundColor Red
    Write-Host "          PRODUCTION DESTROY" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""

    Write-Host "WARNING: You are about to DESTROY the" -ForegroundColor Red
    Write-Host "Terraform infrastructure for:" -ForegroundColor Red
    Write-Host ""
    Write-Host "    Project     : $ProjectName" -ForegroundColor Yellow
    Write-Host "    Environment : $Environment" -ForegroundColor Yellow
    Write-Host ""

    $Confirmation = Read-Host "Type DESTROY to continue"

    if ($Confirmation -cne "DESTROY") {
        Write-Host ""
        Write-Host "Destroy cancelled." -ForegroundColor Yellow
        exit 0
    }
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
# TERRAFORM DIRECTORY
# ============================================================

if (-not (Test-Path $TerraformPath)) {
    throw "Terraform directory not found: $TerraformPath"
}

Set-Location $TerraformPath

# ============================================================
# TERRAFORM INIT
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  1. TERRAFORM INITIALIZATION" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Terraform init..." -ForegroundColor Yellow

& $TerraformExe init -input=false

if ($LASTEXITCODE -ne 0) {
    throw "Terraform init failed."
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
    throw "Terraform workspace '$Environment' does not exist."
}

Write-Host "Selecting workspace: $Environment" -ForegroundColor Yellow

& $TerraformExe workspace select $Environment

if ($LASTEXITCODE -ne 0) {
    throw "Failed to select Terraform workspace: $Environment"
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
# GET TERRAFORM OUTPUTS
# ============================================================

Write-Host ""
Write-Host "Reading Terraform outputs..." -ForegroundColor Yellow

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

$FrontendBucket = Get-TerraformOutput "s3_frontend_bucket"
$LambdaFunctionName = Get-TerraformOutput "lambda_function_name"
$AwsRegion = Get-TerraformOutput "aws_region"

if ([string]::IsNullOrWhiteSpace($AwsRegion)) {
    $AwsRegion = "us-east-1"
}

Write-Host ""
Write-Host "AWS Region      : $AwsRegion" -ForegroundColor Cyan
Write-Host "Frontend Bucket : $FrontendBucket" -ForegroundColor Cyan
Write-Host "Lambda          : $LambdaFunctionName" -ForegroundColor Cyan

# ============================================================
# FINAL DESTROY CONFIRMATION
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "       INFRASTRUCTURE DESTROY" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

Write-Host "The following Terraform workspace will be destroyed:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    Project     : $ProjectName" -ForegroundColor Cyan
Write-Host "    Environment : $Environment" -ForegroundColor Cyan
Write-Host "    AWS Account : $AwsAccountId" -ForegroundColor Cyan
Write-Host "    AWS Region  : $AwsRegion" -ForegroundColor Cyan
Write-Host ""

$Confirmation = Read-Host "Type DESTROY $Environment to continue"

if ($Confirmation -cne "DESTROY $Environment") {
    Write-Host ""
    Write-Host "Destroy cancelled." -ForegroundColor Yellow
    exit 0
}

# ============================================================
# EMPTY FRONTEND S3 BUCKET
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($FrontendBucket)) {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  2. EMPTYING FRONTEND S3 BUCKET" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Bucket:" -ForegroundColor Cyan
    Write-Host "s3://$FrontendBucket/" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Removing frontend objects..." -ForegroundColor Yellow

    aws s3 rm `
        "s3://$FrontendBucket/" `
        --recursive `
        --region $AwsRegion

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to empty frontend S3 bucket."
    }

    Write-Host ""
    Write-Host "Frontend bucket emptied." -ForegroundColor Green
}

# ============================================================
# TERRAFORM PLAN DESTROY
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  3. TERRAFORM DESTROY PLAN" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Generating destroy plan..." -ForegroundColor Yellow

& $TerraformExe plan `
    -destroy `
    -var="project_name=$ProjectName" `
    -var="environment=$Environment"

if ($LASTEXITCODE -ne 0) {
    throw "Terraform destroy plan failed."
}

# ============================================================
# TERRAFORM DESTROY
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "  4. DESTROYING INFRASTRUCTURE" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

Write-Host "Running Terraform destroy..." -ForegroundColor Red
Write-Host ""

& $TerraformExe destroy `
    -var="project_name=$ProjectName" `
    -var="environment=$Environment" `
    -auto-approve

if ($LASTEXITCODE -ne 0) {
    throw "Terraform destroy failed."
}

# ============================================================
# VERIFY DESTROY
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  5. VERIFYING DESTROY" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

$RemainingResources = & $TerraformExe state list 2>$null

if ($LASTEXITCODE -eq 0 -and $RemainingResources) {

    Write-Host "WARNING: Terraform state still contains resources:" -ForegroundColor Yellow
    Write-Host ""

    $RemainingResources | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Yellow
    }

}
else {

    Write-Host "Terraform state is empty." -ForegroundColor Green

}

# ============================================================
# FINAL
# ============================================================

Set-Location $ProjectRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "       DESTROY COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Environment    : $Environment" -ForegroundColor Cyan
Write-Host "Project        : $ProjectName" -ForegroundColor Cyan
Write-Host "AWS Account    : $AwsAccountId" -ForegroundColor Cyan
Write-Host "AWS Region     : $AwsRegion" -ForegroundColor Cyan
Write-Host ""

Write-Host "Terraform infrastructure has been destroyed." -ForegroundColor Green
Write-Host ""

Write-Host "CloudFront     : DISABLED" -ForegroundColor DarkYellow
Write-Host "ACM            : DISABLED" -ForegroundColor DarkYellow
Write-Host "Route53        : DISABLED" -ForegroundColor DarkYellow

Write-Host ""
Write-Host "Destroy finished." -ForegroundColor Green
Write-Host ""
