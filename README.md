# Ruby Catbox
<img width="1942" height="809" alt="ruby-catbox" src="https://github.com/user-attachments/assets/77376f9f-aeca-4291-80f8-5fb3af6eece6" />

Ruby Catbox is a command-line uploader for Catbox and Litterbox that supports file uploads, temporary uploads, remote URL uploads, deletion, albums, user hashes, colored output, progress indicators, and clipboard copying.

## Gems Used

- `faraday` and `faraday-multipart` for HTTP multipart uploads
- `pastel` for colored terminal output
- `tty-progressbar` for per-session progress bars
- `tty-spinner` for progress feedback
- `clipboard` for copying uploaded links and album URLs

## Setup

```sh
bundle install
```

## Windows Compatibility

This CLI should work on Windows when run through Ruby. Use:

```powershell
ruby bin/catbox help
ruby bin/catbox file image.png
ruby bin/catbox temp image.png 12h
```

Notes for Windows:

- Install Ruby for Windows first, then run `bundle install`.
- Prefer `ruby bin/catbox ...` unless you have configured executable Ruby scripts in your shell.
- The clipboard feature uses the `clipboard` gem. Uploading still works if clipboard copying is unavailable.
- Bash/Zsh alias commands below are for Linux, macOS, WSL, and Git Bash. For PowerShell, use a function instead.

PowerShell function example:

```powershell
function catbox { ruby "C:\path\to\ruby-catbox\bin\catbox" @args }
```

To make it permanent, add that function to your PowerShell profile:

```powershell
notepad $PROFILE
```

## Command Alias

By default, run the CLI with `bin/catbox`. To use `catbox` from anywhere, add a shell alias.

Replace `/path/to/ruby-catbox` with the directory where this project is cloned:

```sh
echo 'alias catbox="/path/to/ruby-catbox/bin/catbox"' >> ~/.bashrc
source ~/.bashrc
```

For Zsh, use `~/.zshrc` instead:

```sh
echo 'alias catbox="/path/to/ruby-catbox/bin/catbox"' >> ~/.zshrc
source ~/.zshrc
```

After that, you can run:

```sh
catbox help
catbox file image.png
```

You can also add this project's `bin` directory to your `PATH` instead of using an alias:

```sh
echo 'export PATH="/path/to/ruby-catbox/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Usage

```sh
bin/catbox help
bin/catbox user
bin/catbox user <hash>
bin/catbox user off
bin/catbox file image.png notes.txt
bin/catbox temp scratch.log 1h
bin/catbox url https://example.com/file.zip
bin/catbox delete abc123.png
```

Album commands match the original Bash behavior:

```sh
bin/catbox album create "Title" "Description" file1.png file2.png
bin/catbox album edit abcd "Title" "Description" file1.png
bin/catbox album add abcd file3.png
bin/catbox album remove abcd file1.png
bin/catbox album delete abcd
```

Global options:

```sh
-s, --silent              Only print result links
-S, --silent-all          Hide normal output and errors
-n, --no-color            Turn off colored output
-u, --user-hash HASH      Use this hash for the command
-V, --verbose             Show more album details
```

Global options can be placed before or after a command:

```sh
bin/catbox --no-color help
bin/catbox help --no-color
bin/catbox --user-hash HASH file image.png
bin/catbox file image.png --user-hash HASH
```
