cask "bgviewer" do
  version "1.2.0"
  sha256 "92b07099f6ddb0be982d1f85dfa419fe3045445824f70903eb65d336f8d8728b"

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
