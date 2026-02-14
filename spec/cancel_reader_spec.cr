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
  pending describe "Linux epoll reader", tags: "linux" do
    it "cancels a blocking read" do
      reader, writer = IO.pipe
      cancel_reader = CancelReader.new_reader(reader)

      # Spawn a fiber that will block reading
      done = Channel(Nil).new
      spawn do
        slice = Bytes.new(5)
        expect_raises(CancelReader::CanceledError) do
          cancel_reader.read(slice)
        end
        done.send(nil)
      end

      # Give fiber a chance to start blocking
      Fiber.yield

      # Cancel should succeed
      cancel_reader.cancel.should be_true

      # Wait for fiber to finish (should be unblocked by cancel)
      select
      when done.receive
      when timeout(100.milliseconds)
        fail "expected cancellation to unblock reader"
      end
    end

    it "cancel returns true when successful" do
      reader, writer = IO.pipe
      cancel_reader = CancelReader.new_reader(reader)
      cancel_reader.cancel.should be_true
      reader.close
      writer.close
    end
  end
{% end %}

{% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
  pending describe "BSD kqueue reader", tags: "bsd" do
    it "cancels a blocking read" do
      reader, writer = IO.pipe
      cancel_reader = CancelReader.new_reader(reader)

      # Spawn a fiber that will block reading
      done = Channel(Nil).new
      spawn do
        slice = Bytes.new(5)
        expect_raises(CancelReader::CanceledError) do
          cancel_reader.read(slice)
        end
        done.send(nil)
      end

      # Give fiber a chance to start blocking
      Fiber.yield

      # Cancel should succeed
      cancel_reader.cancel.should be_true

      # Wait for fiber to finish (should be unblocked by cancel)
      select
      when done.receive
      when timeout(100.milliseconds)
        fail "expected cancellation to unblock reader"
      end
    end

    it "cancel returns true when successful" do
      reader, writer = IO.pipe
      cancel_reader = CancelReader.new_reader(reader)
      cancel_reader.cancel.should be_true
      reader.close
      writer.close
    end
  end
{% end %}
