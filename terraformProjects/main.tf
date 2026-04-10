terraform {
  required_version = "1.14.8"

  cloud {
    organization = "Gorillac-org"

    workspaces {
      name = "terraformProjects"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "gorillac-website"
  region  = "us-central1"
  zone    = "us-central1-b"
}

resource "google_compute_instance" "server" {
  name         = "gorillac-server"
  machine_type = "e2-micro"
  zone         = "us-central1-b"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20  # GB
    }
  }

  network_interface {
    network = "default"
    access_config {}  # assigns a public IP
  }

  metadata = {
    ssh-keys = "YOUR_USERNAME:${file("~/.ssh/id_rsa.pub")}"
  }

  tags = ["http-server", "https-server"]
}

output "public_ip" {
  value = google_compute_instance.server.network_interface[0].access_config[0].nat_ip
}

