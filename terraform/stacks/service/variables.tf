variable "application" {
  description = "Application directory under applications/, config in applications/<app>/terraform/ (APP_NAME)."
  type        = string
}

variable "environment" {
  description = "Terraform environment name (dev | staging | production). Its values are environments/<dir>/terraform/, found by the environment: field (production lives in prod/)."
  type        = string
}

variable "image_tag" {
  description = "IMAGE_TAG from the pipeline. Overrides YAML where release.image_tag_source is pipeline; must equal <environment>.yaml image.tag where it is config."
  type        = string
  default     = ""
  nullable    = false
}
