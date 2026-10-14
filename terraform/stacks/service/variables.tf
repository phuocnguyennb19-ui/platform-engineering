variable "application" {
  description = "Application directory under applications/, config in applications/<app>/terraform/ (APP_NAME)."
  type        = string
}

variable "environment" {
  description = "Directory name under infra-base/terraform/environments/ (ENVIRONMENT)."
  type        = string
}

variable "image_tag" {
  description = "IMAGE_TAG from the pipeline. Overrides YAML where release.image_tag_source is pipeline; must equal <environment>.yaml image.tag where it is config."
  type        = string
  default     = ""
  nullable    = false
}
