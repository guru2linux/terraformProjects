# ──────────────────────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────────────────────

variable "sendgrid_api_key" {
  description = "SendGrid API key for sending contact form emails"
  type        = string
  sensitive   = true
  default     = ""
}

variable "billing_account_id" {
  description = "GCP billing account ID (format: XXXXXX-XXXXXX-XXXXXX)"
  type        = string
}

# ──────────────────────────────────────────────────────────────
# Required APIs
# ──────────────────────────────────────────────────────────────

resource "google_project_service" "cloudfunctions" {
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "vpcaccess" {
  service            = "vpcaccess.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "billingbudgets" {
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

# ──────────────────────────────────────────────────────────────
# VPC — private networking for Cloud SQL
# ──────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name                    = "gorillac-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpc" {
  name          = "gorillac-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "us-central1"
  network       = google_compute_network.vpc.id
}

resource "google_compute_subnetwork" "connector" {
  name          = "gorillac-connector-subnet"
  ip_cidr_range = "10.0.1.0/28"
  region        = "us-central1"
  network       = google_compute_network.vpc.id
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "gorillac-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  depends_on              = [google_project_service.servicenetworking]
}

# VPC Access Connector — lets Cloud Functions reach private IPs
resource "google_vpc_access_connector" "connector" {
  name           = "gorillac-vpc-connector"
  region         = "us-central1"
  min_instances  = 2
  max_instances  = 3
  subnet {
    name = google_compute_subnetwork.connector.name
  }
  depends_on = [google_project_service.vpcaccess]
}

# ──────────────────────────────────────────────────────────────
# Cloud SQL — MySQL 8.0
# ──────────────────────────────────────────────────────────────

resource "random_password" "db_password" {
  length  = 24
  special = false
}

resource "google_sql_database_instance" "contacts" {
  name             = "gorillac-contacts"
  database_version = "MYSQL_8_0"
  region           = "us-central1"

  settings {
    tier = "db-f1-micro"

    backup_configuration {
      enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }

  deletion_protection = true

  depends_on = [
    google_project_service.sqladmin,
    google_service_networking_connection.private_vpc,
  ]
}

resource "google_sql_database" "contacts" {
  name     = "contacts"
  instance = google_sql_database_instance.contacts.name
}

resource "google_sql_user" "contact_fn" {
  name     = "contact-fn"
  instance = google_sql_database_instance.contacts.name
  password = random_password.db_password.result
}

# ──────────────────────────────────────────────────────────────
# Secret Manager — SendGrid key + DB password
# ──────────────────────────────────────────────────────────────

resource "google_secret_manager_secret" "sendgrid_key" {
  secret_id = "sendgrid-api-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "sendgrid_key" {
  secret      = google_secret_manager_secret.sendgrid_key.id
  secret_data = var.sendgrid_api_key != "" ? var.sendgrid_api_key : "not-configured"
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "contact-db-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db_password.result
}

# ──────────────────────────────────────────────────────────────
# Cloud Build service account permissions
# (org policy removed the defaults — restore what's needed)
# ──────────────────────────────────────────────────────────────

data "google_project" "project" {}

locals {
  cloudbuild_sa = "${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "cloudbuild_logging" {
  project = "gorillac-site"
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.cloudbuild_sa}"
}

resource "google_project_iam_member" "cloudbuild_storage" {
  project = "gorillac-site"
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${local.cloudbuild_sa}"
}

resource "google_project_iam_member" "cloudbuild_artifactregistry" {
  project = "gorillac-site"
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${local.cloudbuild_sa}"
}

resource "google_project_iam_member" "cloudbuild_run" {
  project = "gorillac-site"
  role    = "roles/run.developer"
  member  = "serviceAccount:${local.cloudbuild_sa}"
}

resource "google_project_iam_member" "cloudbuild_sa_user" {
  project = "gorillac-site"
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${local.cloudbuild_sa}"
}

# Cloud Build service agent — separate from the SA above
resource "google_project_iam_member" "cloudbuild_agent_storage" {
  project = "gorillac-site"
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

# GCF admin robot — creates and coordinates the build
resource "google_project_iam_member" "gcf_robot_storage" {
  project = "gorillac-site"
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcf-admin-robot.iam.gserviceaccount.com"
}

# Explicit bucket-level grant on the GCF staging bucket
# (legacy ACLs on that bucket can override project-level IAM)
resource "google_storage_bucket_iam_member" "cloudbuild_gcf_staging" {
  bucket = "gcf-v2-sources-${data.google_project.project.number}-us-central1"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.cloudbuild_sa}"
}

# ──────────────────────────────────────────────────────────────
# Dedicated build service account for Cloud Functions v2
# (org policy blocks the default Cloud Build SA at CreateBuild)
# ──────────────────────────────────────────────────────────────

resource "google_service_account" "build_sa" {
  account_id   = "gorillac-build-sa"
  display_name = "Cloud Functions Build"
}

resource "google_project_iam_member" "build_sa_logging" {
  project = "gorillac-site"
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build_sa.email}"
}

resource "google_project_iam_member" "build_sa_storage" {
  project = "gorillac-site"
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.build_sa.email}"
}

resource "google_project_iam_member" "build_sa_artifactregistry" {
  project = "gorillac-site"
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.build_sa.email}"
}

resource "google_project_iam_member" "build_sa_run" {
  project = "gorillac-site"
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.build_sa.email}"
}

resource "google_project_iam_member" "build_sa_builder" {
  project = "gorillac-site"
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${google_service_account.build_sa.email}"
}

# Allow the GCF admin robot to impersonate the build SA
resource "google_service_account_iam_member" "gcf_robot_act_as_build_sa" {
  service_account_id = google_service_account.build_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcf-admin-robot.iam.gserviceaccount.com"
}

# ──────────────────────────────────────────────────────────────
# Service account for the Cloud Function
# ──────────────────────────────────────────────────────────────

resource "google_service_account" "contact_fn" {
  account_id   = "gorillac-contact-fn"
  display_name = "Contact Form Function"
}

# Read secrets
resource "google_secret_manager_secret_iam_member" "fn_sendgrid" {
  secret_id = google_secret_manager_secret.sendgrid_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.contact_fn.email}"
}

resource "google_secret_manager_secret_iam_member" "fn_db_pass" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.contact_fn.email}"
}

# Connect to Cloud SQL
resource "google_project_iam_member" "fn_cloudsql" {
  project = "gorillac-site"
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.contact_fn.email}"
}

# ──────────────────────────────────────────────────────────────
# Cloud Function v2
# ──────────────────────────────────────────────────────────────

data "archive_file" "contact_fn_zip" {
  type        = "zip"
  source_dir  = "${path.module}/functions/contact"
  output_path = "${path.module}/functions/contact.zip"
}

resource "google_storage_bucket_object" "contact_fn_source" {
  name   = "functions/contact-${data.archive_file.contact_fn_zip.output_md5}.zip"
  bucket = google_storage_bucket.website.name
  source = data.archive_file.contact_fn_zip.output_path
}

resource "google_cloudfunctions2_function" "contact" {
  name     = "gorillac-contact"
  location = "us-central1"

  build_config {
    runtime         = "python311"
    entry_point     = "contact_handler"
    service_account = "projects/gorillac-site/serviceAccounts/${google_service_account.build_sa.email}"
    source {
      storage_source {
        bucket = google_storage_bucket.website.name
        object = google_storage_bucket_object.contact_fn_source.name
      }
    }
  }

  service_config {
    max_instance_count             = 5
    available_memory               = "256Mi"
    timeout_seconds                = 30
    service_account_email          = google_service_account.contact_fn.email
    vpc_connector                  = google_vpc_access_connector.connector.id
    vpc_connector_egress_settings  = "PRIVATE_RANGES_ONLY"

    environment_variables = {
      CONTACT_EMAIL                = "leedulcio@gorillac.net"
      DB_INSTANCE_CONNECTION_NAME  = google_sql_database_instance.contacts.connection_name
      DB_USER                      = google_sql_user.contact_fn.name
      DB_NAME                      = google_sql_database.contacts.name
    }

    secret_environment_variables {
      key        = "SENDGRID_API_KEY"
      project_id = "gorillac-site"
      secret     = google_secret_manager_secret.sendgrid_key.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "DB_PASS"
      project_id = "gorillac-site"
      secret     = google_secret_manager_secret.db_password.secret_id
      version    = "latest"
    }
  }

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.run,
    google_sql_database_instance.contacts,
    google_vpc_access_connector.connector,
    google_project_iam_member.cloudbuild_logging,
    google_project_iam_member.cloudbuild_storage,
    google_project_iam_member.cloudbuild_artifactregistry,
    google_project_iam_member.cloudbuild_run,
    google_project_iam_member.cloudbuild_sa_user,
    google_project_iam_member.cloudbuild_agent_storage,
    google_project_iam_member.gcf_robot_storage,
    google_storage_bucket_iam_member.cloudbuild_gcf_staging,
    google_project_iam_member.build_sa_logging,
    google_project_iam_member.build_sa_storage,
    google_project_iam_member.build_sa_artifactregistry,
    google_project_iam_member.build_sa_run,
    google_project_iam_member.build_sa_builder,
    google_service_account_iam_member.gcf_robot_act_as_build_sa,
  ]
}

# Allow unauthenticated invocation
resource "google_cloud_run_v2_service_iam_member" "contact_fn_public" {
  project  = google_cloudfunctions2_function.contact.project
  location = google_cloudfunctions2_function.contact.location
  name     = google_cloudfunctions2_function.contact.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ──────────────────────────────────────────────────────────────
# Load balancer wiring — serverless NEG → backend service
# ──────────────────────────────────────────────────────────────

resource "google_compute_region_network_endpoint_group" "api" {
  name                  = "gorillac-api-neg"
  network_endpoint_type = "SERVERLESS"
  region                = "us-central1"

  cloud_run {
    service = google_cloudfunctions2_function.contact.name
  }
}

# Cloud Armor — rate-limit the contact API (10 req/min per IP)
resource "google_compute_security_policy" "contact_api" {
  name        = "gorillac-contact-api-policy"
  description = "Rate-limit the contact form API endpoint"

  rule {
    action      = "throttle"
    priority    = 1000
    description = "Rate limit: 10 req/min per IP"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 10
        interval_sec = 60
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

resource "google_compute_backend_service" "api" {
  name            = "gorillac-api-backend"
  protocol        = "HTTPS"
  security_policy = google_compute_security_policy.contact_api.id

  backend {
    group = google_compute_region_network_endpoint_group.api.id
  }
}

# ──────────────────────────────────────────────────────────────
# Static files
# ──────────────────────────────────────────────────────────────

resource "google_storage_bucket_object" "contact_page" {
  name         = "contact.html"
  bucket       = google_storage_bucket.website.name
  source       = "${path.module}/website/contact.html"
  content_type = "text/html"
}

# ──────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────
# Billing budget — alert at 50%, 90%, and 100% of $25/month
# ──────────────────────────────────────────────────────────────

resource "google_billing_budget" "site" {
  billing_account = var.billing_account_id
  display_name    = "gorillac-site monthly budget"

  budget_filter {
    projects = ["projects/${data.google_project.project.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "25"
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  depends_on = [google_project_service.billingbudgets]
}

output "db_instance_connection_name" {
  value       = google_sql_database_instance.contacts.connection_name
  description = "Use this with Cloud SQL Auth Proxy to connect locally"
}
