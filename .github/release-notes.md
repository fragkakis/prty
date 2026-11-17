**Install:** download PRty-Time.zip, unzip it, move PRty Time.app to /Applications (not ~/Applications, where notifications show no icon) and open it. Needs macOS 15+ and a logged-in [GitHub CLI](https://cli.github.com) (`gh auth login`).

PRty Time isn't notarized by Apple, so macOS blocks the first launch. Open System Settings → Privacy & Security and click **Open Anyway**, or run `xattr -dr com.apple.quarantine "/Applications/PRty Time.app"`.
