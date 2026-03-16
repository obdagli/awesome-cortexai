# VertexAPIs Research Cheat Sheet

This file only references helpers that are actually present in this repo snapshot.

## Setup

```bash
export VERTEX_API_KEY="sk-your-api-key-here"
```

`aiplatform_runner.py` reads `VERTEX_API_KEY` by default.

## Quick Commands

```bash
# List registered models
python3 aiplatform_runner.py list-models

# Text
python3 aiplatform_runner.py text \
  --model gemini-3-pro-preview \
  --prompt "Kisa bir merhaba yaz"

# Gemini image generation
python3 aiplatform_runner.py image \
  --model gemini-3.1-flash-image-preview \
  --prompt "Single red apple icon on white background" \
  --aspect-ratio 1:1

# Imagen predict endpoint
python3 aiplatform_runner.py predict-image \
  --model imagen-4.0-generate-001 \
  --prompt "Single red apple icon on white background"

# STT
python3 aiplatform_runner.py stt \
  --model gemini-2.5-pro \
  --audio ./sample.mp3

# Virtual try-on
python3 aiplatform_runner.py try-on \
  --person ./person.png \
  --product ./product.png
```

## Output Location

Default output directory:

```bash
~/awesome-cortexai/generated
```

Override it with:

```bash
python3 aiplatform_runner.py image ... --out-dir /tmp/vertex-out
```

## Translate Notes

Live and documented behavior to remember:

- `/language/translate/v2` works
- `/language/translate/v2/languages` works
- plain `/v2`, `/v2/detect`, `/v2/languages` return `404`
- `v3` and `v3beta1` translation paths work

## Troubleshooting

```bash
# Check key
echo "$VERTEX_API_KEY"

# Show runner help
python3 aiplatform_runner.py --help

# Show model registry
python3 aiplatform_runner.py list-models
```

## Repo-Contained References

- `QUICK_START.md`
- `aiplatform_runner.py`
- `AIPLATFORM_RUNNER_TEST_RESULTS.md`
- `VERTEXAPIS_FINDINGS_2026-02-28.md`
- `endpoints/translate-vertexapis-com.md`

## Notes

- This repo snapshot does not include a committed video generator helper.
- For TTS/STT curl examples, use `../vertexapis_research/komutlar.md` and `../vertexapis_research/stt.sh`.
