# SimpoConverter

SimpoConverter is a command-line tool that converts PDF pages to PNG, JPG, TIFF or BMP images. The Linux and macOS version can also save WEBP images. Part of SimpoScripts.

```
simpoconv "report.pdf"
```

## Features

- Converts all pages or selected pages, for example `1-3,5,10-`.
- Resolution from 10 to 1200 dpi (default 150).
- Converts several PDF files, or all PDF files in a folder and its sub-folders.
- Opens password-protected PDF files.
- Saves grayscale images and sets JPG quality.
- Skips pages that already have an image. If a run is interrupted, run the same command again to convert the remaining pages. Each image is written to a `.part` file and renamed when complete, so an interrupted write does not leave a partial image under the final name.
- Guided mode: run `simpoconv` without arguments and answer the prompts.

## Requirements

| System | Requirements |
|---|---|
| Windows 10 or 11 | Windows PowerShell 5.1, which is included in Windows. Pages are rendered with the [Windows.Data.Pdf](https://learn.microsoft.com/en-us/uwp/api/windows.data.pdf) API. Python is not required. |
| Linux, macOS | Python 3.8 or later with the `venv` module. The installer adds [pypdfium2](https://github.com/pypdfium2-team/pypdfium2) and [Pillow](https://python-pillow.org/) in a separate virtual environment. |

## Installation

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/nambobi/SimpoConverter/main/install.ps1 | iex
```

Linux and macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/nambobi/SimpoConverter/main/install.sh | bash
```

Both installers install for the current user only. On Ubuntu and Debian, install the `python3-venv` package first if it is missing.

To run the Windows version without installing it, download the repository and double-click `SimpoConverter.bat`, or drop PDF files on it.

## Usage

Guided mode:

```
simpoconv
```

```
Drag a PDF file or folder here and press Enter:
> "D:\Reports\Monthly Report.pdf"
Format (png, jpg, tiff, bmp) [png]: jpg
Resolution in dpi (150 for screen, 300 for print) [150]: 300
Pages, e.g. 1-3,5 [all]: 1-3
```

The output folder opens when the conversion is finished.

Windows examples:

```powershell
simpoconv "report.pdf"
simpoconv "report.pdf" -f jpg -d 300 -p 1-3,7
simpoconv "D:\Scans" -r -o "D:\Scans\images"
simpoconv "statement.pdf" -Password mypass -g
```

Linux and macOS examples:

```bash
simpoconv report.pdf
simpoconv report.pdf -f jpg -d 300 -p 1-3,7
simpoconv ~/Scans -r -o ~/Scans/images
simpoconv statement.pdf --password mypass -g
```

## Options

| Windows | Linux, macOS | Description | Default |
|---|---|---|---|
| `-f`, `-Format` | `-f`, `--format` | `png`, `jpg`, `tiff` or `bmp`; `webp` on Linux and macOS only | `png` |
| `-d`, `-Dpi` | `-d`, `--dpi` | Resolution in dots per inch, 10-1200 | `150` |
| `-p`, `-Pages` | `-p`, `--pages` | Pages to convert, e.g. `1-3,5,10-` (`10-` means page 10 to the last page) | all pages |
| `-o`, `-Output` | `-o`, `--output` | Output folder | `<pdf name>_images` next to each PDF |
| `-q`, `-Quality` | `-q`, `--quality` | JPG quality, 1-100 (also WEBP on Linux and macOS) | `90` |
| `-g`, `-Gray` | `-g`, `--gray` | Save grayscale images | off |
| `-Password` | `--password` | Password for a protected PDF. If omitted, the password is requested. | |
| `-r`, `-Recurse` | `-r`, `--recursive` | Include sub-folders | off |
| `-Overwrite` | `--overwrite` | Convert pages again even if the image exists | off |
| `-Open` | `--open` | Open the output folder when finished | off |

## Commands

| Command | Description |
|---|---|
| `simpoconv update` | Install the latest version from this repository |
| `simpoconv version` | Show the installed version |
| `simpoconv help` | Show help |
| `simpoconv uninstall` | Remove SimpoConverter |

SimpoConverter checks for a new version at most once a day, with a 3-second timeout, and prints a message if one is available.

## Output file names

Images are named after the PDF file and the page number:

```
Monthly Report_page_001.png
Monthly Report_page_002.png
```

If several PDF files are saved to one `-o` folder and two of them have the same name, for example `2025\report.pdf` and `2026\report.pdf`, the parent folder name is added: `2025_report_page_001.png`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All pages converted |
| 1 | One or more pages or files failed |
| 2 | Invalid option; on Linux and macOS, also a missing package |
| 130 | Interrupted with Ctrl+C (Linux and macOS) |

## Notes

- WEBP is not available on Windows because the Windows version saves images with System.Drawing (GDI+), which has no WEBP encoder.
- The Windows version uses Windows Runtime types and therefore runs in Windows PowerShell 5.1 (`powershell.exe`). The `simpoconv` command and `SimpoConverter.bat` start it with Windows PowerShell 5.1.

## Files

| File | Description |
|---|---|
| `simpoconv.ps1` | Windows version |
| `simpoconv.py` | Linux and macOS version |
| `install.ps1`, `install.sh` | Installers |
| `SimpoConverter.bat` | Runs the Windows version without installing it |
| `requirements.txt` | Python packages for the Linux and macOS version |
| `VERSION`, `CHANGELOG.md` | Used by `simpoconv update` |

## License

MIT. See [LICENSE](LICENSE).
