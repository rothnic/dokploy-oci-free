resource "random_password" "admin" {
  length           = 16
  special          = true
  override_special = "!@#$%^&*"
}
