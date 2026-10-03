output "api_gateway_url" {
  description = "Base URL of the API Gateway"

  value = aws_apigatewayv2_api.main.api_endpoint
}


output "chat_url" {
  description = "POST /chat endpoint"

  value = "${aws_apigatewayv2_api.main.api_endpoint}/chat"
}


output "health_url" {
  description = "GET /health endpoint"

  value = "${aws_apigatewayv2_api.main.api_endpoint}/health"
}


output "conversation_url" {
  description = "Conversation endpoint"

  value = "${aws_apigatewayv2_api.main.api_endpoint}/conversation/{session_id}"
}


output "frontend_url" {
  description = "Public S3 website URL"

  value = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
}


output "s3_frontend_bucket" {
  description = "Frontend S3 bucket name"

  value = aws_s3_bucket.frontend.id
}


output "s3_memory_bucket" {
  description = "Memory S3 bucket name"

  value = aws_s3_bucket.memory.id
}


output "lambda_function_name" {
  description = "Lambda function name"

  value = aws_lambda_function.api.function_name
}


output "lambda_role_arn" {
  description = "Lambda IAM role ARN"

  value = aws_iam_role.lambda_role.arn
}


output "bedrock_model_id" {
  description = "Bedrock inference profile ID"

  value = var.bedrock_model_id
}


output "aws_region" {
  description = "AWS region"

  value = var.aws_region
}


output "cloudfront_url" {
  description = "CloudFront is disabled"

  value = "DISABLED"
}


output "custom_domain_url" {
  description = "Custom domain is disabled"

  value = "DISABLED"
}
