variable "project_name" {
  description = "Project name"

  type = string

  default = "twin"
}


variable "environment" {
  description = "Deployment environment"

  type = string

  default = "dev"

  validation {
    condition = contains(
      ["dev", "test", "prod"],
      var.environment
    )

    error_message = "Environment must be dev, test, or prod."
  }
}


variable "aws_region" {
  description = "AWS region where the application is deployed"

  type = string

  default = "us-east-1"
}


variable "bedrock_model_id" {
  description = "Amazon Bedrock inference profile ID"

  type = string

  default = "global.amazon.nova-2-lite-v1:0"
}


variable "lambda_timeout" {
  description = "Lambda timeout in seconds"

  type = number

  default = 60

  validation {
    condition = var.lambda_timeout >= 1 && var.lambda_timeout <= 900

    error_message = "Lambda timeout must be between 1 and 900 seconds."
  }
}


variable "lambda_memory_size" {
  description = "Lambda memory size in MB"

  type = number

  default = 1024

  validation {
    condition = var.lambda_memory_size >= 128 && var.lambda_memory_size <= 10240

    error_message = "Lambda memory must be between 128 MB and 10240 MB."
  }
}


variable "api_throttle_burst_limit" {
  description = "API Gateway burst limit"

  type = number

  default = 100
}


variable "api_throttle_rate_limit" {
  description = "API Gateway rate limit"

  type = number

  default = 50
}
