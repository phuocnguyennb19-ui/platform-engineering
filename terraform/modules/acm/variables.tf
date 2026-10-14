variable "domain_name" {
  description = "Primary domain for the certificate, e.g. \"app.example.com\" or \"*.example.com\"."
  type        = string
}

variable "subject_alternative_names" {
  description = "Additional names on the same certificate. A wildcard does not cover the apex, so a certificate for *.example.com usually needs example.com listed here."
  type        = list(string)
  default     = []
}

variable "zone_id" {
  description = "Route53 hosted zone ID where the DNS validation records are written. Comes from the route53 module."
  type        = string
}

variable "create_route53_records" {
  description = "Write the validation CNAMEs into zone_id. Set false only when the zone lives in another account and the records are created there."
  type        = bool
  default     = true
}

variable "wait_for_validation" {
  description = "Block the apply until ACM reports the certificate ISSUED. Leave true: an ALB HTTPS listener referencing a PENDING_VALIDATION certificate fails the apply, and this turns a confusing listener error into a clear certificate one."
  type        = bool
  default     = true
}

variable "validation_timeout" {
  description = "How long to wait for validation, e.g. \"10m\". Null uses the provider default."
  type        = string
  default     = null
}

variable "key_algorithm" {
  description = "Certificate key algorithm: RSA_2048, EC_prime256v1 or EC_secp384r1."
  type        = string
  default     = "RSA_2048"

  validation {
    condition     = contains(["RSA_2048", "RSA_3072", "RSA_4096", "EC_prime256v1", "EC_secp384r1"], var.key_algorithm)
    error_message = "key_algorithm must be one of RSA_2048, RSA_3072, RSA_4096, EC_prime256v1, EC_secp384r1."
  }
}

variable "tags" {
  description = "Tags applied to the certificate."
  type        = map(string)
  default     = {}
}
