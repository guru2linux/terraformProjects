import functions_framework
import json
import os
import re

import sqlalchemy
from google.cloud.sql.connector import Connector, IPTypes

# Module-level engine — reused across warm invocations
_engine = None


def _build_engine():
    connector = Connector()

    def getconn():
        return connector.connect(
            os.environ["DB_INSTANCE_CONNECTION_NAME"],
            "pymysql",
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASS"],
            db=os.environ["DB_NAME"],
            ip_type=IPTypes.PRIVATE,
        )

    engine = sqlalchemy.create_engine("mysql+pymysql://", creator=getconn)

    # Ensure the contacts table exists on first boot
    with engine.connect() as conn:
        conn.execute(sqlalchemy.text("""
            CREATE TABLE IF NOT EXISTS contacts (
                id         INT AUTO_INCREMENT PRIMARY KEY,
                name       VARCHAR(255)  NOT NULL,
                email      VARCHAR(255)  NOT NULL,
                message    TEXT          NOT NULL,
                created_at TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
            )
        """))
        conn.commit()

    return engine


def get_engine():
    global _engine
    if _engine is None:
        _engine = _build_engine()
    return _engine


def send_email(name, email, message):
    import sendgrid
    from sendgrid.helpers.mail import Mail

    api_key = os.environ.get("SENDGRID_API_KEY", "")
    if not api_key:
        print("SENDGRID_API_KEY not set — skipping email")
        return

    to_email = os.environ.get("CONTACT_EMAIL", "leedulcio@gorillac.net")
    body = f"Name:    {name}\nEmail:   {email}\n\nMessage:\n{message}"

    sg = sendgrid.SendGridAPIClient(api_key)
    mail = Mail(
        from_email="noreply@gorillac.net",
        to_emails=to_email,
        subject=f"gorillac.net — Contact from {name}",
        plain_text_content=body,
    )
    sg.send(mail)


def cors_headers():
    return {
        "Access-Control-Allow-Origin": "https://gorillac.net",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
        "Content-Type": "application/json",
    }


@functions_framework.http
def contact_handler(request):
    headers = cors_headers()

    if request.method == "OPTIONS":
        return ("", 204, headers)

    engine = get_engine()

    # GET — return current contact count
    if request.method == "GET":
        with engine.connect() as conn:
            count = conn.execute(sqlalchemy.text("SELECT COUNT(*) FROM contacts")).scalar() or 0
        return (json.dumps({"count": int(count)}), 200, headers)

    # POST — save contact and send email
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        name    = str(data.get("name", "")).strip()
        email   = str(data.get("email", "")).strip()
        message = str(data.get("message", "")).strip()

        if not (name and email and message):
            return (json.dumps({"error": "All fields are required."}), 400, headers)

        if len(name) > 255:
            return (json.dumps({"error": "Name is too long."}), 400, headers)
        if len(email) > 255:
            return (json.dumps({"error": "Invalid email address."}), 400, headers)
        if len(message) > 5000:
            return (json.dumps({"error": "Message too long."}), 400, headers)

        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
            return (json.dumps({"error": "Invalid email address."}), 400, headers)

        with engine.connect() as conn:
            conn.execute(
                sqlalchemy.text(
                    "INSERT INTO contacts (name, email, message) VALUES (:name, :email, :message)"
                ),
                {"name": name, "email": email, "message": message},
            )
            conn.commit()
            count = conn.execute(sqlalchemy.text("SELECT COUNT(*) FROM contacts")).scalar() or 1

        try:
            send_email(name, email, message)
        except Exception as exc:
            print(f"Email error: {exc}")
            # Don't fail the request — contact is already saved

        return (json.dumps({"success": True, "count": int(count)}), 200, headers)

    return (json.dumps({"error": "Method not allowed"}), 405, headers)
