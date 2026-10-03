#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# PARAMETERS
# ============================================================

Environment="${1:-dev}"
ProjectName="${2:-twin}"

# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ProjectRoot="$(cd "$SCRIPT_DIR/.." && pwd)"

TerraformPath="$ProjectRoot/terraform"
BackendPath="$ProjectRoot/backend"
FrontendPath="$ProjectRoot/frontend"

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
# HEADER
# ============================================================

echo ""
echo "========================================"
echo -e "${GREEN}           TWIN DEPLOYMENT${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Project      : $ProjectName${RESET}"
echo -e "${CYAN}Environment  : $Environment${RESET}"
echo -e "${CYAN}Project Root : $ProjectRoot${RESET}"
echo ""

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
# VALIDATE ENVIRONMENT
# ============================================================

case "$Environment" in
    dev|test|prod)
        ;;
    *)
        error_exit "Invalid environment '$Environment'. Use dev, test, or prod."
        ;;
esac

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
# VALIDATE AWS IDENTITY
# ============================================================

echo -e "${YELLOW}Checking AWS credentials...${RESET}"

AwsAccountId="$(aws sts get-caller-identity \
    --query Account \
    --output text 2>/dev/null)" || error_exit "Unable to determine AWS account."

AwsArn="$(aws sts get-caller-identity \
    --query Arn \
    --output text 2>/dev/null)" || error_exit "Unable to determine AWS identity."

if [[ -z "$AwsAccountId" || "$AwsAccountId" == "None" ]]; then
    error_exit "Unable to determine AWS account."
fi

echo -e "${CYAN}AWS Account : $AwsAccountId${RESET}"
echo -e "${CYAN}AWS Identity: $AwsArn${RESET}"

echo ""

# ============================================================
# AWS REGION
# ============================================================

AwsRegion="${DEFAULT_AWS_REGION:-us-east-1}"

echo -e "${CYAN}AWS Region  : $AwsRegion${RESET}"

# ============================================================
# VALIDATE UV
# ============================================================

echo ""
echo -e "${YELLOW}Checking uv...${RESET}"

if ! command -v uv >/dev/null 2>&1; then
    error_exit "uv was not found."
fi

uv --version

# ============================================================
# VALIDATE NODE
# ============================================================

echo ""
echo -e "${YELLOW}Checking Node.js...${RESET}"

if ! command -v node >/dev/null 2>&1; then
    error_exit "Node.js was not found."
fi

node --version

# ============================================================
# VALIDATE NPM
# ============================================================

echo ""
echo -e "${YELLOW}Checking npm...${RESET}"

if ! command -v npm >/dev/null 2>&1; then
    error_exit "npm was not found."
fi

npm --version

# ============================================================
# 1. BUILD LAMBDA
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  1. BUILDING LAMBDA${RESET}"
echo "========================================"
echo ""

if [[ ! -d "$BackendPath" ]]; then
    error_exit "Backend directory not found: $BackendPath"
fi

cd "$BackendPath"

echo -e "${YELLOW}Running backend deployment script...${RESET}"

uv run deploy.py || error_exit "Lambda package creation failed."

LambdaZip="$BackendPath/lambda-deployment.zip"

if [[ ! -f "$LambdaZip" ]]; then
    error_exit "Lambda ZIP was not created: $LambdaZip"
fi

echo ""
echo -e "${GREEN}Lambda package created successfully.${RESET}"
echo -e "${CYAN}ZIP: $LambdaZip${RESET}"

cd "$ProjectRoot"

# ============================================================
# 2. TERRAFORM
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  2. TERRAFORM INFRASTRUCTURE${RESET}"
echo "========================================"
echo ""

if [[ ! -d "$TerraformPath" ]]; then
    error_exit "Terraform directory not found: $TerraformPath"
fi

cd "$TerraformPath"

# ============================================================
# TERRAFORM BACKEND CONFIGURATION
# ============================================================

TerraformStateBucket="twin-terraform-state-$AwsAccountId"
TerraformStateKey="$Environment/terraform.tfstate"
TerraformLockTable="twin-terraform-locks"

echo -e "${YELLOW}Terraform init...${RESET}"

echo ""
echo -e "${CYAN}Terraform backend configuration:${RESET}"
echo -e "${CYAN}  Bucket : $TerraformStateBucket${RESET}"
echo -e "${CYAN}  Key    : $TerraformStateKey${RESET}"
echo -e "${CYAN}  Region : $AwsRegion${RESET}"
echo -e "${CYAN}  Locks  : $TerraformLockTable${RESET}"
echo -e "${CYAN}  Encrypt: true${RESET}"
echo ""

terraform init \
    -input=false \
    -backend-config="bucket=$TerraformStateBucket" \
    -backend-config="key=$TerraformStateKey" \
    -backend-config="region=$AwsRegion" \
    -backend-config="dynamodb_table=$TerraformLockTable" \
    -backend-config="encrypt=true" \
    || error_exit "Terraform init failed."

# ============================================================
# TERRAFORM FORMAT
# ============================================================

echo ""
echo -e "${YELLOW}Terraform format...${RESET}"

terraform fmt -recursive \
    || error_exit "Terraform format failed."

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
echo -e "${YELLOW}Selecting Terraform workspace...${RESET}"

if terraform workspace list | sed 's/^[* ]*//' | grep -Fxq "$Environment"; then

    echo -e "${YELLOW}Selecting workspace: $Environment${RESET}"

    terraform workspace select "$Environment" \
        || error_exit "Failed to select Terraform workspace: $Environment"

else

    echo -e "${YELLOW}Creating workspace: $Environment${RESET}"

    terraform workspace new "$Environment" \
        || error_exit "Failed to create Terraform workspace: $Environment"

fi

# ============================================================
# TERRAFORM.TFVARS
# ============================================================

TerraformTfvars="$TerraformPath/terraform.tfvars"

echo ""
echo -e "${YELLOW}Checking Terraform variables...${RESET}"

if [[ ! -f "$TerraformTfvars" ]]; then
    error_exit "terraform.tfvars was not found: $TerraformTfvars"
fi

echo -e "${GREEN}Using:${RESET}"
echo -e "${CYAN}$TerraformTfvars${RESET}"

# ============================================================
# TERRAFORM APPLY
# ============================================================

echo ""
echo -e "${YELLOW}Applying Terraform...${RESET}"
echo ""

terraform apply \
    -var="project_name=$ProjectName" \
    -var="environment=$Environment" \
    -auto-approve \
    || error_exit "Terraform apply failed."

# ============================================================
# 3. TERRAFORM OUTPUTS
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  3. TERRAFORM OUTPUTS${RESET}"
echo "========================================"
echo ""

get_terraform_output() {
    local output_name="$1"

    terraform output -raw "$output_name" 2>/dev/null || true
}

ApiUrl="$(get_terraform_output "api_gateway_url")"
ChatUrl="$(get_terraform_output "chat_url")"
HealthUrl="$(get_terraform_output "health_url")"
FrontendBucket="$(get_terraform_output "s3_frontend_bucket")"
FrontendUrl="$(get_terraform_output "frontend_url")"
LambdaFunctionName="$(get_terraform_output "lambda_function_name")"
BedrockModel="$(get_terraform_output "bedrock_model_id")"
TerraformAwsRegion="$(get_terraform_output "aws_region")"

if [[ -n "$TerraformAwsRegion" ]]; then
    AwsRegion="$TerraformAwsRegion"
fi

if [[ -z "$ApiUrl" ]]; then
    error_exit "Could not retrieve Terraform output: api_gateway_url"
fi

if [[ -z "$ChatUrl" ]]; then
    error_exit "Could not retrieve Terraform output: chat_url"
fi

if [[ -z "$HealthUrl" ]]; then
    error_exit "Could not retrieve Terraform output: health_url"
fi

if [[ -z "$FrontendBucket" ]]; then
    error_exit "Could not retrieve Terraform output: s3_frontend_bucket"
fi

if [[ -z "$FrontendUrl" ]]; then
    error_exit "Could not retrieve Terraform output: frontend_url"
fi

if [[ -z "$LambdaFunctionName" ]]; then
    error_exit "Could not retrieve Terraform output: lambda_function_name"
fi

if [[ -z "$BedrockModel" ]]; then
    error_exit "Could not retrieve Terraform output: bedrock_model_id"
fi

echo -e "${CYAN}AWS Region      : $AwsRegion${RESET}"
echo -e "${CYAN}Bedrock Model   : $BedrockModel${RESET}"
echo ""

echo -e "${CYAN}API Gateway     : $ApiUrl${RESET}"
echo -e "${CYAN}Chat URL        : $ChatUrl${RESET}"
echo -e "${CYAN}Health URL      : $HealthUrl${RESET}"
echo -e "${CYAN}Frontend URL    : $FrontendUrl${RESET}"
echo -e "${CYAN}Frontend Bucket : $FrontendBucket${RESET}"
echo -e "${CYAN}Lambda          : $LambdaFunctionName${RESET}"

# ============================================================
# 4. BUILD FRONTEND
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  4. BUILDING FRONTEND${RESET}"
echo "========================================"
echo ""

if [[ ! -d "$FrontendPath" ]]; then
    error_exit "Frontend directory not found: $FrontendPath"
fi

cd "$FrontendPath"

# ============================================================
# CREATE .env.production
# ============================================================

EnvFile="$FrontendPath/.env.production"

echo -e "${YELLOW}Creating .env.production...${RESET}"

printf 'NEXT_PUBLIC_API_URL=%s\n' "$ApiUrl" > "$EnvFile"

echo -e "${GREEN}NEXT_PUBLIC_API_URL=$ApiUrl${RESET}"

# ============================================================
# NPM INSTALL
# ============================================================

echo ""
echo -e "${YELLOW}Installing frontend dependencies...${RESET}"

npm install \
    || error_exit "npm install failed."

# ============================================================
# NPM BUILD
# ============================================================

echo ""
echo -e "${YELLOW}Building frontend...${RESET}"

npm run build \
    || error_exit "Frontend build failed."

# ============================================================
# 5. UPLOAD FRONTEND
# ============================================================

echo ""
echo "========================================"
echo -e "${YELLOW}  5. UPLOADING FRONTEND${RESET}"
echo "========================================"
echo ""

OutPath="$FrontendPath/out"

if [[ ! -d "$OutPath" ]]; then
    error_exit "Frontend output directory not found: $OutPath"
fi

echo -e "${YELLOW}Uploading frontend to:${RESET}"
echo -e "${CYAN}s3://$FrontendBucket/${RESET}"
echo ""

aws s3 sync \
    "$OutPath" \
    "s3://$FrontendBucket/" \
    --delete \
    || error_exit "Frontend upload failed."

echo ""
echo -e "${GREEN}Frontend uploaded successfully.${RESET}"

# ============================================================
# 6. TEST API
# ============================================================

cd "$ProjectRoot"

echo ""
echo "========================================"
echo -e "${YELLOW}  6. TESTING API${RESET}"
echo "========================================"
echo ""

# ============================================================
# TEST HEALTH
# ============================================================

echo -e "${YELLOW}Testing /health endpoint...${RESET}"

if command -v curl >/dev/null 2>&1; then

    HealthResponse="$(curl \
        --silent \
        --show-error \
        --fail \
        --max-time 30 \
        "$HealthUrl" 2>&1)" || {

        echo ""
        echo -e "${RED}WARNING: /health failed.${RESET}"
        echo "$HealthResponse"

    }

    if [[ -n "${HealthResponse:-}" ]]; then
        echo ""
        echo -e "${GREEN}Health response:${RESET}"
        echo "$HealthResponse"
    fi

else

    echo -e "${YELLOW}curl not found. Skipping health test.${RESET}"

fi

# ============================================================
# TEST CHAT
# ============================================================

echo ""
echo -e "${YELLOW}Testing /chat endpoint...${RESET}"

ChatBody='{"message":"Hello. Reply with exactly: API_TEST_OK"}'

if command -v curl >/dev/null 2>&1; then

    ChatResponseFile="$(mktemp)"

    ChatHttpCode="$(curl \
        --silent \
        --show-error \
        --max-time 60 \
        --output "$ChatResponseFile" \
        --write-out "%{http_code}" \
        --request POST \
        --header "Content-Type: application/json" \
        --data "$ChatBody" \
        "$ChatUrl" 2>/dev/null || true)"

    ChatResponse="$(cat "$ChatResponseFile" 2>/dev/null || true)"

    rm -f "$ChatResponseFile"

    echo ""
    echo -e "${GREEN}Chat HTTP status: $ChatHttpCode${RESET}"

    echo ""
    echo -e "${GREEN}Chat response:${RESET}"
    echo "$ChatResponse"

    if [[ "$ChatHttpCode" =~ ^2[0-9][0-9]$ ]]; then

        if echo "$ChatResponse" | grep -q "API_TEST_OK"; then

            echo ""
            echo -e "${GREEN}CHAT TEST PASSED.${RESET}"

        else

            echo ""
            echo -e "${GREEN}CHAT REQUEST SUCCEEDED.${RESET}"
            echo -e "${YELLOW}Response did not exactly match API_TEST_OK.${RESET}"

        fi

    else

        echo ""
        echo "========================================"
        echo -e "${RED}CHAT API TEST FAILED${RESET}"
        echo "========================================"

        echo ""
        echo -e "${YELLOW}HTTP Status:${RESET}"
        echo "$ChatHttpCode"

        echo ""
        echo -e "${YELLOW}Server response:${RESET}"
        echo "$ChatResponse"

        echo ""
        echo -e "${YELLOW}Infrastructure deployment completed,${RESET}"
        echo -e "${YELLOW}but the chat endpoint returned an error.${RESET}"

        echo ""
        echo -e "${CYAN}Lambda function:${RESET}"
        echo "$LambdaFunctionName"

        echo ""
        echo -e "${CYAN}CloudWatch logs:${RESET}"
        echo ""

        echo "aws logs tail /aws/lambda/$LambdaFunctionName --follow --region $AwsRegion"

    fi

else

    echo -e "${YELLOW}curl not found. Skipping chat test.${RESET}"

fi

# ============================================================
# FINAL
# ============================================================

cd "$ProjectRoot"

echo ""
echo "========================================"
echo -e "${GREEN}       DEPLOYMENT COMPLETE${RESET}"
echo "========================================"
echo ""

echo -e "${CYAN}Environment    : $Environment${RESET}"
echo -e "${CYAN}Project        : $ProjectName${RESET}"
echo -e "${CYAN}AWS Account    : $AwsAccountId${RESET}"
echo -e "${CYAN}AWS Region     : $AwsRegion${RESET}"
echo -e "${CYAN}Bedrock Model  : $BedrockModel${RESET}"

echo ""

echo -e "${CYAN}Terraform State:${RESET}"
echo -e "${CYAN}  S3 Bucket    : $TerraformStateBucket${RESET}"
echo -e "${CYAN}  State Key    : $TerraformStateKey${RESET}"
echo -e "${CYAN}  Lock Table   : $TerraformLockTable${RESET}"

echo ""

echo -e "${CYAN}Frontend URL   : $FrontendUrl${RESET}"
echo -e "${CYAN}API Gateway    : $ApiUrl${RESET}"
echo -e "${CYAN}Chat URL       : $ChatUrl${RESET}"
echo -e "${CYAN}Health URL     : $HealthUrl${RESET}"
echo -e "${CYAN}S3 Bucket      : $FrontendBucket${RESET}"
echo -e "${CYAN}Lambda         : $LambdaFunctionName${RESET}"

echo ""

echo -e "${YELLOW}CloudFront     : DISABLED${RESET}"
echo -e "${YELLOW}ACM            : DISABLED${RESET}"
echo -e "${YELLOW}Route53        : DISABLED${RESET}"

echo ""
echo -e "${GREEN}Deployment finished.${RESET}"
echo ""
