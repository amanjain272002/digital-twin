#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# PARAMETERS
# ============================================================

Environment="${1:-}"
ProjectName="${2:-twin}"

# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
RESET='\033[0m'

# ============================================================
# ERROR HANDLER
# ============================================================

error_exit() {
    echo ""
    echo -e "${RED}ERROR: $1${RESET}"
    echo ""
    exit 1
}

# ============================================================
# REQUIRE ENVIRONMENT
# ============================================================

if [[ -z "$Environment" ]]; then

    echo -e "${RED}Error: Environment is required.${RESET}"
    echo ""
    echo "Usage:"
    echo "  ./scripts/destroy.sh dev"
    echo "  ./scripts/destroy.sh test"
    echo "  ./scripts/destroy.sh prod"
    echo ""

    exit 1

fi

# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ProjectRoot="$(cd "$SCRIPT_DIR/.." && pwd)"

TerraformPath="$ProjectRoot/terraform"

# ============================================================
# HEADER
# ============================================================

echo ""
echo "========================================"
echo -e "${RED}           TWIN DESTROY${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Project      : $ProjectName${RESET}"
echo -e "${CYAN}Environment  : $Environment${RESET}"
echo -e "${CYAN}Project Root : $ProjectRoot${RESET}"
echo ""

# ============================================================
# VALIDATE ENVIRONMENT
# ============================================================

case "$Environment" in

    dev|test|prod)
        ;;

    *)
        echo -e "${RED}Error: Invalid environment '$Environment'${RESET}"
        echo -e "${YELLOW}Available environments: dev, test, prod${RESET}"
        exit 1
        ;;

esac

# ============================================================
# PRODUCTION SAFETY
# ============================================================

if [[ "$Environment" == "prod" ]]; then

    echo "========================================"
    echo -e "${RED}          PRODUCTION DESTROY${RESET}"
    echo "========================================"
    echo ""

    echo -e "${RED}WARNING: You are about to DESTROY the${RESET}"
    echo -e "${RED}Terraform infrastructure for:${RESET}"
    echo ""

    echo -e "${YELLOW}    Project     : $ProjectName${RESET}"
    echo -e "${YELLOW}    Environment : $Environment${RESET}"
    echo ""

    read -r -p "Type DESTROY to continue: " Confirmation

    if [[ "$Confirmation" != "DESTROY" ]]; then

        echo ""
        echo -e "${YELLOW}Destroy cancelled.${RESET}"

        exit 0

    fi

fi

# ============================================================
# VALIDATE TERRAFORM
# ============================================================

echo -e "${YELLOW}Checking Terraform...${RESET}"

if ! command -v terraform >/dev/null 2>&1; then
    error_exit "Terraform was not found."
fi

terraform version

echo ""

# ============================================================
# VALIDATE AWS CLI
# ============================================================

echo -e "${YELLOW}Checking AWS CLI...${RESET}"

if ! command -v aws >/dev/null 2>&1; then
    error_exit "AWS CLI was not found."
fi

aws --version

echo ""

# ============================================================
# VALIDATE AWS CREDENTIALS
# ============================================================

echo -e "${YELLOW}Checking AWS credentials...${RESET}"

AwsAccountId="$(
    aws sts get-caller-identity \
        --query Account \
        --output text \
        2>/dev/null
)" || error_exit "Unable to determine AWS account."

AwsArn="$(
    aws sts get-caller-identity \
        --query Arn \
        --output text \
        2>/dev/null
)" || error_exit "Unable to determine AWS identity."

if [[ -z "$AwsAccountId" || "$AwsAccountId" == "None" ]]; then
    error_exit "Unable to determine AWS account."
fi

echo -e "${CYAN}AWS Account : $AwsAccountId${RESET}"
echo -e "${CYAN}AWS Identity: $AwsArn${RESET}"

# ============================================================
# AWS REGION
# ============================================================

AwsRegion="${DEFAULT_AWS_REGION:-us-east-1}"

echo -e "${CYAN}AWS Region  : $AwsRegion${RESET}"

# ============================================================
# TERRAFORM DIRECTORY
# ============================================================

if [[ ! -d "$TerraformPath" ]]; then
    error_exit "Terraform directory not found: $TerraformPath"
fi

cd "$TerraformPath"

echo ""
echo -e "${YELLOW}Terraform directory:${RESET}"
echo -e "${CYAN}$(pwd)${RESET}"

# ============================================================
# TERRAFORM BACKEND CONFIGURATION
# ============================================================

TerraformStateBucket="twin-terraform-state-$AwsAccountId"
TerraformLockTable="twin-terraform-locks"
TerraformStateKey="$Environment/terraform.tfstate"

echo ""
echo "========================================"
echo -e "${YELLOW}  TERRAFORM BACKEND CONFIGURATION${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}State Bucket : $TerraformStateBucket${RESET}"
echo -e "${CYAN}State Key    : $TerraformStateKey${RESET}"
echo -e "${CYAN}Lock Table   : $TerraformLockTable${RESET}"
echo -e "${CYAN}AWS Region   : $AwsRegion${RESET}"

# ============================================================
# TERRAFORM INIT
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  1. TERRAFORM INITIALIZATION${RESET}"
echo "========================================"
echo ""

echo -e "${YELLOW}Initializing Terraform with S3 backend...${RESET}"

terraform init \
    -input=false \
    -backend-config="bucket=$TerraformStateBucket" \
    -backend-config="key=$TerraformStateKey" \
    -backend-config="region=$AwsRegion" \
    -backend-config="dynamodb_table=$TerraformLockTable" \
    -backend-config="encrypt=true" \
    || error_exit "Terraform init failed."

# ============================================================
# TERRAFORM VALIDATE
# ============================================================

echo ""
echo -e "${YELLOW}Terraform validate...${RESET}"

terraform validate \
    || error_exit "Terraform validation failed."

# ============================================================
# TERRAFORM WORKSPACE
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  2. TERRAFORM WORKSPACE${RESET}"
echo "========================================"
echo ""

echo -e "${YELLOW}Checking Terraform workspaces...${RESET}"

WorkspaceExists=false

while IFS= read -r Workspace; do

    CleanWorkspace="$(echo "$Workspace" | sed 's/^[*[:space:]]*//;s/[[:space:]]*$//')"

    if [[ "$CleanWorkspace" == "$Environment" ]]; then
        WorkspaceExists=true
        break
    fi

done < <(terraform workspace list)

if [[ "$WorkspaceExists" != true ]]; then

    echo ""
    echo -e "${RED}Error: Workspace '$Environment' does not exist.${RESET}"
    echo ""

    echo -e "${YELLOW}Available workspaces:${RESET}"

    terraform workspace list

    cd "$ProjectRoot"

    exit 1

fi

echo -e "${YELLOW}Selecting workspace: $Environment${RESET}"

terraform workspace select "$Environment" \
    || error_exit "Failed to select Terraform workspace: $Environment"

# ============================================================
# TERRAFORM VARIABLES
# ============================================================

TerraformTfvars="$TerraformPath/terraform.tfvars"

echo ""
echo -e "${YELLOW}Checking Terraform variables...${RESET}"

if [[ ! -f "$TerraformTfvars" ]]; then

    echo -e "${YELLOW}Warning: terraform.tfvars was not found.${RESET}"
    echo -e "${YELLOW}Continuing because variables are supplied through -var.${RESET}"

else

    echo -e "${GREEN}Using:${RESET}"
    echo -e "${CYAN}$TerraformTfvars${RESET}"

fi

# ============================================================
# PRODUCTION TFVARS
# ============================================================

ProdTfvars="$TerraformPath/prod.tfvars"

if [[ "$Environment" == "prod" && -f "$ProdTfvars" ]]; then

    echo ""
    echo -e "${YELLOW}Production variables detected:${RESET}"
    echo -e "${CYAN}$ProdTfvars${RESET}"

fi

# ============================================================
# DEFINE APPLICATION S3 BUCKETS
# ============================================================

FrontendBucket="$ProjectName-$Environment-frontend-$AwsAccountId"
MemoryBucket="$ProjectName-$Environment-memory-$AwsAccountId"

echo ""
echo "========================================"
echo -e "${YELLOW}  APPLICATION RESOURCES${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Frontend Bucket : $FrontendBucket${RESET}"
echo -e "${CYAN}Memory Bucket   : $MemoryBucket${RESET}"

# ============================================================
# GET TERRAFORM OUTPUTS
# ============================================================

echo ""
echo -e "${YELLOW}Reading Terraform outputs...${RESET}"

get_terraform_output() {

    local OutputName="$1"

    terraform output -raw "$OutputName" 2>/dev/null || true

}

TerraformFrontendBucket="$(get_terraform_output "s3_frontend_bucket")"
LambdaFunctionName="$(get_terraform_output "lambda_function_name")"
TerraformAwsRegion="$(get_terraform_output "aws_region")"

# ============================================================
# USE TERRAFORM OUTPUTS WHEN AVAILABLE
# ============================================================

if [[ -n "$TerraformFrontendBucket" ]]; then

    echo ""
    echo -e "${YELLOW}Terraform Frontend Bucket:${RESET}"
    echo -e "${CYAN}$TerraformFrontendBucket${RESET}"

    FrontendBucket="$TerraformFrontendBucket"

fi

if [[ -n "$TerraformAwsRegion" ]]; then
    AwsRegion="$TerraformAwsRegion"
fi

echo ""
echo -e "${CYAN}AWS Region      : $AwsRegion${RESET}"
echo -e "${CYAN}Frontend Bucket : $FrontendBucket${RESET}"
echo -e "${CYAN}Memory Bucket   : $MemoryBucket${RESET}"
echo -e "${CYAN}Lambda          : ${LambdaFunctionName:-Not found}${RESET}"

# ============================================================
# FINAL DESTROY CONFIRMATION
# ============================================================

echo ""
echo "========================================"
echo -e "${RED}       INFRASTRUCTURE DESTROY${RESET}"
echo "========================================"
echo ""

echo -e "${YELLOW}The following Terraform workspace will be destroyed:${RESET}"
echo ""

echo -e "${CYAN}    Project     : $ProjectName${RESET}"
echo -e "${CYAN}    Environment : $Environment${RESET}"
echo -e "${CYAN}    AWS Account : $AwsAccountId${RESET}"
echo -e "${CYAN}    AWS Region  : $AwsRegion${RESET}"
echo -e "${CYAN}    Workspace   : $Environment${RESET}"
echo ""

read -r -p "Type DESTROY $Environment to continue: " Confirmation

if [[ "$Confirmation" != "DESTROY $Environment" ]]; then

    echo ""
    echo -e "${YELLOW}Destroy cancelled.${RESET}"

    cd "$ProjectRoot"

    exit 0

fi

# ============================================================
# EMPTY FRONTEND S3 BUCKET
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  3. EMPTYING FRONTEND S3 BUCKET${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Bucket:${RESET}"
echo -e "${CYAN}s3://$FrontendBucket/${RESET}"
echo ""

echo -e "${YELLOW}Checking frontend bucket...${RESET}"

if aws s3api head-bucket \
    --bucket "$FrontendBucket" \
    --region "$AwsRegion" \
    2>/dev/null; then

    echo -e "${YELLOW}Emptying $FrontendBucket...${RESET}"

    aws s3 rm \
        "s3://$FrontendBucket/" \
        --recursive \
        --region "$AwsRegion" \
        || error_exit "Failed to empty frontend S3 bucket."

    echo -e "${GREEN}Frontend bucket emptied.${RESET}"

else

    echo -e "${GRAY}Frontend bucket not found or already deleted.${RESET}"

fi

# ============================================================
# EMPTY MEMORY S3 BUCKET
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  4. EMPTYING MEMORY S3 BUCKET${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Bucket:${RESET}"
echo -e "${CYAN}s3://$MemoryBucket/${RESET}"
echo ""

echo -e "${YELLOW}Checking memory bucket...${RESET}"

if aws s3api head-bucket \
    --bucket "$MemoryBucket" \
    --region "$AwsRegion" \
    2>/dev/null; then

    echo -e "${YELLOW}Emptying $MemoryBucket...${RESET}"

    aws s3 rm \
        "s3://$MemoryBucket/" \
        --recursive \
        --region "$AwsRegion" \
        || error_exit "Failed to empty memory S3 bucket."

    echo -e "${GREEN}Memory bucket emptied.${RESET}"

else

    echo -e "${GRAY}Memory bucket not found or already deleted.${RESET}"

fi

# ============================================================
# TERRAFORM DESTROY PLAN
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  5. TERRAFORM DESTROY PLAN${RESET}"
echo "========================================"
echo ""

echo -e "${YELLOW}Generating destroy plan...${RESET}"

if [[ "$Environment" == "prod" && -f "$ProdTfvars" ]]; then

    terraform plan \
        -destroy \
        -var-file="$ProdTfvars" \
        -var="project_name=$ProjectName" \
        -var="environment=$Environment"

else

    terraform plan \
        -destroy \
        -var="project_name=$ProjectName" \
        -var="environment=$Environment"

fi

# ============================================================
# TERRAFORM DESTROY
# ============================================================

echo ""
echo "========================================"
echo -e "${RED}  6. DESTROYING INFRASTRUCTURE${RESET}"
echo "========================================"
echo ""

echo -e "${RED}Running Terraform destroy...${RESET}"
echo ""

if [[ "$Environment" == "prod" && -f "$ProdTfvars" ]]; then

    terraform destroy \
        -var-file="$ProdTfvars" \
        -var="project_name=$ProjectName" \
        -var="environment=$Environment" \
        -auto-approve

else

    terraform destroy \
        -var="project_name=$ProjectName" \
        -var="environment=$Environment" \
        -auto-approve

fi

# ============================================================
# VERIFY TERRAFORM DESTROY
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  7. VERIFYING DESTROY${RESET}"
echo "========================================"
echo ""

echo -e "${YELLOW}Checking Terraform state...${RESET}"

RemainingResources="$(terraform state list 2>/dev/null || true)"

if [[ -n "$RemainingResources" ]]; then

    echo ""
    echo -e "${YELLOW}WARNING: Terraform state still contains resources:${RESET}"
    echo ""

    while IFS= read -r Resource; do
        echo -e "${YELLOW}  $Resource${RESET}"
    done <<< "$RemainingResources"

else

    echo -e "${GREEN}Terraform state is empty.${RESET}"

fi

# ============================================================
# VERIFY FRONTEND S3 BUCKET
# ============================================================

echo ""
echo -e "${YELLOW}Checking frontend S3 bucket...${RESET}"

FrontendStillExists=false

if aws s3api head-bucket \
    --bucket "$FrontendBucket" \
    --region "$AwsRegion" \
    2>/dev/null; then

    FrontendStillExists=true

fi

if [[ "$FrontendStillExists" == true ]]; then

    echo -e "${YELLOW}WARNING: Frontend bucket still exists:${RESET}"
    echo -e "${YELLOW}  $FrontendBucket${RESET}"

else

    echo -e "${GREEN}Frontend bucket no longer exists.${RESET}"

fi

# ============================================================
# VERIFY MEMORY S3 BUCKET
# ============================================================

echo ""
echo -e "${YELLOW}Checking memory S3 bucket...${RESET}"

MemoryStillExists=false

if aws s3api head-bucket \
    --bucket "$MemoryBucket" \
    --region "$AwsRegion" \
    2>/dev/null; then

    MemoryStillExists=true

fi

if [[ "$MemoryStillExists" == true ]]; then

    echo -e "${YELLOW}WARNING: Memory bucket still exists:${RESET}"
    echo -e "${YELLOW}  $MemoryBucket${RESET}"

else

    echo -e "${GREEN}Memory bucket no longer exists.${RESET}"

fi

# ============================================================
# FINAL SUMMARY
# ============================================================

cd "$ProjectRoot"

echo ""
echo "========================================"
echo -e "${GREEN}       DESTROY COMPLETE${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Environment    : $Environment${RESET}"
echo -e "${CYAN}Project        : $ProjectName${RESET}"
echo -e "${CYAN}AWS Account    : $AwsAccountId${RESET}"
echo -e "${CYAN}AWS Region     : $AwsRegion${RESET}"
echo -e "${CYAN}Terraform State: $TerraformStateKey${RESET}"

echo ""

echo -e "${GREEN}Terraform application infrastructure has been destroyed.${RESET}"

echo ""

if [[ "$FrontendStillExists" == true ]]; then

    echo -e "${YELLOW}Frontend S3    : STILL EXISTS${RESET}"

else

    echo -e "${GREEN}Frontend S3    : DESTROYED${RESET}"

fi

if [[ "$MemoryStillExists" == true ]]; then

    echo -e "${YELLOW}Memory S3      : STILL EXISTS${RESET}"

else

    echo -e "${GREEN}Memory S3      : DESTROYED${RESET}"

fi

echo ""

if [[ -n "$RemainingResources" ]]; then

    echo -e "${YELLOW}Terraform State: RESOURCES REMAIN${RESET}"

else

    echo -e "${GREEN}Terraform State: EMPTY${RESET}"

fi

echo ""

echo -e "${CYAN}NOTE: The Terraform backend resources were NOT destroyed.${RESET}"
echo -e "${CYAN}This includes the Terraform state bucket and lock table.${RESET}"

echo ""

echo -e "${CYAN}To remove the Terraform workspace completely, run:${RESET}"
echo ""

echo -e "${WHITE}    cd \"$TerraformPath\"${RESET}"
echo -e "${WHITE}    terraform workspace select default${RESET}"
echo -e "${WHITE}    terraform workspace delete $Environment${RESET}"

echo ""

echo -e "${GREEN}Destroy finished.${RESET}"
echo ""
