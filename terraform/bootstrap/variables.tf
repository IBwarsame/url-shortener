variable "region" {
  type    = string
  default = "us-east-1"

}
# GitHub's immutable subject: the token names the repo by numeric IDs too, so a
# deleted-and-recreated repo with the same name cannot reuse this trust.
# Find yours with: gh api repos/OWNER/REPO/actions/oidc/customization/sub
variable "github_subject" {
  type    = string
  default = "repo:IBwarsame@165455194/url-shortener@1433463931"
}

variable "services" {
  type    = set(string)
  default = ["worker", "dashboard", "api"]
}