param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,

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

if ($Environment -notmatch '^(dev|test|prod)$') {

    Write-Host "Error: Invalid environment '$Environment'" -ForegroundColor Red
    Write-Host "Available environments: dev, test, prod" -ForegroundColor Yellow

    exit 1
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
# VALIDATE AWS CREDENTIALS
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
# AWS REGION
# ============================================================

$AwsRegion = if ($env:DEFAULT_AWS_REGION) {
    $env:DEFAULT_AWS_REGION
}
else {
    "us-east-1"
}

Write-Host "AWS Region  : $AwsRegion" -ForegroundColor Cyan

# ============================================================
# TERRAFORM DIRECTORY
# ============================================================

if (-not (Test-Path $TerraformPath)) {
    throw "Terraform directory not found: $TerraformPath"
}

Set-Location $TerraformPath

Write-Host ""
Write-Host "Terraform directory:" -ForegroundColor Yellow
Write-Host (Get-Location).Path -ForegroundColor Cyan

# ============================================================
# TERRAFORM BACKEND CONFIGURATION
# ============================================================

$TerraformStateBucket = "twin-terraform-state-$AwsAccountId"
$TerraformLockTable = "twin-terraform-locks"
$TerraformStateKey = "$Environment/terraform.tfstate"

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  TERRAFORM BACKEND CONFIGURATION" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "State Bucket : $TerraformStateBucket" -ForegroundColor Cyan
Write-Host "State Key    : $TerraformStateKey" -ForegroundColor Cyan
Write-Host "Lock Table   : $TerraformLockTable" -ForegroundColor Cyan
Write-Host "AWS Region   : $AwsRegion" -ForegroundColor Cyan

# ============================================================
# TERRAFORM INIT
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  1. TERRAFORM INITIALIZATION" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Initializing Terraform with S3 backend..." -ForegroundColor Yellow

& $TerraformExe init `
    -input=false `
    -backend-config="bucket=$TerraformStateBucket" `
    -backend-config="key=$TerraformStateKey" `
    -backend-config="region=$AwsRegion" `
    -backend-config="dynamodb_table=$TerraformLockTable" `
    -backend-config="encrypt=true"

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
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  2. TERRAFORM WORKSPACE" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Checking Terraform workspaces..." -ForegroundColor Yellow

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

    Write-Host ""
    Write-Host "Error: Workspace '$Environment' does not exist." -ForegroundColor Red
    Write-Host ""

    Write-Host "Available workspaces:" -ForegroundColor Yellow

    & $TerraformExe workspace list

    Set-Location $ProjectRoot

    exit 1
}

Write-Host "Selecting workspace: $Environment" -ForegroundColor Yellow

& $TerraformExe workspace select $Environment

if ($LASTEXITCODE -ne 0) {
    throw "Failed to select Terraform workspace: $Environment"
}

# ============================================================
# TERRAFORM VARIABLES
# ============================================================

$TerraformTfvars = Join-Path $TerraformPath "terraform.tfvars"

Write-Host ""
Write-Host "Checking Terraform variables..." -ForegroundColor Yellow

if (-not (Test-Path $TerraformTfvars)) {

    Write-Host "Warning: terraform.tfvars was not found." -ForegroundColor Yellow
    Write-Host "Continuing because variables are supplied through -var." -ForegroundColor Yellow

}
else {

    Write-Host "Using:" -ForegroundColor Green
    Write-Host $TerraformTfvars -ForegroundColor Cyan
}

# ============================================================
# PRODUCTION TFVARS
# ============================================================

$ProdTfvars = Join-Path $TerraformPath "prod.tfvars"

if ($Environment -eq "prod" -and (Test-Path $ProdTfvars)) {

    Write-Host ""
    Write-Host "Production variables detected:" -ForegroundColor Yellow
    Write-Host $ProdTfvars -ForegroundColor Cyan
}

# ============================================================
# DEFINE APPLICATION S3 BUCKETS
# ============================================================

$FrontendBucket = "$ProjectName-$Environment-frontend-$AwsAccountId"
$MemoryBucket = "$ProjectName-$Environment-memory-$AwsAccountId"

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  APPLICATION RESOURCES" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Frontend Bucket : $FrontendBucket" -ForegroundColor Cyan
Write-Host "Memory Bucket   : $MemoryBucket" -ForegroundColor Cyan

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

$TerraformFrontendBucket = Get-TerraformOutput "s3_frontend_bucket"
$LambdaFunctionName = Get-TerraformOutput "lambda_function_name"
$TerraformAwsRegion = Get-TerraformOutput "aws_region"

# ============================================================
# USE TERRAFORM OUTPUTS WHEN AVAILABLE
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($TerraformFrontendBucket)) {

    Write-Host ""
    Write-Host "Terraform Frontend Bucket:" -ForegroundColor Yellow
    Write-Host $TerraformFrontendBucket -ForegroundColor Cyan

    $FrontendBucket = $TerraformFrontendBucket
}

if (-not [string]::IsNullOrWhiteSpace($TerraformAwsRegion)) {
    $AwsRegion = $TerraformAwsRegion
}

Write-Host ""
Write-Host "AWS Region      : $AwsRegion" -ForegroundColor Cyan
Write-Host "Frontend Bucket : $FrontendBucket" -ForegroundColor Cyan
Write-Host "Memory Bucket   : $MemoryBucket" -ForegroundColor Cyan
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
Write-Host "    Workspace   : $Environment" -ForegroundColor Cyan
Write-Host ""

$Confirmation = Read-Host "Type DESTROY $Environment to continue"

if ($Confirmation -cne "DESTROY $Environment") {

    Write-Host ""
    Write-Host "Destroy cancelled." -ForegroundColor Yellow

    Set-Location $ProjectRoot

    exit 0
}

# ============================================================
# EMPTY FRONTEND S3 BUCKET
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  3. EMPTYING FRONTEND S3 BUCKET" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Bucket:" -ForegroundColor Cyan
Write-Host "s3://$FrontendBucket/" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking frontend bucket..." -ForegroundColor Yellow

$FrontendBucketExists = $true

aws s3api head-bucket `
    --bucket $FrontendBucket `
    --region $AwsRegion `
    2>$null

if ($LASTEXITCODE -ne 0) {
    $FrontendBucketExists = $false
}

if ($FrontendBucketExists) {

    Write-Host "Emptying $FrontendBucket..." -ForegroundColor Yellow

    aws s3 rm `
        "s3://$FrontendBucket/" `
        --recursive `
        --region $AwsRegion

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to empty frontend S3 bucket."
    }

    Write-Host "Frontend bucket emptied." -ForegroundColor Green

}
else {

    Write-Host "Frontend bucket not found or already deleted." -ForegroundColor Gray
}

# ============================================================
# EMPTY MEMORY S3 BUCKET
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  4. EMPTYING MEMORY S3 BUCKET" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Bucket:" -ForegroundColor Cyan
Write-Host "s3://$MemoryBucket/" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking memory bucket..." -ForegroundColor Yellow

$MemoryBucketExists = $true

aws s3api head-bucket `
    --bucket $MemoryBucket `
    --region $AwsRegion `
    2>$null

if ($LASTEXITCODE -ne 0) {
    $MemoryBucketExists = $false
}

if ($MemoryBucketExists) {

    Write-Host "Emptying $MemoryBucket..." -ForegroundColor Yellow

    aws s3 rm `
        "s3://$MemoryBucket/" `
        --recursive `
        --region $AwsRegion

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to empty memory S3 bucket."
    }

    Write-Host "Memory bucket emptied." -ForegroundColor Green

}
else {

    Write-Host "Memory bucket not found or already deleted." -ForegroundColor Gray
}

# ============================================================
# TERRAFORM DESTROY PLAN
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  5. TERRAFORM DESTROY PLAN" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Generating destroy plan..." -ForegroundColor Yellow

if ($Environment -eq "prod" -and (Test-Path $ProdTfvars)) {

    & $TerraformExe plan `
        -destroy `
        -var-file="$ProdTfvars" `
        -var="project_name=$ProjectName" `
        -var="environment=$Environment"

}
else {

    & $TerraformExe plan `
        -destroy `
        -var="project_name=$ProjectName" `
        -var="environment=$Environment"
}

if ($LASTEXITCODE -ne 0) {
    throw "Terraform destroy plan failed."
}

# ============================================================
# TERRAFORM DESTROY
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "  6. DESTROYING INFRASTRUCTURE" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

Write-Host "Running Terraform destroy..." -ForegroundColor Red
Write-Host ""

if ($Environment -eq "prod" -and (Test-Path $ProdTfvars)) {

    & $TerraformExe destroy `
        -var-file="$ProdTfvars" `
        -var="project_name=$ProjectName" `
        -var="environment=$Environment" `
        -auto-approve

}
else {

    & $TerraformExe destroy `
        -var="project_name=$ProjectName" `
        -var="environment=$Environment" `
        -auto-approve
}

if ($LASTEXITCODE -ne 0) {
    throw "Terraform destroy failed."
}

# ============================================================
# VERIFY TERRAFORM DESTROY
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  7. VERIFYING DESTROY" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Checking Terraform state..." -ForegroundColor Yellow

$RemainingResources = & $TerraformExe state list 2>$null

if ($LASTEXITCODE -eq 0 -and $RemainingResources) {

    Write-Host ""
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
# VERIFY FRONTEND S3 BUCKET
# ============================================================

Write-Host ""
Write-Host "Checking frontend S3 bucket..." -ForegroundColor Yellow

$FrontendStillExists = $true

aws s3api head-bucket `
    --bucket $FrontendBucket `
    --region $AwsRegion `
    2>$null

if ($LASTEXITCODE -ne 0) {
    $FrontendStillExists = $false
}

if ($FrontendStillExists) {

    Write-Host "WARNING: Frontend bucket still exists:" -ForegroundColor Yellow
    Write-Host "  $FrontendBucket" -ForegroundColor Yellow

}
else {

    Write-Host "Frontend bucket no longer exists." -ForegroundColor Green
}

# ============================================================
# VERIFY MEMORY S3 BUCKET
# ============================================================

Write-Host ""
Write-Host "Checking memory S3 bucket..." -ForegroundColor Yellow

$MemoryStillExists = $true

aws s3api head-bucket `
    --bucket $MemoryBucket `
    --region $AwsRegion `
    2>$null

if ($LASTEXITCODE -ne 0) {
    $MemoryStillExists = $false
}

if ($MemoryStillExists) {

    Write-Host "WARNING: Memory bucket still exists:" -ForegroundColor Yellow
    Write-Host "  $MemoryBucket" -ForegroundColor Yellow

}
else {

    Write-Host "Memory bucket no longer exists." -ForegroundColor Green
}

# ============================================================
# FINAL SUMMARY
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
Write-Host "Terraform State: $TerraformStateKey" -ForegroundColor Cyan
Write-Host ""

Write-Host "Terraform application infrastructure has been destroyed." -ForegroundColor Green
Write-Host ""

if ($FrontendStillExists) {
    Write-Host "Frontend S3    : STILL EXISTS" -ForegroundColor Yellow
}
else {
    Write-Host "Frontend S3    : DESTROYED" -ForegroundColor Green
}

if ($MemoryStillExists) {
    Write-Host "Memory S3      : STILL EXISTS" -ForegroundColor Yellow
}
else {
    Write-Host "Memory S3      : DESTROYED" -ForegroundColor Green
}

Write-Host ""

if ($RemainingResources) {

    Write-Host "Terraform State: RESOURCES REMAIN" -ForegroundColor Yellow

}
else {

    Write-Host "Terraform State: EMPTY" -ForegroundColor Green
}

Write-Host ""
Write-Host "NOTE: The Terraform backend resources were NOT destroyed." -ForegroundColor Cyan
Write-Host "This includes the Terraform state bucket and lock table." -ForegroundColor Cyan
Write-Host ""

Write-Host "To remove the Terraform workspace completely, run:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    cd `"$TerraformPath`"" -ForegroundColor White
Write-Host "    $TerraformExe workspace select default" -ForegroundColor White
Write-Host "    $TerraformExe workspace delete $Environment" -ForegroundColor White
Write-Host ""

Write-Host "Destroy finished." -ForegroundColor Green
Write-Host ""
