#!/usr/bin/env bash
set -euo pipefail

# Prefer explicit color from custom metadata; fallback to unknown (will infer from hostname later)
COLOR="${COLOR:-"$(curl -fsS http://metadata.google.internal/computeMetadata/v1/instance/attributes/color -H "Metadata-Flavor: Google" || echo "unknown")"}"
# Prefer explicit app-version metadata; fallback to instance-template self-link, else unknown
APP_VERSION="${APP_VERSION:-"$(curl -fsS http://metadata.google.internal/computeMetadata/v1/instance/attributes/app-version -H "Metadata-Flavor: Google" || curl -fsS http://metadata.google.internal/computeMetadata/v1/instance/attributes/instance-template -H "Metadata-Flavor: Google" || echo "unknown")"}"

mkdir -p /app

# Ensure python3 is available
if ! command -v python3 >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y python3 >/dev/null 2>&1 || true
fi

cat > /app/server.py << 'PY'
import http.server, socketserver, os, json, socket

class Handler(http.server.SimpleHTTPRequestHandler):
  def do_GET(self):
    if self.path == '/':
      hostname = socket.gethostname()
      color = os.environ.get('COLOR', 'unknown')
      if color == 'unknown':
        hn = hostname.lower()
        if 'blue' in hn:
          color = 'blue'
        elif 'green' in hn:
          color = 'green'
      version = os.environ.get('APP_VERSION', 'unknown')
      msg = f"Hello from {hostname} (color: {color}, version: {version})\n"
      self.send_response(200)
      self.send_header('Content-Type', 'text/plain')
      self.end_headers()
      self.wfile.write(msg.encode('utf-8'))
    else:
      self.send_response(404)
      self.end_headers()

if __name__ == '__main__':
  PORT = 80
  with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.serve_forever()
PY

export COLOR="$COLOR"
export APP_VERSION="$APP_VERSION"
python3 /app/server.py
