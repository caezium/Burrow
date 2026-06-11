# Homebrew cask for Burrow.
#
# This is a template for a tap (e.g. caezium/homebrew-tap). After a GitHub
# release, set `version` + `sha256` (scripts/release.sh prints both), copy
# this to `Casks/burrow.rb` in the tap, and users install with:
#
#   brew install --cask caezium/tap/burrow
#
cask "burrow" do
  version "0.4.0"
  sha256 "1db64cb10da2c63b203b1dc012c8b57b27003882f4b47db93da8869b7bb67c33"

  url "https://github.com/caezium/Burrow/releases/download/v#{version}/Burrow-#{version}.zip"
  name "Burrow"
  desc "Free, open-source native GUI for the Mole CLI"
  homepage "https://github.com/caezium/Burrow"

  depends_on formula: "mole"
  # Homebrew 5.1.11 (May 2026) changed `depends_on macos: :sonoma` from
  # "exactly Sonoma" to "Sonoma or newer" and deprecated the `">= :sonoma"`
  # string form (a hard error under HOMEBREW_DEVELOPER). Branch so both old
  # and new Homebrew get "macOS 14 or newer" with no warning.
  # TODO: drop the legacy branch once pre-5.1.11 Homebrew is rare (~2027).
  if Version.new(HOMEBREW_VERSION.split("-").first) >= Version.new("5.1.11")
    depends_on macos: :sonoma
  else
    depends_on macos: ">= :sonoma"
  end

  app "Burrow.app"

  # PATH shim so coding agents can spawn the MCP server as `burrow mcp`
  # without hardcoding the .app bundle path. The same binary serves the
  # GUI (no args) and the stdio MCP server (`mcp` / `--mcp`).
  binary "#{appdir}/Burrow.app/Contents/MacOS/Burrow", target: "burrow"

  # Pre-1.0 builds aren't notarized yet, so clear the quarantine flag to
  # avoid a Gatekeeper block on first launch. Remove this once the app
  # ships signed + notarized.
  postflight do
    system_command "/usr/bin/xattr", args: ["-cr", "#{appdir}/Burrow.app"], sudo: false
  end

  caveats <<~EOS
    Burrow is an unsigned pre-1.0 build. If macOS still blocks it, right-click
    the app and choose Open, or run:  xattr -cr "#{appdir}/Burrow.app"
  EOS

  zap trash: [
    "~/Library/Application Support/Burrow",
    "~/Library/Caches/dev.caezium.Burrow",
    "~/Library/HTTPStorages/dev.caezium.Burrow",
    "~/Library/Preferences/dev.caezium.Burrow.plist",
    "~/Library/Saved Application State/dev.caezium.Burrow.savedState",
  ]
end
