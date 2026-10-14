variable "base" {
  description = "Lower-precedence document, e.g. app.yaml."
  type        = any
  default     = {}
  nullable    = false
}

variable "override" {
  description = "Higher-precedence document, e.g. <environment>.yaml."
  type        = any
  default     = {}
  nullable    = false
}
