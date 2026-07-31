require "../spec_helper"

describe Fluxion::PublicUrl do
  it "leaves an ordinary URL alone" do
    Fluxion::PublicUrl.from("https://example.test/rg.tar.gz")
      .should eq("https://example.test/rg.tar.gz")
  end

  it "drops signed-request query parameters" do
    Fluxion::PublicUrl.from("https://example.test/rg?X-Amz-Signature=deadbeef")
      .should eq("https://example.test/rg")
  end

  it "drops fragments" do
    Fluxion::PublicUrl.from("https://example.test/rg#token").should eq("https://example.test/rg")
  end

  it "truncates at whichever of ? and # comes first" do
    Fluxion::PublicUrl.from("https://example.test/rg#a?b").should eq("https://example.test/rg")
    Fluxion::PublicUrl.from("https://example.test/rg?a#b").should eq("https://example.test/rg")
  end

  it "removes user-info credentials" do
    Fluxion::PublicUrl.from("https://user:hunter2@example.test/rg")
      .should eq("https://example.test/rg")
  end

  it "uses the last @ in the authority, since a password may contain one" do
    Fluxion::PublicUrl.from("https://user:p@ss@example.test/rg")
      .should eq("https://example.test/rg")
  end

  it "does not mistake an @ in the path for credentials" do
    Fluxion::PublicUrl.from("https://example.test/@scope/pkg")
      .should eq("https://example.test/@scope/pkg")
  end

  it "handles a URL with no scheme separator" do
    Fluxion::PublicUrl.from("/etc/apt/keyrings/docker.gpg")
      .should eq("/etc/apt/keyrings/docker.gpg")
  end

  it "strips credentials and query together" do
    Fluxion::PublicUrl.from("https://user:pw@example.test/rg?sig=1")
      .should eq("https://example.test/rg")
  end
end
