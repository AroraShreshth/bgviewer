cask "bgviewer" do
  version "1.4.0"
  sha256 "1c9202b424df6a09614699a95fc66c7833a168f4594ace35d8c347d3c0f87c09"

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
