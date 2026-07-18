variable "TAG" {
  default = "latest"
}

group "default" {
  targets = ["agent-sandbox"]
}

target "agent-sandbox" {
  context    = "."
  dockerfile = "Dockerfile"
  tags       = ["agent-sandbox:${TAG}"]
}
