#!/usr/bin/env python3
"""
Antigravity Live STT Adapter for Conveyor OS.
Transcribes audio input using the Antigravity / Gemini Live multimodal audio API.
"""

import sys
import os
import json
import base64
import urllib.request
import urllib.error

def load_env():
    env_paths = [
        os.path.expanduser("~/.config/conveyor/antigravity.env"),
        "/etc/conveyor/antigravity.env",
    ]
    for p in env_paths:
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

def transcribe_audio(audio_path):
    load_env()
    api_key = os.environ.get("ANTIGRAVITY_API_KEY") or os.environ.get("GEMINI_API_KEY")

    if not os.path.isfile(audio_path) or os.path.getsize(audio_path) < 1000:
        return ""

    with open(audio_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode("utf-8")

    # If API key is present, use high-speed Gemini 2.0 Flash multimodal audio API
    if api_key:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key={api_key}"
        payload = {
            "contents": [
                {
                    "parts": [
                        {
                            "inlineData": {
                                "mimeType": "audio/wav",
                                "data": audio_b64
                            }
                        },
                        {
                            "text": "Transcribe the spoken audio with exact precision. Return ONLY the transcribed speech as plain text. Do not add quotes, commentary or formatting."
                        }
                    ]
                }
            ],
            "generationConfig": {
                "temperature": 0.0,
                "maxOutputTokens": 1000
            }
        }

        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST"
        )

        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                candidates = data.get("candidates", [])
                if candidates:
                    parts = candidates[0].get("content", {}).get("parts", [])
                    if parts:
                        return parts[0].get("text", "").strip()
        except Exception:
            pass

    # Fallback to local whisper-cli if available
    if os.path.isfile("/usr/local/bin/whisper-cli") and os.path.isfile("/var/lib/models/ggml-small.bin"):
        try:
            import subprocess
            res = subprocess.run(
                ["/usr/local/bin/whisper-cli", "-m", "/var/lib/models/ggml-small.bin", "-f", audio_path, "-nt"],
                capture_output=True,
                text=True,
                timeout=15
            )
            return res.stdout.strip()
        except Exception:
            pass

    return ""

if __name__ == "__main__":
    if len(sys.argv) > 1:
        text = transcribe_audio(sys.argv[1])
        if text:
            print(text)
