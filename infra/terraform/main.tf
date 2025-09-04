locals {
  bucket_name = "${var.project_name}-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 3
}

# ---------- S3 bucket for uploads ----------
resource "aws_s3_bucket" "receipts" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.receipts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.receipts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.receipts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.receipts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- DynamoDB Table ----------
resource "aws_dynamodb_table" "receipts" {
  name         = "${var.project_name}-table"
  billing_mode = "PAY_PER_REQUEST" # On-demand
  hash_key     = "receipt_id"

  attribute {
    name = "receipt_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}

# ---------- Lambda packaging ----------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/lambda"
  output_path = "${path.module}/build/lambda.zip"
}

# ---------- IAM for Lambda ----------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.receipts.arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "textract:AnalyzeExpense"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem"
    ]
    resources = [aws_dynamodb_table.receipts.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_inline" {
  name   = "${var.project_name}-lambda-policy"
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_inline.arn
}

# ---------- Lambda function ----------
resource "aws_lambda_function" "processor" {
  function_name = "${var.project_name}-fn"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "receipt_processor.handler"
  runtime = "python3.12"
  role    = aws_iam_role.lambda_exec.arn
  timeout = 60
  memory_size = 512

  environment {
    variables = {
      DDB_TABLE_NAME = aws_dynamodb_table.receipts.name
      SES_SENDER     = var.ses_sender_email
      SES_RECIPIENT  = var.ses_recipient_email
    }
  }

  tags = var.tags
}

# ---------- Allow S3 to invoke Lambda ----------
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.receipts.arn
}

# ---------- S3 -> Lambda notification ----------
resource "aws_s3_bucket_notification" "notify" {
  bucket = aws_s3_bucket.receipts.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpeg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".png"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# ---------- (Optional) Verify SES identities ----------
# Note: In SES sandbox, both sender and recipient must be verified.
resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.ses_sender_email
}

resource "aws_sesv2_email_identity" "recipient" {
  email_identity = var.ses_recipient_email
}
