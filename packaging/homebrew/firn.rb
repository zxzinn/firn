class Firn < Formula
  desc "Native macOS Apple Silicon Docker, Kubernetes & Linux VM runtime"
  homepage "https://github.com/zxzinn/firn"
  url "https://github.com/zxzinn/firn.git", tag: "v0.4.0"
  license "Apache-2.0"
  head "https://github.com/zxzinn/firn.git", branch: "main"

  depends_on macos: :sonoma
  depends_on arch: :arm64
  depends_on "go" => :build

  def install
    system "make", "hostnet", "swift"
    bin.install "build/firn", "build/firnd", "build/firn-hostnet"
    prefix.install "build/Firn.app"
  end

  def caveats
    <<~EOS
      Run `firn doctor` to verify Apple Hypervisor, nested virtualization, and Linux VM images.
      Build guest Linux images locally via:
        git clone https://github.com/zxzinn/firn && cd firn && make rootfs
      Or start Firnbar from:
        #{prefix}/Firn.app
    EOS
  end

  test do
    assert_match "Firn 0.4.0", shell_output("#{bin}/firn version")
  end
end
