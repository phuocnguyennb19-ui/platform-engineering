module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "5.2.0"

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  zone_id                   = var.zone_id

  validation_method   = "DNS"
  key_algorithm       = var.key_algorithm
  wait_for_validation = var.wait_for_validation

  create_route53_records  = var.create_route53_records
  validation_record_fqdns = []

  validation_timeout = var.validation_timeout

  tags = var.tags
}
