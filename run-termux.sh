#!/bin/bash
# Run this from inside the extracted peyamapp folder (the one containing server.js).
set -e
echo "================================"
echo "  PeyamApp - Setup"
echo "================================"

# Make sure Node.js is available (Termux)
if ! command -v node >/dev/null 2>&1; then
  echo "Installing Node.js via pkg..."
  pkg install -y nodejs
fi

echo "Installing dependencies (express, socket.io, multer, nodemailer, web-push, cors)..."
npm install

if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  echo "Generating a self-signed HTTPS certificate (needed for mic + push notifications on your phone)..."
  if ! command -v openssl >/dev/null 2>&1; then
    pkg install -y openssl-tool 2>/dev/null || pkg install -y openssl 2>/dev/null
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=peyamapp" 2>/dev/null
  else
    echo "⚠️  openssl not found — running over plain HTTP. Mic/notifications will only work on http://localhost on this same phone."
  fi
fi

echo ""
echo "To send REAL verification emails to @gmail.com addresses, export a Gmail App Password first:"
echo "  1) Create one at https://myaccount.google.com/apppasswords"
echo "  2) export GMAIL_USER=\"you@gmail.com\""
echo "     export GMAIL_APP_PASSWORD=\"xxxx xxxx xxxx xxxx\""
echo ""
echo "Starting PeyamApp..."
node server.js
