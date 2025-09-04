variable "project_name" {
  description = "A short name used to tag/name resources"
  type        = string
  default     = "serverless-receipt-processing"
}

variable "aws_region" {
  description = "AWS region to deploy into (also used for SES)"
  type        = string
  default     = "us-east-1"
}

variable "ses_sender_email" {
  description = "Verified SES sender email address"
  type        = string
}

variable "ses_recipient_email" {
  description = "Verified SES recipient email address (SES sandbox requires verification)"
  type        = string
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {
    "project" = "serverless-receipt-processing"
    "owner"   = "demo"
  }
}
