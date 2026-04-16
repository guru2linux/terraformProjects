# gorillac.net — Terraform Infrastructure

Terraform configuration that deploys the full GCP infrastructure for [gorillac.net](https://gorillac.net) — a personal portfolio and resume website.

## What this provisions

### Static website hosting
- **GCS bucket** (`gorillac-site-bucket`) serving HTML pages: `index.html`, `resume.html`, `portfolio.html`, `contact.html`, and `job-copilot-demo.html`
- **Cloud CDN** via a backend bucket for fast global delivery
- **Global HTTPS load balancer** with a Google-managed SSL certificate for `gorillac.net` and `www.gorillac.net`
- **HTTP → HTTPS redirect** (port 80 permanently redirects to 443)
- **Static external IP** for DNS configuration

### Contact form backend
- **Cloud Function v2** (Python 3.11, `gorillac-contact`) handles `POST /api/contact` requests
- Sends email notifications via **SendGrid**
- Persists submissions to **Cloud SQL MySQL 8.0** over a private VPC connection
- **Cloud Armor** rate-limiting policy: 10 requests/minute per IP (returns 429 on excess)
- Routed through the load balancer via a **serverless NEG**

### Networking & security
- Custom **VPC** with private subnets for Cloud SQL (no public IP on the database)
- **VPC Access Connector** so the Cloud Function can reach private IP ranges
- **Secret Manager** stores the SendGrid API key and auto-generated database password
- Dedicated service accounts with least-privilege IAM for the function runtime and Cloud Build

### Observability & cost
- **Billing budget** alerts at 50%, 90%, and 100% of a $25/month threshold

## Project structure

```
.
├── main.tf          # GCS bucket, CDN, load balancer, SSL, static file uploads
├── contact.tf       # Cloud Function, Cloud SQL, VPC, Secret Manager, Cloud Armor
├── provider.tf      # Google provider + required providers
├── website/         # Static HTML/CSS/JS files uploaded to GCS
│   ├── index.html
│   ├── resume.html
│   ├── portfolio.html
│   ├── contact.html
│   ├── job-copilot-demo.html
│   ├── projects.json
│   └── certs/       # CompTIA certification badge images
└── functions/
    └── contact/     # Cloud Function source (Python)
        ├── main.py
        └── requirements.txt
```

## Notes

- The GCS bucket is intentionally public — it serves static website content. An SCC finding (`PUBLIC_BUCKET_ACL`) is muted via a static mute config since the exposure is deliberate.
