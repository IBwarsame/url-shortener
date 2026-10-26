variable "region" {
  type    = string
  default = "us-east-1"

}
variable "github_repo" {
  type    = string
  default = "IBwarsame/url-shortener"
}

variable "services" {
  type    = set(string)
  default = ["worker", "dashboard", "api"]
}