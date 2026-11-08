#!/usr/bin/env python3
"""Parallel docker pull with per-image progress display.

Reads image references from stdin (one per line, as output by `kix images`)
and pulls them in parallel via the Docker Engine API over /var/run/docker.sock.
Renders a live multi-line progress display showing per-image status.

Usage:
    kix images homelab-kind | ./how-to/homelab/demos/docker-pull-parallel.py
    echo "nginx:latest" | ./how-to/homelab/demos/docker-pull-parallel.py
    ./how-to/homelab/demos/docker-pull-parallel.py < images.txt

Requires: Python 3.13+, Docker daemon running.
No pip dependencies — uses only stdlib.
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from enum import Enum
from urllib.parse import quote


# ── Docker unix-socket HTTP client ──────────────────────────────────────


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection subclass that connects over a unix domain socket."""

    def __init__(self, socket_path: str, timeout: float = 300):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._socket_path)


DOCKER_SOCK = os.environ.get("DOCKER_HOST_PATH", "/var/run/docker.sock")
MAX_PARALLEL = int(os.environ.get("PULL_PARALLEL", "6"))


# ── Image pull state ────────────────────────────────────────────────────


class Status(Enum):
    QUEUED = "queued"
    PULLING = "pulling"
    DONE = "done"
    CACHED = "cached"
    FAILED = "failed"


@dataclass
class LayerProgress:
    current: int = 0
    total: int = 0


@dataclass
class ImageState:
    image: str
    status: Status = Status.QUEUED
    layers: dict[str, LayerProgress] = field(default_factory=dict)
    error: str = ""
    start_time: float = 0.0
    end_time: float = 0.0
    total_bytes: int = 0
    was_cached: bool = False

    @property
    def current_bytes(self) -> int:
        return sum(lay.current for lay in self.layers.values())

    @property
    def total_bytes_from_layers(self) -> int:
        return sum(lay.total for lay in self.layers.values())

    @property
    def elapsed(self) -> float:
        end = self.end_time or time.monotonic()
        return end - self.start_time if self.start_time else 0.0


# ── Progress rendering ──────────────────────────────────────────────────

SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def format_bytes(b: int) -> str:
    if b < 1024:
        return f"{b} B"
    elif b < 1024 * 1024:
        return f"{b / 1024:.0f} KiB"
    elif b < 1024 * 1024 * 1024:
        return f"{b / (1024 * 1024):.1f} MiB"
    else:
        return f"{b / (1024 * 1024 * 1024):.2f} GiB"


def render_image(state: ImageState, spinner_idx: int, term_width: int) -> str:
    sym = ""
    detail = ""

    match state.status:
        case Status.QUEUED:
            sym = " "
            detail = "\033[90m[queued]\033[0m"
        case Status.PULLING:
            sym = f"\033[33m{SPINNER[spinner_idx % len(SPINNER)]}\033[0m"
            cur = state.current_bytes
            tot = state.total_bytes_from_layers
            if tot > 0:
                pct = cur / tot * 100
                speed = cur / max(state.elapsed, 0.1)
                remaining = (tot - cur) / max(speed, 1)
                detail = (
                    f"\033[36m[{format_bytes(cur)} / {format_bytes(tot)}"
                    f"  {pct:3.0f}%  {format_bytes(int(speed))}/s"
                    f"  ETA {remaining:.0f}s]\033[0m"
                )
            else:
                detail = "\033[36m[starting...]\033[0m"
        case Status.DONE:
            elapsed = state.elapsed
            sym = "\033[32m✓\033[0m"
            detail = f"\033[32m[pulled {format_bytes(state.total_bytes)} in {elapsed:.1f}s]\033[0m"
        case Status.CACHED:
            sym = "\033[32m✓\033[0m"
            detail = "\033[32m[cached]\033[0m"
        case Status.FAILED:
            sym = "\033[31m✗\033[0m"
            detail = f"\033[31m[{state.error[:60]}]\033[0m"

    # Truncate image name to fit
    max_img = min(55, term_width - 20)
    img_display = (
        state.image
        if len(state.image) <= max_img
        else "..." + state.image[-(max_img - 3) :]
    )
    return f"  {sym} {img_display:<{max_img}}  {detail}"


def render_all(states: list[ImageState], spinner_idx: int) -> str:
    term_width = shutil.get_terminal_size((80, 24)).columns
    lines = [render_image(s, spinner_idx, term_width) for s in states]
    done = sum(
        1 for s in states if s.status in (Status.DONE, Status.CACHED, Status.FAILED)
    )
    total = len(states)
    header = f"\033[1m  Pulling {total} images ({done}/{total} complete)\033[0m"
    return header + "\n" + "\n".join(lines)


# ── Docker pull logic ───────────────────────────────────────────────────


def parse_image_ref(image: str) -> tuple[str, str]:
    """Split image into (fromImage, tag) for the Docker API.

    Handles:
      - repo:tag
      - repo:tag@sha256:digest  (tag present, digest appended)
      - repo@sha256:digest      (no tag)
      - repo                    (implicit :latest)
    """
    # If there's a digest, the API wants it as part of fromImage
    if "@sha256:" in image:
        # Docker API: pass the whole thing as fromImage, tag empty
        return image, ""

    # Split on last colon that isn't part of the registry port
    parts = image.rsplit(":", 1)
    if len(parts) == 2 and "/" not in parts[1]:
        return parts[0], parts[1]
    return image, "latest"


def check_image_exists(image: str) -> bool:
    """Check if an image already exists locally."""
    try:
        conn = UnixHTTPConnection(DOCKER_SOCK, timeout=10)
        # Use /images/json with filter
        conn.request("GET", f"/v1.43/images/{quote(image, safe='')}/json")
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status == 200
    except Exception:
        return False


def pull_image(state: ImageState):
    """Pull a single image, updating state with progress."""
    state.start_time = time.monotonic()
    state.status = Status.PULLING

    from_image, tag = parse_image_ref(state.image)
    url = f"/v1.43/images/create?fromImage={quote(from_image, safe='')}"
    if tag:
        url += f"&tag={quote(tag, safe='')}"

    try:
        conn = UnixHTTPConnection(DOCKER_SOCK)
        conn.request("POST", url)
        resp = conn.getresponse()

        if resp.status not in (200, 201):
            body = resp.read().decode(errors="replace")
            state.status = Status.FAILED
            state.error = f"HTTP {resp.status}: {body[:100]}"
            conn.close()
            return

        # Stream JSON progress events
        saw_download = False
        buf = b""
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            buf += chunk
            # Events are newline-delimited JSON
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue

                status = evt.get("status", "")
                layer_id = evt.get("id", "")
                progress_detail = evt.get("progressDetail", {})

                if status in ("Downloading", "Extracting") and layer_id:
                    saw_download = True
                    current = progress_detail.get("current", 0)
                    total = progress_detail.get("total", 0)
                    if layer_id not in state.layers:
                        state.layers[layer_id] = LayerProgress()
                    lp = state.layers[layer_id]
                    if total > 0:
                        lp.total = total
                    if current > lp.current:
                        lp.current = current

                if "error" in evt:
                    state.status = Status.FAILED
                    state.error = evt["error"]
                    conn.close()
                    return

        conn.close()
        state.end_time = time.monotonic()
        state.total_bytes = state.current_bytes

        if not saw_download:
            state.status = Status.CACHED
        else:
            state.status = Status.DONE

    except Exception as e:
        state.status = Status.FAILED
        state.error = str(e)
        state.end_time = time.monotonic()


# ── Main ────────────────────────────────────────────────────────────────


def main():
    if sys.stdin.isatty():
        print(
            "Usage: kix images <cluster> | ./how-to/homelab/demos/docker-pull-parallel.py",
            file=sys.stderr,
        )
        print(
            "       Reads image references from stdin, one per line.", file=sys.stderr
        )
        sys.exit(1)

    images = [line.strip() for line in sys.stdin if line.strip()]
    if not images:
        print("No images to pull.", file=sys.stderr)
        sys.exit(0)

    is_tty = sys.stderr.isatty()

    states = [ImageState(image=img) for img in images]
    semaphore = threading.Semaphore(MAX_PARALLEL)
    threading.Lock()

    def worker(state: ImageState):
        with semaphore:
            pull_image(state)

    threads = [threading.Thread(target=worker, args=(s,), daemon=True) for s in states]
    for t in threads:
        t.start()

    # Render loop
    spinner_idx = 0
    num_lines = 0
    try:
        while any(t.is_alive() for t in threads):
            if is_tty:
                # Move cursor up and clear previous output
                if num_lines > 0:
                    sys.stderr.write(f"\033[{num_lines}A\033[J")

                output = render_all(states, spinner_idx)
                sys.stderr.write(output + "\n")
                sys.stderr.flush()
                num_lines = output.count("\n") + 1
            spinner_idx += 1
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(130)

    # Final render
    if is_tty:
        if num_lines > 0:
            sys.stderr.write(f"\033[{num_lines}A\033[J")
        output = render_all(states, spinner_idx)
        sys.stderr.write(output + "\n")
        sys.stderr.flush()

    # Summary
    failed = [s for s in states if s.status == Status.FAILED]
    cached = [s for s in states if s.status == Status.CACHED]
    pulled = [s for s in states if s.status == Status.DONE]

    sum(s.total_bytes for s in pulled)
    if not is_tty:
        # Non-TTY: simple summary
        print(
            f"Pulled {len(pulled)}, cached {len(cached)}, failed {len(failed)}",
            file=sys.stderr,
        )

    if failed:
        print(f"\n\033[31m{len(failed)} image(s) failed:\033[0m", file=sys.stderr)
        for s in failed:
            print(f"  {s.image}: {s.error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
