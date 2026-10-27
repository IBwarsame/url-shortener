variable "image_tag" {
  description = "Image tag to run for all three services (a git SHA in CI)"
  type        = string
  default     = "v1"
}
variable "production" {
  description = "false = cheap dev settings, true = production settings"
  type        = bool
  default     = false
}