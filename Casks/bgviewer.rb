cask "bgviewer" do
  version "1.0.0"
  sha256 "fcec91b4882ce6a909e8bc68702c47fb06b4c1efdb08a6fd7fbf0e634b3e2683"

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
