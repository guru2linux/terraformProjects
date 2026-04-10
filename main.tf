# GCS Bucket
resource "google_storage_bucket" "website" {
  name          = "gorillac-site-bucket"
  location      = "US"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  website {
    main_page_suffix = "index.html"
  }
}

# Upload the index.html file to the bucket
resource "google_storage_bucket_object" "index" {
  name         = "index.html"
  bucket       = google_storage_bucket.website.name
  source       = "${path.module}/website/index.html"
  content_type = "text/html"
}

# Upload the resume.html file to the bucket
resource "google_storage_bucket_object" "resume" {
  name         = "resume.html"
  bucket       = google_storage_bucket.website.name
  source       = "${path.module}/website/resume.html"
  content_type = "text/html"
}

# Make the bucket publicly readable
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.website.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Reserve a static external IP
resource "google_compute_global_address" "website" {
  name = "gorillac-site-ip"
}

# Backend bucket with CDN enabled
resource "google_compute_backend_bucket" "website" {
  name        = "gorillac-site-backend"
  bucket_name = google_storage_bucket.website.name
  enable_cdn  = true
}

# URL map
resource "google_compute_url_map" "website" {
  name            = "gorillac-site-url-map"
  default_service = google_compute_backend_bucket.website.self_link
}

# URL map for HTTP -> HTTPS redirect
resource "google_compute_url_map" "https_redirect" {
  name = "gorillac-site-https-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# Managed SSL certificate
resource "google_compute_managed_ssl_certificate" "website" {
  name = "gorillac-site-ssl"

  managed {
    domains = ["gorillac.net", "www.gorillac.net"]
  }
}

# HTTPS proxy
resource "google_compute_target_https_proxy" "website" {
  name             = "gorillac-site-https-proxy"
  url_map          = google_compute_url_map.website.self_link
  ssl_certificates = [google_compute_managed_ssl_certificate.website.self_link]
}

# HTTP proxy (redirects to HTTPS)
resource "google_compute_target_http_proxy" "website" {
  name    = "gorillac-site-http-proxy"
  url_map = google_compute_url_map.https_redirect.self_link
}

# Forwarding rule for HTTPS (port 443)
resource "google_compute_global_forwarding_rule" "https" {
  name       = "gorillac-site-https-rule"
  target     = google_compute_target_https_proxy.website.self_link
  port_range = "443"
  ip_address = google_compute_global_address.website.address
}

# Forwarding rule for HTTP (port 80) - redirects to HTTPS
resource "google_compute_global_forwarding_rule" "http" {
  name       = "gorillac-site-http-rule"
  target     = google_compute_target_http_proxy.website.self_link
  port_range = "80"
  ip_address = google_compute_global_address.website.address
}

# Output the static IP to configure DNS
output "website_ip" {
  value = google_compute_global_address.website.address
}

output "website_url" {
  value = "https://gorillac.net"
}
