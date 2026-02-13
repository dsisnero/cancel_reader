require "./spec_helper"

describe CancelReader do
  it "defines ErrCanceled" do
    CancelReader::ErrCanceled.should be_a(Exception)
    CancelReader::ErrCanceled.message.should eq("read canceled")
  end

  it "can raise ErrCanceled" do
    expect_raises(Exception, "read canceled") do
      raise CancelReader::ErrCanceled
    end
  end

  describe "fallback reader" do
    it "returns false from cancel for non-file readers" do
      io = IO::Memory.new("data")
      reader = CancelReader.new_reader(io)
      reader.should be_a(CancelReader::Reader)
      reader.cancel.should be_false
    end

    it "reads data before cancellation" do
      io = IO::Memory.new("hello")
      reader = CancelReader.new_reader(io)
      slice = Bytes.new(5)
      bytes_read = reader.read(slice)
      bytes_read.should eq(5)
      String.new(slice).should eq("hello")
      reader.cancel.should be_false
    end

    it "returns ErrCanceled after cancellation" do
      io = IO::Memory.new("data")
      reader = CancelReader.new_reader(io)
      reader.cancel
      expect_raises(CancelReader::CanceledError) do
        slice = Bytes.new(1)
        reader.read(slice)
      end
    end
  end

  it "defines File interface" do
    CancelReader::File.is_a?(Class).should be_true
  end

  it "defines CancelReader abstract class" do
    CancelReader::Reader.is_a?(Class).should be_true
  end
end

describe CancelReader::CancelMixin do
  it "tracks cancellation status thread-safely" do
    mixin = CancelReader::CancelMixin.new
    mixin.canceled?.should be_false
    mixin.cancel
    mixin.canceled?.should be_true
  end
end

{% if flag?(:linux) %}
  describe "Linux epoll reader", tags: "linux" do
    it "cancels a file read" do
      # create temp file with data
      path = nil
      File.tempfile("cancel_test") do |f|
        f.print "hello"
        path = f.path
      end
      file = File.open(path, "r")
      reader = CancelReader.new_reader(file)
      spawn do
        reader.cancel
      end
      expect_raises(CancelReader::CanceledError) do
        slice = Bytes.new(5)
        reader.read(slice)
      end
      file.close
    end

    it "cancel returns true when successful" do
      path = nil
      File.tempfile("cancel_test") do |f|
        f.print "test"
        path = f.path
      end
      file = File.open(path, "r")
      reader = CancelReader.new_reader(file)
      reader.cancel.should be_true
      file.close
    end
  end
{% end %}
