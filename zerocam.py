"""
Shared code for the Pi Zero e-Paper camera: settings, photo storage,
capture, image processing for the 6-color panel and the display itself.

Used by camera_to_epaper.py (command line) and zero_cam_server.py
(web interface and photo triggers).
"""

import configparser
import fcntl
import json
import re
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

# Pillow is imported inside the functions: it takes seconds to load on the
# Pi Zero W, and the web server sets up the button before it is needed.

# Visible orientation of the display (landscape)
VISUAL_WIDTH = 600
VISUAL_HEIGHT = 400

CONFIG_PATH = Path(os.environ.get("ZERO_CAM_CONFIG", Path.home() / "zero-cam.conf"))
# Settings changed in the web interface; read after zero-cam.conf and take precedence
WEB_CONFIG_PATH = CONFIG_PATH.with_name("zero-cam-web.conf")

DEFAULTS = {
    "camera": {
        "width": "1200",
        "height": "800",
        # 180 if the camera is mounted upside down
        "rotation": "0",
        # time for autofocus/exposure in ms
        "timeout_ms": "1500",
        # Lens shading correction of the camera software. On the Pi Zero W it
        # paints pink/green bands into the photos, so it is off by default.
        "lens_shading": "off",
    },
    "display": {
        # If the image on the display is upside down, use -90 instead of 90
        "rotation": "90",
        # Waveshare: at least 180 s between refreshes
        "min_refresh_interval": "180",
    },
    "image": {
        # 0 = ideal palette (more contrast), 1 = measured panel colors (more detail)
        "palette_blend": "0.6",
        "brightness": "1.2",
        "contrast": "1.0",
        "saturation": "1.2",
        # percent of the darkest/brightest pixels cut off by auto contrast
        "autocontrast_cutoff": "1",
    },
    "storage": {
        "photo_dir": str(Path.home() / "photos"),
    },
    "triggers": {
        # GPIO numbers (BCM), empty = off
        "button_gpio": "26",
        "motion_gpio": "",
        # minutes between automatic photos, 0 = off
        "interval_minutes": "0",
    },
    "web": {
        "port": "8080",
    },
}


def load_config(path=CONFIG_PATH):
    config = configparser.ConfigParser()
    config.read_dict(DEFAULTS)
    config.read([path, WEB_CONFIG_PATH])
    return config


def save_web_setting(section, key, value):
    """Store a setting from the web interface (keeps zero-cam.conf and its comments untouched)."""
    web = configparser.ConfigParser()
    web.read(WEB_CONFIG_PATH)
    if not web.has_section(section):
        web.add_section(section)
    web[section][key] = str(value)
    with open(WEB_CONFIG_PATH, "w") as f:
        f.write("# Written by the web interface, overrides zero-cam.conf\n")
        web.write(f)


# --- Waveshare library -------------------------------------------------------
def _find_epd_lib():
    """Locate the Waveshare library BEFORE importing it."""
    if os.environ.get("EPD_LIB"):
        return os.environ["EPD_LIB"]
    bases = [Path.home()]
    if os.environ.get("SUDO_USER"):
        bases.append(Path("/home") / os.environ["SUDO_USER"])
    for base in bases:
        for hit in (base / "4inch_e-Paper_E").glob("**/waveshare_epd"):
            return str(hit.parent)
    return None


def _epd_module():
    lib = _find_epd_lib()
    if lib and lib not in sys.path:
        sys.path.insert(0, lib)
    from waveshare_epd import epd4in0e
    return epd4in0e


# --- Photo storage -----------------------------------------------------------
class PhotoStore:
    """Originals in photo_dir, previews in photo_dir/thumbs and photo_dir/dithered."""

    def __init__(self, config):
        self.root = Path(config["storage"]["photo_dir"]).expanduser()
        self.thumbs = self.root / "thumbs"
        self.dithered = self.root / "dithered"
        for folder in (self.root, self.thumbs, self.dithered):
            folder.mkdir(parents=True, exist_ok=True)

    def new_name(self):
        name = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        n = 1
        candidate = name
        while (self.root / f"{candidate}.jpg").exists():
            n += 1
            candidate = f"{name}_{n}"
        return candidate

    def original(self, name):
        return self.root / f"{name}.jpg"

    def thumb(self, name):
        return self.thumbs / f"{name}.jpg"

    def preview(self, name):
        return self.dithered / f"{name}.png"

    def names(self):
        """All photos, newest first."""
        return sorted((p.stem for p in self.root.glob("*.jpg")), reverse=True)

    def delete(self, name):
        """Delete a photo with its thumbnail and dithered preview."""
        for path in (self.original(name), self.thumb(name), self.preview(name)):
            path.unlink(missing_ok=True)

    def resolve(self, name_or_path):
        """Photo name (as listed) or path to any image file."""
        if self.original(name_or_path).exists():
            return self.original(name_or_path)
        path = Path(name_or_path).expanduser()
        if path.exists():
            return path
        raise FileNotFoundError(f"Photo not found: {name_or_path}")


CACHE_DIR = Path.home() / ".cache" / "zero-cam"


def _sensor_model():
    """Camera model as libcamera names its tuning file, e.g. imx708 or imx708_wide (cached)."""
    cache = CACHE_DIR / "sensor"
    try:
        return cache.read_text().strip()
    except OSError:
        pass
    out = subprocess.run(["rpicam-hello", "--list-cameras"], capture_output=True, text=True).stdout
    match = re.search(r"^\s*0 : (\S+)", out, re.M)
    if not match:
        return None
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache.write_text(match.group(1))
    return match.group(1)


def tuning_without_lens_shading():
    """Copy of the system tuning file without rpi.alsc; rebuilt when the system file changes.

    Returns None if the tuning file cannot be found (then the default is used).
    """
    model = _sensor_model()
    if not model:
        return None
    # Pi 5 uses the PiSP image processor, all older models the VC4 one
    compatible = Path("/proc/device-tree/compatible").read_bytes()
    platform = "pisp" if b"bcm2712" in compatible else "vc4"
    source = Path("/usr/share/libcamera/ipa/rpi") / platform / f"{model}.json"
    target = CACHE_DIR / f"{model}_no_lens_shading.json"
    if not source.exists():
        return None
    if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
        # tuning files may contain // comments
        tuning = json.loads(re.sub(r"(?m)^\s*//.*$", "", source.read_text()))
        tuning["algorithms"] = [a for a in tuning["algorithms"] if "rpi.alsc" not in a]
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(tuning, indent=1))
    return target


def capture(config, store):
    """Take a photo, save original + thumbnail and return its name."""
    cam = config["camera"]
    name = store.new_name()
    path = store.original(name)
    command = [
        "rpicam-still",
        "-o", str(path),
        "--width", cam["width"],
        "--height", cam["height"],
        "--rotation", cam["rotation"],
        "--nopreview",
        "-t", cam["timeout_ms"],
    ]
    if not cam.getboolean("lens_shading"):
        tuning = tuning_without_lens_shading()
        if tuning:
            command += ["--tuning-file", str(tuning)]
    print("Taking photo...")
    subprocess.run(
        command,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    from PIL import Image, ImageOps
    with Image.open(path) as image:
        thumb = ImageOps.exif_transpose(image).convert("RGB")
        thumb.thumbnail((300, 200))
        thumb.save(store.thumb(name), quality=80)
    return name


# --- Image processing --------------------------------------------------------
# Panel color indices as expected by the controller (4 = unused).
# Ideal and measured colors after pimoroni/inky (MIT): the measured ones
# look closer to the real panel, so dithering with them keeps more detail.
PANEL_COLORS = [
    # index, ideal, measured
    (0, (0, 0, 0), (57, 48, 57)),           # black
    (1, (255, 255, 255), (255, 255, 255)),  # white
    (2, (255, 255, 0), (208, 190, 71)),     # yellow
    (3, (255, 0, 0), (156, 72, 75)),        # red
    (5, (0, 0, 255), (61, 59, 94)),         # blue
    (6, (0, 255, 0), (58, 91, 70)),         # green
]


def _palette(blend):
    colors = []
    for _, ideal, measured in PANEL_COLORS:
        colors += [round(i * (1 - blend) + m * blend) for i, m in zip(ideal, measured)]
    from PIL import Image
    palette = Image.new("P", (1, 1))
    palette.putpalette(colors + [0, 0, 0] * (256 - len(PANEL_COLORS)))
    return palette


def fit_landscape(image):
    """Center-crop to 3:2 and scale to 600x400."""
    from PIL import Image, ImageOps
    image = ImageOps.exif_transpose(image).convert("RGB")
    return ImageOps.fit(image, (VISUAL_WIDTH, VISUAL_HEIGHT), Image.LANCZOS)


def dither(image, config):
    """Enhance the photo and dither it to the 6 panel colors.

    Returns a palette image (600x400) whose indices are positions in PANEL_COLORS.
    """
    from PIL import Image, ImageEnhance, ImageOps
    opts = config["image"]
    image = fit_landscape(image)
    cutoff = opts.getfloat("autocontrast_cutoff")
    if cutoff > 0:
        image = ImageOps.autocontrast(image, cutoff=cutoff)
    image = ImageEnhance.Brightness(image).enhance(opts.getfloat("brightness"))
    image = ImageEnhance.Contrast(image).enhance(opts.getfloat("contrast"))
    image = ImageEnhance.Color(image).enhance(opts.getfloat("saturation"))
    return image.quantize(palette=_palette(opts.getfloat("palette_blend")),
                          dither=Image.Dither.FLOYDSTEINBERG)


def save_preview(dithered, path, config):
    """Save the dithered image with the blended colors (close to the real panel)."""
    preview = dithered.copy()
    preview.putpalette(_palette(config["image"].getfloat("palette_blend")).getpalette())
    preview.convert("RGB").save(path)


def panel_buffer(dithered, rotation):
    """Pack the dithered image into the panel buffer (portrait, 2 pixels per byte)."""
    to_panel = bytes(index for index, _, _ in PANEL_COLORS) + bytes(256 - len(PANEL_COLORS))
    image = dithered.rotate(rotation, expand=True)
    pixels = image.tobytes().translate(to_panel)
    return bytes((pixels[i] << 4) | pixels[i + 1] for i in range(0, len(pixels), 2))


# --- Display -----------------------------------------------------------------
LOCK_PATH = Path("/tmp/zero-cam-display.lock")


class Display:
    """The e-Paper display. Only one process at a time may refresh it, and
    refreshes keep the minimum interval recommended by Waveshare."""

    def __init__(self, config):
        self.config = config
        self.min_interval = config["display"].getfloat("min_refresh_interval")
        self.rotation = config["display"].getint("rotation")
        # stored with the photos so it survives a reboot
        self.stamp = Path(config["storage"]["photo_dir"]).expanduser() / ".last_refresh"

    def last_refresh(self):
        try:
            return float(self.stamp.read_text())
        except (OSError, ValueError):
            return 0.0

    def wait_seconds(self):
        """Seconds until the next refresh is allowed."""
        return max(0.0, self.last_refresh() + self.min_interval - time.time())

    @contextmanager
    def _session(self, force):
        with open(LOCK_PATH, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            wait = 0.0 if force else self.wait_seconds()
            if wait > 0:
                print(f"Waiting {wait:.0f} s (minimum interval between refreshes)...")
                time.sleep(wait)
            epd4in0e = _epd_module()
            epd = epd4in0e.EPD()
            print("Initializing display...")
            if epd.init() != 0:
                raise IOError("Display initialization failed")
            try:
                yield epd
                self.stamp.write_text(str(time.time()))
            finally:
                # Always put the display to sleep and release GPIO/5V, even on errors
                try:
                    epd.sleep()
                except Exception:
                    epd4in0e.epdconfig.module_exit(cleanup=True)

    def show(self, dithered, force=False):
        buffer = panel_buffer(dithered, self.rotation)
        with self._session(force) as epd:
            print("Sending photo to display (~20 s refresh)...")
            epd.display(buffer)

    def clear(self, force=False):
        with self._session(force) as epd:
            print("Clearing display to white (~20 s refresh)...")
            epd.Clear()


def prepare(config, store, name_or_path):
    """Dither a stored photo (or any image file) for the display.

    For stored photos the dithered preview is saved for the web interface.
    """
    path = store.resolve(name_or_path)
    from PIL import Image
    with Image.open(path) as image:
        dithered = dither(image, config)
    if path.parent == store.root:
        save_preview(dithered, store.preview(path.stem), config)
    return dithered
