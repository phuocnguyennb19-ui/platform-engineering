# s3

One private, encrypted S3 bucket. Wraps `terraform-aws-s3-bucket` (v4.2.1).

Always on, not configurable: ACLs disabled (`BucketOwnerEnforced`), every public access block
setting, a bucket policy denying non-TLS and pre-1.2 TLS access, and encryption (SSE-S3, or
SSE-KMS with `kms_key_arn`).

## Usage

```hcl
module "artifacts" {
  source = "../../modules/s3"

  name = "platform-dev-artifacts"

  lifecycle_rules = [{
    id              = "expire-builds"
    prefix          = "builds/"
    expiration_days = 30
  }]

  tags = local.tags
}
```

Every input not listed below has a default — 9 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Bucket name. Globally unique; the caller decides it. |

## Outputs

| Name | Description |
|---|---|
| `s3_bucket_id` | Name (ID) of the bucket. |
| `s3_bucket_arn` | ARN of the bucket. |
| `s3_bucket_bucket_domain_name` | Bucket domain name (global). |
| `s3_bucket_regional_domain_name` | Bucket regional domain name (for CloudFront origins). |
| `s3_bucket_hosted_zone_id` | Route 53 hosted zone ID for the bucket (for alias records). |
| `s3_bucket_website_endpoint` | Website endpoint (null when website not configured). |
| `s3_bucket_website_domain` | Website domain (null when website not configured). |

## Tests

`tests/s3.tftest.hcl` — plan-only contract tests against a mocked provider (Terraform ≥ 1.7):
`terraform init -backend=false && terraform test`.
