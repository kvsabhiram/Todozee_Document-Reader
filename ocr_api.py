import io
import logging
import os
import re
import tempfile
import time
from contextlib import asynccontextmanager
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler
from typing import List, Optional

import filetype
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from PIL import Image
from pydantic import BaseModel

from surya.common.surya.schema import TaskNames
from surya.debug.draw import draw_polys_on_image
from surya.detection import DetectionPredictor
from surya.foundation import FoundationPredictor
from surya.input.load import load_pdf
from surya.recognition import RecognitionPredictor
from surya.settings import settings


LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "ocr_api.log")

_log_formatter = logging.Formatter(
    "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)

_file_handler = TimedRotatingFileHandler(
    LOG_FILE, when="midnight", backupCount=14, encoding="utf-8"
)
_file_handler.setFormatter(_log_formatter)

_console_handler = logging.StreamHandler()
_console_handler.setFormatter(_log_formatter)

logging.basicConfig(
    level=logging.INFO,
    handlers=[_console_handler, _file_handler],
)
logger = logging.getLogger("ocr_api")


predictors: dict = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    foundation_predictor = FoundationPredictor(
        checkpoint=settings.RECOGNITION_MODEL_CHECKPOINT
    )
    predictors["recognition"] = RecognitionPredictor(foundation_predictor)
    predictors["detection"] = DetectionPredictor()
    yield
    predictors.clear()


app = FastAPI(
    title="Surya OCR API",
    description="FastAPI endpoints for OCR using Surya.",
    lifespan=lifespan,
)


class TextLine(BaseModel):
    text: str
    bbox: List[float]
    confidence: Optional[float] = None


class PageResult(BaseModel):
    page: int
    text: str
    text_lines: List[TextLine]


class OCRResponse(BaseModel):
    filename: str
    pages: List[PageResult]
    text: str


def _load_images_from_upload(filename: str, content: bytes):
    kind = filetype.guess(content)
    is_pdf = kind is not None and kind.extension == "pdf"
    detected_type = kind.extension if kind is not None else "unknown"
    logger.info(
        "Input: filename=%r size=%d bytes detected_type=%s is_pdf=%s",
        filename,
        len(content),
        detected_type,
        is_pdf,
    )

    if is_pdf:
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=True) as tmp:
            tmp.write(content)
            tmp.flush()
            images, _ = load_pdf(tmp.name)
            highres_images, _ = load_pdf(tmp.name, dpi=settings.IMAGE_DPI_HIGHRES)
        logger.info("Input: loaded %d page(s) from PDF %r", len(images), filename)
        return images, highres_images

    try:
        image = Image.open(io.BytesIO(content)).convert("RGB")
    except Exception as e:
        logger.warning("Input: failed to decode %r as image/PDF: %s", filename, e)
        raise HTTPException(
            status_code=400,
            detail=f"Could not read '{filename}' as an image or PDF: {e}",
        )
    logger.info("Input: loaded image %r size=%dx%d", filename, image.width, image.height)
    return [image], [image]


def _run_ocr(images, highres_images, disable_math: bool = False):
    task_names = [TaskNames.ocr_with_boxes] * len(images)
    logger.info(
        "Detection+OCR: running on %d image(s) (math_mode=%s)",
        len(images),
        not disable_math,
    )
    start = time.perf_counter()
    predictions = predictors["recognition"](
        images,
        task_names=task_names,
        det_predictor=predictors["detection"],
        highres_images=highres_images,
        math_mode=not disable_math,
    )
    elapsed = time.perf_counter() - start
    total_lines = sum(len(p.text_lines) for p in predictions)
    logger.info(
        "Detection+OCR: finished %d page(s), %d line(s) in %.2fs",
        len(predictions),
        total_lines,
        elapsed,
    )
    _log_predictions(predictions)
    return predictions


def _sanitize_name(filename: str) -> str:
    stem = os.path.splitext(os.path.basename(filename))[0]
    return re.sub(r"[^A-Za-z0-9._-]", "_", stem) or "upload"


def _save_annotated_images(filename: str, images, predictions) -> List[str]:
    """Draw predicted bounding boxes + text on each input page and save to LOG_DIR."""
    saved: List[str] = []
    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    base = _sanitize_name(filename)
    for idx, (image, pred) in enumerate(zip(images, predictions)):
        page_image = image.copy().convert("RGB")
        polys = [line.polygon for line in pred.text_lines]
        labels = [line.text for line in pred.text_lines]
        draw_polys_on_image(polys, page_image, labels=labels)
        out_path = os.path.join(LOG_DIR, f"{ts}_{base}_page{idx + 1}.png")
        page_image.save(out_path)
        saved.append(out_path)
        logger.info(
            "Saved annotated image: %s (%d box(es))", out_path, len(polys)
        )
    return saved


def _log_predictions(predictions) -> None:
    """Log the predicted output per page: bbox, confidence and recognized text."""
    for idx, pred in enumerate(predictions):
        page = idx + 1
        logger.info("Predicted page %d: %d line(s)", page, len(pred.text_lines))
        for line_no, line in enumerate(pred.text_lines):
            bbox = [round(float(c), 1) for c in line.bbox]
            conf = getattr(line, "confidence", None)
            conf_str = f"{conf:.3f}" if isinstance(conf, (int, float)) else "n/a"
            logger.debug(
                "  page %d line %d bbox=%s conf=%s text=%r",
                page,
                line_no,
                bbox,
                conf_str,
                line.text,
            )


def _build_response(filename: str, predictions) -> OCRResponse:
    pages: List[PageResult] = []
    all_text_parts: List[str] = []

    for idx, pred in enumerate(predictions):
        lines = [
            TextLine(
                text=line.text,
                bbox=list(line.bbox),
                confidence=getattr(line, "confidence", None),
            )
            for line in pred.text_lines
        ]
        page_text = "\n".join(line.text for line in lines)
        pages.append(PageResult(page=idx + 1, text=page_text, text_lines=lines))
        all_text_parts.append(page_text)

    return OCRResponse(
        filename=filename,
        pages=pages,
        text="\n\n".join(all_text_parts),
    )


@app.get("/health")
def health():
    return {"status": "ok", "models_loaded": bool(predictors)}


@app.get("/logs")
def list_logs():
    """List every file in the logs folder (log files + annotated images)."""
    entries = []
    for name in sorted(os.listdir(LOG_DIR)):
        path = os.path.join(LOG_DIR, name)
        if not os.path.isfile(path):
            continue
        stat = os.stat(path)
        entries.append({
            "name": name,
            "size_bytes": stat.st_size,
            "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            "url": f"/logs/{name}",
        })
    return {"log_dir": LOG_DIR, "count": len(entries), "files": entries}


@app.get("/logs/{name}")
def get_log(name: str):
    """Download a single log file or annotated image by name."""
    safe_name = os.path.basename(name)
    path = os.path.join(LOG_DIR, safe_name)
    # Block path traversal: must resolve inside LOG_DIR
    if os.path.commonpath([os.path.abspath(path), LOG_DIR]) != LOG_DIR:
        raise HTTPException(status_code=400, detail="Invalid path.")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail=f"Log file '{safe_name}' not found.")
    media_type = "image/png" if safe_name.lower().endswith(".png") else "text/plain"
    return FileResponse(path, media_type=media_type, filename=safe_name)


@app.post("/ocr", response_model=OCRResponse)
async def ocr(file: UploadFile = File(...), disable_math: bool = False):
    filename = file.filename or "upload"
    logger.info("Request: POST /ocr filename=%r disable_math=%s", filename, disable_math)

    if not predictors:
        logger.warning("Request rejected: models not loaded yet (filename=%r)", filename)
        raise HTTPException(status_code=503, detail="Models are not loaded yet.")

    content = await file.read()
    if not content:
        logger.warning("Request rejected: empty file (filename=%r)", filename)
        raise HTTPException(status_code=400, detail="Empty file.")

    images, highres_images = _load_images_from_upload(filename, content)
    predictions = _run_ocr(images, highres_images, disable_math=disable_math)
    _save_annotated_images(filename, images, predictions)
    response = _build_response(filename, predictions)
    logger.info(
        "Response: filename=%r pages=%d total_chars=%d",
        filename,
        len(response.pages),
        len(response.text),
    )
    return response


if __name__ == "__main__":
    uvicorn.run("ocr_api:app", host="0.0.0.0", port=8040, reload=False)
