require "./spec_helper"

describe CancelReader do
  it "defines ErrCanceled" do
    CancelReader::ErrCanceled.should be_a(Exception)
    CancelReader::ErrCanceled.message.should eq("read canceled")
  end
end
