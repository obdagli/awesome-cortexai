# Quick Start Guide

This guide only uses helpers that are present in the current repo snapshot.

Run the commands below from the repository root. The committed helper lives at `vertexapis-research/aiplatform_runner.py`.

## 1. Setup

```bash
export VERTEX_API_KEY="sk-your-api-key-here"
```

## 2. List Available Models

```bash
python3 vertexapis-research/aiplatform_runner.py list-models
```

## 3. Your First Text Request

```bash
python3 vertexapis-research/aiplatform_runner.py text \
  --model gemini-3-pro-preview \
  --prompt "Kisa bir merhaba yaz"
```

## 4. Your First Image

```bash
python3 vertexapis-research/aiplatform_runner.py image \
  --model gemini-3.1-flash-image-preview \
  --prompt "a cat in space" \
  --aspect-ratio 1:1
```

## 5. Common Commands

```bash
# Gemini image generation
python3 vertexapis-research/aiplatform_runner.py image \
  --model gemini-3.1-flash-image-preview \
  --prompt "studio product shot" \
  --aspect-ratio 1:1

# Imagen predict endpoint
python3 vertexapis-research/aiplatform_runner.py predict-image \
  --model imagen-4.0-generate-001 \
  --prompt "studio product shot"

# STT
python3 vertexapis-research/aiplatform_runner.py stt \
  --model gemini-2.5-pro \
  --audio ./sample.mp3

# Virtual try-on
python3 vertexapis-research/aiplatform_runner.py try-on \
  --person ./person.png \
  --product ./product.png
```

## 6. Provider Notes

- `aiplatform.vertexapis.com` is the main repo-contained workflow here.
- `beta.vertexapis.com` remains the higher-volume image provider in the research notes.
- The older generator-based `gemini.vertexapis.com` workflow is not included as a committed helper in this repo snapshot.

## 7. Output

Default output directory:

```bash
~/awesome-cortexai/generated
```

## 8. Translate Reminder

For `translate.vertexapis.com`:

- `/language/translate/v2` works
- `/language/translate/v2/detect` works
- `/language/translate/v2/languages` works
- plain `/v2` paths return `404`
- `v3` and `v3beta1` work

## 9. Troubleshooting

```bash
echo "$VERTEX_API_KEY"
python3 vertexapis-research/aiplatform_runner.py --help
python3 vertexapis-research/aiplatform_runner.py list-models
```

## 10. More Info

- `CHEATSHEET.md`
- `AIPLATFORM_RUNNER_TEST_RESULTS.md`
- `VERTEXAPIS_FINDINGS_2026-02-28.md`
- `endpoints/translate-vertexapis-com.md`
