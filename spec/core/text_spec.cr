require "../spec_helper"

describe Fluxion::Text do
  describe ".pluralize" do
    it "adds an s to everything but one" do
      Fluxion::Text.pluralize(0, "package").should eq("0 packages")
      Fluxion::Text.pluralize(1, "package").should eq("1 package")
      Fluxion::Text.pluralize(2, "package").should eq("2 packages")
    end

    it "counts a multi-word noun as a whole" do
      Fluxion::Text.pluralize(3, "signing key").should eq("3 signing keys")
    end
  end

  describe ".singular_or_plural" do
    it "gives the noun on its own, for a sentence that places the count elsewhere" do
      Fluxion::Text.singular_or_plural(1, "phase").should eq("phase")
      Fluxion::Text.singular_or_plural(4, "phase").should eq("phases")
    end
  end
end
