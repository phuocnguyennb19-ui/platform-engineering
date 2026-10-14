variable "config_root" {
  description = "Directory holding environments/ (infra-base/terraform/)."
  type        = string
}

variable "applications_root" {
  description = "Directory holding <app>/terraform/{app,<environment>}.yaml. Null means <config_root>/applications (test fixtures)."
  type        = string
  default     = null
}

variable "environment" {
  description = "Directory name under infra-base/terraform/environments/."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,31}$", var.environment))
    error_message = "environment must be a lowercase directory name under infra-base/terraform/environments/."
  }
}

variable "application" {
  description = "Application directory name under applications/. Null loads every application for the registry layer."
  type        = string
  default     = null

  validation {
    condition     = var.application == null || can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.application))
    error_message = "application must be a lowercase directory name under applications/."
  }
}

variable "image_tag" {
  description = "IMAGE_TAG from the pipeline. Empty means not passed."
  type        = string
  default     = ""
  nullable    = false
}
