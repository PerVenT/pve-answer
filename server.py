import argparse
import hmac
import html
import json
import logging
import os
import pathlib
import ssl
import stat

try:
    import tomlkit
    from aiohttp import web
except ImportError as e:
    import sys

    message = """Could not import required packages.
Please ensure you've installed all necessary packages first!

On Debian-based distributions, you should be able to install them via:

\tapt update
\tapt install python3-aiohttp python3-tomlkit"""

    print(message, file=sys.stderr)

    raise e


DEFAULT_ANSWER_FILE_PATH = pathlib.Path("./default.toml")
ANSWER_FILE_DIR = pathlib.Path("./answers/")

# Set at startup; only used by the debug status page.
TLS_ENABLED = False

# Expected 'Authorization: Bearer <name>:<secret>' value, or None to serve
# the answer endpoint without authentication.
AUTH_TOKEN = None

routes = web.RouteTableDef()
debug_routes = web.RouteTableDef()


def is_authorized(request: web.Request) -> bool:
    """
    Check the bearer token the installer sends when the ISO was prepared
    with 'proxmox-auto-install-assistant prepare-iso --answer-auth-token'.

    Always true when no token is configured, so existing ISOs keep working.
    """
    if AUTH_TOKEN is None:
        return True

    header = request.headers.get("Authorization", "")
    scheme, _, presented = header.partition(" ")

    if scheme.lower() != "bearer":
        return False

    # Constant time, so a wrong token leaks nothing through response timing.
    return hmac.compare_digest(presented.strip(), AUTH_TOKEN)




@routes.post("/answer")
async def answer(request: web.Request):
    if not is_authorized(request):
        logging.warning(
            f"Rejected unauthorized request from peer '{request.remote}'"
        )
        return web.Response(
            status=401,
            text="Unauthorized: a valid answer auth token is required.\n",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        request_data = json.loads(await request.text())
    except json.JSONDecodeError as e:
        return web.Response(
            status=500,
            text=f"Internal Server Error: failed to parse request contents: {e}",
        )

    logging.info(
        f"Request data for peer '{request.remote}':\n"
        f"{json.dumps(request_data, indent=1)}"
    )

    try:
        answer, matched = create_answer(request_data)

        if matched is None:
            macs = [
                nic["mac"]
                for nic in request_data.get("network_interfaces", [])
                if "mac" in nic
            ]
            logging.warning(
                f"No answer file for MAC(s) {macs or '(none reported)'} from "
                f"peer '{request.remote}': serving "
                f"'{DEFAULT_ANSWER_FILE_PATH}'."
            )

        logging.info(
            f"Answer file for peer '{request.remote}':\n{answer}"
        )

        return web.Response(
            text=answer,
            headers={"X-Answer-Match": matched or "none"},
        )

    except Exception as e:
        logging.exception(f"failed to create answer: {e}")
        return web.Response(
            status=500,
            text=f"Internal Server Error: {e}",
        )


@routes.get("/answer")
async def answer_get(request: web.Request):
    """
    The Proxmox installer POSTs to this endpoint. Answer a GET with an
    explanation rather than aiohttp's bare 405 body.
    """
    return web.Response(
        status=405,
        text=(
            "This endpoint expects a POST from the Proxmox installer.\n"
            "See: proxmox-auto-install-assistant prepare-iso --fetch-from http\n"
        ),
    )


@routes.get("/health")
async def health(request: web.Request):
    """
    Contentless liveness check, safe to expose to monitoring.
    """
    return web.Response(text="ok\n")


@debug_routes.get("/")
async def status(request: web.Request):
    """
    Status page, only registered when debug mode is enabled. It lists the
    MAC addresses answer files exist for, so it stays off by default.
    """
    return web.Response(text=render_status_page(), content_type="text/html")


def render_status_page() -> str:
    answer_files = sorted(ANSWER_FILE_DIR.glob("*.toml"))

    if answer_files:
        rows = "\n".join(
            "<tr><td><code>{}</code></td><td>{}</td></tr>".format(
                html.escape(normalize_mac(f.stem)), html.escape(f.name)
            )
            for f in answer_files
        )
    else:
        rows = '<tr><td colspan="2">No answer files found.</td></tr>'

    try:
        assert_default_answer_file_parseable()
        default_state = "ok"
    except Exception as e:
        default_state = f"ERROR: {e}"

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Proxmox answer file server</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 2rem; max-width: 46rem; }}
  table {{ border-collapse: collapse; margin-top: .5rem; }}
  th, td {{ border: 1px solid #ccc; padding: .35rem .7rem; text-align: left; }}
  dt {{ font-weight: 600; margin-top: .5rem; }}
  .warn {{ background: #fff3cd; border: 1px solid #e0c040;
           padding: .6rem .8rem; border-radius: 4px; }}
</style>
</head>
<body>
<h1>Proxmox answer file server</h1>
<p class="warn">Debug mode is enabled. This page lists the MAC addresses
answer files exist for. Disable it once you are done troubleshooting.</p>
<dl>
  <dt>TLS</dt><dd>{"enabled" if TLS_ENABLED else "DISABLED (plain HTTP)"}</dd>
  <dt>Auth token</dt>
  <dd>{"enabled" if AUTH_TOKEN is not None else "DISABLED (open endpoint)"}</dd>
  <dt>Default answer file</dt>
  <dd><code>{html.escape(str(DEFAULT_ANSWER_FILE_PATH))}</code> &mdash;
      {html.escape(default_state)}</dd>
  <dt>Answer file directory</dt>
  <dd><code>{html.escape(str(ANSWER_FILE_DIR))}</code> &mdash;
      {len(answer_files)} file(s)</dd>
</dl>
<table>
  <tr><th>Normalized MAC</th><th>File</th></tr>
  {rows}
</table>
<p>Answer files are served by POSTing to <code>/answer</code>; their contents
are never exposed here.</p>
</body>
</html>
"""


def create_answer(request_data: dict) -> tuple[str, str | None]:
    """
    Build the answer for a request, returning the file contents and the name
    of the answer file that matched, or None when falling back to the default.
    """
    with open(DEFAULT_ANSWER_FILE_PATH) as file:
        answer = tomlkit.parse(file.read())

    matched = None

    for nic in request_data.get("network_interfaces", []):
        if "mac" not in nic:
            continue

        answer_mac = lookup_answer_for_mac(nic["mac"])

        if answer_mac is not None:
            answer, matched = answer_mac

    return tomlkit.dumps(answer), matched


def normalize_mac(mac: str) -> str:
    """
    Normalize a MAC address by removing separators and converting
    it to lowercase.

    Examples:

        aa:bb:cc:dd:ee:ff -> aabbccddeeff
        aa-bb-cc-dd-ee-ff -> aabbccddeeff
        AABBCCDDEEFF       -> aabbccddeeff
    """
    return mac.replace(":", "").replace("-", "").lower()


def lookup_answer_for_mac(
    mac: str,
) -> tuple[tomlkit.TOMLDocument, str] | None:
    """
    Find an answer file matching the supplied MAC address, returning its
    contents and its name.

    The MAC address received from the client can use colons,
    hyphens, or no separators.

    Answer files should preferably be named using hyphens, e.g.:

        answers/aa-bb-cc-dd-ee-ff.toml
    """
    normalized_mac = normalize_mac(mac)

    for filename in ANSWER_FILE_DIR.glob("*.toml"):
        filename_mac = normalize_mac(filename.stem)

        if filename_mac == normalized_mac:
            logging.info(
                f"Found answer file '{filename}' for MAC '{mac}'"
            )

            with open(filename) as mac_file:
                return tomlkit.parse(mac_file.read()), filename.stem

    logging.info(
        f"No answer file found for MAC '{mac}'"
    )

    return None


def assert_default_answer_file_exists():
    if not DEFAULT_ANSWER_FILE_PATH.exists():
        raise RuntimeError(
            f"Default answer file '{DEFAULT_ANSWER_FILE_PATH}' does not exist"
        )


def assert_default_answer_file_parseable():
    with open(DEFAULT_ANSWER_FILE_PATH) as file:
        try:
            tomlkit.parse(file.read())
        except Exception as e:
            raise RuntimeError(
                "Could not parse default answer file "
                f"'{DEFAULT_ANSWER_FILE_PATH}':\n{e}"
            )


def assert_answer_dir_exists():
    if not ANSWER_FILE_DIR.exists():
        raise RuntimeError(
            f"Answer file directory '{ANSWER_FILE_DIR}' does not exist"
        )


def env_flag(name: str) -> bool:
    """
    Read a boolean from the environment. Accepts 1/true/yes/on, any case.
    """
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def env_path(name: str) -> pathlib.Path | None:
    """
    Read a path from the environment. argparse's type= does not apply to
    defaults, so the conversion has to happen here.
    """
    value = os.environ.get(name, "").strip()

    return pathlib.Path(value) if value else None


def load_auth_token(token_file: pathlib.Path | None) -> str | None:
    """
    Read the expected auth token from a file, or from PVE_ANSWER_TOKEN.

    The token must match what the ISO was prepared with:

        proxmox-auto-install-assistant prepare-iso ... \\
            --answer-auth-token '<name>:<secret>'
    """
    if token_file is not None:
        if not token_file.exists():
            raise RuntimeError(f"Auth token file '{token_file}' does not exist")

        mode = token_file.stat().st_mode

        if mode & (stat.S_IRWXG | stat.S_IRWXO):
            logging.warning(
                f"Auth token file '{token_file}' is readable by group or "
                "others. Restrict it with: chmod 600"
            )

        token = token_file.read_text().strip()

        if not token:
            raise RuntimeError(f"Auth token file '{token_file}' is empty")
    else:
        token = os.environ.get("PVE_ANSWER_TOKEN", "").strip() or None

    if token is not None and ":" not in token:
        raise RuntimeError(
            "Auth token must have the form '<name>:<secret>', matching "
            "prepare-iso --answer-auth-token"
        )

    return token


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve Proxmox automated installation answer files.",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="address to bind to (default: %(default)s)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8443,
        help="port to listen on (default: %(default)s)",
    )
    parser.add_argument(
        "--cert",
        type=pathlib.Path,
        help="path to the TLS certificate (PEM). Enables HTTPS together with --key",
    )
    parser.add_argument(
        "--key",
        type=pathlib.Path,
        help="path to the TLS private key (PEM). Enables HTTPS together with --cert",
    )
    parser.add_argument(
        "--answers-dir",
        type=pathlib.Path,
        default=ANSWER_FILE_DIR,
        help="directory holding the per-MAC answer files (default: %(default)s)",
    )
    parser.add_argument(
        "--default-answer",
        type=pathlib.Path,
        default=DEFAULT_ANSWER_FILE_PATH,
        help="answer file served when no MAC matches (default: %(default)s)",
    )
    parser.add_argument(
        "--auth-token-file",
        type=pathlib.Path,
        default=env_path("PVE_ANSWER_TOKEN_FILE"),
        help=(
            "file containing the answer auth token as '<name>:<secret>'. "
            "Falls back to the PVE_ANSWER_TOKEN environment variable. "
            "Without either, the answer endpoint is unauthenticated"
        ),
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        default=env_flag("PVE_ANSWER_DEBUG"),
        help=(
            "enable the status page at GET /. Off by default because it "
            "lists the MAC addresses answer files exist for. Can also be "
            "enabled with PVE_ANSWER_DEBUG=1"
        ),
    )

    args = parser.parse_args()

    if bool(args.cert) != bool(args.key):
        parser.error("--cert and --key must be given together")

    return args


def create_ssl_context(
    cert: pathlib.Path, key: pathlib.Path
) -> ssl.SSLContext:
    for path in (cert, key):
        if not path.exists():
            raise RuntimeError(f"TLS file '{path}' does not exist")

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert, keyfile=key)

    return context


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)

    args = parse_args()

    ANSWER_FILE_DIR = args.answers_dir
    DEFAULT_ANSWER_FILE_PATH = args.default_answer
    TLS_ENABLED = bool(args.cert and args.key)
    AUTH_TOKEN = load_auth_token(args.auth_token_file)

    if AUTH_TOKEN is None:
        logging.warning(
            "No auth token configured: anyone who can reach this server can "
            "fetch answer files. See --auth-token-file"
        )

    assert_default_answer_file_exists()
    assert_answer_dir_exists()
    assert_default_answer_file_parseable()

    ssl_context = None

    if args.cert and args.key:
        ssl_context = create_ssl_context(args.cert, args.key)
    else:
        logging.warning(
            "No --cert/--key given, serving plain HTTP. "
            "The Proxmox installer expects HTTPS."
        )

    app = web.Application()
    app.add_routes(routes)

    if args.debug:
        logging.warning(
            "Debug mode enabled: the status page at GET / lists the MAC "
            "addresses answer files exist for. Disable it when done."
        )
        app.add_routes(debug_routes)

    web.run_app(
        app,
        host=args.host,
        port=args.port,
        ssl_context=ssl_context,
    )
