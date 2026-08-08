# Burrow 0.12.0

Burrow's admin operations can now authenticate with **Touch ID**.

Until now every elevated action went through macOS's classic authorization
dialog, which is password-only by construction — it never offers Touch ID, and
it can't be cancelled safely. This release adds an optional signed helper that
replaces that path.

## Added
- **Touch ID for admin operations.** Install the helper in **Settings ▸
  Advanced ▸ Privileged helper** and Clean, Optimize, the admin scan previews,
  Flush DNS, Renew DHCP, and the Login Items list all authenticate through the
  system's normal prompt — which offers Touch ID where the hardware has it, and
  falls back to your password everywhere else.
- **The Login Items list is now complete.** Reading it needs root, so
  previously macOS raised its own unexplained "sfltool wants to make changes"
  prompt and still returned only a partial list. Through the helper it's one
  prompt you recognise, and the full list.

## What the helper can and cannot do

It is strictly opt-in, takes its own one-time macOS approval, and grants no
standing access — you authenticate for each operation you start.

It accepts seven fixed operations and builds every command line itself. There
is no field in its API for a path, a shell string, or an executable, so it
cannot be asked to run anything else. It runs the engine sealed inside the
signed app plus four Apple tools by absolute path, each as a separate process
with no shell involved. Only Burrow can talk to it: callers are pinned to the
app's bundle identifier and signing team by the system.

One honest caveat: the credential from your authentication stays valid for ten
seconds, because it has to survive the hop from the app to the helper. A second
operation begun inside that window won't prompt again. Full detail in
[SECURITY.md](https://github.com/caezium/Burrow/blob/main/SECURITY.md).

Not installing it changes nothing — every operation keeps working exactly as it
does today, through the existing password prompt. You can remove the helper at
any time from Settings, or from System Settings ▸ General ▸ Login Items &
Extensions.

## Changed
- **Flush DNS no longer runs a root shell.** It previously elevated
  `/bin/sh -c "dscacheutil -flushcache; killall -HUP mDNSResponder"`, handing a
  command string to a shell running as root. It's now two separate processes
  with fixed arguments.
- **Removed the "Touch ID for sudo" setting.** It configured `pam_tid` for
  terminal `sudo` and never affected Burrow's own admin prompts, which is what
  people expected it to do. Those prompts are what the privileged helper now
  covers. Nothing already configured on your Mac is changed by removing it; to
  undo it yourself, run `mo touchid disable`.

## Fixed
- A failed elevated run could report "Done — caches cleared" when nothing had
  actually run. Failures now say so.
