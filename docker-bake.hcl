// Multi-arch build definitions for CI (docker buildx bake).
// Local development uses the Makefile + podman; this file is for buildx runners.

variable "REGISTRY" { default = "docker.io/morrismukiri" }
variable "PLATFORMS" { default = ["linux/amd64", "linux/arm64"] }

variable "RAPIDPRO_VERSION" { default = "v9.0.0" }
variable "RAPIDPRO_REPO" { default = "rapidpro/rapidpro" }
variable "NODE_MAJOR" { default = "20" }
# Match the app's DB schema (v9.0.0 stable), not the 9.3 dev line.
variable "MAILROOM_VERSION" { default = "9.0.1" }
variable "COURIER_VERSION" { default = "9.0.1" }
variable "INDEXER_VERSION" { default = "9.0.0" }
variable "ARCHIVER_VERSION" { default = "9.0.0" }

group "default" {
  targets = ["app", "mailroom", "courier", "rp-indexer", "rp-archiver"]
}

target "app" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = PLATFORMS
  args = {
    RAPIDPRO_VERSION = RAPIDPRO_VERSION
    RAPIDPRO_REPO    = RAPIDPRO_REPO
    NODE_MAJOR       = NODE_MAJOR
  }
  tags = ["${REGISTRY}/rapidpro:${RAPIDPRO_VERSION}", "${REGISTRY}/rapidpro:v9"]
}

target "_go" {
  context    = "go-services"
  dockerfile = "Dockerfile"
  platforms  = PLATFORMS
}

target "mailroom" {
  inherits = ["_go"]
  args = { BINARY = "mailroom", REPO = "nyaruka/mailroom", VERSION = MAILROOM_VERSION, PORT = "8090" }
  tags = ["${REGISTRY}/mailroom:v${MAILROOM_VERSION}", "${REGISTRY}/mailroom:v9"]
}
target "courier" {
  inherits = ["_go"]
  args = { BINARY = "courier", REPO = "nyaruka/courier", VERSION = COURIER_VERSION, PORT = "8080" }
  tags = ["${REGISTRY}/courier:v${COURIER_VERSION}", "${REGISTRY}/courier:v9"]
}
target "rp-indexer" {
  inherits = ["_go"]
  args = { BINARY = "rp-indexer", REPO = "nyaruka/rp-indexer", VERSION = INDEXER_VERSION, PORT = "8080" }
  tags = ["${REGISTRY}/rp-indexer:v${INDEXER_VERSION}", "${REGISTRY}/rp-indexer:v9"]
}
target "rp-archiver" {
  inherits = ["_go"]
  args = { BINARY = "rp-archiver", REPO = "nyaruka/rp-archiver", VERSION = ARCHIVER_VERSION, PORT = "8080" }
  tags = ["${REGISTRY}/rp-archiver:v${ARCHIVER_VERSION}", "${REGISTRY}/rp-archiver:v9"]
}
