#!/usr/bin/env bash
set -euo pipefail

# Fetch quiz file from GCS and start a simple HTTP server serving QuizCafe
# Variables expected: BUCKET_NAME metadata or instance env

BUCKET_NAME="${BUCKET_NAME:-"$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name -H "Metadata-Flavor: Google" || echo "")"}"

mkdir -p /app
if [[ -n "$BUCKET_NAME" ]]; then
  command -v gsutil >/dev/null 2>&1 && gsutil cp "gs://$BUCKET_NAME/quiz.json" /app/quiz.json || echo "gsutil not available yet"
fi

cat > /app/index.html << 'HTML'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>QuizCafe</title></head>
<body>
<h1>QuizCafe</h1>
<p>Quiz file at /quiz.json</p>
</body>
</html>
HTML

# Serve files
cd /app
python3 -m http.server 80
