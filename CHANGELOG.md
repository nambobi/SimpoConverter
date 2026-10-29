# Changelog

## 1.0

- Converts PDF pages to PNG, JPG, TIFF and BMP images. WEBP is also supported on Linux and macOS.
- Options for resolution (dpi), page selection (for example `1-3,5,10-`), output folder, JPG quality and grayscale.
- Accepts several PDF files or folders; `-r` includes sub-folders.
- Supports password-protected PDF files.
- Skips pages that already have an image, so an interrupted run can be continued.
- Windows version uses Windows PowerShell 5.1 and the Windows.Data.Pdf API; Python is not required.
- Linux and macOS version uses Python 3 with pypdfium2 and Pillow.
- Installers for Windows and Linux/macOS; commands `update`, `version`, `help` and `uninstall`.
