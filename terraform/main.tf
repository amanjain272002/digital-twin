data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  memory_bucket_name = "${local.name_prefix}-memory-${data.aws_caller_identity.current.account_id}"

  frontend_bucket_name = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
}


# ============================================================
# S3 - MEMORY
# ============================================================

resource "aws_s3_bucket" "memory" {
  bucket = local.memory_bucket_name

  tags = local.common_tags
}


resource "aws_s3_bucket_public_access_block" "memory" {
  bucket = aws_s3_bucket.memory.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


resource "aws_s3_bucket_ownership_controls" "memory" {
  bucket = aws_s3_bucket.memory.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}


# ============================================================
# S3 - FRONTEND
# ============================================================

resource "aws_s3_bucket" "frontend" {
  bucket = local.frontend_bucket_name

  tags = local.common_tags
}


resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}


resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}


resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}


resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"

        Action = [
          "s3:GetObject"
        ]

        Resource = [
          "${aws_s3_bucket.frontend.arn}/*"
        ]
      }
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.frontend
  ]
}


# ============================================================
# IAM ROLE - LAMBDA
# ============================================================

resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"

  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = "sts:AssumeRole"

        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}


# ============================================================
# CLOUDWATCH LOGGING
# ============================================================

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role = aws_iam_role.lambda_role.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}


# ============================================================
# LAMBDA APPLICATION IAM POLICY
# ============================================================

resource "aws_iam_role_policy" "lambda_app" {
  name = "${local.name_prefix}-lambda-app-policy"

  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [

      # ------------------------------------------------------
      # BEDROCK INFERENCE PROFILE
      # ------------------------------------------------------

      {
        Sid = "InvokeNova2LiteInferenceProfile"

        Effect = "Allow"

        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]

        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"
        ]
      },

      # ------------------------------------------------------
      # BEDROCK FOUNDATION MODELS
      # ------------------------------------------------------

      {
        Sid = "InvokeNova2LiteFoundationModels"

        Effect = "Allow"

        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]

        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.nova-2-lite-v1:0"
        ]
      },

      # ------------------------------------------------------
      # BEDROCK INFERENCE PROFILE READ
      # ------------------------------------------------------

      {
        Sid = "ReadNova2LiteInferenceProfile"

        Effect = "Allow"

        Action = [
          "bedrock:GetInferenceProfile"
        ]

        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"
        ]
      },

      # ------------------------------------------------------
      # S3 MEMORY BUCKET
      # ------------------------------------------------------

      {
        Sid = "ListMemoryBucket"

        Effect = "Allow"

        Action = [
          "s3:ListBucket"
        ]

        Resource = [
          aws_s3_bucket.memory.arn
        ]
      },

      {
        Sid = "ReadWriteMemoryObjects"

        Effect = "Allow"

        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]

        Resource = [
          "${aws_s3_bucket.memory.arn}/*"
        ]
      }
    ]
  })
}


# ============================================================
# LAMBDA FUNCTION
# ============================================================

resource "aws_lambda_function" "api" {
  filename = "${path.module}/../backend/lambda-deployment.zip"

  function_name = "${local.name_prefix}-api"

  role = aws_iam_role.lambda_role.arn

  handler = "lambda_handler.handler"

  runtime = "python3.12"

  architectures = [
    "x86_64"
  ]

  timeout = var.lambda_timeout

  memory_size = var.lambda_memory_size

  source_code_hash = filebase64sha256(
    "${path.module}/../backend/lambda-deployment.zip"
  )

  tags = local.common_tags

  environment {
    variables = {
      CORS_ORIGINS = "*"

      S3_BUCKET = aws_s3_bucket.memory.id

      DEFAULT_AWS_REGION = var.aws_region

      USE_S3 = "true"

      BEDROCK_MODEL_ID = var.bedrock_model_id

      MEMORY_DIR = "/tmp/memory"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_app
  ]
}


# ============================================================
# API GATEWAY HTTP API
# ============================================================

resource "aws_apigatewayv2_api" "main" {
  name = "${local.name_prefix}-api-gateway"

  protocol_type = "HTTP"

  tags = local.common_tags

  cors_configuration {
    allow_credentials = false

    allow_headers = [
      "*"
    ]

    allow_methods = [
      "GET",
      "POST",
      "OPTIONS"
    ]

    allow_origins = [
      "*"
    ]

    max_age = 300
  }
}


# ============================================================
# API GATEWAY STAGE
# ============================================================

resource "aws_apigatewayv2_stage" "default" {
  api_id = aws_apigatewayv2_api.main.id

  name = "$default"

  auto_deploy = true

  tags = local.common_tags

  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst_limit

    throttling_rate_limit = var.api_throttle_rate_limit
  }
}


# ============================================================
# API GATEWAY -> LAMBDA
# ============================================================

resource "aws_apigatewayv2_integration" "lambda" {
  api_id = aws_apigatewayv2_api.main.id

  integration_type = "AWS_PROXY"

  integration_uri = aws_lambda_function.api.invoke_arn

  payload_format_version = "2.0"

  timeout_milliseconds = 30000
}


# ============================================================
# ROUTES
# ============================================================

resource "aws_apigatewayv2_route" "get_root" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /"

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


resource "aws_apigatewayv2_route" "post_chat" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "POST /chat"

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


resource "aws_apigatewayv2_route" "get_health" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /health"

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


resource "aws_apigatewayv2_route" "get_conversation" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /conversation/{session_id}"

  target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


# ============================================================
# API GATEWAY -> LAMBDA PERMISSION
# ============================================================

resource "aws_lambda_permission" "api_gw" {
  statement_id = "AllowExecutionFromAPIGateway"

  action = "lambda:InvokeFunction"

  function_name = aws_lambda_function.api.function_name

  principal = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
