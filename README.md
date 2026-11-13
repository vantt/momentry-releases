# momentry releases

Binary releases of [momentry](https://momentry.cc): it watches your coding-agent sessions on your own machine and
turns the moments worth telling into stories. This repo holds only the release files (archives, installers,
`checksums.txt`) and the workflow that smoke-tests each release before it is published. There is no source code here.

## Platforms

| OS | CPU | Asset |
|---|---|---|
| Linux | x86-64 | `momentry-vX.Y.Z-linux-amd64.tar.gz` |
| Linux | ARM64 | `momentry-vX.Y.Z-linux-arm64.tar.gz` |
| macOS | Intel | `momentry-vX.Y.Z-darwin-amd64.tar.gz` |
| macOS | Apple silicon | `momentry-vX.Y.Z-darwin-arm64.tar.gz` |
| Windows 10/11 | x86-64 (ARM64 runs it through emulation) | `momentry-vX.Y.Z-windows-amd64.tar.gz` |

## Install

Linux, macOS, WSL:

```sh
curl -fsSL https://github.com/vantt/momentry-releases/releases/latest/download/install.sh | sh
```

Windows (PowerShell, as your normal user, not as Administrator):

```powershell
irm https://github.com/vantt/momentry-releases/releases/latest/download/install.ps1 | iex
```

Then, in a git repo: `momentry init`.

The installer downloads `checksums.txt` and your platform's archive over HTTPS, refuses the archive unless its
SHA-256 matches, installs per user (no root, no admin), and keeps the previous version next to the new one.

### A fixed version

```sh
curl -fsSL https://github.com/vantt/momentry-releases/releases/latest/download/install.sh | sh -s -- --version v1.2.3
```

```powershell
$env:MOMENTRY_VERSION = 'v1.2.3'; irm https://github.com/vantt/momentry-releases/releases/latest/download/install.ps1 | iex
```

`sh -s -- --help` lists every option (install dir, home, dry run, uninstall).

### Check an archive by hand

Download the archive and `checksums.txt` of the same release into one folder, then:

```sh
sha256sum -c --ignore-missing checksums.txt          # Linux
shasum -a 256 -c --ignore-missing checksums.txt      # macOS
```

```powershell
(Get-FileHash .\momentry-v1.2.3-windows-amd64.tar.gz -Algorithm SHA256).Hash.ToLower()
Select-String 'windows-amd64' .\checksums.txt        # the two hashes must be equal
```

## Update and uninstall

```sh
momentry update --check        # is there a newer release?
momentry update                # install it; the previous version stays installed
momentry uninstall             # remove momentry and its hooks; keeps your config, cache and stories
momentry uninstall --purge     # also remove config and cache (stories in your repos are never touched)
```

`momentry update` never downgrades on its own. To go back: `momentry update --version vX.Y.Z --yes`.

## Unsigned binaries

The binaries are not code-signed yet; the SHA-256 check above is what proves a file is the one published here.
The one-line installers are not affected by macOS Gatekeeper. An archive downloaded with a browser may be blocked by
Gatekeeper, and Windows SmartScreen may warn about it: prefer the installers.

## Tiếng Việt

Bản phát hành binary của [momentry](https://momentry.cc). Cài:

- Linux, macOS, WSL: `curl -fsSL https://github.com/vantt/momentry-releases/releases/latest/download/install.sh | sh`
- Windows (PowerShell, user thường, không Administrator): `irm https://github.com/vantt/momentry-releases/releases/latest/download/install.ps1 | iex`

Rồi trong một git repo: `momentry init`. Cài một bản cố định: `sh -s -- --version v1.2.3` (Windows:
`$env:MOMENTRY_VERSION = 'v1.2.3'`). Kiểm archive bằng tay: `sha256sum -c --ignore-missing checksums.txt` (macOS:
`shasum -a 256`, Windows: `Get-FileHash`). Cập nhật: `momentry update`; gỡ: `momentry uninstall` (thêm `--purge`
để xoá cả cấu hình và cache). Binary chưa ký số: installer kiểm SHA-256; archive tải bằng trình duyệt có thể bị
Gatekeeper hay SmartScreen cảnh báo, nên dùng installer.
