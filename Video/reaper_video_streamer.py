"""
REAPER Video Window Streamer
=============================

VERSION = 2.0

Captures ONLY the REAPER video window and streams it as MJPEG
over HTTP to any device on your local network (tablet, phone, etc.).

Open http://<YOUR_PC_IP>:9062 on your tablet's browser to view.

Requirements:
    pip install pywin32 opencv-python numpy

Usage:
    python reaper_video_streamer.py
    python reaper_video_streamer.py --port 9062 --fps 60 --quality 90
    python reaper_video_streamer.py --no-crop --no-adaptive
    python reaper_video_streamer.py --transparent

Press Ctrl+C to stop.
"""

import sys
import os
import time
import json
import socket
import logging
import argparse
import threading
import ctypes
import ctypes.wintypes
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

# ── DPI Awareness (MUST be set before any Win32 GUI operations) ──────
# Fixes incorrect window dimensions on high-DPI displays which causes
# the captured image to be cropped/wrong size.
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # Per-Monitor DPI Aware V2
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()  # Fallback for older Windows
    except Exception:
        pass

# ── Third-party imports ──────────────────────────────────────────────
try:
    import win32gui
    import win32ui
    import win32con
except ImportError:
    print("ERROR: pywin32 is required. Install it with:")
    print("  pip install pywin32")
    sys.exit(1)

try:
    import cv2
except ImportError:
    print("ERROR: OpenCV is required. Install it with:")
    print("  pip install opencv-python")
    sys.exit(1)

try:
    import numpy as np
except ImportError:
    print("ERROR: numpy is required. Install it with:")
    print("  pip install numpy")
    sys.exit(1)

try:
    import simplejpeg
    HAS_SIMPLEJPEG = True
except ImportError:
    HAS_SIMPLEJPEG = False


# ══════════════════════════════════════════════════════════════════════
#  CONFIGURATION — edit these to customise behavior
# ══════════════════════════════════════════════════════════════════════
PORT = 9062               # HTTP port to serve on
TARGET_FPS = 60           # Maximum frames per second
JPEG_QUALITY = 92         # JPEG quality 1-100 (higher = sharper, more bandwidth)
SCALE = 1.0               # Scale factor (0.5 = half resolution, saves bandwidth)
VIDEO_WINDOW_TITLE = "Video Window"  # REAPER video window title to search for

# ── Feature Flags ────────────────────────────────────────────────────

CAPTURE_MODE_ENABLED = False   # Enable Mode A (Screen Capture). Disable to save CPU if using exclusively Mode B.

ADAPTIVE_FPS = True           # Only encode/send frames when content actually changes.
                              # Full FPS during playback, near-zero during pause.
AUTO_CROP_BLACK_BARS = True   # Crop letterbox/pillarbox black bars that REAPER draws
                              # when "Preserve video aspect ratio" is enabled.
TRANSPARENCY_MODE = False     # Apply CSS mix-blend-mode:multiply on the HTML viewer.
                              # Makes white areas transparent — useful for overlaying
                              # Guitar Pro tabs on other content (e.g. SyncLyrics embed).
WHITE_KEY_STREAM  = False      # Enable the /transparent endpoint: serves MJPEG where each
                              # frame is PNG with near-white pixels keyed to alpha=0.
                              # Provides true browser-native transparency for SyncLyrics
                              # overlay (no CSS tricks needed — native <img> alpha).
                              # CPU cost: per-frame JPEG decode + PNG encode per client.
                              # Zero overhead when no /transparent client is connected.

# ── Adaptive FPS Settings ────────────────────────────────────────────
COMPARE_SIZE = 128             # Thumbnail size for frame comparison (pixels).
                              # Larger = more sensitive to tiny changes, slightly slower.
ADAPTIVE_FPS_METHOD = "diff"  # "exact" = original byte comparison (fast, may miss thin cursor)
                              # "diff"  = numpy pixel-sum diff (recommended, catches thin cursors)
CHANGE_THRESHOLD_SUM = 20    # Only used when ADAPTIVE_FPS_METHOD = "diff".
                              # Minimum total pixel change to count as a changed frame.
                              # Lower = more sensitive (sends more frames when near-static).
                              # Tune using --log-level DEBUG "Frame diff:" output lines.

# ── Black Bar Cropping Settings ──────────────────────────────────────
BLACK_THRESHOLD = 15          # Pixel brightness below this counts as "black" (0-255).
CROP_MARGIN = 2               # Extra pixels to keep around the detected content edge.
CROP_MIN_STRIP = 5            # Only crop if the black border is at least this many px wide.

# ── Transparency Settings ────────────────────────────────────────────
# Background color when transparency mode is on.
# Medium/light tones work best with mix-blend-mode:multiply.
# Dark backgrounds wash out Guitar Pro highlights — use with caution.
BACKGROUND_COLOR = "#808080"

# ── White-Key Stream Settings ────────────────────────────────────────
WHITE_KEY_THRESHOLD = 255     # Noise gate for the luma key in the /transparent endpoint.
                              # Maps to: alpha_thresh = 255 - WHITE_KEY_THRESHOLD.
                              # Pixels where the computed alpha <= alpha_thresh are zeroed
                              # (treated as background residue, made fully transparent).
                              # Default 250 → alpha_thresh=5: only zero pixels with computed
                              # alpha < 6 (all channels ≥ 250 in the raw capture).
                              # Tune: lower = more aggressive key (may eat faint content).
                              #        raise toward 255 = softer, residue may linger.

# ── Smart Idle & Network ─────────────────────────────────────────────
WINDOW_SCAN_INTERVAL_SEC = 1.0     # Seconds to sleep between window title scans when REAPER is closed
IDLE_TIMEOUT_SEC = 15.0            # Seconds to hold the last frame when REAPER is minimized/hidden
IDLE_ACTION = "close"              # "hold" (freeze frame), "clear" (send solid white frame), or "close (drop connection)"
BLACK_TIMEOUT_SEC = 15.0           # Seconds to hold the last frame when REAPER is projecting pure black
BLACK_ACTION = "close"            # "hold", "clear", or "close"
IDLE_CLEAR_COLOR = [255, 255, 255]# BGR color for the clear frame (White is transparent in multiply mode)
TCP_NODELAY = True                # Disable Nagle's algorithm for faster TCP packet delivery

# ── Auto-Reconnect ──────────────────────────────────────────────────
AUTO_RECONNECT = True             # Tablet auto-reconnects when streamer restarts.
RECONNECT_INTERVAL_MS = 3000      # Milliseconds between reconnect attempts.

# ── Encoding ────────────────────────────────────────────────────────
FORCE_OPENCV = False              # Force OpenCV JPEG encoder instead of simplejpeg (if installed)

# ── Direct Video Sync (Phase 5) ─────────────────────────────────────
DIRECT_VIDEO_SYNC = True          # Master switch for Mode B: direct video file streaming
                                  # with REAPER transport sync via companion script.
                                  # Requires: companion script running inside REAPER.
                                  # When False: zero overhead, all Mode B code is completely dead.
COMPANION_UDP_PORT = 9063         # UDP port for companion script → streamer communication.
                                  # Must match UDP_PORT in the companion script.
COMPANION_TIMEOUT_SEC = 6.0       # Seconds without UDP data before companion declared dead.
SYNC_POLL_INTERVAL_MS = 200       # How often tablet JS polls /playback (milliseconds).
DRIFT_THRESHOLD_SEC = 0.20        # Correct video position if drift exceeds this (seconds).
DRIFT_CHECK_INTERVAL_MS = 1000    # How often to check for sync drift (milliseconds).
DRIFT_COOLDOWN_MS = 2000          # After a correction, skip drift checks for this long (ms).
SEEK_DEBOUNCE_MS = 300            # Debounce rapid scrubbing: wait for cursor stability (ms).
LATENCY_COMP_MS = 0              # Play video this many ms ahead of REAPER (negative latency). +100 ms means a playtime of 5.0 secs in REAPER corresponds to 5.1 secs in video.
LATENCY_COMP_MODE = "playback"    # When to apply comp: "playback", "always" (e.g. during scrub/pause).
PLAY_SEEK_THRESHOLD_SEC = 0.500   # Do not seek if position delta is below this when unpausing (smooth startup)
SEEK_FLUSH_COMPENSATION = "always" # "off": standard seeks. "start": decoder flush measured only on play/unpause. "always": measured on unpause and timeline scrubbing.


# ── Drift PLL (smooth speed-based correction for small sync errors) ────
DRIFT_PLL_ENABLED = True          # Enable slew-rate PLL for sub-threshold drift.
                                   # When enabled: drifts between PLL_THRESHOLD and DRIFT_THRESHOLD
                                   # are corrected by gently bending playback speed rather than
                                   # hard-seeking (jarring jump). Disable if speed variations are
                                   # undesirable or if the PLL causes oscillation.
DRIFT_PLL_THRESHOLD_SEC = 0.050   # Minimum drift (seconds) before PLL activates (hysteresis enter).
                                   # Drifts below DRIFT_PLL_EXIT_THRESH_SEC are ignored (dead zone).
DRIFT_PLL_EXIT_THRESH_SEC = 0.020  # Drift below which an active PLL deactivates (hysteresis exit).
                                   # Keeps PLL correcting from DRIFT_PLL_THRESHOLD_SEC down to this value.
DRIFT_PLL_GAIN = 0.3              # How aggressively to correct: fraction of drift closed per second.
                                   # 0.5 = aim to close 50% of the gap per second.
                                   # Lower = smoother but slower convergence. Suggested: 0.2-0.5.
                                   # At DRIFT_CHECK_INTERVAL_MS=1000, gain > 1.0 would overshoot.
DRIFT_PLL_MAX_RATE_MULT = 1.10    # Maximum playback rate multiplier for PLL correction.
                                   # 1.10 = allow up to 10% speed-up/slow-down. Keep <= 1.10.
DRIFT_PLL_COOLDOWN_MS = 1000      # How long after a checkDrift hard seek before PLL may fire.
                                   # Separate from DRIFT_COOLDOWN_MS (which gates hard seeks only).
DRIFT_PLL_EVENT_COOL_MS = 400     # How long after a manual event (play, scrub, switch) before PLL may fire.
DROP_PLL_SUPPRESS_THRESH = 30      # If droppedVideoFrames increases by more than this between drift checks,
                                   # suppress PLL and restore normal rate for that cycle.
                                   # Prevents PLL from making decoder drops worse by demanding faster playback.
                                   # Set to 999 to disable suppression entirely.

# ── Logging ──────────────────────────────────────────────────────────
LOG_LEVEL = "INFO"            # DEBUG, INFO, WARNING, ERROR
MAX_LOG_FILES = 6             # Keep this many session log files before cleanup

# ══════════════════════════════════════════════════════════════════════


# ── Constants & Globals ──────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.resolve()
LOG_DIR = SCRIPT_DIR / "logs"
PID_FILE = SCRIPT_DIR / "streamer.pid"
BOUNDARY = b"--frameboundary"
_shutdown_event = threading.Event()
_user32 = ctypes.windll.user32
PW_CLIENTONLY = 0x1
PW_RENDERFULLCONTENT = 0x2


# ══════════════════════════════════════════════════════════════════════
#  LOGGING
# ══════════════════════════════════════════════════════════════════════
def setup_logging(level_name="INFO"):
    """Configure file + console logging. Each run creates a new session log."""
    LOG_DIR.mkdir(exist_ok=True)

    # Clean up old session logs (keep most recent MAX_LOG_FILES)
    log_files = sorted(LOG_DIR.glob("reaper_video_*.log"), key=lambda f: f.stat().st_mtime)
    for old_file in log_files[:-MAX_LOG_FILES]:
        try:
            old_file.unlink()
        except Exception:
            pass

    level = getattr(logging, level_name.upper(), logging.INFO)
    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    log_file = LOG_DIR / f"reaper_video_{timestamp}.log"

    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)-7s] %(message)s", datefmt="%H:%M:%S"
    )

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setLevel(level)
    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(level)
    console_handler.setFormatter(formatter)

    logger = logging.getLogger("rvs")
    logger.setLevel(level)
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    logger.info(f"Session log: {log_file}")
    return logger


# ══════════════════════════════════════════════════════════════════════
#  FRAME BUFFER (multi-client safe)
# ══════════════════════════════════════════════════════════════════════
class FrameBuffer:
    """Thread-safe frame buffer with multi-client notification via Condition."""

    def __init__(self):
        self._lock = threading.Lock()
        self._frame = None      # JPEG bytes (always present)
        self._png_frame = None  # PNG bytes with alpha (None when no /transparent clients)
        self._frame_id = 0      # Increments on each new frame
        self.stream_state = "starting"
        self._force_disconnect = False
        self._condition = threading.Condition(self._lock)

    def trigger_disconnect(self):
        """Force all current stream clients to disconnect cleanly."""
        with self._condition:
            self._force_disconnect = True
            self._condition.notify_all()

    def put(self, jpeg_bytes, png_bytes=None):
        """Store a new JPEG frame and optional PNG frame, then wake ALL waiting clients."""
        with self._condition:
            self._force_disconnect = False
            self._frame = jpeg_bytes
            self._png_frame = png_bytes
            self._frame_id += 1
            self._condition.notify_all()

    def get(self, last_id=0, timeout=2.0):
        """Wait for a frame newer than last_id.
        Returns (jpeg_bytes, png_bytes, frame_id). Raises ConnectionAbortedError if force-dropped."""
        with self._condition:
            if self._force_disconnect:
                raise ConnectionAbortedError("Forced disconnect via idle/black configuration")
            if self._frame is None or self._frame_id <= last_id:
                self._condition.wait(timeout)
                if self._force_disconnect:
                    raise ConnectionAbortedError("Forced disconnect via idle/black configuration")
            return self._frame, self._png_frame, self._frame_id

    def shutdown(self):
        """Wake all waiting clients for clean shutdown."""
        with self._condition:
            self._condition.notify_all()

    @property
    def latest(self):
        """Get the most recent frame without waiting."""
        with self._lock:
            return self._frame


frame_buffer = FrameBuffer()


# ══════════════════════════════════════════════════════════════════════
#  COMPANION STATE (Phase 5 — Direct Video Sync)
# ══════════════════════════════════════════════════════════════════════
class CompanionState:
    """Thread-safe container for the latest state from the REAPER companion script.
    Updated by the UDP listener thread, read by HTTP handlers."""

    def __init__(self, timeout_sec=COMPANION_TIMEOUT_SEC):
        self._lock = threading.Lock()
        self._state = {
            "pos": 0.0, "state": 0, "rate": 1.0,
            "src_time": None, "file": None
        }
        self._last_update = 0.0
        self._timeout_sec = timeout_sec

    def update(self, data):
        """Called by UDP listener thread with parsed JSON from companion."""
        with self._lock:
            self._state.update(data)
            self._last_update = time.time()

    def get(self):
        """Returns current state dict with companion_alive flag and received_at timestamp.
        received_at is the wall-clock time (seconds since epoch) when the last UDP
        packet arrived. The browser uses this to compute data age for RTT-based sync."""
        with self._lock:
            now = time.time()
            alive = (now - self._last_update) < self._timeout_sec if self._last_update > 0 else False
            return {
                **self._state,
                "companion_alive": alive,
                "received_at": round(self._last_update, 4),
                "server_time": round(now, 4),
            }


companion_state = CompanionState()


def udp_listener(comp_state, port, shutdown_evt):
    """Background daemon thread: receives UDP datagrams from REAPER companion script."""
    log = logging.getLogger("rvs")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.settimeout(1.0)
    log.info(f"UDP listener started on 127.0.0.1:{port}")

    while not shutdown_evt.is_set():
        try:
            data, _ = sock.recvfrom(4096)
            comp_state.update(json.loads(data.decode("utf-8")))
        except socket.timeout:
            pass
        except json.JSONDecodeError:
            log.debug("Invalid JSON from companion script")
        except Exception as e:
            if not shutdown_evt.is_set():
                log.debug(f"UDP listener error: {e}")

    sock.close()
    log.info("UDP listener stopped.")


# ══════════════════════════════════════════════════════════════════════
#  WINDOW DISCOVERY
# ══════════════════════════════════════════════════════════════════════
def find_reaper_video_window(title=VIDEO_WINDOW_TITLE):
    """Find the REAPER video window by scanning all visible windows.
    Returns HWND or None."""
    results = []

    def enum_callback(hwnd, _):
        if win32gui.IsWindowVisible(hwnd):
            wnd_title = win32gui.GetWindowText(hwnd)
            if wnd_title and title.lower() in wnd_title.lower():
                results.append((hwnd, wnd_title))

    win32gui.EnumWindows(enum_callback, None)

    if not results:
        return None

    # Prefer exact title match, fall back to first partial match
    for hwnd, wnd_title in results:
        if wnd_title.lower() == title.lower():
            return hwnd
    # Fallback to partial match commented out to prevent capturing web browsers:
    # return results[0][0]
    return None


def list_visible_windows():
    """Debug helper: return list of (hwnd, title) for all visible windows."""
    windows = []
    def enum_callback(hwnd, _):
        if win32gui.IsWindowVisible(hwnd):
            title = win32gui.GetWindowText(hwnd)
            if title.strip():
                windows.append((hwnd, title))
    win32gui.EnumWindows(enum_callback, None)
    return windows


# ══════════════════════════════════════════════════════════════════════
#  WINDOW CAPTURE (Win32 GDI + PrintWindow)
# ══════════════════════════════════════════════════════════════════════
class TargetWindowCapturer:
    """
    Captures the client area of a window using PrintWindow API.
    Maintains persistent GDI resources (DC, Bitmap) across frames to eliminate
    the heavy OS overhead of allocating/destroying them 60 times a second.
    Resources are automatically rebuilt if the target window size changes.
    """
    def __init__(self):
        self.log = logging.getLogger("rvs")
        self.hwnd = None
        self.width = 0
        self.height = 0
        
        self.hwnd_dc = None
        self.mfc_dc = None
        self.save_dc = None
        self.bitmap = None

    def capture(self, hwnd):
        try:
            # Get client area dimensions (excludes title bar / borders)
            left, top, right, bottom = win32gui.GetClientRect(hwnd)
            w = right - left
            h = bottom - top

            if w <= 0 or h <= 0:
                return None

            # Re-init GDI resources only if window/size changed
            if self.hwnd != hwnd or self.width != w or self.height != h:
                self.release_resources()
                
                self.hwnd = hwnd
                self.width = w
                self.height = h
                
                self.hwnd_dc = win32gui.GetWindowDC(hwnd)
                self.mfc_dc = win32ui.CreateDCFromHandle(self.hwnd_dc)
                self.save_dc = self.mfc_dc.CreateCompatibleDC()
                
                self.bitmap = win32ui.CreateBitmap()
                self.bitmap.CreateCompatibleBitmap(self.mfc_dc, w, h)
                self.save_dc.SelectObject(self.bitmap)

            # PrintWindow via ctypes: captures the window's own rendering
            # PW_CLIENTONLY (1) = client area only (no title bar/borders)
            # PW_RENDERFULLCONTENT (2) = DWM-composed content (Win 8.1+)
            result = _user32.PrintWindow(
                hwnd, self.save_dc.GetSafeHdc(),
                PW_CLIENTONLY | PW_RENDERFULLCONTENT
            )

            if result == 0:
                # Fallback: BitBlt (only works if window is not occluded)
                nc_left, nc_top = win32gui.ClientToScreen(hwnd, (0, 0))
                wnd_left, wnd_top, _, _ = win32gui.GetWindowRect(hwnd)
                self.save_dc.BitBlt(
                    (0, 0), (w, h),
                    self.mfc_dc,
                    (nc_left - wnd_left, nc_top - wnd_top),
                    win32con.SRCCOPY
                )

            # Convert bitmap to numpy array (BGR format for OpenCV)
            bmp_bits = self.bitmap.GetBitmapBits(True)
            arr = np.frombuffer(bmp_bits, dtype=np.uint8).reshape(h, w, 4)
            return arr[:, :, :3].copy()  # BGRX -> BGR, contiguous

        except Exception as e:
            self.log.debug(f"Capture error: {e}")
            self.release_resources() # clean slate if error
            return None

    def release_resources(self):
        try:
            if self.save_dc: self.save_dc.DeleteDC()
        except Exception: pass
        try:
            if self.mfc_dc: self.mfc_dc.DeleteDC()
        except Exception: pass
        try:
            if self.hwnd_dc and self.hwnd: win32gui.ReleaseDC(self.hwnd, self.hwnd_dc)
        except Exception: pass
        try:
            if self.bitmap: win32gui.DeleteObject(self.bitmap.GetHandle())
        except Exception: pass
        
        self.hwnd = None
        self.width = 0
        self.height = 0
        self.hwnd_dc = None
        self.mfc_dc = None
        self.save_dc = None
        self.bitmap = None


# ══════════════════════════════════════════════════════════════════════
#  IMAGE PROCESSING
# ══════════════════════════════════════════════════════════════════════
def crop_black_bars(frame):
    """
    Crop letterbox/pillarbox black bars from the captured frame.
    Uses numpy to find the bounding box of non-black content.
    Input and output are BGR numpy arrays.
    Returns cropped frame, or the original if no significant bars detected.
    """
    # A pixel is "non-black" if any channel exceeds the threshold
    mask = np.any(frame > BLACK_THRESHOLD, axis=2)

    rows_with_content = np.any(mask, axis=1)
    cols_with_content = np.any(mask, axis=0)

    if not rows_with_content.any() or not cols_with_content.any():
        return frame  # Entirely black frame - return as-is

    row_indices = np.where(rows_with_content)[0]
    col_indices = np.where(cols_with_content)[0]
    row_min, row_max = row_indices[0], row_indices[-1]
    col_min, col_max = col_indices[0], col_indices[-1]

    h, w = frame.shape[:2]

    # Apply safety margin (stay within image bounds)
    row_min = max(0, row_min - CROP_MARGIN)
    row_max = min(h - 1, row_max + CROP_MARGIN)
    col_min = max(0, col_min - CROP_MARGIN)
    col_max = min(w - 1, col_max + CROP_MARGIN)

    # Only crop if the black strip is meaningful (avoids micro-crops from noise)
    top_strip = row_min
    bottom_strip = h - 1 - row_max
    left_strip = col_min
    right_strip = w - 1 - col_max

    if (top_strip >= CROP_MIN_STRIP or bottom_strip >= CROP_MIN_STRIP or
            left_strip >= CROP_MIN_STRIP or right_strip >= CROP_MIN_STRIP):
        return frame[row_min:row_max + 1, col_min:col_max + 1].copy()

    return frame


def compute_frame_thumbnail(frame):
    """Compute a small thumbnail numpy array for frame comparison."""
    return cv2.resize(frame, (COMPARE_SIZE, COMPARE_SIZE), interpolation=cv2.INTER_NEAREST)


def create_placeholder_frame(text="Waiting for REAPER Video Window..."):
    """Create a placeholder image with centered text for when the window isn't found."""
    w, h = 640, 360
    frame = np.full((h, w, 3), 20, dtype=np.uint8)  # Dark grey background

    # OpenCV putText with centered positioning
    font = cv2.FONT_HERSHEY_SIMPLEX
    font_scale = 0.7
    thickness = 1
    (text_w, text_h), baseline = cv2.getTextSize(text, font, font_scale, thickness)
    x = (w - text_w) // 2
    y = (h + text_h) // 2
    cv2.putText(frame, text, (x, y), font, font_scale,
                (150, 150, 150), thickness, cv2.LINE_AA)

    _, jpeg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return jpeg.tobytes()



# ══════════════════════════════════════════════════════════════════════
#  CAPTURE LOOP
# ══════════════════════════════════════════════════════════════════════
def capture_loop(config):
    """Continuously capture the REAPER video window and feed frames to the buffer."""
    log = logging.getLogger("rvs")

    if not config.capture_mode_enabled:
        log.info("Mode A capture loop completely disabled via config.")
        return

    frame_interval = 1.0 / config.fps
    hwnd = config.hwnd  # May be pre-set via CLI, or None
    prev_thumbnail = None
    placeholder = create_placeholder_frame()
    placeholder_active = False
    capturer = TargetWindowCapturer()

    # Timing and Idle tracking
    last_valid_capture_time = time.perf_counter()
    idle_handled = False
    acc_capture_time = 0.0
    acc_encode_time = 0.0
    acc_captured_count = 0

    # Periodic stats (logged every 30s to avoid spam)
    stats_captured = 0
    stats_sent = 0
    stats_skipped = 0
    stats_bytes_sent = 0  # Total JPEG bytes delivered to clients
    last_stats_time = time.perf_counter()
    stats_period_start = time.perf_counter()

    log.info(f"Capture loop started (max {config.fps} FPS, quality {config.quality})")

    while not _shutdown_event.is_set():
        if not StreamHandler._viewer_event.wait(timeout=2.0):
            continue  # Smart Sleep: 0 viewers, wait for connection without spinning CPU. Re-checks shutdown every 2s.

        t_start = time.perf_counter()

        # ── Find or re-find the video window ─────────────────────────
        if hwnd is None or not win32gui.IsWindow(hwnd):
            hwnd = None

            # Try CLI-provided HWND first, then search by title
            if config.hwnd and win32gui.IsWindow(config.hwnd):
                hwnd = config.hwnd
            else:
                hwnd = find_reaper_video_window(config.window_title)

            if hwnd is not None:
                title = win32gui.GetWindowText(hwnd)
                rect = win32gui.GetClientRect(hwnd)
                log.info(f"Found: \"{title}\" (HWND=0x{hwnd:08X}, client={rect[2]}x{rect[3]})")
                placeholder_active = False
                prev_thumbnail = None  # Reset adaptive FPS baseline
            else:
                if not placeholder_active:
                    placeholder_active = True
                    log.info("Video window not found. Waiting...")
                
                frame_buffer.stream_state = "idle"
                # Smart Idle Logic (Window Missing)
                elapsed_idle = time.perf_counter() - last_valid_capture_time
                if elapsed_idle >= config.idle_timeout_sec and not idle_handled:
                    if config.idle_action == "clear":
                        idle_img = np.full((2, 2, 3), config.idle_clear_color, dtype=np.uint8)
                        _, idle_jpeg = cv2.imencode('.jpg', idle_img, [cv2.IMWRITE_JPEG_QUALITY, 50])
                        frame_buffer.put(idle_jpeg.tobytes(), None)
                        log.info(f"Window hidden for >{config.idle_timeout_sec}s. Sent clear frame.")
                    elif config.idle_action == "close":
                        log.info(f"Window hidden for >{config.idle_timeout_sec}s. Dropping client connections.")
                        frame_buffer.trigger_disconnect()
                    idle_handled = True

                time.sleep(config.window_scan_interval_sec)
                continue

        # ── Capture frame ────────────────────────────────────────────
        t_cap_start = time.perf_counter()
        img = capturer.capture(hwnd)
        t_cap_done = time.perf_counter()

        if img is None:
            log.debug(f"Capture returned None for HWND=0x{hwnd:08X}")
            hwnd = None  # Window likely closed — will re-search next iteration
            time.sleep(config.window_scan_interval_sec)
            continue

        # Check if screen is completely black
        is_black = np.mean(img) <= 2.0

        if is_black:
            frame_buffer.stream_state = "black"
            # Smart Black Logic
            elapsed_idle = time.perf_counter() - last_valid_capture_time
            if elapsed_idle >= config.black_timeout_sec and not idle_handled:
                if config.black_action == "clear":
                    idle_img = np.full((2, 2, 3), config.idle_clear_color, dtype=np.uint8)
                    _, idle_jpeg = cv2.imencode('.jpg', idle_img, [cv2.IMWRITE_JPEG_QUALITY, 50])
                    frame_buffer.put(idle_jpeg.tobytes(), None)
                    log.info(f"Window black for >{config.black_timeout_sec}s. Sent clear frame.")
                elif config.black_action == "close":
                    log.info(f"Window black for >{config.black_timeout_sec}s. Dropping client connections.")
                    frame_buffer.trigger_disconnect()
                idle_handled = True

            time.sleep(config.window_scan_interval_sec)
            continue

        frame_buffer.stream_state = "active"
        last_valid_capture_time = t_cap_done
        idle_handled = False
        acc_capture_time += (t_cap_done - t_cap_start)
        acc_captured_count += 1

        stats_captured += 1
        send_frame = True

        # ── Adaptive FPS: skip encoding if frame is unchanged ────────
        if config.adaptive:
            thumbnail = compute_frame_thumbnail(img)
            if prev_thumbnail is not None:
                if config.adaptive_method == "exact":
                    changed = not np.array_equal(thumbnail, prev_thumbnail)
                else:  # "diff"
                    diff = int(np.sum(
                        np.abs(thumbnail.astype(np.int16) - prev_thumbnail.astype(np.int16))
                    ))
                    changed = diff > config.change_threshold
                    # log.debug(
                    #     f"Frame diff: {diff} (threshold={config.change_threshold}) "
                    #     f"-> {'SEND' if changed else 'SKIP'}"
                    # )
                if not changed:
                    send_frame = False
                    stats_skipped += 1
            prev_thumbnail = thumbnail

        # ── Process and send if frame changed ────────────────────────
        if send_frame:
            t_encode_start = time.perf_counter()
            t_proc = time.perf_counter()

            # Crop black bars
            if config.crop:
                h_before, w_before = img.shape[:2]
                img = crop_black_bars(img)
                h_after, w_after = img.shape[:2]
                # log.debug(f"Crop: {w_before}x{h_before} -> {w_after}x{h_after}")

            # Scale (if configured)
            if config.scale != 1.0:
                new_w = max(1, int(img.shape[1] * config.scale))
                new_h = max(1, int(img.shape[0] * config.scale))
                img = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA)

            # Encode to JPEG (force_opencv bypasses simplejpeg even if installed)
            if HAS_SIMPLEJPEG and not config.force_opencv:
                # 4:4:4 subsampling completely disables chroma blurring for razor-sharp text
                jpeg_bytes = simplejpeg.encode_jpeg(
                    img, quality=config.quality, 
                    colorspace='BGR', colorsubsampling='444', fastdct=True
                )
            else:
                try:
                    _, jpeg = cv2.imencode('.jpg', img, [
                        cv2.IMWRITE_JPEG_QUALITY, config.quality,
                        cv2.IMWRITE_JPEG_SAMPLING_FACTOR, cv2.IMWRITE_JPEG_SAMPLING_FACTOR_444
                    ])
                except AttributeError:
                    # Fallback for extremely old OpenCV versions
                    _, jpeg = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, config.quality])
                jpeg_bytes = jpeg.tobytes()

            # White-key PNG: luma key + un-premultiplication.
            # Applied to raw (pre-JPEG) img so pure white is exactly 255, no JPEG ringing.
            #
            # Math:
            #   alpha = clip(255 + max_channel - 2 × min_channel, 0, 255)
            #     → 0 for pure white, 255 for black, exact for neutral grey anti-aliasing.
            #     → Near-255 for saturated colors (yellow highlights stay fully opaque).
            #   Un-premultiply: strip white contribution from stored color so compositing
            #     on SyncLyrics dark background gives clean notation, not grey halos.
            #     true_fg = (pixel - (1-alpha)×255) / alpha
            # Compression level 1: ~2ms encode vs ~40ms at zlib default level 6.
            png_bytes = None
            if config.white_key_stream and StreamHandler.transparent_viewers > 0:
                img16 = img.astype(np.int16)        # int16 prevents overflow in arithmetic
                b_max = img16.max(axis=2)            # brightest channel per pixel
                b_min = img16.min(axis=2)            # darkest channel per pixel

                # Alpha: how much is each pixel NOT the white background?
                alpha16 = np.clip(255 + b_max - 2 * b_min, 0, 255)

                # Noise gate: zero near-background residue below alpha_thresh
                alpha16[alpha16 <= (255 - WHITE_KEY_THRESHOLD)] = 0

                # Un-premultiply white from colors — recovers true foreground color.
                # Without this, grey anti-aliasing pixels render as bright halos on dark bg.
                white_contrib = (255 - alpha16)[:, :, np.newaxis]
                premult = img16 - white_contrib
                alpha_safe = np.where(alpha16 == 0, 1, alpha16)[:, :, np.newaxis]
                rgb_true = np.clip(premult * 255 // alpha_safe, 0, 255).astype(np.uint8)

                # Assemble BGRA (img/rgb_true are BGR-ordered, matching OpenCV convention)
                bgra = np.empty((img.shape[0], img.shape[1], 4), dtype=np.uint8)
                bgra[:, :, :3] = rgb_true
                bgra[:, :, 3] = alpha16.astype(np.uint8)

                _, png_buf = cv2.imencode('.png', bgra,
                                         [cv2.IMWRITE_PNG_COMPRESSION, 1])
                png_bytes = png_buf.tobytes()

            t_encode_done = time.perf_counter()
            acc_encode_time += (t_encode_done - t_encode_start)

            frame_buffer.put(jpeg_bytes, png_bytes)
            frame_size_kb = len(jpeg_bytes) / 1024
            stats_bytes_sent += len(jpeg_bytes)
            stats_sent += 1

            # log.debug(
            #     f"Frame {stats_sent}: {img.shape[1]}x{img.shape[0]} "
            #     f"{frame_size_kb:.1f} KB  proc={1000*(time.perf_counter()-t_proc):.1f}ms"
            # )

        # ── Periodic stats (every 30s) ───────────────────────────────
        now = time.perf_counter()
        if now - last_stats_time >= 30.0:
            period_secs = now - stats_period_start
            total = stats_captured
            skip_pct = (stats_skipped * 100 / total) if total > 0 else 0
            fps_sent = stats_sent / period_secs if period_secs > 0 else 0
            avg_kb = (stats_bytes_sent / stats_sent / 1024) if stats_sent > 0 else 0
            mbps = (stats_bytes_sent * 8 / 1_000_000 / period_secs) if period_secs > 0 else 0

            avg_cap_ms = (acc_capture_time / acc_captured_count * 1000) if acc_captured_count > 0 else 0
            avg_enc_ms = (acc_encode_time / stats_sent * 1000) if stats_sent > 0 else 0

            with StreamHandler._stats_lock:
                net_time = StreamHandler._stats_net_time
                net_frames = StreamHandler._stats_net_frames
                StreamHandler._stats_net_time = 0.0
                StreamHandler._stats_net_frames = 0
            
            avg_net_ms = (net_time / net_frames * 1000) if net_frames > 0 else 0

            log.info(
                f"Stats: cap={total} sent={stats_sent} "
                f"skip={stats_skipped} ({skip_pct:.0f}%) | "
                f"FPS={fps_sent:.1f} avg={avg_kb:.0f}KB {mbps:.1f}Mbps | "
                f"Latency: cap={avg_cap_ms:.1f}ms enc={avg_enc_ms:.1f}ms net={avg_net_ms:.1f}ms"
            )
            # Reset period counters
            stats_captured = 0
            stats_sent = 0
            stats_skipped = 0
            stats_bytes_sent = 0
            acc_capture_time = 0.0
            acc_encode_time = 0.0
            acc_captured_count = 0
            last_stats_time = now
            stats_period_start = now

        # ── Throttle to target FPS ───────────────────────────────────
        elapsed = time.perf_counter() - t_start
        sleep_time = frame_interval - elapsed
        if sleep_time > 0:
            time.sleep(sleep_time)

    log.info("Capture loop stopped.")


# ══════════════════════════════════════════════════════════════════════
#  HTTP SERVER (MJPEG stream)
# ══════════════════════════════════════════════════════════════════════
def build_index_html(config):
    """Build the HTML viewer page with optional transparency and auto-reconnect."""
    bg = "#000"
    blend_css = ""
    reconnect_js = ""

    # Phase 5: Direct Video Sync optional sections (empty when flag is off)
    direct_css = ""
    direct_html = ""
    direct_popup = ""
    direct_js = ""
    video_fit_line = ""

    if config.direct_video_sync:
        video_blend = ""
        if config.transparency:
            video_blend = "\n      mix-blend-mode: multiply;"

        direct_css = f"""

    #rvs-video {{
      display: none;
      width: 100%;
      height: 100%;
      object-fit: contain;
      background: transparent;
      transition: opacity 0.3s ease;{video_blend}
    }}
    #companion-overlay {{
      display: none;
      position: fixed;
      bottom: 18px;
      left: 50%;
      transform: translateX(-50%);
      background: rgba(0,0,0,0.60);
      color: rgba(255,255,255,0.70);
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      font-size: 12px;
      padding: 4px 14px;
      border-radius: 20px;
      pointer-events: none;
      white-space: nowrap;
      z-index: 5;
    }}
    #companion-overlay.visible {{
      display: block;
    }}
    .lat-btn {{
      width: 34px;
      height: 30px;
      background: rgba(255,255,255,0.1);
      color: rgba(255,255,255,0.8);
      border: 1px solid rgba(255,255,255,0.15);
      border-radius: 6px;
      font-size: 16px;
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      cursor: pointer;
      user-select: none;
      -webkit-user-select: none;
      touch-action: manipulation;
    }}
    .lat-btn:active {{
      background: rgba(255,255,255,0.25);
    }}
    /* ── Debug HUD overlay ── */
    #rvs-dbg-tap {{
      position: fixed;
      top: 0; left: 0;
      width: 52px; height: 52px;
      z-index: 200;
      pointer-events: auto;
      cursor: default;
    }}
    #rvs-dbg {{
      display: none;
      position: fixed;
      top: 8px; left: 8px;
      background: rgba(0,0,0,0.72);
      backdrop-filter: blur(6px);
      -webkit-backdrop-filter: blur(6px);
      color: rgba(255,255,255,0.9);
      font: 11px/1.5 'SF Mono','Menlo','Consolas',monospace;
      border-radius: 7px;
      padding: 5px 10px 6px;
      pointer-events: none;
      z-index: 199;
      border: 1px solid rgba(255,255,255,0.12);
      min-width: 230px;
    }}
    #rvs-dbg.dbg-on {{ display: block; }}
    .dbg-row {{ display: flex; gap: 0; align-items: center; }}
    .dbg-row + .dbg-row {{ border-top: 1px solid rgba(255,255,255,0.08); margin-top: 3px; padding-top: 3px; }}
    .dbg-cell {{ flex: 1; display: flex; flex-direction: column; padding-right: 10px; }}
    .dbg-cell:last-child {{ padding-right: 0; }}
    .dbg-lbl {{ font-size: 8.5px; letter-spacing: 0.6px; color: rgba(255,255,255,0.38); text-transform: uppercase; line-height: 1.2; }}
    .dbg-val {{ font-size: 12px; font-weight: 700; letter-spacing: 0; line-height: 1.4; }}
    .dbg-val.locked {{ color: #4dff91; }}
    .dbg-val.pll    {{ color: #ffd64d; }}
    .dbg-val.seek   {{ color: #ff5f5f; }}
    .dbg-val.dim    {{ color: rgba(255,255,255,0.35); }}
    .dbg-wide       {{ min-width: 60px; }}"""

        direct_html = """
  <video id="rvs-video" playsinline preload="auto" muted></video>
  <div id="companion-overlay">Waiting for REAPER companion script...</div>
  <div id="rvs-dbg-tap"></div>
  <div id="rvs-dbg">
    <div class="dbg-row">
      <div class="dbg-cell"><div class="dbg-lbl">FPS</div><div id="dbg-fps" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">RTT</div><div id="dbg-rtt" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">AGE</div><div id="dbg-age" class="dbg-val dim">—</div></div>
      <div class="dbg-cell dbg-wide"><div class="dbg-lbl">SYNC</div><div id="dbg-sync" class="dbg-val dim">—</div></div>
      <div class="dbg-cell dbg-wide"><div class="dbg-lbl">DRIFT</div><div id="dbg-drift" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">RATE</div><div id="dbg-rate" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">FLUSH</div><div id="dbg-flush" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">BUF</div><div id="dbg-buf" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">DROP</div><div id="dbg-drop" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">SEEKS</div><div id="dbg-seeks" class="dbg-val dim">—</div></div>
      <div class="dbg-cell"><div class="dbg-lbl">PLL</div><div id="dbg-pll" class="dbg-val dim">—</div></div>
    </div>
  </div>"""

        direct_popup = """
    <div style="border-top:1px solid rgba(255,255,255,0.1);margin:6px 0"></div>
    <button class="mode-btn source-btn" data-source="capture">\u25cf Capture</button>
    <button class="mode-btn source-btn" data-source="direct">\u25cb Direct</button>
    <div id="latency-ctrl" style="display:none;border-top:1px solid rgba(255,255,255,0.1);margin:6px 0;padding:6px 4px 2px">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:6px">
        <button id="lat-down" class="lat-btn">\u2212</button>
        <span id="lat-value" style="color:#fff;font-size:13px;font-family:monospace;min-width:52px;text-align:center">0 ms</span>
        <button id="lat-up" class="lat-btn">+</button>
        <button id="lat-reset" class="lat-btn" style="font-size:11px;padding:5px 7px;margin-left:2px">RST</button>
      </div>
      <div style="color:rgba(255,255,255,0.4);font-size:10px;text-align:center;margin-top:3px">Latency Comp (hold to adjust)</div>
    </div>
    <div id="video-selector-ui" style="display:none;border-top:1px solid rgba(255,255,255,0.1);margin:6px 0;padding:6px 4px 2px">
      <div style="color:rgba(255,255,255,0.4);font-size:10px;text-align:center;margin-bottom:5px">Target Video</div>
      <div id="video-select" style="display:flex;flex-direction:column;gap:4px">
        <!-- Buttons injected here -->
      </div>
    </div>"""

        video_fit_line = "\n        var vid = document.getElementById('rvs-video'); if (vid) vid.style.objectFit = fit;"

        direct_js = f"""
  <script>
  (function() {{
    var video = document.getElementById('rvs-video');
    var img = document.getElementById('rvs');
    var overlay = document.getElementById('companion-overlay');
    if (!video) return;

    var SOURCE_KEY = 'rvs_source_mode';
    var POLL_MS = {config.sync_poll_interval};
    var DRIFT_THRESH = {config.drift_threshold};
    var DRIFT_CHECK_MS = {config.drift_check_interval};
    var DRIFT_COOL_MS = {config.drift_cooldown};
    var SEEK_DEBOUNCE = {config.seek_debounce};
    var LATENCY_DEFAULT_MS = {config.latency_comp_ms};
    var LATENCY_MODE = '{config.latency_comp_mode}';
    var LATENCY_KEY = 'rvs_latency_comp_ms';
    var LATENCY_COMP_SEC = (function() {{
      var saved = localStorage.getItem(LATENCY_KEY);
      return saved !== null ? parseInt(saved, 10) / 1000.0 : LATENCY_DEFAULT_MS / 1000.0;
    }})();
    var BLACK_TIMEOUT = {config.black_timeout_sec};
    var BLACK_ACTION = '{config.black_action}';
    var DRIFT_PLL_ENABLED  = {str(config.drift_pll_enabled).lower()}; // slew-rate PLL on/off feature flag
    var DRIFT_PLL_THRESH   = {config.drift_pll_threshold};            // min drift (sec) to activate PLL
    var DRIFT_PLL_GAIN     = {config.drift_pll_gain};                 // proportion of gap closed per second
    var DRIFT_PLL_MAX      = {config.drift_pll_max_rate_mult};        // max speed-up/down multiplier
    var DRIFT_PLL_COOL_MS     = {config.drift_pll_cooldown};          // ms after hard-seek before PLL may fire
    var DRIFT_PLL_EVENT_COOL_MS = {config.drift_pll_event_cool_ms};   // ms after manual event before PLL may fire
    var SEEK_FLUSH_COMP = '{config.seek_flush_comp}';
    var DRIFT_PLL_EXIT_THRESH = {config.drift_pll_exit_thresh};      // drift below which active PLL deactivates (hysteresis exit)
    var DROP_SUPPRESS_THRESH  = {config.drop_pll_suppress};          // max frame drops per drift-check before PLL is suppressed (999 = disabled)
    var PLAY_SEEK_THRESH   = {config.play_seek_threshold};            // threshold for hard seeking during play transition

    var syncActive = false;
    var pollTimer = null;
    var driftTimer = null;
    var lastState = null;
    var lastPollTime = 0;
    var lastSyncDisruption = 0;  // timestamp of last hard seek or major event; gates hard seeks and PLL
    var syncCooldownTarget = 0;  // dynamic cooldown required before PLL can fire again
    var seekDebounceTimer = null;
    // Sync perf stats — accumulated per 30s period, logged once to console
    var _sRttSum = 0; var _sRttN = 0;  // network RTT accumulator
    var _sPllCount = 0; var _sHardSeekCount = 0;  // correction event counters
    var _sFlushMs = -1;  // last decoder flush time from seeked-event measurement (-1 = none this period)
    var _sStatsTimer = null;
    // Debug HUD state
    var _dbgEl = document.getElementById('rvs-dbg');
    var _dbgVisible = localStorage.getItem('rvs_debug_overlay') === '1';
    var _dbgLastDiffMs = 0;    // last computed drift in ms (system target error, updated by checkDrift)
    var _dbgRawSyncMs = 0;     // raw video-vs-REAPER offset in ms (positive=ahead, no comp/dataAge)
    var _dbgDriftState = 'dim'; // CSS class: locked / pll / seek / dim
    var _dbgFlushDisplay = -1; // last decoder flush ms to display
    var _dbgFlushClearAt = 0;  // hide flush value after this timestamp
    var _dbgLastRtt = 0;       // last RTT for HUD
    var _dbgTotalSeeks = 0;    // session-lifetime hard seek counter
    var _dbgTotalPll = 0;      // session-lifetime PLL correction counter
    var _dbgLastDrop = 0;      // last droppedVideoFrames reading for HUD display
    var _dropCheckLast = 0;    // last droppedVideoFrames at checkDrift time (for PLL suppression rate)
    var pllWasActive = false;  // PLL hysteresis state: true = PLL is currently active this session
    var _fpsLastFrameCount = 0; // totalVideoFrames at last checkDrift call
    var _fpsLastFpsTime = 0;   // performance.now() at last checkDrift call
    var _fpsValue = 0;         // last computed video FPS
    if (_dbgVisible && _dbgEl) _dbgEl.classList.add('dbg-on');
    var currentFile = null;
    var noVideoSince = 0;
    var blackHandled = false;
    var fileLoading = false; // true while a new video src is loading (guards opacity reset)
    var fileLoadCanplayHandler = null;
    var fileLoadSeekedHandler = null;
    var fileLoadSafetyTimer = null;
    var lastDataAgeSec = 0; // age of data at time of last poll (for precise drift)
    var latestServerTime = 0; // Fix A: monotonic server_time guard — drop out-of-order responses
    var currentProject = ''; // last known REAPER project name (from companion payload)

    // ── Per-project video preference helpers ──────────────────────────────────
    // Stores a JSON dict keyed by project filename (e.g. "MySong.rpp") so each
    // REAPER project remembers its own video selector choice independently.
    var TARGET_VIDEOS_KEY = 'rvs_target_videos'; // dict key (replaces old scalar 'rvs_target_video')
    var _cachedRawTargetJson = null;
    var _cachedParsedTargetDict = {{}};

    function _getTargetVideo(project) {{
      try {{
        var rawJson = localStorage.getItem(TARGET_VIDEOS_KEY) || '{{}}';
        if (rawJson !== _cachedRawTargetJson) {{
          _cachedParsedTargetDict = JSON.parse(rawJson);
          _cachedRawTargetJson = rawJson;
        }}
        return _cachedParsedTargetDict[project] || 'auto';
      }} catch(e) {{ return 'auto'; }}
    }}
    function _setTargetVideo(project, file) {{
      try {{
        var rawJson = localStorage.getItem(TARGET_VIDEOS_KEY) || '{{}}';
        var dict = JSON.parse(rawJson);
        dict[project] = file;
        var newJson = JSON.stringify(dict);
        localStorage.setItem(TARGET_VIDEOS_KEY, newJson);
        _cachedParsedTargetDict = dict;
        _cachedRawTargetJson = newJson;
      }} catch(e) {{}}
    }}

    // ── Debug HUD ─────────────────────────────────────────────────────
    function _updateDbg(rtt) {{
      if (!_dbgEl || !_dbgVisible) return;
      // FPS (video presentation rate — computed in checkDrift, displayed here)
      var fpsEl = document.getElementById('dbg-fps');
      if (fpsEl) {{
        fpsEl.textContent = _fpsValue > 0 ? _fpsValue : '—';
        fpsEl.className = 'dbg-val';
      }}
      // RTT
      var rttEl = document.getElementById('dbg-rtt');
      if (rttEl && rtt !== undefined) {{ _dbgLastRtt = rtt; rttEl.textContent = rtt + 'ms'; rttEl.className = 'dbg-val'; }}
      else if (rttEl) {{ rttEl.textContent = _dbgLastRtt + 'ms'; rttEl.className = 'dbg-val'; }}
      // AGE (companion data staleness = how old the UDP payload was when HTTP served it)
      var ageEl = document.getElementById('dbg-age');
      if (ageEl) {{ ageEl.textContent = Math.round(lastDataAgeSec * 1000) + 'ms'; ageEl.className = lastDataAgeSec > 0.08 ? 'dbg-val seek' : 'dbg-val'; }}
      // SYNC — raw video position vs REAPER (NO comp, NO dataAge). + = video ahead, - = video behind.
      var syncEl = document.getElementById('dbg-sync');
      if (syncEl) {{
        var rawSign = _dbgRawSyncMs >= 0 ? '+' : '';
        syncEl.textContent = rawSign + Math.round(_dbgRawSyncMs) + 'ms';
        // Green: video within 50ms of REAPER. Yellow: 50-150ms off. Red: >150ms
        syncEl.className = Math.abs(_dbgRawSyncMs) < 50 ? 'dbg-val locked' :
                           Math.abs(_dbgRawSyncMs) < 150 ? 'dbg-val pll' : 'dbg-val seek';
      }}
      // DRIFT — system target error (includes comp+dataAge). Green when PLL locked.
      var dEl = document.getElementById('dbg-drift');
      if (dEl) {{
        var sign = _dbgLastDiffMs >= 0 ? '+' : '';
        dEl.textContent = sign + Math.round(_dbgLastDiffMs) + 'ms';
        dEl.className = 'dbg-val ' + _dbgDriftState;
      }}
      // RATE (highlight yellow when PLL is bending speed)
      var rEl = document.getElementById('dbg-rate');
      if (rEl) {{ var pr = video.playbackRate; rEl.textContent = pr.toFixed(4) + 'x'; rEl.className = Math.abs(pr - 1.0) > 0.0005 ? 'dbg-val pll' : 'dbg-val dim'; }}
      // FLUSH (highlight bright for 8s after a seek, then dim)
      var fEl = document.getElementById('dbg-flush');
      if (fEl) {{
        var now = Date.now();
        fEl.textContent = _dbgFlushDisplay >= 0 ? (_dbgFlushDisplay + 'ms') : '—';
        fEl.className = (_dbgFlushDisplay >= 0 && now < _dbgFlushClearAt) ? 'dbg-val' : 'dbg-val dim';
      }}
      // BUF (seconds of video buffered ahead of playhead)
      var bufEl = document.getElementById('dbg-buf');
      if (bufEl) {{
        var bufSec = 0;
        try {{ if (video.buffered.length > 0) {{ bufSec = video.buffered.end(video.buffered.length - 1) - video.currentTime; bufSec = Math.max(0, bufSec); }} }} catch(e) {{}}
        bufEl.textContent = bufSec.toFixed(1) + 's';
        bufEl.className = bufSec < 2.0 ? 'dbg-val seek' : bufSec < 5.0 ? 'dbg-val pll' : 'dbg-val locked';
      }}
      // DROP (cumulative dropped frames since video element created)
      var dropEl = document.getElementById('dbg-drop');
      if (dropEl) {{
        var totalDrop = 0;
        try {{ var q = video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null; if (q) totalDrop = q.droppedVideoFrames || 0; }} catch(e) {{}}
        _dbgLastDrop = totalDrop;
        dropEl.textContent = totalDrop;
        dropEl.className = totalDrop > 0 ? 'dbg-val seek' : 'dbg-val dim';
      }}
      // SEEKS — session lifetime hard-seek count
      var skEl = document.getElementById('dbg-seeks');
      if (skEl) {{ skEl.textContent = _dbgTotalSeeks; skEl.className = _dbgTotalSeeks > 0 ? 'dbg-val seek' : 'dbg-val dim'; }}
      // PLL — session lifetime PLL correction count
      var plEl = document.getElementById('dbg-pll');
      if (plEl) {{ plEl.textContent = _dbgTotalPll; plEl.className = _dbgTotalPll > 0 ? 'dbg-val pll' : 'dbg-val dim'; }}
    }}
    // Tap/click in top-left corner to toggle HUD
    (function() {{
      var tapEl = document.getElementById('rvs-dbg-tap');
      if (!tapEl) return;
      tapEl.addEventListener('click', function(e) {{
        e.stopPropagation();
        _dbgVisible = !_dbgVisible;
        localStorage.setItem('rvs_debug_overlay', _dbgVisible ? '1' : '0');
        if (_dbgEl) _dbgEl.classList.toggle('dbg-on', _dbgVisible);
      }});
    }})();
    // ───────────────────────────────────────────────────────────────────

    function switchSource(mode) {{
      localStorage.setItem(SOURCE_KEY, mode);
      window._directMode = (mode === 'direct');
      updateSourceBtns(mode);
      if (mode === 'direct') {{
        img.style.display = 'none';
        img.removeAttribute('src');
        video.style.display = 'block';
        video.style.opacity = '0'; // start invisible; first canplay will fade in
        startSync();
      }} else {{
        stopSync();
        video.pause();
        video.removeAttribute('src');
        video.style.display = 'none';
        overlay.classList.remove('visible');
        img.style.display = 'block';
        img.src = '/stream?t=' + Date.now();
      }}
    }}

    function updateSourceBtns(mode) {{
      document.querySelectorAll('.source-btn').forEach(function(btn) {{
        var isActive = btn.dataset.source === mode;
        btn.classList.toggle('active', isActive);
        btn.textContent = (isActive ? '\\u25cf ' : '\\u25cb ') +
          (btn.dataset.source === 'capture' ? 'Capture' : 'Direct');
      }});
    }}

    function startSync() {{
      if (syncActive) return;
      syncActive = true;
      lastState = null;
      currentFile = null;
      noVideoSince = 0;
      blackHandled = false;
      doPoll();
      pollTimer = setInterval(doPoll, POLL_MS);
      driftTimer = setInterval(checkDrift, DRIFT_CHECK_MS);
      _sStatsTimer = setInterval(function() {{
        var rttAvg = _sRttN > 0 ? Math.round(_sRttSum / _sRttN) : -1;
        var flushStr = _sFlushMs >= 0 ? (_sFlushMs + 'ms') : 'n/a';
        console.info('[RVS Sync] rtt_avg=' + rttAvg + 'ms  pll=' + _sPllCount + '  hard_seeks=' + _sHardSeekCount + '  decoder_flush=' + flushStr);
        _sRttSum = 0; _sRttN = 0; _sPllCount = 0; _sHardSeekCount = 0; _sFlushMs = -1;
      }}, 30000);
    }}

    function stopSync() {{
      syncActive = false;
      if (pollTimer)       {{ clearInterval(pollTimer);       pollTimer       = null; }}
      if (driftTimer)      {{ clearInterval(driftTimer);      driftTimer      = null; }}
      if (seekDebounceTimer) {{ clearTimeout(seekDebounceTimer); seekDebounceTimer = null; }}
      if (_sStatsTimer)    {{ clearInterval(_sStatsTimer);    _sStatsTimer    = null; }}
      if (fileLoadCanplayHandler) {{ video.removeEventListener('canplay', fileLoadCanplayHandler); fileLoadCanplayHandler = null; }}
      if (fileLoadSeekedHandler)  {{ video.removeEventListener('seeked', fileLoadSeekedHandler); fileLoadSeekedHandler = null; }}
      if (fileLoadSafetyTimer)    {{ clearTimeout(fileLoadSafetyTimer); fileLoadSafetyTimer = null; }}
      fileLoading = false;
      latestServerTime = 0; // Fix D: reset monotonic guard so fresh sessions are not blocked
      lastSyncDisruption = 0; // reset so PLL/hard-seek gates don't carry over to next session
      syncCooldownTarget = 0;
      pllWasActive = false;    // reset PLL hysteresis state for fresh session
    }}

    function doPoll() {{
      var fetchStart = Date.now();
      fetch('/playback')
        .then(function(r) {{ return r.ok ? r.json() : Promise.reject('err'); }})
        .then(function(data) {{
          var rtt = Date.now() - fetchStart;
          _sRttSum += rtt; _sRttN++;
          // Update HUD RTT and state
          var playingStr = !data.companion_alive ? '\u25a0 no companion' :
                           (data.state & 1) ? '\u25b6 playing' :
                           (data.state & 4) ? '\u25b6\u25b6 recording' :
                           (data.state === 2) ? '\u23f8 paused' : '\u25a0 stopped';
          _updateDbg(rtt);
          // Compute precise data age: how old is this data right now?
          // server_time = when Python generated the response
          // received_at = when Python last got a UDP packet from REAPER
          // data_age = (server_time - received_at) + (rtt / 2)
          //          = time data sat in Python + estimated one-way network transit
          if (data.server_time && data.received_at) {{
            lastDataAgeSec = (data.server_time - data.received_at) + (rtt / 2000.0);
          }} else {{
            lastDataAgeSec = rtt / 2000.0;
          }}
          handleState(data);
        }})
        .catch(function() {{
          overlay.textContent = 'Streamer not responding...';
          overlay.classList.add('visible');
        }});
    }}

    function handleState(data) {{
      var prevPollTime = lastPollTime;
      lastPollTime = Date.now();

      // Fix A: Monotonic server_time guard — drop out-of-order fetch responses.
      // At 250ms poll intervals, two in-flight fetches can resolve in reversed order.
      // An older response arriving late would snap the video backward, causing thrash.
      if (data.server_time) {{
        if (data.server_time <= latestServerTime) return; // stale or duplicate — discard (P3)
        latestServerTime = data.server_time;
      }}

      // --- TARGET VIDEO SCRIPTING OVERRIDE + UI UPDATE ---
      currentProject = data.project || ''; // keep in sync for click handler
      var currentTargetVideo = _getTargetVideo(currentProject);
      var uiSelect = document.getElementById('video-select');
      var uiSelectContainer = document.getElementById('video-selector-ui');
      
      // Update UI dropdown options if list of videos has changed or we haven't set it up
      if (data.all_videos) {{
        if (uiSelectContainer) uiSelectContainer.style.display = 'block';
        if (uiSelect) {{
           // Generate a clean signature of available videos to avoid DOM thrashing
           var videoSig = data.all_videos.map(function(v) {{ return v.file + (v.muted ? "_m" : ""); }}).join("|");
           var foundCurrent = false;
           var selectedOverride = null;

           // Identify if our override target is currently available
           for (var i = 0; i < data.all_videos.length; i++) {{
             var v = data.all_videos[i];
             if (v.file === currentTargetVideo) {{
                 foundCurrent = true;
                 selectedOverride = v;
             }}
           }}

           // Only rebuild the DOM if the available videos actually changed
           if (uiSelect.dataset.sig !== videoSig) {{
               var html = '<button class="vid-btn" data-file="auto" style="text-align:left;padding:10px 8px;border:1px solid rgba(255,255,255,0.2);border-radius:4px;background:rgba(255,255,255,0.1);color:#fff;font-family:inherit;font-size:12px;cursor:pointer;width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">Auto / Active Video</button>';
               for (var j = 0; j < data.all_videos.length; j++) {{
                 var vid = data.all_videos[j];
                 var color = vid.muted ? "color:rgba(255,255,255,0.4);" : "color:#fff;";
                 var mutedName = vid.muted ? "[Muted] " + vid.name : vid.name;
                 html += '<button class="vid-btn" data-file="' + encodeURIComponent(vid.file) + '" style="text-align:left;padding:10px 8px;border:1px solid rgba(255,255,255,0.2);border-radius:4px;background:rgba(255,255,255,0.1);font-family:inherit;font-size:12px;cursor:pointer;width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;' + color + '">' + mutedName + '</button>';
               }}
               uiSelect.innerHTML = html;
               uiSelect.dataset.sig = videoSig;
           }}

           // Update visually selected state (no DOM rebuild)
           var btns = uiSelect.querySelectorAll('.vid-btn');
           for (var k = 0; k < btns.length; k++) {{
               var btnFile = decodeURIComponent(btns[k].dataset.file || "auto");
               if (btnFile === currentTargetVideo) {{
                   btns[k].style.background = 'rgba(255,255,255,0.3)';
                   btns[k].style.borderColor = 'rgba(255,255,255,0.5)';
               }} else {{
                   btns[k].style.background = 'rgba(255,255,255,0.1)';
                   btns[k].style.borderColor = 'rgba(255,255,255,0.2)';
               }}
           }}

           // If chosen video is absent from current payload (cursor moved away from that item),
           // fall back to Auto for this poll WITHOUT touching localStorage — preference is sticky.
           // When the cursor returns to that region, the saved choice is automatically restored.
           if (!foundCurrent && currentTargetVideo !== 'auto') {{
               currentTargetVideo = 'auto'; // local fallback for this poll only
               // Highlight Auto temporarily to reflect current effective behaviour
               for (var k = 0; k < btns.length; k++) {{
                   if (decodeURIComponent(btns[k].dataset.file) === "auto") {{
                       btns[k].style.background = 'rgba(255,255,255,0.3)';
                       btns[k].style.borderColor = 'rgba(255,255,255,0.5)';
                   }}
               }}
           }}

           // Safely override REAPER's payload for the rest of processing
           if (selectedOverride) {{
             data.file = selectedOverride.file;
             data.src_time = selectedOverride.src_time;
             data.rate = selectedOverride.rate;
           }}
        }}
      }} else {{
          if (uiSelectContainer) uiSelectContainer.style.display = 'none';
      }}
      // --------------------------------------------------

      // Companion not running
      if (!data.companion_alive) {{
        overlay.textContent = 'Waiting for REAPER companion script...';
        overlay.classList.add('visible');
        video.pause();
        lastState = data;
        return;
      }}
      overlay.classList.remove('visible');

      // No video item at current position -> Black action
      if (!data.file || data.src_time === null || data.src_time === undefined) {{
        if (noVideoSince === 0) {{
          noVideoSince = Date.now();
          blackHandled = false;
        }}
        if (!blackHandled && (Date.now() - noVideoSince) / 1000 >= BLACK_TIMEOUT) {{
          blackHandled = true;
          video.pause();
          if (BLACK_ACTION === 'close' || BLACK_ACTION === 'clear') {{
            video.style.opacity = '0';
          }}
        }}
        lastState = data;
        return;
      }}

      // Valid video - reset black tracking
      noVideoSince = 0;
      blackHandled = false;
      // Only restore opacity here when NOT mid-load. During a file-change transition the
      // canplay handler owns opacity; setting it to 1 here would cancel the fade-in.
      if (!fileLoading) video.style.opacity = '1';

      // File changed - reload video source
      if (data.file !== currentFile) {{
        currentFile = data.file;
        fileLoading = true;

        if (fileLoadCanplayHandler) {{ video.removeEventListener('canplay', fileLoadCanplayHandler); fileLoadCanplayHandler = null; }}
        if (fileLoadSeekedHandler)  {{ video.removeEventListener('seeked', fileLoadSeekedHandler); fileLoadSeekedHandler = null; }}
        if (fileLoadSafetyTimer)    {{ clearTimeout(fileLoadSafetyTimer); fileLoadSafetyTimer = null; }}

        // Instant hide — no CSS transition on fade-out.
        // The animated 300ms window lets the loading placeholder bleed through at non-zero
        // opacity; in Screen+Invert mode that thin black placeholder inverts to a white bar.
        video.style.transition = 'none';
        void video.offsetWidth; // force reflow so 'none' takes effect before opacity changes
        video.style.opacity = '0';
        video.src = '/video?v=' + encodeURIComponent(currentFile || '');
        video.load();
        
        var onReady = function() {{
          video.removeEventListener('canplay', onReady);
          fileLoadCanplayHandler = null;
          // Note: fileLoading stays true here — the seek is still async.
          
          // Use the freshest available poll data, not the stale closure capture.
          // While this video was loading (100-500ms), polls kept running and updated lastState.
          // The closure's `data` is from when the file change was first detected — potentially
          // 400ms+ stale. lastState holds the most recent poll data. Combined with the
          // wallElapsed extrapolation in applyPlaybackState, this eliminates the systematic
          // 300-400ms drift that previously appeared after every video switch.
          var freshData = lastState || data;
          lastState = null; // force transitionToPlay = true in applyPlaybackState
          applyPlaybackState(freshData);
          lastState = freshData;
          
          // Fade in AFTER seek completes. canplay fires at frame 0 (thin black placeholder);
          // Screen+Invert mode inverts that black to a white bar. 'seeked' fires once
          // the correct frame is decoded. Restore CSS transition first for smooth fade-in.
          var onSeeked = function() {{
            clearTimeout(fileLoadSafetyTimer);
            fileLoadSafetyTimer = null;
            fileLoadSeekedHandler = null;
            fileLoading = false;
            video.style.transition = ''; // restore CSS transition from stylesheet
            requestAnimationFrame(function() {{ video.style.opacity = '1'; }});
          }};
          fileLoadSafetyTimer = setTimeout(function() {{
            video.removeEventListener('seeked', onSeeked);
            fileLoadSafetyTimer = null;
            fileLoadSeekedHandler = null;
            fileLoading = false;
            video.style.transition = '';
            video.style.opacity = '1';
          }}, 500); // 500ms: safe margin over H.265 flush worst-case (~300ms). Also fires fast
                   // for the no-seek edge case (REAPER near pos 0) instead of waiting 1.5s.
                   // If wrong-frame flashes appear on slow seeks, raise toward 1000-1200ms.
          fileLoadSeekedHandler = onSeeked;
          video.addEventListener('seeked', onSeeked, {{ once: true }});
        }};
        fileLoadCanplayHandler = onReady;
        video.addEventListener('canplay', onReady);
        lastState = data;
        return;
      }}

      // If we are still waiting for the video to finish loading, silently update the state cache.
      // This prevents calling video.play() or currentTime on an unloaded object (readyState=0),
      // which queues up buggy executions and throws DOM exceptions.
      if (fileLoading) {{
        lastState = data;
        return;
      }}

      applyPlaybackState(data);
      lastState = data;
    }}

    // Shared helper for Fix 2 compensated seeks
    function performCompensatedSeek(seekTarget, seekRate, isPlayStart) {{
      if (SEEK_FLUSH_COMP === 'off') {{
        // 'off' mode: full old-behavior rollback — 1000ms cooldown intentional
        video.currentTime = seekTarget;
        if (isPlayStart) video.play().catch(function() {{}});
        lastSyncDisruption = Date.now();
        syncCooldownTarget = DRIFT_PLL_COOL_MS;
        return;
      }}
      if (!isPlayStart && SEEK_FLUSH_COMP === 'start') {{
        // 'start' mode scrub: no flush measured — fast 200ms recovery is correct
        video.currentTime = seekTarget;
        lastSyncDisruption = Date.now();
        syncCooldownTarget = DRIFT_PLL_EVENT_COOL_MS;
        return;
      }}
      lastSyncDisruption = Date.now();
      syncCooldownTarget = 86400000; // Block PLL completely while measuring flush
      var seekStart = Date.now();
      
      function _onSeekDone() {{
        clearTimeout(_flushTimeout);
        video.removeEventListener('seeked', _onSeekDone);
        var flushMs = Date.now() - seekStart;
        _sFlushMs = flushMs;
        _dbgFlushDisplay = flushMs; _dbgFlushClearAt = Date.now() + 8000;
        
        var secondSeekTarget = seekTarget + (flushMs / 1000.0) * seekRate;
        var secondSeekFired = false;
        
        function _onSecondSeekDone() {{
          if (secondSeekFired) return;
          secondSeekFired = true;
          clearTimeout(_secondFlushTimeout);
          video.removeEventListener('seeked', _onSecondSeekDone);
          if (isPlayStart) video.play().catch(function() {{}});
          lastSyncDisruption = Date.now();
          syncCooldownTarget = DRIFT_PLL_EVENT_COOL_MS;
        }}
        
        var _secondFlushTimeout = setTimeout(_onSecondSeekDone, 1000);
        video.addEventListener('seeked', _onSecondSeekDone);
        
        video.currentTime = secondSeekTarget;
      }}

      var _flushTimeout = setTimeout(function() {{
        video.removeEventListener('seeked', _onSeekDone);
        if (isPlayStart) video.play().catch(function() {{}});
        lastSyncDisruption = Date.now();
        syncCooldownTarget = DRIFT_PLL_EVENT_COOL_MS;
      }}, 1000); // 1s max wait if seek hangs; call play() if needed so video doesn't stay paused

      video.addEventListener('seeked', _onSeekDone);
      video.currentTime = seekTarget;
    }}

    function applyPlaybackState(data) {{
      var prevPlaying = lastState ? lastState.state : -1;
      // Clamp rate to browser-allowed range
      var safeRate = Math.max(0.0625, Math.min(16, data.rate));

      // REAPER States: 0=Stopped, 1=Playing, 2=Paused, 4=Recording (can be bitwise)
      var isPlaying = (data.state & 1) || (data.state & 4);

      var compTime = data.src_time;
      if (compTime !== null && LATENCY_COMP_SEC !== 0) {{
        if (LATENCY_MODE === 'always' || isPlaying) {{
          compTime += LATENCY_COMP_SEC;
        }}
      }}
      // Position extrapolation: only when actively playing.
      // Uses (wallElapsed + dataAge) * rate — identical to checkDrift's expected-position formula.
      // wallElapsed accounts for time since the last poll arrived (critical when applyPlaybackState
      // is called from the canplay callback after a video-file load, where 200-500ms may have
      // elapsed since the last poll). In normal poll→handleState→applyPlaybackState flow,
      // wallElapsed ≈ 0ms and the result is identical to the old lastDataAgeSec-only formula.
      // When stopped/paused, src_time is a static cursor snapshot — position is not advancing,
      // so no extrapolation (would over-seek and cause thrash).
      if (compTime !== null && isPlaying) {{
        var _wallElapsed = (Date.now() - lastPollTime) / 1000;
        compTime += (_wallElapsed + lastDataAgeSec) * data.rate;
      }}

      if (isPlaying) {{
        // Playing.
        // Only set playbackRate here when REAPER's actual project rate changes (e.g. user moves
        // master playrate knob), or on the very first play transition. During steady-state
        // playback, checkDrift() owns the rate for PLL correction — overwriting it every 200ms
        // would silently undo all PLL adjustments, limiting PLL to only 200ms of effect per
        // 1-second drift check interval.
        var rateChanged = !lastState || Math.abs(data.rate - lastState.rate) > 0.001;
        var transitionToPlay = prevPlaying !== 1 && prevPlaying !== 5;
        if (rateChanged || transitionToPlay) {{
          video.playbackRate = safeRate;
        }}

        if (transitionToPlay) {{
          // Transition to play
          if (Math.abs(video.currentTime - compTime) > PLAY_SEEK_THRESH) {{
            performCompensatedSeek(compTime, safeRate, true);
          }} else {{
            // Close enough — play on warm decoder, no seek needed.
            video.play().catch(function() {{}});
            lastSyncDisruption = Date.now();
            syncCooldownTarget = DRIFT_PLL_EVENT_COOL_MS;
          }}
        }} else if (lastState && Math.abs(data.src_time - lastState.src_time) > 1.0) {{
          // Large position jump while playing = timeline scrub — debounce to avoid stalls
          if (seekDebounceTimer) clearTimeout(seekDebounceTimer);
          seekDebounceTimer = setTimeout(function() {{
            seekDebounceTimer = null;
            performCompensatedSeek(compTime, safeRate, false);
          }}, SEEK_DEBOUNCE);
        }}
        // Update rate if changed
        if (lastState && Math.abs(data.rate - lastState.rate) > 0.001) {{
          video.playbackRate = safeRate;
        }}
      }} else {{
        // Paused (2) or Stopped (0) — use src_time directly, no data_age offset.
        // Fix B: Zero-Thrashing Stopped Seek
        // We only seek if REAPER's time changed since the last poll. We NEVER compare against
        // video.currentTime because it is slow/asynchronous to update mid-seek and causes thrashing.
        //
        // P1: Cancel any pending play-scrub debounce timer. A 255ms timer created during a
        // large jump while playing could fire AFTER stop and seek to a stale playing-state position.
        if (seekDebounceTimer) {{ clearTimeout(seekDebounceTimer); seekDebounceTimer = null; }}
        video.pause();
        var reaperTimeChanged = !lastState || Math.abs(compTime - lastState.src_time) > 0.001;
        if (compTime !== null && reaperTimeChanged) {{
          video.currentTime = compTime;
        }}
      }}
    }}

    function checkDrift() {{
      var isPlaying = lastState && ((lastState.state & 1) || (lastState.state & 4));
      if (!syncActive || !lastState || !isPlaying) return;
      if (video.readyState < 2) return; // not enough data yet

      // Self-heal: REAPER is playing but video.play() was silently aborted (AbortError
      // swallowed by .catch(function(){{}}), typically from concurrent currentTime+play()).
      // prevPlaying stays at 1 so applyPlaybackState never re-calls play().
      // checkDrift is the only catch-all recovery point (runs every DRIFT_CHECK_MS).
      if (video.paused) {{
        video.play().catch(function() {{}});
        return; // skip position correction this cycle; next cycle will assess drift
      }}

      if (seekDebounceTimer) return;

      // Unified cooldown gating:
      // Hard seeks are always gated by DRIFT_COOL_MS to protect the decoder.
      // PLL is gated by syncCooldownTarget (fast recovery for manual events, slow for auto hard-seeks).
      var sinceLastDisruption = Date.now() - lastSyncDisruption;

      // Precise drift computation using data age from RTT measurement
      var wallElapsed = (Date.now() - lastPollTime) / 1000;
      var expected = lastState.src_time + (wallElapsed + lastDataAgeSec) * lastState.rate;
      if (LATENCY_COMP_SEC !== 0 && (LATENCY_MODE === 'always' || isPlaying)) {{
        expected += LATENCY_COMP_SEC;
      }}

      var actual = video.currentTime;
      var diff = expected - actual; // positive if video is behind (needs to speed up)
      var absDrift = Math.abs(diff);
      // Compute raw sync (video vs true REAPER, including dataAge but no latency comp) for SYNC HUD cell
      var _rawReaperNow = lastState.src_time + (wallElapsed + lastDataAgeSec) * lastState.rate;
      _dbgRawSyncMs = (video.currentTime - _rawReaperNow) * 1000; // + = video ahead
      // Update HUD before branching
      // Also compute video FPS from totalVideoFrames delta vs real time elapsed
      (function() {{
        try {{
          var _fq = video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null;
          var _fnow = performance.now();
          if (_fq && _fpsLastFpsTime > 0) {{
            var _fFrames = _fq.totalVideoFrames - _fpsLastFrameCount;
            var _fTime = (_fnow - _fpsLastFpsTime) / 1000;
            _fpsValue = _fTime > 0 ? Math.round(_fFrames / _fTime) : 0;
          }}
          if (_fq) {{ _fpsLastFrameCount = _fq.totalVideoFrames; }}
          _fpsLastFpsTime = _fnow;
        }} catch(e) {{}}
      }})();
      _dbgLastDiffMs = diff * 1000;
      _dbgDriftState = absDrift > DRIFT_THRESH ? 'seek' : absDrift > DRIFT_PLL_THRESH ? 'pll' : 'locked';
      _updateDbg();

      // Drop-aware PLL suppression: if decoder is dropping frames, don't worsen it by demanding
      // higher playback rate. Check drop delta since last drift check.
      var _dropNow = 0;
      try {{ var _q = video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null; if (_q) _dropNow = _q.droppedVideoFrames || 0; }} catch(e) {{}}
      var _dropDelta = Math.max(0, _dropNow - _dropCheckLast);
      _dropCheckLast = _dropNow;
      if (_dropDelta > DROP_SUPPRESS_THRESH) {{
        // Decoder is struggling — restore normal rate, reset PLL, skip PLL this cycle.
        // Hard seeks are still permitted (they flush the decoder to a clean position).
        if (Math.abs(video.playbackRate - lastState.rate) > 0.001) {{
          video.playbackRate = lastState.rate;
        }}
        pllWasActive = false; // suppress PLL during drop storm; re-evaluate from scratch next cycle
        if (absDrift <= DRIFT_THRESH) return;
      }}

      // PLL hysteresis: activate at DRIFT_PLL_THRESH (50ms), stay active until DRIFT_PLL_EXIT_THRESH (20ms).
      // Prevents rapid toggling near the activation boundary — PLL "sticks" until well into dead zone.
      if (pllWasActive) {{
        pllWasActive = (absDrift > DRIFT_PLL_EXIT_THRESH && absDrift < DRIFT_THRESH);
      }} else {{
        pllWasActive = (absDrift > DRIFT_PLL_THRESH && absDrift < DRIFT_THRESH);
      }}

      if (absDrift > DRIFT_THRESH) {{
        // Hard seek: ALWAYS gated by DRIFT_COOL_MS to prevent death spiral.
        if (sinceLastDisruption < DRIFT_COOL_MS) return;
        pllWasActive = false; // reset PLL state — hard seek displaces video, PLL must re-evaluate
        _sHardSeekCount++; _dbgTotalSeeks++;
        video.currentTime = expected;
        video.playbackRate = lastState.rate;
        lastSyncDisruption = Date.now();
        syncCooldownTarget = DRIFT_PLL_COOL_MS;
      }} else if (DRIFT_PLL_ENABLED && pllWasActive) {{
        // PLL: dynamically gated by syncCooldownTarget (Fast Recovery 200ms vs Auto 1000ms).
        if (sinceLastDisruption < syncCooldownTarget) return;
        _sPllCount++; _dbgTotalPll++;
        var pllRate = lastState.rate + (diff * DRIFT_PLL_GAIN);
        var maxRate = lastState.rate * DRIFT_PLL_MAX;
        var minRate = lastState.rate / DRIFT_PLL_MAX;
        video.playbackRate = Math.max(minRate, Math.min(maxRate, pllRate));
      }} else {{
        // Drift in dead zone (or PLL disabled): restore normal rate cleanly.
        if (Math.abs(video.playbackRate - lastState.rate) > 0.001) {{
          video.playbackRate = lastState.rate;
        }}
      }}
    }}

    // Source mode button clicks
    document.querySelectorAll('.source-btn').forEach(function(btn) {{
      btn.addEventListener('click', function(e) {{
        switchSource(btn.dataset.source);
        closePopup();
        e.stopPropagation();
      }});
    }});

    // ── Latency compensation control (hold-to-accelerate +/- buttons) ──
    var latCtrl = document.getElementById('latency-ctrl');
    var latValue = document.getElementById('lat-value');
    var latDown = document.getElementById('lat-down');
    var latUp = document.getElementById('lat-up');
    var latReset = document.getElementById('lat-reset');

    // Video selector — prevent popup from closing when native dropdown opens
    document.getElementById('video-select').addEventListener('click', function(e) {{
        var btn = e.target.closest('.vid-btn');
        if (!btn) {{
            e.stopPropagation(); // Still swallow clicks inside the div so it doesn't close the popup
            return;
        }}
        var file = decodeURIComponent(btn.dataset.file);
        if (file) {{
            _setTargetVideo(currentProject, file);
            e.stopPropagation();
        }}
    }});

    function getLatencyMs() {{
      return Math.round(LATENCY_COMP_SEC * 1000);
    }}

    function setLatencyMs(ms) {{
      ms = Math.max(-2000, Math.min(2000, ms));
      LATENCY_COMP_SEC = ms / 1000.0;
      localStorage.setItem(LATENCY_KEY, String(ms));
      latValue.textContent = (ms >= 0 ? '+' : '') + ms + ' ms';
    }}

    // Show current value on load
    (function() {{
      var ms = getLatencyMs();
      latValue.textContent = (ms >= 0 ? '+' : '') + ms + ' ms';
    }})();

    // Hold-to-accelerate: 10ms per click, accelerates after 400ms hold
    // Acceleration: starts at 10ms steps, ramps to 50ms steps after 1.5s hold
    function setupHold(btn, direction) {{
      var holdTimer = null;
      var accelTimer = null;
      var holdStart = 0;

      function doStep() {{
        var held = Date.now() - holdStart;
        var step = held > 1500 ? 50 : 10;
        setLatencyMs(getLatencyMs() + direction * step);
      }}

      function startHold(e) {{
        e.preventDefault();
        e.stopPropagation();
        holdStart = Date.now();
        setLatencyMs(getLatencyMs() + direction * 10);  // immediate first step
        holdTimer = setTimeout(function() {{
          // After 400ms hold, start repeating
          accelTimer = setInterval(doStep, 80);
        }}, 400);
      }}

      function stopHold(e) {{
        if (e) e.preventDefault();
        if (holdTimer) {{ clearTimeout(holdTimer); holdTimer = null; }}
        if (accelTimer) {{ clearInterval(accelTimer); accelTimer = null; }}
      }}

      btn.addEventListener('pointerdown', startHold);
      btn.addEventListener('pointerup', stopHold);
      btn.addEventListener('pointerleave', stopHold);
      btn.addEventListener('pointercancel', stopHold);
      // Prevent click from also firing (pointerdown already handled it)
      btn.addEventListener('click', function(e) {{ e.stopPropagation(); }});
    }}

    if (latDown && latUp) {{
      setupHold(latDown, -1);
      setupHold(latUp, +1);
    }}
    if (latReset) {{
      latReset.addEventListener('click', function(e) {{
        e.stopPropagation();
        setLatencyMs(LATENCY_DEFAULT_MS);
      }});
    }}

    // Show/hide latency control based on source mode
    function updateLatencyCtrlVisibility(mode) {{
      if (latCtrl) latCtrl.style.display = (mode === 'direct') ? 'block' : 'none';
    }}

    // Patch switchSource to also toggle latency control
    var _origSwitchSource = switchSource;
    switchSource = function(mode) {{
      _origSwitchSource(mode);
      updateLatencyCtrlVisibility(mode);
    }};

    // Apply saved mode on load
    var saved = localStorage.getItem(SOURCE_KEY) || 'capture';
    window._directMode = (saved === 'direct');
    updateSourceBtns(saved);
    updateLatencyCtrlVisibility(saved);
    if (saved === 'direct') {{
      switchSource('direct');
    }}
  }})();
  </script>"""

    if config.transparency:
        bg = config.bg_color
        blend_css = "\n      mix-blend-mode: multiply;"

    if config.auto_reconnect:
        reconnect_js = f"""
  <script>
    (function() {{
      var img = document.getElementById('rvs');
      var interval = {config.reconnect_interval};
      var polling = false;
      var streamOk = false;

      // Mark stream as healthy and show UI when it starts painting frames
      img.addEventListener('load', function() {{ 
        streamOk = true; 
        img.style.opacity = '1';
      }});

      function reloadStream() {{
        streamOk = false;
        // The ?t= cache-buster is required to force mobile/desktop browsers to actually re-request the src!
        img.src = '/stream?t=' + new Date().getTime();
        polling = false;
      }}

      function startPolling() {{
        if (polling) return;
        if (window._directMode) return;
        img.style.opacity = '0'; // instantly hide the frozen frame natively
        polling = true;
        streamOk = false;
        poll();
      }}

      function poll() {{
        fetch('/status')
          .then(function(r) {{ return r.ok ? r.json() : Promise.reject('HTTP Error'); }})
          .then(function(data) {{
            // ONLY reconnect if server reports stream is actively receiving frames.
            if (data.running && data.stream_state === 'active') {{
              reloadStream();
            }} else {{
              // Server is up but stream is idle/black. Keep polling silently.
              setTimeout(poll, interval);
            }}
          }})
          .catch(function() {{
            // Server dead — keep polling
            setTimeout(poll, interval);
          }});
      }}

      // Trigger when stream errors (connection dropped via Python "close" action)
      img.addEventListener('error', startPolling);

      // Fallback interval: covers cases where error event doesn't fire (browser quirks)
      setInterval(function() {{
        if (window._directMode) return;
        fetch('/status')
          .then(function(r) {{ return r.ok ? r.json() : Promise.reject('HTTP Error'); }})
          .then(function(data) {{
            // If stream appears completely dead but server says it's active
            if (data.running && data.stream_state === 'active' && !streamOk && !polling) {{
              reloadStream();
            }} else if (data.stream_state !== 'active') {{
              // Server tells us stream is dead (idle/black/closed), so force hide if not already
              startPolling();
            }}
          }})
          .catch(function() {{
            startPolling();
          }});
      }}, interval);
    }})();
  </script>"""

    return f"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <title>REAPER Video Monitor</title>
  <style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    html, body {{ width: 100%; height: 100%; background: {bg}; overflow: hidden;
             animation: rvs-fadein 0.3s ease; }}
    @keyframes rvs-fadein {{ from {{ opacity: 0; }} to {{ opacity: 1; }} }}

    #rvs {{
      display: block;
      width: 100%;
      height: 100%;
      object-fit: contain;
      transition: opacity 0.3s ease;
      opacity: 0;{blend_css}
    }}{direct_css}

    /* Invisible tap zone — bottom-right corner */
    #tap-zone {{
      position: fixed;
      bottom: 0;
      right: 0;
      width: 80px;
      height: 80px;
      z-index: 10;
      /* Completely transparent — no background, no border */
    }}

    /* Display mode picker popup */
    #mode-popup {{
      display: none;
      position: fixed;
      bottom: 90px;
      right: 12px;
      background: rgba(20, 20, 20, 0.92);
      border: 1px solid rgba(255,255,255,0.15);
      border-radius: 10px;
      padding: 8px 6px;
      z-index: 20;
      backdrop-filter: blur(8px);
    }}
    #mode-popup.open {{ display: block; }}

    .mode-btn {{
      display: block;
      width: 100%;
      padding: 9px 18px;
      margin: 2px 0;
      background: transparent;
      color: rgba(255,255,255,0.7);
      border: none;
      border-radius: 6px;
      font-size: 14px;
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      text-align: left;
      cursor: pointer;
      white-space: nowrap;
    }}
    .mode-btn:hover {{ background: rgba(255,255,255,0.1); color: #fff; }}
    .mode-btn.active {{ background: rgba(255,255,255,0.18); color: #fff; font-weight: 600; }}
  </style>
</head>
<body>
  <img id="rvs" src="/stream" alt="REAPER Video">{direct_html}

  <!-- Invisible tap zone — bottom-right corner -->
  <div id="tap-zone"></div>

  <!-- Display mode picker -->
  <div id="mode-popup">
    <button class="mode-btn" data-fit="contain">Contain</button>
    <button class="mode-btn" data-fit="cover">Cover</button>
    <button class="mode-btn" data-fit="fill">Fill</button>
    <button class="mode-btn" data-fit="none">Native</button>{direct_popup}
  </div>

  <script>
    (function() {{
      var img   = document.getElementById('rvs');
      var popup = document.getElementById('mode-popup');
      var zone  = document.getElementById('tap-zone');
      var STORAGE_KEY = 'rvs_display_mode';
      var POPUP_AUTO_FADE_MS = 4000; // ms before the settings popup auto-closes if left open
      var popupFadeTimer = null;

      function openPopup() {{
        popup.classList.add('open');
        clearTimeout(popupFadeTimer);
        popupFadeTimer = setTimeout(closePopup, POPUP_AUTO_FADE_MS);
      }}
      function closePopup() {{
        clearTimeout(popupFadeTimer);
        popupFadeTimer = null;
        popup.classList.remove('open');
      }}

      // Apply saved mode on load
      var saved = localStorage.getItem(STORAGE_KEY) || 'contain';
      applyMode(saved);

      function applyMode(fit) {{
        img.style.objectFit = fit;{video_fit_line}
        localStorage.setItem(STORAGE_KEY, fit);
        document.querySelectorAll('.mode-btn').forEach(function(btn) {{
          btn.classList.toggle('active', btn.dataset.fit === fit);
        }});
      }}

      // Toggle popup on tap zone press
      zone.addEventListener('click', function(e) {{
        if (popup.classList.contains('open')) {{ closePopup(); }} else {{ openPopup(); }}
        e.stopPropagation();
      }});

      // Mode button clicks — close immediately (no need to wait for auto-fade)
      document.querySelectorAll('.mode-btn').forEach(function(btn) {{
        btn.addEventListener('click', function(e) {{
          applyMode(btn.dataset.fit);
          closePopup();
          e.stopPropagation();
        }});
      }});

      // Dismiss popup on tap anywhere else
      document.addEventListener('click', function() {{
        closePopup();
      }});

      // Triple-tap to enter/exit fullscreen natively
      var taps = [];
      document.addEventListener('pointerup', function(e) {{
        var now = Date.now();
        taps = taps.filter(function(t) {{ return now - t < 600; }});
        taps.push(now);
        if (taps.length === 3) {{
          taps = [];
          
          if (window.parent !== window) {{
            // Safely teleport the gesture to the SyncLyrics parent
            window.parent.postMessage({{ type: 'rvs-triple-tap' }}, '*');
          }} else {{
            // We are being viewed naked in a browser tab
            var doc = window.document;
            var docEl = doc.documentElement;
            var req = docEl.requestFullscreen || docEl.webkitRequestFullscreen;
            var ext = doc.exitFullscreen || doc.webkitExitFullscreen;
            
            if(!doc.fullscreenElement && !doc.webkitFullscreenElement) {{
              if (req) req.call(docEl);
            }} else {{
              if (ext) ext.call(doc);
            }}
          }}
        }}
      }});
    }})();
  </script>{reconnect_js}{direct_js}
</body>
</html>
"""


class StreamHandler(BaseHTTPRequestHandler):
    """HTTP request handler for MJPEG streaming and HTML viewer."""

    server_config = None       # Set in main() before server starts
    _index_html = None         # Cached rendered HTML bytes

    _viewer_lock = threading.Lock()
    _viewer_event = threading.Event()
    _stream_viewers = 0
    transparent_viewers = 0    # Maintained for capture_loop logic

    _stats_lock = threading.Lock()
    _stats_net_time = 0.0
    _stats_net_frames = 0

    def do_GET(self):
        # Strip query string (e.g. cache-buster ?t=... from reconnect JS)
        path = self.path.split('?')[0]
        if path in ("/", "/index.html"):
            self._serve_index()
        elif path == "/stream":
            self._serve_stream()
        elif path == "/transparent":
            self._serve_transparent()
        elif path == "/snapshot":
            self._serve_snapshot()
        elif path == "/status":
            self._serve_status()
        elif path == "/playback":
            self._serve_playback()
        elif path == "/video":
            self._serve_video()
        else:
            self.send_error(404)

    def _serve_index(self):
        """Serve the HTML viewer page."""
        if StreamHandler._index_html is None:
            StreamHandler._index_html = build_index_html(
                StreamHandler.server_config
            ).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(StreamHandler._index_html)))
        self.end_headers()
        self.wfile.write(StreamHandler._index_html)

    def _serve_stream(self):
        """Serve the MJPEG stream. Each connected client gets its own thread."""
        if not StreamHandler.server_config.capture_mode_enabled:
            self.send_error(503, "Mode A (screen capture) is disabled")
            return
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "multipart/x-mixed-replace; boundary=frameboundary",
        )
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()

        with StreamHandler._viewer_lock:
            StreamHandler._stream_viewers += 1
            StreamHandler._viewer_event.set()

        try:
            frame_id = 0
            while not _shutdown_event.is_set():
                frame, _, frame_id = frame_buffer.get(last_id=frame_id, timeout=2.0)
                if frame is None:
                    continue

                t_net_start = time.perf_counter()

                # Batch write to minimize TCP packets
                header = (
                    BOUNDARY + b"\r\n" +
                    b"Content-Type: image/jpeg\r\n" +
                    f"Content-Length: {len(frame)}\r\n\r\n".encode("utf-8")
                )
                self.wfile.write(header)
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
                self.wfile.flush()

                net_time = time.perf_counter() - t_net_start
                with StreamHandler._stats_lock:
                    StreamHandler._stats_net_time += net_time
                    StreamHandler._stats_net_frames += 1
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # Client disconnected — normal for streaming
        finally:
            with StreamHandler._viewer_lock:
                StreamHandler._stream_viewers -= 1
                if StreamHandler._stream_viewers == 0 and StreamHandler.transparent_viewers == 0:
                    StreamHandler._viewer_event.clear()

    def _serve_transparent(self):
        """Serve MJPEG with white pixels keyed to alpha=0, as PNG frames.

        PNG is generated once per frame in capture_loop on the raw (pre-JPEG) array,
        so there are no JPEG ringing artifacts. This handler is thin: it reads
        pre-computed png_bytes from FrameBuffer and streams them out.

        transparent_viewers signals capture_loop to generate PNGs. The finally block
        always decrements it, handling both clean close and abrupt disconnect.
        """
        if not StreamHandler.server_config.white_key_stream:
            self.send_error(404, "White-key stream disabled (WHITE_KEY_STREAM=False)")
            return

        with StreamHandler._viewer_lock:
            StreamHandler.transparent_viewers += 1
            StreamHandler._viewer_event.set()

        self.send_response(200)
        self.send_header(
            "Content-Type",
            "multipart/x-mixed-replace; boundary=frameboundary",
        )
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()

        try:
            frame_id = 0
            while not _shutdown_event.is_set():
                _, png_frame, frame_id = frame_buffer.get(last_id=frame_id, timeout=2.0)
                if png_frame is None:
                    continue  # PNG not generated yet (viewer just connected)

                t_net_start = time.perf_counter()

                # Batch write to minimize TCP packets
                header = (
                    BOUNDARY + b"\r\n" +
                    b"Content-Type: image/png\r\n" +
                    f"Content-Length: {len(png_frame)}\r\n\r\n".encode("utf-8")
                )
                self.wfile.write(header)
                self.wfile.write(png_frame)
                self.wfile.write(b"\r\n")
                self.wfile.flush()

                net_time = time.perf_counter() - t_net_start
                with StreamHandler._stats_lock:
                    StreamHandler._stats_net_time += net_time
                    StreamHandler._stats_net_frames += 1
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # client disconnected — normal for streaming
        finally:
            with StreamHandler._viewer_lock:
                StreamHandler.transparent_viewers = max(0, StreamHandler.transparent_viewers - 1)
                if StreamHandler._stream_viewers == 0 and StreamHandler.transparent_viewers == 0:
                    StreamHandler._viewer_event.clear()

    def _serve_snapshot(self):
        """Serve a single JPEG snapshot of the current frame."""
        frame = frame_buffer.latest
        if frame:
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.end_headers()
            self.wfile.write(frame)
        else:
            self.send_error(503, "No frame available yet")

    def _serve_status(self):
        """JSON health check endpoint for companion scripts."""
        status = {
            "running": True,
            "port": StreamHandler.server_config.port if StreamHandler.server_config else PORT,
            "has_frame": frame_buffer.latest is not None,
            "stream_state": frame_buffer.stream_state
        }
        content = json.dumps(status).encode("utf-8")
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    _playback_count = 0
    _video_serve_count = 0
    _video_bytes_served = 0
    _video_cache_hits = 0
    _last_playback_log = time.time()
    _last_companion_alive = None

    def _serve_playback(self):
        """JSON endpoint returning current REAPER playback state from companion script."""
        if not StreamHandler.server_config.direct_video_sync:
            self.send_error(404, "Direct video sync disabled")
            return

        state = companion_state.get()
        content = json.dumps(state).encode("utf-8")
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

        # ── Mode B 30-second rolling stats ──
        cls = StreamHandler
        cls._playback_count += 1
        log = logging.getLogger("rvs")

        # Log companion alive/dead transitions immediately (rare, high-value)
        alive = state.get("companion_alive", False)
        if cls._last_companion_alive is not None and alive != cls._last_companion_alive:
            log.info("[Mode B] Companion %s", "connected" if alive else "LOST")
        cls._last_companion_alive = alive

        now = time.time()
        if now - cls._last_playback_log >= 30.0:
            elapsed = now - cls._last_playback_log
            state_names = {0: "Stopped", 1: "Playing", 2: "Paused", 4: "Recording", 5: "Play+Rec"}
            ps = state.get("state", -1)
            fname = state.get("file")
            projname = state.get("project", "")
            short_file = os.path.basename(fname) if fname else "(none)"
            log.info("[Mode B] %ds: polls=%d video_reqs=%d (%.1f MB) cache_hits=%d | companion=%s state=%s rate=%.2f proj=%s file=%s",
                     int(elapsed), cls._playback_count, cls._video_serve_count,
                     cls._video_bytes_served / (1024 * 1024),
                     cls._video_cache_hits,
                     "alive" if alive else "DEAD",
                     state_names.get(ps, str(ps)),
                     state.get("rate", 0),
                     projname or "(unsaved)",
                     short_file)
            cls._playback_count = 0
            cls._video_serve_count = 0
            cls._video_bytes_served = 0
            cls._video_cache_hits = 0
            cls._last_playback_log = now

    def _serve_video(self):
        """Serve the current video file with HTTP Range support for browser seeking."""
        if not StreamHandler.server_config.direct_video_sync:
            self.send_error(404, "Direct video sync disabled")
            return

        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        filepath = qs.get("v", [None])[0]

        state = companion_state.get()
        if not filepath:
            filepath = state.get("file")

        if not filepath:
            self.send_error(404, "No video file active")
            return

        fpath = Path(filepath)
        if not fpath.is_file():
            self.send_error(404, "Video file not found on disk")
            return

        stat = fpath.stat()
        file_size = stat.st_size
        mtime = int(stat.st_mtime)
        etag = f'"{mtime}-{file_size}"'

        if self.headers.get("If-None-Match") == etag:
            StreamHandler._video_cache_hits += 1
            self.send_response(304)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            return

        StreamHandler._video_serve_count += 1
        ext = fpath.suffix.lower()
        mime_map = {
            ".mp4": "video/mp4", ".m4v": "video/mp4",
            ".webm": "video/webm", ".mov": "video/quicktime",
            ".avi": "video/x-msvideo", ".mkv": "video/x-matroska",
            ".ts": "video/mp2t", ".mts": "video/mp2t", ".m2ts": "video/mp2t",
        }
        content_type = mime_map.get(ext, "application/octet-stream")

        range_header = self.headers.get("Range")
        try:
            if range_header:
                # Parse "bytes=START-END" or "bytes=START-"
                range_spec = range_header.replace("bytes=", "").strip()
                parts = range_spec.split("-")
                start = int(parts[0])
                end = int(parts[1]) if parts[1] else file_size - 1
                end = min(end, file_size - 1)

                if start > end or start >= file_size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{file_size}")
                    self.end_headers()
                    return

                length = end - start + 1
                self.send_response(206)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(length))
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("ETag", etag)
                self.send_header("Cache-Control", "public, max-age=3600")
                self.end_headers()

                with open(fpath, "rb") as f:
                    f.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = f.read(min(remaining, 65536))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
                StreamHandler._video_bytes_served += length
            else:
                # Full file response
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(file_size))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("ETag", etag)
                self.send_header("Cache-Control", "public, max-age=3600")
                self.end_headers()

                with open(fpath, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # Client cancelled request (e.g. during seek) — normal
        except (ValueError, IndexError):
            self.send_error(416, "Invalid Range header")

    def log_message(self, format, *args):
        # Suppress default per-request logging (too noisy for streaming)
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Multi-client HTTP server. Each connection runs in its own daemon thread."""
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        super().server_bind()
        if hasattr(StreamHandler, 'server_config') and StreamHandler.server_config and StreamHandler.server_config.tcp_nodelay:
            self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


# ══════════════════════════════════════════════════════════════════════
#  CONFIGURATION & CLI
# ══════════════════════════════════════════════════════════════════════
class Config:
    """Runtime configuration merged from file-level defaults + CLI arguments."""

    def __init__(self, args=None):
        self.port = PORT
        self.fps = TARGET_FPS
        self.quality = JPEG_QUALITY
        self.scale = SCALE
        self.window_title = VIDEO_WINDOW_TITLE
        self.adaptive = ADAPTIVE_FPS
        self.adaptive_method = ADAPTIVE_FPS_METHOD
        self.change_threshold = CHANGE_THRESHOLD_SUM
        self.crop = AUTO_CROP_BLACK_BARS
        self.transparency = TRANSPARENCY_MODE
        self.white_key_stream = WHITE_KEY_STREAM
        self.capture_mode_enabled = CAPTURE_MODE_ENABLED
        self.bg_color = BACKGROUND_COLOR
        self.auto_reconnect = AUTO_RECONNECT
        self.reconnect_interval = RECONNECT_INTERVAL_MS
        self.log_level = LOG_LEVEL
        self.hwnd = None

        self.window_scan_interval_sec = WINDOW_SCAN_INTERVAL_SEC
        self.idle_timeout_sec = IDLE_TIMEOUT_SEC
        self.idle_action = IDLE_ACTION
        self.black_timeout_sec = BLACK_TIMEOUT_SEC
        self.black_action = BLACK_ACTION
        self.idle_clear_color = IDLE_CLEAR_COLOR
        self.tcp_nodelay = TCP_NODELAY
        self.force_opencv = FORCE_OPENCV

        # Phase 5: Direct Video Sync
        self.direct_video_sync = DIRECT_VIDEO_SYNC
        self.companion_udp_port = COMPANION_UDP_PORT
        self.companion_timeout_sec = COMPANION_TIMEOUT_SEC
        self.sync_poll_interval = SYNC_POLL_INTERVAL_MS
        self.drift_threshold = DRIFT_THRESHOLD_SEC
        self.drift_check_interval = DRIFT_CHECK_INTERVAL_MS
        self.drift_cooldown = DRIFT_COOLDOWN_MS
        self.seek_debounce = SEEK_DEBOUNCE_MS
        self.latency_comp_ms = LATENCY_COMP_MS
        self.latency_comp_mode = LATENCY_COMP_MODE
        self.play_seek_threshold = PLAY_SEEK_THRESHOLD_SEC
        self.drift_pll_enabled = DRIFT_PLL_ENABLED
        self.drift_pll_threshold = DRIFT_PLL_THRESHOLD_SEC
        self.drift_pll_gain = DRIFT_PLL_GAIN
        self.drift_pll_max_rate_mult = DRIFT_PLL_MAX_RATE_MULT
        self.drift_pll_cooldown = DRIFT_PLL_COOLDOWN_MS
        self.drift_pll_event_cool_ms = DRIFT_PLL_EVENT_COOL_MS
        self.drift_pll_exit_thresh = DRIFT_PLL_EXIT_THRESH_SEC
        self.seek_flush_comp = SEEK_FLUSH_COMPENSATION
        self.drop_pll_suppress = DROP_PLL_SUPPRESS_THRESH

        # CLI overrides
        if args:
            if args.port is not None:
                self.port = args.port
            if args.fps is not None:
                self.fps = args.fps
            if args.quality is not None:
                self.quality = args.quality
            if args.hwnd is not None:
                self.hwnd = args.hwnd
            if args.no_adaptive:
                self.adaptive = False
            if args.adaptive_method is not None:
                self.adaptive_method = args.adaptive_method
            if args.change_threshold is not None:
                self.change_threshold = args.change_threshold
            if args.no_crop:
                self.crop = False
            if args.transparent:
                self.transparency = True
            if args.no_white_key:
                self.white_key_stream = False
            if args.no_nagle:
                self.tcp_nodelay = True
            if args.force_opencv:
                self.force_opencv = True
            if args.idle_action:
                self.idle_action = args.idle_action
            if args.black_action:
                self.black_action = args.black_action
            if args.log_level:
                self.log_level = args.log_level
            if args.direct_sync:
                self.direct_video_sync = True
            
            # Additional Phase 5 configs (with backwards compatibility check)
            if hasattr(args, "latency_comp") and args.latency_comp is not None:
                self.latency_comp_ms = args.latency_comp
            if hasattr(args, "latency_mode") and args.latency_mode:
                self.latency_comp_mode = args.latency_mode
            if hasattr(args, "play_seek_threshold") and args.play_seek_threshold is not None:
                self.play_seek_threshold = args.play_seek_threshold


def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Stream REAPER's Video Window to your tablet over HTTP"
    )
    parser.add_argument("--port", type=int,
                        help=f"HTTP port (default: {PORT})")
    parser.add_argument("--fps", type=int,
                        help=f"Max FPS (default: {TARGET_FPS})")
    parser.add_argument("--quality", type=int,
                        help=f"JPEG quality 1-100 (default: {JPEG_QUALITY})")
    parser.add_argument("--hwnd", type=lambda x: int(x, 0),
                        help="Video window handle (hex or decimal), skips auto-detection")
    parser.add_argument("--no-adaptive", action="store_true",
                        help="Disable adaptive frame rate")
    parser.add_argument("--adaptive-method", choices=["exact", "diff"],
                        help=f"Adaptive FPS comparison method (default: {ADAPTIVE_FPS_METHOD})")
    parser.add_argument("--change-threshold", type=int,
                        help=f"Pixel diff sum threshold for 'diff' method (default: {CHANGE_THRESHOLD_SUM})")
    parser.add_argument("--no-crop", action="store_true",
                        help="Disable black bar cropping")
    parser.add_argument("--transparent", action="store_true",
                        help="Enable transparency mode (CSS mix-blend-mode:multiply)")
    parser.add_argument("--no-white-key", action="store_true",
                        help="Disable the /transparent white-key PNG stream endpoint")
    parser.add_argument("--no-nagle", action="store_true",
                        help="Disable Nagle's Algorithm for lower latency (TCP_NODELAY)")
    parser.add_argument("--force-opencv", action="store_true",
                        help="Disable simplejpeg and force OpenCV encoding")
    parser.add_argument("--idle-action", choices=["hold", "clear", "close"],
                        help=f"Behavior when window is closed (default: {IDLE_ACTION})")
    parser.add_argument("--black-action", choices=["hold", "clear", "close"],
                        help=f"Behavior when window is pure black (default: {BLACK_ACTION})")
    parser.add_argument("--log-level", choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                        help=f"Log level (default: {LOG_LEVEL})")
    parser.add_argument("--direct-sync", action="store_true",
                        help="Enable Phase 5 direct video sync (requires companion script in REAPER)")
    parser.add_argument("--latency-comp", type=int,
                        help=f"Direct sync latency compensation in ms (default: {LATENCY_COMP_MS})")
    parser.add_argument("--latency-mode", choices=["always", "playback"],
                        help=f"When to apply latency compensation (default: {LATENCY_COMP_MODE})")
    parser.add_argument("--play-seek-threshold", type=float,
                        help=f"Seconds of drift allowed before forcing a seek on play transition (default: {PLAY_SEEK_THRESHOLD_SEC})")
    return parser.parse_args()


# ══════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════
def get_local_ip():
    """Best-effort local LAN IP detection."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def write_pid_file():
    """Write PID file for companion scripts (e.g. REAPER Lua launcher)."""
    try:
        PID_FILE.write_text(str(os.getpid()))
    except Exception:
        pass


def remove_pid_file():
    """Remove PID file on shutdown."""
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass


def main():
    args = parse_args()
    config = Config(args)
    log = setup_logging(config.log_level)

    # Set config on handler class before server starts
    StreamHandler.server_config = config

    local_ip = get_local_ip()

    # Feature summary for banner
    features = []
    if config.adaptive:
        if config.adaptive_method == "diff":
            features.append(f"adaptive-fps(diff:{config.change_threshold})")
        else:
            features.append("adaptive-fps(exact)")
    if config.crop:
        features.append("auto-crop")
    if config.transparency:
        features.append("transparency")
    if config.white_key_stream:
        features.append("white-key-stream")
        
    if config.direct_video_sync:
        features.append("direct-video-sync")

    if HAS_SIMPLEJPEG and not config.force_opencv:
        features.append("jpeg(turbo:444)")
    else:
        features.append("jpeg(cv2:444)")
        
    features_str = ", ".join(features) if features else "none"

    print("=" * 60)
    print("  REAPER Video Window Streamer")
    print("=" * 60)
    print(f"  Target window : \"{config.window_title}\"")
    print(f"  Max FPS       : {config.fps}")
    print(f"  JPEG quality  : {config.quality}")
    print(f"  Scale         : {config.scale}")
    print(f"  Port          : {config.port}")
    print(f"  Features      : {features_str}")
    print(f"  Log level     : {config.log_level}")
    print()
    print(f"  Open on your tablet:")
    print(f"     http://{local_ip}:{config.port}")
    print()
    print(f"  Endpoints:")
    print(f"     /          HTML viewer (fullscreen)")
    print(f"     /stream    Raw MJPEG stream")
    if config.white_key_stream:
        print(f"     /transparent  White pixels → alpha=0 (PNG frames, true transparency)")
    if config.direct_video_sync:
        print(f"     /playback  REAPER companion state (JSON)")
        print(f"     /video     Source video file (Range support)")
    print(f"     /snapshot  Single JPEG snapshot")
    print(f"     /status    JSON health check")
    print()
    print("  Press Ctrl+C to stop.")
    print("=" * 60)
    print()

    log.info(f"Starting on port {config.port}, features: {features_str}")

    write_pid_file()

    # Start UDP listener for Phase 5 companion script (only when enabled)
    udp_thread = None
    if config.direct_video_sync:
        companion_state._timeout_sec = config.companion_timeout_sec
        udp_thread = threading.Thread(
            target=udp_listener,
            args=(companion_state, config.companion_udp_port, _shutdown_event),
            daemon=True
        )
        udp_thread.start()

    # Start capture thread
    capture_thread = threading.Thread(target=capture_loop, args=(config,), daemon=True)
    capture_thread.start()

    # Start HTTP server
    try:
        server = ThreadedHTTPServer(("0.0.0.0", config.port), StreamHandler)
    except OSError as e:
        log.error(f"Cannot bind to port {config.port}: {e}")
        log.error("Is another instance already running?")
        remove_pid_file()
        sys.exit(1)

    log.info(f"HTTP server listening on 0.0.0.0:{config.port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Ctrl+C received.")
    finally:
        _shutdown_event.set()
        frame_buffer.shutdown()  # Wake any clients waiting for frames
        server.server_close()
        capture_thread.join(timeout=3.0)
        remove_pid_file()
        log.info("Server stopped. Goodbye.")


if __name__ == "__main__":
    main()
