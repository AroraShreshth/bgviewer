cask "bgviewer" do
  version "1.6.0"
  sha256 "ee1813cf7f1b5b4815a5353365c9930c8728389776883415f847bca9af3b286b"

  url "https://github.com/AroraShreshth/bgviewer/releases/download/v#{version}/bgviewer-#{version}.zip"
  name "bgviewer"
  desc "Menu-bar kill-switch for macOS background services"
  homepage "https://github.com/AroraShreshth/bgviewer"

  depends_on macos: ">= :ventura"

  app "bgviewer.app"

  caveats <<~EOS
    bgviewer is not notarized yet. If macOS blocks the first launch, either
    reinstall with `--no-quarantine`, or run:
      xattr -d com.apple.quarantine /Applications/bgviewer.app
  EOS
end
