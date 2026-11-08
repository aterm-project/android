# Embedded Local Shell

On Windows, Linux and macOS, open the workspace **+** menu and choose **Local
Console**, an installed shell, or **Local shell options…**. The options dialog
lets you choose a shell and its starting directory. The session runs inside an
Atermius terminal tab through a PTY.

Windows choices include cmd, Windows PowerShell, PowerShell 7 and Git Bash when
installed. POSIX choices include bash, zsh, fish, sh and PowerShell 7 when found.
The system-default entry uses the host's normal shell. Browser and mobile
clients display an explanation that a desktop app is required.

Use the tab or pane controls to split horizontally or vertically, duplicate,
move between panes, close, or detach a desktop terminal window. Splitting a lone
Shell creates an independent PTY. Shell panes can share a layout with SSH,
Telnet, RDP, VNC and file panes. Input and resizing belong to the selected pane;
closing one Shell leaves the others running.

Duplicates preserve the selected shell and starting directory. Linux also
reads the current directory from the running shell when available; Windows and
macOS retain the configured starting directory. A serial Console keeps its COM
port and baud rate when duplicated or split. Opening the same serial port may
fail if the operating system already has it in use; it never falls back to a
Shell.

Saved window sets retain the shell kind and directory in the existing encrypted
layout storage. Executable paths and command strings are not accepted from a
saved layout. Older clients cannot read the additional shell settings. MCP's
existing `console_open` tool continues to open the default local shell; live
Shell sessions support the existing terminal read/input tools.

Input is limited to 1 MiB per batch and pending queue. Oversized pastes are
rejected as a whole. Output uses the existing bounded terminal scrollback.
The PTY belongs to its tab and is closed when the tab or local workspace closes.
