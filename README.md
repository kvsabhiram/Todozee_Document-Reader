# Todozee Document Reader

A FastAPI server that does OCR on images and PDFs using [Surya OCR](https://github.com/datalab-to/surya).

Upload a file, get back the recognized text with bounding boxes. Logs and annotated debug images are saved to a `logs/` folder.

## Install

```bash
git clone https://github.com/kvsabhiram/Todozee_Document-Reader.git
cd Todozee_Document-Reader

python -m venv surya_env
source surya_env/bin/activate

pip install -r requirements.txt
```

Models download automatically on first run (~several GB, cached in `~/.cache/datalab/models`).

## Run the server

```bash
python ocr_api.py
```

Server starts on `http://localhost:8040`. Interactive docs at `http://localhost:8040/docs`.

## Use it

### With the included client

```bash
python client.py path/to/image-or.pdf
```

Prints the OCR text and saves the full JSON response next to the input file.

### With curl

```bash
curl -F file=@invoice.pdf http://localhost:8040/ocr
```

### Endpoints

| Method | Path | What it does |
|---|---|---|
| `GET`  | `/health`       | Health check |
| `POST` | `/ocr`          | Upload an image or PDF, returns text + bboxes |
| `GET`  | `/logs`         | List log files and annotated images |
| `GET`  | `/logs/{name}`  | Download a specific log file or image |

## What's in `logs/`

After every `/ocr` request you get:
- `ocr_api.log` — request + prediction logs (daily-rotated)
- `<timestamp>_<filename>_pageN.png` — the input page with predicted bounding boxes and recognized text drawn on it
