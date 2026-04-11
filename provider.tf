terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    archive = {
      source = "hashicorp/archive"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

# GCP Provider
provider "google" {
  project = "gorillac-site"
  region  = "us-central1"
}
