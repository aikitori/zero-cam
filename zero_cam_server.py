#!/usr/bin/env python3
"""
Web interface and photo triggers for the Pi Zero e-Paper camera.

- Web page (port 8080): browse photos, take a photo, clear the display,
  send a saved photo to the display
- Button (GPIO26 by default): take a photo
- Optional: motion sensor (PIR) and automatic photos at a fixed interval

Display refreshes are queued: a photo is taken right away, the display shows
the newest request as soon as the minimum interval since the last refresh
has passed. Settings: ~/zero-cam.conf (see zero-cam.conf.example).

Runs as a systemd service (as the normal user), set up by install.sh.
Uses only the Python standard library plus Pillow and gpiozero, so it stays
light enough for the Pi Zero W.
"""

import html
import re
import subprocess
import threading
import time
import traceback
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote

import zerocam

NAME = re.compile(r"^[0-9][0-9_-]*$")


class Camera:
    """Takes photos and hands them to the display queue."""

    def __init__(self, config, store, queue):
        self.config = config
        self.store = store
        self.queue = queue
        self.lock = threading.Lock()
        self.last_error = ""

    def busy(self):
        return self.lock.locked()

    def take(self, source):
        """Take a photo unless one is being taken already. Returns the name or None."""
        if not self.lock.acquire(blocking=False):
            print(f"{source}: camera busy, ignored")
            return None
        try:
            print(f"{source}: taking photo")
            name = zerocam.capture(self.config, self.store)
            self.last_error = ""
            self.queue.request("show", name)
            return name
        except subprocess.CalledProcessError as e:
            self.last_error = f"Camera capture failed: {e}"
            print(self.last_error)
            return None
        finally:
            self.lock.release()

    def take_async(self, source):
        threading.Thread(target=self.take, args=(source,), daemon=True).start()


class DisplayQueue(threading.Thread):
    """Runs display refreshes one after another; only the newest request waits."""

    def __init__(self, config, store, display):
        super().__init__(daemon=True)
        self.config = config
        self.store = store
        self.display = display
        self.cond = threading.Condition()
        self.pending = None   # ("show", name) or ("clear", None)
        self.current = None
        self.last_error = ""

    def request(self, action, name=None):
        with self.cond:
            self.pending = (action, name)
            self.cond.notify()

    def cancel(self, name):
        """Drop a waiting request for a photo (e.g. because it was deleted)."""
        with self.cond:
            if self.pending == ("show", name):
                self.pending = None

    def run(self):
        while True:
            with self.cond:
                while self.pending is None:
                    self.cond.wait()
            # wait outside the lock so newer requests can replace the pending one
            while self.display.wait_seconds() > 0:
                time.sleep(min(5.0, self.display.wait_seconds()))
            with self.cond:
                self.current, self.pending = self.pending, None
            if self.current is None:  # cancelled while waiting
                continue
            action, name = self.current
            try:
                if action == "clear":
                    self.display.clear()
                else:
                    self.display.show(zerocam.prepare(self.config, self.store, name))
                self.last_error = ""
            except Exception as e:
                self.last_error = f"Display error: {e}"
                traceback.print_exc()
            finally:
                self.current = None


def setup_triggers(config, camera):
    """Button, motion sensor and interval timer, as configured."""
    triggers = config["triggers"]
    devices = []
    if triggers["button_gpio"].strip() or triggers["motion_gpio"].strip():
        from gpiozero import Button, MotionSensor
        if triggers["button_gpio"].strip():
            pin = int(triggers["button_gpio"])
            button = Button(pin, pull_up=True, bounce_time=0.05)
            button.when_pressed = lambda: camera.take_async("Button")
            devices.append(button)
            print(f"Button on GPIO{pin}")
        if triggers["motion_gpio"].strip():
            pin = int(triggers["motion_gpio"])
            sensor = MotionSensor(pin)
            sensor.when_motion = lambda: _on_motion(camera)
            devices.append(sensor)
            print(f"Motion sensor on GPIO{pin}")

    minutes = triggers.getfloat("interval_minutes")
    if minutes > 0:
        def every():
            while True:
                time.sleep(minutes * 60)
                camera.take("Interval")
        threading.Thread(target=every, daemon=True).start()
        print(f"Automatic photo every {minutes:g} min")
    return devices  # keep references, otherwise the pins are released


_last_motion = 0.0


def _on_motion(camera):
    """At most one motion photo per display refresh interval."""
    global _last_motion
    now = time.time()
    if now - _last_motion < camera.queue.display.min_interval:
        return
    _last_motion = now
    camera.take_async("Motion")


# --- Web interface -----------------------------------------------------------
STYLE = """
body{font-family:system-ui,sans-serif;margin:0;background:#f4f2ee;color:#222}
header{padding:16px;background:#222;color:#fff}
header h1{margin:0;font-size:1.3em}
main{padding:16px;max-width:1000px;margin:auto}
.status{background:#fff;border-radius:8px;padding:12px 16px;margin-bottom:16px}
.error{color:#b00}
form{display:inline}
button{font-size:1em;padding:10px 16px;margin:4px 4px 4px 0;border:0;border-radius:6px;
  background:#2b6cb0;color:#fff;cursor:pointer}
button.light{background:#ddd;color:#222}
button.danger{background:#c53030}
.settings{display:block;margin:8px 0 0}
.settings input{width:6em;font-size:1em;padding:6px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}
.card{background:#fff;border-radius:8px;overflow:hidden}
.card img{width:100%;display:block;aspect-ratio:3/2;object-fit:cover}
.card div{padding:8px}
.card small{display:block;margin-bottom:4px}
a{color:#2b6cb0}
.photo img{width:100%;border-radius:8px}
"""


def page(title, body, refresh=False):
    meta = '<meta http-equiv="refresh" content="10">' if refresh else ""
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">{meta}
<title>{html.escape(title)}</title><style>{STYLE}</style></head>
<body><header><h1><a href="/" style="color:#fff;text-decoration:none">Zero Cam</a></h1></header>
<main>{body}</main></body></html>"""


def delete_button(name):
    return (f'<form method="post" action="/delete/{name}" '
            f'onsubmit="return confirm(\'Delete photo {label(name)}?\')">'
            f'<button class="danger">Delete</button></form>')


def label(name):
    try:
        return datetime.strptime(name[:19], "%Y-%m-%d_%H-%M-%S").strftime("%d.%m.%Y %H:%M:%S")
    except ValueError:
        return name


class Handler(BaseHTTPRequestHandler):
    server_version = "ZeroCam"
    app = None  # set in main()

    # --- helpers
    def send_html(self, text):
        data = text.encode()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location="/"):
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", location)
        self.end_headers()

    def send_file(self, path, content_type):
        if not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass  # keep the journal quiet

    # --- routes
    def do_GET(self):
        store = self.app["store"]
        parts = [unquote(p) for p in self.path.split("?")[0].strip("/").split("/")]
        if parts == [""]:
            self.send_html(self.index())
        elif len(parts) == 2 and parts[0] == "photo" and NAME.match(parts[1]):
            self.send_html(self.photo(parts[1]))
        elif len(parts) == 2 and NAME.match(parts[1].rsplit(".", 1)[0]):
            name = parts[1].rsplit(".", 1)[0]
            if parts[0] == "original":
                self.send_file(store.original(name), "image/jpeg")
            elif parts[0] == "thumb":
                self.send_file(store.thumb(name), "image/jpeg")
            elif parts[0] == "dithered":
                self.send_file(store.preview(name), "image/png")
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        camera, queue, store = self.app["camera"], self.app["queue"], self.app["store"]
        parts = self.path.strip("/").split("/")
        if parts == ["capture"]:
            camera.take_async("Web")
            time.sleep(0.2)  # so the page already shows "taking photo"
        elif parts == ["clear"]:
            queue.request("clear")
        elif len(parts) == 2 and parts[0] == "show" and NAME.match(parts[1]) \
                and store.original(parts[1]).exists():
            queue.request("show", parts[1])
        elif len(parts) == 2 and parts[0] == "delete" and NAME.match(parts[1]) \
                and store.original(parts[1]).exists():
            if queue.current == ("show", parts[1]):
                self.app["message"] = "The photo is being shown right now, try again in a moment."
            else:
                queue.cancel(parts[1])
                store.delete(parts[1])
                print(f"Web: deleted {parts[1]}")
        elif parts == ["settings"]:
            self.save_settings()
        else:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.redirect("/")

    def save_settings(self):
        length = int(self.headers.get("Content-Length") or 0)
        form = parse_qs(self.rfile.read(length).decode())
        try:
            seconds = int(form.get("min_refresh_interval", [""])[0])
            if not 0 <= seconds <= 86400:
                raise ValueError
        except ValueError:
            self.app["message"] = "Refresh interval: please enter whole seconds between 0 and 86400."
            return
        self.app["display"].min_interval = seconds
        zerocam.save_web_setting("display", "min_refresh_interval", seconds)
        self.app["message"] = f"Refresh interval set to {seconds} s."
        print(f"Web: refresh interval {seconds} s")

    # --- pages
    def status(self):
        camera, queue, display = self.app["camera"], self.app["queue"], self.app["display"]
        lines = []
        if camera.busy():
            lines.append("Taking photo...")
        if queue.current:
            action, name = queue.current
            lines.append("Clearing display..." if action == "clear"
                         else f"Display is refreshing: {html.escape(label(name))}")
        if queue.pending:
            action, name = queue.pending
            what = "clear" if action == "clear" else html.escape(label(name))
            lines.append(f"Waiting for display ({what}), "
                         f"next refresh in {display.wait_seconds():.0f} s")
        last = display.last_refresh()
        lines.append("Last display refresh: "
                     + (datetime.fromtimestamp(last).strftime("%d.%m.%Y %H:%M:%S") if last else "unknown"))
        message = self.app.pop("message", "")
        if message:
            lines.append(f"<strong>{html.escape(message)}</strong>")
        for error in (camera.last_error, queue.last_error):
            if error:
                lines.append(f'<span class="error">{html.escape(error)}</span>')
        busy = camera.busy() or queue.current is not None or queue.pending is not None
        return "<br>".join(lines), busy

    def index(self):
        status, busy = self.status()
        names = self.app["store"].names()
        cards = "".join(
            f'<div class="card"><a href="/photo/{n}"><img src="/thumb/{n}.jpg" loading="lazy" alt=""></a>'
            f'<div><small>{label(n)}</small>'
            f'<form method="post" action="/show/{n}"><button class="light">Show on display</button></form>'
            f'{delete_button(n)}</div></div>'
            for n in names)
        interval = self.app["display"].min_interval
        warning = ('<small class="error">Waveshare recommends at least 180 s.</small>'
                   if interval < 180 else "")
        body = f"""<div class="status">{status}</div>
<form method="post" action="/capture"><button>Take photo</button></form>
<form method="post" action="/clear"><button class="light">Clear display</button></form>
<form method="post" action="/settings" class="settings">
<label>Minimum time between display refreshes:
<input type="number" name="min_refresh_interval" min="0" max="86400" step="1" value="{interval:.0f}"> s</label>
<button class="light">Save</button> {warning}</form>
<h2>Photos ({len(names)})</h2>
<div class="grid">{cards or "<p>No photos yet.</p>"}</div>"""
        return page("Zero Cam", body, refresh=busy)

    def photo(self, name):
        if not self.app["store"].original(name).exists():
            return page("Not found", "<p>Photo not found.</p>")
        has_preview = self.app["store"].preview(name).exists()
        preview = (f'<h3>As shown on the display</h3><img src="/dithered/{name}.png" alt="">'
                   if has_preview else "")
        body = f"""<p><a href="/">&larr; All photos</a></p>
<h2>{label(name)}</h2>
<form method="post" action="/show/{name}"><button>Show on display</button></form>
{delete_button(name)}
<a href="/original/{name}.jpg" download>Download original</a>
<div class="photo"><h3>Original</h3><img src="/original/{name}.jpg" alt="">{preview}</div>"""
        return page(label(name), body)


def main():
    config = zerocam.load_config()
    store = zerocam.PhotoStore(config)
    display = zerocam.Display(config)
    queue = DisplayQueue(config, store, display)
    queue.start()
    camera = Camera(config, store, queue)
    devices = setup_triggers(config, camera)  # noqa: F841 (keeps the pins open)

    Handler.app = {"store": store, "display": display, "queue": queue, "camera": camera}
    port = config["web"].getint("port")
    server = ThreadingHTTPServer(("", port), Handler)
    print(f"Web interface on port {port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
