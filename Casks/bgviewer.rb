cask "bgviewer" do
  version "1.0.1"
  sha256 "7e863aea98fbfa25732576f067cfdbc205ac1b5bd4db4a35122baa2408d8f8ce"

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
