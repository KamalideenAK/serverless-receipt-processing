import json
import os
import boto3
import uuid
import datetime
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

textract = boto3.client("textract")
dynamodb = boto3.resource("dynamodb")
ses = boto3.client("ses")

TABLE_NAME = os.environ["DDB_TABLE_NAME"]
SES_SENDER = os.environ["SES_SENDER"]
SES_RECIPIENT = os.environ["SES_RECIPIENT"]

table = dynamodb.Table(TABLE_NAME)

def _coalesce(value, default=""):
    return value if value is not None else default

def _parse_summary_fields(summary_fields):
    """Convert Textract summary fields list into a dict by Type/Label."""
    out = {}
    for field in summary_fields or []:
        ftype = None
        if "Type" in field and field["Type"].get("Text"):
            ftype = field["Type"]["Text"]
        elif "LabelDetection" in field and field["LabelDetection"].get("Text"):
            ftype = field["LabelDetection"]["Text"]
        val = field.get("ValueDetection", {}).get("Text")
        if ftype:
            out[ftype] = val
    return out

def _parse_line_items(groups):
    """Extract a normalized list of line items from Textract AnalyzeExpense response."""
    items = []
    for g in groups or []:
        for li in g.get("LineItems", []):
            item = {}
            for field in li.get("LineItemExpenseFields", []):
                t = field.get("Type", {}).get("Text") or field.get("LabelDetection", {}).get("Text")
                v = field.get("ValueDetection", {}).get("Text")
                if t:
                    item[t] = v
            # Normalize a few probable keys
            normalized = {
                "description": item.get("ITEM", item.get("DESCRIPTION", "")),
                "quantity": item.get("QUANTITY", ""),
                "unit_price": item.get("PRICE", item.get("UNIT_PRICE", "")),
                "total": item.get("TOTAL", item.get("LINE_TOTAL", "")),
                "_raw": item
            }
            items.append(normalized)
    return items

def handler(event, context):
    logger.info("Received event: %s", json.dumps(event))
    # Support both S3 Put event and manual test invocation
    if "Records" in event and event["Records"] and event["Records"][0].get("s3"):
        rec = event["Records"][0]
        bucket = rec["s3"]["bucket"]["name"]
        key = rec["s3"]["object"]["key"]
    else:
        bucket = event.get("bucket")
        key = event.get("key")
        if not bucket or not key:
            raise ValueError("Provide {bucket, key} when invoking manually.")

    # Call Textract AnalyzeExpense (best for receipts/invoices)
    try:
        tx = textract.analyze_expense(
            Document={"S3Object": {"Bucket": bucket, "Name": key}}
        )
    except ClientError as e:
        logger.exception("Textract analyze_expense failed")
        raise

    expense_docs = tx.get("ExpenseDocuments", [])
    if not expense_docs:
        logger.warning("No ExpenseDocuments returned by Textract")
        summary = {}
        items = []
    else:
        doc = expense_docs[0]
        summary = _parse_summary_fields(doc.get("SummaryFields", []))
        items = _parse_line_items(doc.get("LineItemGroups", []))

    receipt_id = str(uuid.uuid4())
    now_iso = datetime.datetime.utcnow().isoformat() + "Z"

    record = {
        "receipt_id": receipt_id,
        "s3_bucket": bucket,
        "s3_key": key,
        "inserted_at": now_iso,
        "summary": summary,
        "line_items": items,
        # Keep a tiny subset of raw metadata to help troubleshooting
        "textract_meta": {
            "api": "AnalyzeExpense",
            "doc_count": len(expense_docs),
        }
    }

    # Store to DynamoDB
    table.put_item(Item=record)

    # Compose email body
    vendor = _coalesce(summary.get("VENDOR_NAME") or summary.get("RECEIVER_NAME") or summary.get("SUPPLIER_NAME"), "Unknown vendor")
    date = _coalesce(summary.get("INVOICE_RECEIPT_DATE") or summary.get("INVOICE_DATE") or summary.get("RECEIPT_DATE"), "Unknown date")
    total = _coalesce(summary.get("TOTAL") or summary.get("AMOUNT_DUE") or summary.get("INVOICE_TOTAL"), "Unknown total")

    lines_preview = "\n".join([
        f"- {i.get('description','?')}  qty={i.get('quantity','?')}  price={i.get('unit_price','?')}  total={i.get('total','?')}"
        for i in items[:10]
    ]) or "(no line items detected)"

    text_body = f"""
Your receipt has been processed.

Vendor: {vendor}
Date:   {date}
Total:  {total}

Top line items:
{lines_preview}

Metadata:
- Receipt ID: {receipt_id}
- S3: s3://{bucket}/{key}
- Inserted at: {now_iso}
"""

    html_items = "".join([
        f"<tr><td>{i.get('description','')}</td><td>{i.get('quantity','')}</td><td>{i.get('unit_price','')}</td><td>{i.get('total','')}</td></tr>"
        for i in items[:50]
    ]) or "<tr><td colspan='4'>(no line items detected)</td></tr>"

    html_body = f"""<html><body>
<h2>Receipt processed</h2>
<p><strong>Vendor</strong>: {vendor}<br/>
<strong>Date</strong>: {date}<br/>
<strong>Total</strong>: {total}</p>
<table border="1" cellspacing="0" cellpadding="6">
<thead><tr><th>Description</th><th>Qty</th><th>Unit Price</th><th>Line Total</th></tr></thead>
<tbody>{html_items}</tbody>
</table>
<p>Receipt ID: {receipt_id}<br/>
S3: s3://{bucket}/{key}<br/>
Inserted at: {now_iso}</p>
</body></html>"""

    # Send via SES
    try:
        ses.send_email(
            Source=SES_SENDER,
            Destination={"ToAddresses": [SES_RECIPIENT]},
            Message={
                "Subject": {"Data": f"Receipt processed: {vendor} on {date} (Total {total})"},
                "Body": {
                    "Text": {"Data": text_body},
                    "Html": {"Data": html_body},
                },
            },
        )
        logger.info("SES email sent to %s", SES_RECIPIENT)
    except ClientError:
        logger.exception("Failed to send SES email. Is the identity verified / out of sandbox?")

    return {"status": "ok", "receipt_id": receipt_id, "summary": summary, "line_items_count": len(items)}
