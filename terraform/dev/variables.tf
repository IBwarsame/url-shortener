variable "image_tag" {
  description = "Image tag to run for all three services (a git SHA in CI)"
  type        = string
  default     = "v1"
}
