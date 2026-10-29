#!/usr/bin/env python3
"""SimpoConverter: convert PDF pages to images (Linux and macOS version).

Usage:
    simpoconv                                   guided mode
    simpoconv report.pdf                        all pages as PNG at 150 dpi
    simpoconv report.pdf -f jpg -d 300 -p 1-3,7
    simpoconv ~/Scans -r -o ~/Scans/images
    simpoconv update | version | help | uninstall

Pages that already have an image are skipped, so an interrupted run can be
continued by running the same command again.

Requires pypdfium2 and Pillow (see requirements.txt).
"""

import argparse
import contextlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from getpass import getpass
from pathlib import Path

__version__ = "1.0"

APP = "SimpoConverter"
REPO_RAW = "https://raw.githubusercontent.com/nambobi/SimpoConverter/main"
REPO_PAGE = "https://github.com/nambobi/SimpoConverter"
STATE_DIR = Path.home() / ".simpoconverter"
INSTALL_DIR = Path.home() / ".local" / "share" / "simpoconverter"
COMMAND_FILE = Path.home() / ".local" / "bin" / "simpoconv"

# Format name -> (Pillow format, file extension)
FORMATS = {
    "png": ("PNG", ".png"),
    "jpg": ("JPEG", ".jpg"),
    "jpeg": ("JPEG", ".jpg"),
    "webp": ("WEBP", ".webp"),
    "tiff": ("TIFF", ".tiff"),
    "tif": ("TIFF", ".tiff"),
    "bmp": ("BMP", ".bmp"),
}
LOSSY_FORMATS = {"JPEG", "WEBP"}
PDFIUM_ERR_PASSWORD = 4  # pypdfium2 error code for a missing or wrong password
COMMANDS = {"update", "version", "help", "uninstall"}

# Replace characters the console cannot encode instead of raising an error.
for _stream in (sys.stdout, sys.stderr):
    with contextlib.suppress(AttributeError, ValueError):
        _stream.reconfigure(errors="replace")

try:
    import PIL  # noqa: F401  (required by pypdfium2's to_pil)
    import pypdfium2 as pdfium
except ImportError:
    pdfium = None  # checked in main() so that update and uninstall still work


class WrongPasswordError(Exception):
    pass


# Input --------------------------------------------------------------------


def parse_pages(spec, total):
    """Convert a page list such as '1-3,5,10-' to sorted zero-based indexes."""
    if spec is None or spec.strip().lower() in ("", "all"):
        return list(range(total))
    chosen = set()
    for part in spec.replace(" ", "").split(","):
        if not part:
            continue
        try:
            if "-" in part:
                first, last = part.split("-", 1)
                start = int(first) if first else 1
                end = int(last) if last else total
            else:
                start = end = int(part)
        except ValueError:
            raise ValueError(
                f"'{part}' is not a page number or range, e.g. 1-3,5,10-"
            ) from None
        if start < 1 or end < start:
            raise ValueError(f"'{part}' is not a valid range")
        if start > total:
            continue
        chosen.update(range(start - 1, min(end, total)))
    return sorted(chosen)


def find_pdfs(inputs, recursive):
    """Return the PDF files in the given files and folders, without duplicates."""
    found, seen, problems = [], set(), []
    for raw in inputs:
        path = Path(raw).expanduser()
        if path.is_dir():
            entries = path.rglob("*") if recursive else path.iterdir()
            pdfs = sorted(
                p for p in entries if p.is_file() and p.suffix.lower() == ".pdf"
            )
            if not pdfs:
                problems.append(f"no PDF files in folder: {path}")
        elif path.is_file():
            pdfs = [path]
        else:
            problems.append(f"not found: {path}")
            continue
        for pdf in pdfs:
            key = os.path.normcase(str(pdf.resolve()))
            if key not in seen:
                seen.add(key)
                found.append(pdf)
    return found, problems


def image_prefixes(pdfs, shared_folder):
    """Return the file name prefix for each PDF's images.

    Images are named after their PDF. If all images go to one output folder and
    two PDFs have the same name, the parent folder name is added to the prefix.
    """
    prefixes = [p.stem for p in pdfs]
    if not shared_folder:
        return prefixes
    counts = {}
    for name in prefixes:
        counts[name.lower()] = counts.get(name.lower(), 0) + 1
    used = set()
    for i, pdf in enumerate(pdfs):
        name = prefixes[i]
        if counts[name.lower()] > 1 and pdf.parent.name:
            name = f"{pdf.parent.name}_{pdf.stem}"
        candidate, n = name, 2
        while candidate.lower() in used:
            candidate, n = f"{name}_{n}", n + 1
        used.add(candidate.lower())
        prefixes[i] = candidate
    return prefixes


def split_dropped_paths(text):
    """Split paths that were dragged into a terminal.

    Paths are separated by spaces and quoted or escaped if they contain spaces.
    A single unquoted path that contains spaces is also accepted.
    """
    text = text.strip()
    if not text:
        return []
    for candidate in (text.strip('"').strip("'"), text.replace("\\ ", " ")):
        if Path(candidate).expanduser().exists():
            return [candidate]
    try:
        parts = shlex.split(text, posix=os.name != "nt")
    except ValueError:
        parts = [text]
    # PowerShell inserts a dragged file as: & 'C:\path\file.pdf'
    return [p.strip('"').strip("'") for p in parts if p != "&"]


# Conversion ---------------------------------------------------------------


def open_pdf(path, password, ask_password):
    """Open a PDF and ask for the password if required (up to three times)."""
    attempts = 0
    while True:
        try:
            return pdfium.PdfDocument(str(path), password=password)
        except pdfium.PdfiumError as e:
            if getattr(e, "err_code", None) != PDFIUM_ERR_PASSWORD:
                raise
            if not ask_password or attempts >= 3:
                raise WrongPasswordError() from None
            attempts += 1
            label = "Password" if password is None else "Wrong password, try again"
            password = getpass(f"    {label} for {path.name}: ")


def save_image(image, target, pil_format, quality):
    """Write the image to <target>.part, then rename it to <target>.

    An interrupted write leaves only the .part file, so a partial image is
    never saved under the final name.
    """
    part = target.with_name(target.name + ".part")
    options = {}
    if pil_format in LOSSY_FORMATS:
        options["quality"] = quality
    if pil_format == "JPEG":
        options["optimize"] = True
    elif pil_format == "TIFF":
        options["compression"] = "tiff_lzw"
    try:
        image.save(part, format=pil_format, **options)
        os.replace(part, target)
    except BaseException:
        with contextlib.suppress(OSError):
            part.unlink()
        raise


def show_progress(done, total, width=28):
    filled = int(width * done / total) if total else width
    sys.stdout.write(f"\r    [{'#' * filled}{'-' * (width - filled)}] {done}/{total}")
    sys.stdout.flush()


def open_folder(folder):
    try:
        if sys.platform.startswith("win"):
            os.startfile(folder)
        else:
            opener = "open" if sys.platform == "darwin" else "xdg-open"
            subprocess.Popen(
                [opener, str(folder)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    except OSError:
        pass


def convert_pdf(pdf_path, prefix, opts, stats):
    """Convert one PDF. Return the output folder, or None if the file was skipped."""
    pil_format, ext = FORMATS[opts.format]

    try:
        doc = open_pdf(pdf_path, opts.password, opts.ask_password)
    except WrongPasswordError:
        if opts.password:
            print("    Error: wrong password. Skipped.")
        else:
            print(
                "    Error: the file is password protected (use --password). Skipped."
            )
        stats["failed_pdfs"] += 1
        return None
    except pdfium.PdfiumError as e:
        print(f"    Error: cannot open the file: {str(e).rstrip('.')}. Skipped.")
        stats["failed_pdfs"] += 1
        return None

    try:
        total = len(doc)
        pages = parse_pages(opts.pages, total)
        if not pages:
            print(f"    Error: no pages in '{opts.pages}' ({total} in file). Skipped.")
            stats["failed_pdfs"] += 1
            return None

        if opts.output:
            out_dir = Path(opts.output).expanduser()
        else:
            out_dir = pdf_path.parent / f"{pdf_path.stem}_images"
        out_dir.mkdir(parents=True, exist_ok=True)

        with contextlib.suppress(pdfium.PdfiumError):
            doc.init_forms()  # render form field values

        pad = max(3, len(str(total)))
        scale = opts.dpi / 72  # PDF user space unit is 1/72 inch
        print(f"    {total} pages, converting {len(pages)} to {out_dir}")

        for n, index in enumerate(pages, 1):
            target = out_dir / f"{prefix}_page_{index + 1:0{pad}d}{ext}"
            if not opts.overwrite and target.exists() and target.stat().st_size > 0:
                stats["skipped"] += 1
                show_progress(n, len(pages))
                continue
            page = None
            try:
                page = doc[index]
                image = page.render(scale=scale, grayscale=opts.gray).to_pil()
                if pil_format == "JPEG" and image.mode not in ("RGB", "L"):
                    image = image.convert("RGB")
                save_image(image, target, pil_format, opts.quality)
                stats["saved"] += 1
            except (pdfium.PdfiumError, MemoryError, OSError, ValueError) as e:
                print(f"\n    Error: page {index + 1} failed: {e}")
                stats["failed_pages"] += 1
            finally:
                if page is not None:
                    page.close()
            show_progress(n, len(pages))
        print()
        return out_dir
    finally:
        doc.close()


def run(opts):
    """Convert all inputs. Return the exit code."""
    pdfs, problems = find_pdfs(opts.inputs, opts.recursive)
    for message in problems:
        print(f"Error: {message}")
    if not pdfs:
        print("No PDF files to convert.")
        return 1

    image_type = FORMATS[opts.format][0] + (" grayscale" if opts.gray else "")
    print(f"Converting {len(pdfs)} PDF file(s) to {image_type} at {opts.dpi} dpi\n")
    stats = {"saved": 0, "skipped": 0, "failed_pages": 0, "failed_pdfs": 0}
    prefixes = image_prefixes(pdfs, shared_folder=bool(opts.output))
    folders = []
    started = time.time()

    try:
        for i, pdf in enumerate(pdfs, 1):
            print(f"[{i}/{len(pdfs)}] {pdf.name}")
            folder = convert_pdf(pdf, prefixes[i - 1], opts, stats)
            if folder and folder not in folders:
                folders.append(folder)
    except KeyboardInterrupt:
        print("\n\nInterrupted. Run the same command again to convert the rest.")
        return 130

    summary = f"\nDone in {time.time() - started:.1f} s. Saved: {stats['saved']}"
    if stats["skipped"]:
        summary += f". Skipped (already exist): {stats['skipped']}"
    if stats["failed_pages"]:
        summary += f". Failed pages: {stats['failed_pages']}"
    if stats["failed_pdfs"]:
        summary += f". Skipped files: {stats['failed_pdfs']}"
    print(summary + ".")
    if len(folders) == 1:
        print(f"Output folder: {folders[0]}")
    if opts.open:
        for folder in folders:
            open_folder(folder)
    return 0 if not (stats["failed_pages"] or stats["failed_pdfs"]) else 1


# Updates ------------------------------------------------------------------


def version_tuple(version):
    return tuple(int(x) for x in version.strip().split("."))


def fetch(name, timeout):
    request = urllib.request.Request(
        f"{REPO_RAW}/{name}",
        headers={"Cache-Control": "no-cache", "User-Agent": f"{APP}/{__version__}"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def latest_version(timeout):
    try:
        version = fetch("VERSION", timeout).decode().strip()
        version_tuple(version)
        return version
    except (OSError, ValueError):
        return None


def save_update_check():
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / "last_update_check").write_text(time.strftime("%Y-%m-%dT%H:%M:%S"))
    except OSError:
        pass


def show_update_notice():
    """Check for a new version at most once a day, with a 3-second timeout."""
    stamp = STATE_DIR / "last_update_check"
    try:
        if stamp.exists() and time.time() - stamp.stat().st_mtime < 24 * 3600:
            return
    except OSError:
        return
    save_update_check()
    latest = latest_version(3)
    if latest and version_tuple(latest) > version_tuple(__version__):
        print(f"Version {latest} is available (installed: {__version__}).")
        print("Run: simpoconv update")


def self_update():
    print("Checking for updates...")
    latest = latest_version(15)
    if not latest:
        print(f"Error: cannot reach {REPO_PAGE}. Check the internet connection.")
        return False
    if version_tuple(latest) <= version_tuple(__version__):
        print(f"{APP} {__version__} is the latest version.")
        return True
    target = Path(os.path.realpath(__file__))
    try:
        code = fetch("simpoconv.py", 60)
        compile(code, "simpoconv.py", "exec")  # reject a damaged download
        if APP.encode() not in code:
            raise ValueError("the downloaded file is not valid")
        shutil.copy2(target, str(target) + ".bak")
        new_file = Path(str(target) + ".new")
        new_file.write_bytes(code)
        os.chmod(new_file, 0o755)
        os.replace(new_file, target)
    except (OSError, ValueError, SyntaxError) as e:
        print(f"Update failed: {e}. The installed version was not changed.")
        return False

    # Install new package requirements, if any.
    try:
        with tempfile.NamedTemporaryFile("wb", suffix=".txt", delete=False) as f:
            f.write(fetch("requirements.txt", 15))
        subprocess.run(
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "-q",
                "--upgrade",
                "--disable-pip-version-check",
                "-r",
                f.name,
            ],
            check=False,
        )
        os.unlink(f.name)
    except OSError:
        pass

    print(f"Updated {APP} {__version__} to {latest}.")
    try:
        lines, sections = fetch("CHANGELOG.md", 15).decode().splitlines(), 0
        print("\nChanges:")
        for line in lines:
            if line.startswith("## "):
                sections += 1
                if sections > 1:
                    break
            if sections and line.strip():
                print("  " + line.rstrip())
    except (OSError, UnicodeDecodeError):
        pass
    save_update_check()
    return True


def uninstall():
    if not INSTALL_DIR.exists() and not COMMAND_FILE.exists():
        print(f"{APP} is not installed for this user.")
        return
    shutil.rmtree(INSTALL_DIR, ignore_errors=True)
    with contextlib.suppress(OSError):
        COMMAND_FILE.unlink()
    print(f"{APP} has been uninstalled.")


# Command line -------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        prog="simpoconv",
        description="Convert PDF pages to PNG, JPG, WEBP, TIFF or BMP images.",
        epilog="Commands: simpoconv update | version | help | uninstall. "
        "Run without arguments for guided mode. "
        f"Project page: {REPO_PAGE}",
    )
    parser.add_argument(
        "inputs",
        nargs="*",
        metavar="PDF_OR_FOLDER",
        help="PDF files or folders that contain PDF files",
    )
    parser.add_argument(
        "-f",
        "--format",
        default="png",
        type=str.lower,
        choices=sorted(FORMATS),
        help="image format (default: png)",
    )
    parser.add_argument(
        "-d",
        "--dpi",
        default=150,
        type=int,
        help="resolution in dots per inch, 10-1200 (default: 150)",
    )
    parser.add_argument(
        "-p",
        "--pages",
        default=None,
        help="pages to convert, e.g. 1-3,5,10- (default: all)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="output folder (default: <pdf name>_images next to each PDF)",
    )
    parser.add_argument(
        "-q",
        "--quality",
        default=90,
        type=int,
        help="JPG and WEBP quality, 1-100 (default: 90)",
    )
    parser.add_argument(
        "-g", "--gray", action="store_true", help="save grayscale images"
    )
    parser.add_argument(
        "--password", default=None, help="password for protected PDF files"
    )
    parser.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="include sub-folders when a folder is given",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="convert pages again even if the image exists",
    )
    parser.add_argument(
        "--open", action="store_true", help="open the output folder when finished"
    )
    parser.add_argument(
        "-v", "--version", action="version", version=f"{APP} {__version__}"
    )
    return parser


def validate(parser, opts):
    if not 10 <= opts.dpi <= 1200:
        parser.error("--dpi must be between 10 and 1200")
    if not 1 <= opts.quality <= 100:
        parser.error("--quality must be between 1 and 100")
    try:
        parse_pages(opts.pages, 10**6)
    except ValueError as e:
        parser.error(f"--pages: {e}")


def ask(prompt, default):
    answer = input(f"{prompt} [{default}]: ").strip()
    return answer or str(default)


def guided_mode(base):
    """Ask for the input and settings, convert, and repeat if requested."""
    code = 0
    while True:
        inputs = split_dropped_paths(
            input("\nDrag a PDF file or folder here and press Enter:\n> ")
        )
        if not inputs:
            print("No file given.")
            return code

        while True:
            fmt = ask("Format (png, jpg, webp, tiff, bmp)", base.format).lower()
            if fmt in FORMATS:
                break
            print("  Enter png, jpg, webp, tiff or bmp.")
        while True:
            dpi = ask("Resolution in dpi (150 for screen, 300 for print)", base.dpi)
            if dpi.isdigit() and 10 <= int(dpi) <= 1200:
                break
            print("  Enter a number from 10 to 1200.")
        while True:
            pages = ask("Pages, e.g. 1-3,5", base.pages or "all")
            try:
                parse_pages(pages, 10**6)
                break
            except ValueError as e:
                print(f"  {e}")

        opts = argparse.Namespace(**vars(base))
        opts.inputs, opts.format, opts.dpi, opts.pages = inputs, fmt, int(dpi), pages
        opts.open = opts.ask_password = True
        print()
        code = run(opts)
        if not ask("\nConvert another file? (y/n)", "n").lower().startswith("y"):
            return code


def main(argv=None):
    parser = build_parser()
    argv = sys.argv[1:] if argv is None else argv

    if len(argv) == 1 and argv[0].lower() in COMMANDS and not Path(argv[0]).exists():
        command = argv[0].lower()
        if command == "help":
            parser.print_help()
        elif command == "version":
            print(f"{APP} {__version__}")
        elif command == "update":
            return 0 if self_update() else 1
        else:
            uninstall()
        return 0

    opts = parser.parse_args(argv)
    validate(parser, opts)

    if pdfium is None:
        print(
            f"{APP} requires the pypdfium2 and Pillow packages. Install them with:\n\n"
            f"    {Path(sys.executable).name} -m pip install pypdfium2 pillow\n\n"
            "or run the installer again."
        )
        return 2

    print(f"{APP} {__version__}")
    show_update_notice()

    if not opts.inputs:
        try:
            return guided_mode(opts)
        except (KeyboardInterrupt, EOFError):
            print()
            return 130

    opts.ask_password = sys.stdin.isatty() and opts.password is None
    return run(opts)


if __name__ == "__main__":
    sys.exit(main())
