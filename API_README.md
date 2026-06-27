# Surya OCR API

A FastAPI HTTP wrapper around [Surya OCR](README.md). Upload an image or PDF, get back recognized text with per-line bounding boxes and confidence.

Runs end-to-end OCR using Surya's `DetectionPredictor` + `RecognitionPredictor` (powered by the `FoundationPredictor`), with logging, request/prediction logs persisted to disk, and annotated debug images saved per request.

## Files

| File | Purpose |
|---|---|
| `ocr_api.py` | FastAPI app — `/health`, `/ocr`, `/logs`, `/logs/{name}` |
| `client.py`  | CLI uploader — sends a file to the API and prints/saves the result |
| `requirements.txt` | Python deps for the API + client |
| `logs/` | Auto-created runtime folder for log files and annotated images (ignored by git) |

## Installation

```bash
python -m venv surya_env
source surya_env/bin/activate
pip install -r requirements.txt
```

`surya-ocr` will install the heavy ML deps (`torch`, `transformers`, etc.). Models are downloaded from Datalab's S3 on first run into `~/.cache/datalab/models`.

## Running the server

```bash
python ocr_api.py
# Or via uvicorn for autoreload / workers:
uvicorn ocr_api:app --host 0.0.0.0 --port 8040
```

The server listens on **port 8040**. Models load once at startup via FastAPI's `lifespan` hook.

Interactive docs: <http://localhost:8040/docs>

## Endpoints

### `GET /health`
Liveness + readiness.
```json
{ "status": "ok", "models_loaded": true }
```

### `POST /ocr`
Upload an image or PDF and run OCR.

| Param | Type | Description |
|---|---|---|
| `file` | multipart file | Image (JPG/PNG/…) or PDF |
| `disable_math` | query bool | If `true`, disables LaTeX/math recognition. Default `false`. |

Response shape:
```json
{
  "filename": "invoice.pdf",
  "pages": [
    {
      "page": 1,
      "text": "...full-page text...",
      "text_lines": [
        { "text": "Hello", "bbox": [x1, y1, x2, y2], "confidence": 0.97 }
      ]
    }
  ],
  "text": "...concatenated text..."
}
```

cURL:
```bash
curl -F file=@invoice.pdf "http://localhost:8040/ocr?disable_math=false"
```

### `GET /logs`
List every file in the `logs/` folder.
```json
{
  "log_dir": "/.../logs",
  "count": 12,
  "files": [
    { "name": "ocr_api.log", "size_bytes": 4321, "modified": "...", "url": "/logs/ocr_api.log" },
    { "name": "20260526_111522_..._page1.png", "size_bytes": 91234, "modified": "...", "url": "/logs/..." }
  ]
}
```

### `GET /logs/{name}`
Download a specific log file or annotated PNG. Path traversal is blocked.

## Logging

Configured at module level — written to **both** stdout and `logs/ocr_api.log` with daily rotation (14 days kept).

Each `/ocr` request logs:
- Request received (filename, `disable_math`)
- Input loaded (size, type, page count or image dims)
- Detection + OCR start, finish, total lines, elapsed seconds
- Per-page line counts (INFO) and per-line `bbox` + `confidence` + recognized text (DEBUG)
- Response summary (pages, total chars)

To see the per-line predicted text, switch the level in `ocr_api.py` from `logging.INFO` → `logging.DEBUG`.

## Annotated debug images

After every `/ocr` request, each input page is saved to `logs/` with the predicted bounding boxes and recognized text drawn on it (red polygons + text labels), using Surya's own [`draw_polys_on_image`](surya/debug/draw.py).

Naming:
```
logs/<timestamp>_<sanitized-filename>_page<N>.png
e.g. logs/20260526_111522_494043_invoice_page1.png
```

Files accumulate — there is no auto-rotation for these PNGs. Clean up periodically or add a toggle if needed.

## Client script

`client.py` uploads a file, prints the recognized text per page, and writes the full JSON response next to the input.

```bash
python client.py path/to/image-or.pdf
python client.py invoice.pdf --url http://1.2.3.4:8040
python client.py doc.pdf --disable-math
```

## Notes & limitations

- The OCR call is synchronous inside an `async def` endpoint, so a single uvicorn worker handles one request at a time. For concurrency, run multiple workers (`uvicorn ... --workers N`) — each loads its own model copy, so plan VRAM accordingly.
- PDFs are rasterized twice (lowres + highres DPI). For very large PDFs this can be slow and memory-heavy.
- No upload-size limit, no auth — add a reverse proxy or middleware if exposing publicly.
- Models live in `~/.cache/datalab/models`; first run downloads several GB.
