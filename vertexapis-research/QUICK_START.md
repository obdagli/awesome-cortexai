# Quick Start Guide

This guide only uses helpers that are present in the current repo snapshot.

## 1. Setup

```bash
export VERTEX_API_KEY="sk-your-api-key-here"
```

## 2. List Available Models

```bash
python3 aiplatform_runner.py list-models
```

## 3. Your First Text Request

```bash
python3 aiplatform_runner.py text \
  --model gemini-3-pro-preview \
  --prompt "Kisa bir merhaba yaz"
```

## 4. Your First Image

```bash
python3 aiplatform_runner.py image \
  --model gemini-3.1-flash-image-preview \
  --prompt "a cat in space" \
  --aspect-ratio 1:1
```

## 5. Common Commands

```bash
# Gemini image generation
python3 aiplatform_runner.py image \
  --model gemini-3.1-flash-image-preview \
  --prompt "studio product shot" \
  --aspect-ratio 1:1

# Imagen predict endpoint
python3 aiplatform_runner.py predict-image \
  --model imagen-4.0-generate-001 \
  --prompt "studio product shot"

# STT
python3 aiplatform_runner.py stt \
  --model gemini-2.5-pro \
  --audio ./sample.mp3

# Virtual try-on
python3 aiplatform_runner.py try-on \
  --person ./person.png \
  --product ./product.png
```

## 6. Output

Default output directory:

```bash
~/awesome-cortexai/generated
```

## 7. Translate Reminder

For `translate.vertexapis.com`:

- `/language/translate/v2` works
- `/language/translate/v2/languages` works
- plain `/v2` paths return `404`
- `v3` and `v3beta1` work

## 8. Troubleshooting

```bash
echo "$VERTEX_API_KEY"
python3 aiplatform_runner.py --help
python3 aiplatform_runner.py list-models
```

## 9. More Info

- `CHEATSHEET.md`
- `AIPLATFORM_RUNNER_TEST_RESULTS.md`
- `VERTEXAPIS_FINDINGS_2026-02-28.md`
- `endpoints/translate-vertexapis-com.md`
