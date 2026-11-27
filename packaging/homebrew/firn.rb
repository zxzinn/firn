class Firn < Formula
  desc "Native macOS Apple Silicon Docker, Kubernetes & Linux VM runtime"
  homepage "https://github.com/zxzinn/firn"
  url "https://github.com/zxzinn/firn/releases/download/v0.5.0/firn-darwin-arm64.tar.gz"
  version "0.5.0"
  sha256 "fc088926f9062582863f681aae1f3a6e093bf09ca288747971546d3d47f5238b"
  license "Apache-2.0"
  head "https://github.com/zxzinn/firn.git", branch: "main"

  depends_on macos: :sonoma
  depends_on arch: :arm64
  depends_on "go" => :build if build.head?

  def install
    if build.head?
      system "make", "hostnet", "swift"
      bin.install "build/firn", "build/firnd", "build/firn-hostnet"
      bin.install "build/entitlements.plist" if File.exist?("build/entitlements.plist")
      prefix.install "build/Firn.app"
    else
      bin.install "firn", "firnd", "firn-hostnet"
      bin.install "entitlements.plist" if File.exist?("entitlements.plist")
      prefix.install "Firn.app"
    end
    if File.exist?(bin/"entitlements.plist")
      system "codesign", "--entitlements", bin/"entitlements.plist", "--force", "-s", "-", bin/"firnd"
    end
  end

  def caveats
    <<~EOS
      Run `firn doctor` to check Hypervisor, Nested KVM, and guest images.
      `firn up` downloads matching Linux VM images automatically on first run
      (or run `firn images pull`).
      Open FirnBar via `firn gui` or:
        #{prefix}/Firn.app
    EOS
  end

  test do
    assert_match "Firn 0.5.0", shell_output("#{bin}/firn version")
  end
end
