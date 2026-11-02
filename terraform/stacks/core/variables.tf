variable "environment" {
  description = "Terraform environment name (dev | staging | production). Its values are environments/<dir>/terraform/, found by the environment: field (production lives in prod/)."
  type        = string
}
