# Serverless Receipt Processing System

> **A production-oriented, serverless pipeline that extracts structured data from receipt images using AWS Textract, persists results to DynamoDB, and notifies users via SES.**

---

## Table of contents

1. [Project overview](#project-overview)
2. [Who this is for](#who-this-is-for)
3. [Problem statement](#problem-statement)
4. [Architecture at a glance](#architecture-at-a-glance)
5. [Repository layout](#repository-layout)
6. [Prerequisites](#prerequisites)
7. [Configuration](#configuration)
8. [Step-by-step deployment (Terraform)](#step-by-step-deployment-terraform)
9. [Testing the system](#testing-the-system)
10. [Operational / debugging tips](#operational--debugging-tips)
11. [Cost estimation & optimization tips](#cost-estimation--optimization-tips)
12. [Security considerations](#security-considerations)
13. [Extending the project](#extending-the-project)
14. [FAQ / Troubleshooting](#faq--troubleshooting)
15. [Contributing & License](#contributing--license)

---

## Project overview

This repository contains a ready-to-deploy, serverless solution for **receipt processing** that demonstrates:

* Event-driven architecture (S3 → Lambda)
* OCR for receipts with **Amazon Textract** (AnalyzeExpense)
* NoSQL data storage with **Amazon DynamoDB**
* Email notifications using **Amazon SES**
* Reproducible infrastructure using **Terraform**

The goal is a minimal, production-minded reference implementation you can fork and adapt for retail, e‑commerce, bookkeeping, or personal-finance workflows.

---

## Who this is for

* Engineers learning serverless patterns on AWS
* Architects evaluating Textract + serverless cost / design
* Developers prototyping receipt ingestion for apps
* Companies needing a lightweight pipeline for receipt OCR and storage

---

## Problem statement

Receipts come in many shapes and formats. Manually entering or building custom OCR pipelines is expensive. This project demonstrates how to: when a user uploads a receipt image, automatically extract vendor, date, totals and line items, store the parsed result, and send a confirmation email — all without servers.

---

## Architecture at a glance

* **User** uploads an image to an **S3** bucket.
* S3 triggers a **Lambda** function on `ObjectCreated` events (image types filtered in Terraform).
* Lambda calls **Textract AnalyzeExpense** to parse the receipt's `SummaryFields` and `LineItemGroups`.
* Parsed data is written to **DynamoDB** as a JSON document keyed by `receipt_id` (UUID).
* Lambda sends a confirmation email to the user via **SES** with the parsed summary and a preview of line items.

A Mermaid diagram and a PNG are included in `architecture/`.

<img width="873" height="522" alt="image" src="https://github.com/user-attachments/assets/da4b59ed-0443-4f0d-80fa-8407e27ac861" />
---

## Repository layout

```
├── infra/terraform/           # Terraform IaC (deploys S3, Lambda, DynamoDB, SES identities)
├── src/lambda/                # Lambda function (Python 3.12)
├── sample-data/               # Fake receipt image for testing
├── architecture/              # Mermaid + PNG architecture diagram
├── demo/                      # Mock screenshots + demo GIF
├── README.md                  # (this file)
└── LICENSE
```

---

## Prerequisites

1. **AWS account** with permissions to create S3, Lambda, IAM roles/policies, DynamoDB, SES, and CloudWatch resources.
2. **AWS CLI** installed and configured with credentials (`aws configure`) or environment variables.
3. **Terraform** >= 1.5 installed locally.
4. A verified **SES sender email** and (if in SES sandbox) a verified **recipient email**. You can verify identities in the SES Console or via the AWS CLI.
5. (Optional) `jq` for parsing JSON in the shell when testing.

> **Note:** Textract and SES are region-specific. Use a region that supports **Textract AnalyzeExpense** and **SES** (example: `us-east-1`). You can override the region via Terraform variables.

---

## Configuration

Terraform variables are defined in `infra/terraform/variables.tf`. The important ones to set during `terraform apply`:

* `ses_sender_email` — The verified sender email (e.g. `sender@example.com`).
* `ses_recipient_email` — The recipient (SES sandbox requires verification for both).
* `aws_region` — Optional, default `us-east-1`.

You can pass these as `-var` arguments to `terraform plan` / `apply`, or create a `terraform.tfvars` file in `infra/terraform/`.

Example `terraform.tfvars`:

```hcl
ses_sender_email = "sender@example.com"
ses_recipient_email = "recipient@example.com"
aws_region = "us-east-1"
```

---

## Step-by-step deployment (Terraform)

> The Terraform used here packages the `src/lambda` folder automatically using the `archive_file` data source.

1. Open a terminal and change into the Terraform folder:

```bash
cd infra/terraform
```

2. Initialize Terraform providers:

```bash
terraform init
```

3. Review the planned changes (replace emails):

```bash
terraform plan -var "ses_sender_email=YOUR_VERIFIED_SENDER@example.com" \
               -var "ses_recipient_email=YOUR_VERIFIED_RECIPIENT@example.com"
```

4. Apply the infrastructure (this creates S3, Lambda, DynamoDB, SES identities):

```bash
terraform apply -auto-approve \
  -var "ses_sender_email=YOUR_VERIFIED_SENDER@example.com" \
  -var "ses_recipient_email=YOUR_VERIFIED_RECIPIENT@example.com"
```

5. After `apply` completes, Terraform prints outputs including the S3 bucket name, DynamoDB table name, and Lambda function name. Copy them for the next steps.

6. **Verify SES identities**: if Terraform created SES identities, you must check the inbox of `ses_sender_email` and `ses_recipient_email` and click the verification links (SES sends a verification email).

> If you keep SES in sandbox for development, make sure the recipient is verified. To move out of sandbox, open an SES sending increase request in AWS Support.

---

## Testing the system

### 1) Upload a test receipt (S3)

Use the AWS CLI to upload the sample receipt included in this repo: `sample-data/sample_receipt.jpg`.

```bash
aws s3 cp ../../sample-data/sample_receipt.jpg s3://<bucket_name>/receipts/sample_receipt.jpg
```

Replace `<bucket_name>` with the bucket printed by Terraform.

### 2) Observe Lambda logs

Tail CloudWatch logs to see Lambda execution and the Textract result summary (you will find the `receipt_id` printed in logs):

```bash
# Replace with the real Lambda function name from Terraform outputs
aws logs tail /aws/lambda/<lambda_function_name> --follow
```

### 3) Inspect DynamoDB

You can open the DynamoDB Console, select the table (`<project>-table`), and view the most recent items. To query via CLI (scan-first-5):

```bash
aws dynamodb scan --table-name <dynamodb_table_name> --limit 5
```

Alternatively, if you captured the `receipt_id` from logs, get a single item:

```bash
aws dynamodb get-item --table-name <dynamodb_table_name> --key '{"receipt_id": {"S": "<receipt_id>"}}'
```

### 4) Confirm email

SES will attempt to send a confirmation email to `ses_recipient_email`. If the email is not received, check CloudWatch logs and SES console for bounced/blocked messages (SES sandbox restrictions are a common cause).

### 5) Invoke Lambda directly (optional)

You can test Lambda with a manual payload (no S3 upload required) using the AWS CLI:

```bash
aws lambda invoke --function-name <lambda_function_name> \
  --payload '{"bucket":"<bucket_name>","key":"receipts/sample_receipt.jpg"}' out.json

cat out.json
```

---

## Operational / debugging tips

* **SES errors**: Check SES console -> `Email sending` -> `Sending statistics` and verify identities. When in sandbox, unverified recipients will be blocked.
* **Textract returns empty**: Ensure the image is legible and not rotated. Textract performs better on flat, high-contrast scans. Consider pre-processing (deskew / enhance) if receipts are poor quality.
* **Lambda timeouts**: Increase `timeout` and `memory_size` in Terraform (`aws_lambda_function.processor`). Textract calls can take a few seconds depending on content.
* **S3 access errors**: Confirm the Lambda's IAM role has `s3:GetObject` for the S3 bucket.
* **DynamoDB capacity / billing**: This project uses `PAY_PER_REQUEST` (on-demand). For very high volumes, evaluate provisioned capacity with autoscaling.

---

## Cost estimation & optimization tips

**Primary cost drivers**:

* Amazon **Textract** (per-page OCR) — typically the largest cost for high volume.
* S3 storage (small for receipts) — cheap.
* Lambda compute — usually negligible at low volume.
* DynamoDB on-demand writes — small at low volume.
* SES email sends — very low.

**Example (rough)**: 1,000 one-page receipts/month → Textract dominates and costs roughly `$10` (depends on pricing/region). See the `README.md` in repo root for more detail.

**Optimization ideas**:

* Pre-filter clear scans, reject low-resolution images client-side.
* Delete images after confirmation or move to Glacier to reduce S3 storage costs.
* Batch processing: if you can queue X receipts in a batch, consider reducing per-page overhead.

---

## Security considerations

* **S3**: Public access is blocked in Terraform; server-side encryption (SSE-S3) is enabled. For stricter control use an AWS KMS CMK.
* **IAM**: The Lambda role grants only the permissions necessary (Textract AnalyzeExpense, S3 GetObject, DynamoDB PutItem, SES SendEmail). Review and scope down further if needed.
* **SES**: Validate and control sender addresses and confirm recipients when out of sandbox.
* **Data retention**: Receipts contain PII and transaction data. Define a retention policy and delete or redact if necessary.

---

## Extending the project

Here are common next-step extensions you might implement:

* Add an **API** to query receipts (API Gateway + AWS Lambda + Cognito for auth).
* Add **presigned upload** URLs so the client uploads directly to S3 with limited-time credentials.
* Stream DynamoDB changes into **Kinesis** or **EventBridge** for analytics or ETL.
* Export parsed data into a data lake (S3 + Glue + Athena) for reporting.
* Add **OCR confidence** thresholds and manual review workflow (Step Functions + Dynamo + SNS).
* Add a simple UI (React) for uploads and viewing parsed receipts.

---

## FAQ / Troubleshooting

**Q: I deployed but I never receive email from SES — what next?**

A: Check the SES console to confirm the sender and recipient are verified (if you are in sandbox). Check CloudWatch logs for SES send errors. If you need to send to arbitrary recipients, request to move SES out of sandbox.

**Q: Textract returned no line items**

A: Try using a clearer image, higher DPI, or cropping to the receipt area. Validate that Textract supports the language and layout you’re sending.

**Q: How can I test without incurring Textract costs?**

A: You can unit test the Lambda parsing logic with saved examples of Textract `AnalyzeExpense` responses. The repository focuses on a working end-to-end pipeline, but you can stub Textract calls during local dev.

---

## Contributing

Contributions are welcome. Please open issues or PRs for bug fixes, improvements to Terraform, or feature additions. Suggested small improvements:

* Add unit tests for Lambda parsing logic
* Add a GitHub Actions pipeline for `terraform fmt` + `terraform validate` (a sample is included)
* Add CloudWatch dashboards and alarms for monitoring

---

## License

This project is released under the **MIT License**. See `LICENSE` for details.

---

Thank you for checking out the Serverless Receipt Processing System — fork it, adapt it, and ship faster!
