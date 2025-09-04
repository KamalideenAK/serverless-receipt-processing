output "bucket_name" {
  value       = aws_s3_bucket.receipts.bucket
  description = "S3 bucket for uploading receipts"
}

output "lambda_function_name" {
  value       = aws_lambda_function.processor.function_name
  description = "Lambda function name"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.receipts.name
  description = "DynamoDB table name"
}
