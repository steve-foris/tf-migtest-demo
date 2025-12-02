#!/usr/bin/env bash
set -euo pipefail

# Fetch quiz file from GCS (if available) and start a tiny Python HTTP server
# Exposes:
#   GET /            -> "Hello from <hostname> (color: <blue|green>)"
#   GET /quiz.json   -> quiz file if present

BUCKET_NAME="${BUCKET_NAME:-"$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name -H "Metadata-Flavor: Google" || echo "")"}"
COLOR="${COLOR:-"$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/instance-template -H "Metadata-Flavor: Google" || echo "unknown")"}"

mkdir -p /app

if command -v gsutil >/dev/null 2>&1 && [[ -n "$BUCKET_NAME" ]]; then
  gsutil cp "gs://$BUCKET_NAME/quiz.json" /app/quiz.json || true
fi

cat > /app/server.py << 'PY'
import http.server, socketserver, os, json, socket

class Handler(http.server.SimpleHTTPRequestHandler):
  def do_GET(self):
    if self.path == '/':
      hostname = socket.gethostname()
      color = os.environ.get('COLOR', 'unknown')
      msg = f"Hello from {hostname} (color: {color})\n"
      self.send_response(200)
      self.send_header('Content-Type', 'text/plain')
      self.end_headers()
      self.wfile.write(msg.encode('utf-8'))
    elif self.path == '/quiz.json':
      path = '/app/quiz.json'
      if os.path.exists(path):
        with open(path, 'rb') as f:
          data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(data)
      else:
        self.send_response(404)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'error': 'quiz.json not found'}).encode('utf-8'))
    else:
      self.send_response(404)
      self.end_headers()

if __name__ == '__main__':
  PORT = 80
  with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.serve_forever()
PY

export COLOR="$COLOR"
python3 /app/server.py
