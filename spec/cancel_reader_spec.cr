require "./spec_helper"

class BlockingReader < IO
  @read = false
  @unblock_ch = Channel(Bool).new
  @started_ch = Channel(Bool).new
  @closed = false

  def initialize
    super
  end

  def read(slice : Bytes) : Int32
    @started_ch.send(true)
    @unblock_ch.receive
    @read = true
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("not implemented")
  end

  def close
    @closed = true
  end

  def closed? : Bool
    @closed
  end

  def flush
    # no-op
  end

  def read? : Bool
    @read
  end

  def unblock_ch
    @unblock_ch
  end

  def started_ch
    @started_ch
  end
end

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

  # Port of TestFallbackReaderConcurrentCancel from cancelreader_fallback_test.go
  describe "fallback reader concurrent cancellation" do
    it "waits for reader before cancelling" do
      r = BlockingReader.new
      cr = CancelReader.new_reader(r)

      done_ch = Channel(Bool).new
      spawn do
        expect_raises(CancelReader::CanceledError) do
          cr.read(Bytes.new(1))
        end
        done_ch.send(true)
      end

      # make sure the read started before canceling the reader
      r.started_ch.receive
      cr.cancel.should be_false
      r.unblock_ch.send(true)

      # wait for the read to end to ensure its assertions were made
      select
      when done_ch.receive
      when timeout(100.milliseconds)
        fail "expected read to complete"
      end

      # make sure that it waited for the reader
      r.read?.should be_true
    end
  end

  # Port of TestFallbackReader from cancelreader_fallback_test.go
  describe "fallback reader basic functionality" do
    it "reads data before cancellation" do
      io = IO::Memory.new("first")
      cr = CancelReader.new_reader(io)

      slice = Bytes.new(5)
      n = cr.read(slice)
      n.should eq(5)
      String.new(slice[0, n]).should eq("first")
    end

    it "returns ErrCanceled after cancellation" do
      io = IO::Memory.new("data")
      cr = CancelReader.new_reader(io)
      cr.cancel.should be_false

      expect_raises(CancelReader::CanceledError) do
        cr.read(Bytes.new(1))
      end
    end
  end

  # Port of TestReaderNonFile from cancelreader_test.go
  describe "non-file reader" do
    it "cannot cancel non-file reader" do
      io = IO::Memory.new("")
      cr = CancelReader.new_reader(io)
      cr.cancel.should be_false
    end
  end
end

{% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
  describe "BSD kqueue reader", tags: "bsd" do
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

    it "cancels a read with data available" do
      reader, writer = IO.pipe
      cancel_reader = CancelReader.new_reader(reader)

      # Write data to pipe
      msg = "hello"
      writer.write(msg.to_slice)
      writer.flush

      # Variables to capture read result
      read_bytes = Channel(Int32).new(1)
      read_error = Channel(Exception?).new(1)

      # Spawn a fiber that will read
      done = Channel(Nil).new
      spawn do
        slice = Bytes.new(1)
        begin
          n = cancel_reader.read(slice)
          read_bytes.send(n)
          read_error.send(nil)
        rescue e
          read_bytes.send(0)
          read_error.send(e)
        end
        done.send(nil)
      end

      # Cancel before yielding to fiber (so cancellation flag is set)
      cancel_reader.cancel.should be_true

      # Give fiber a chance to run
      Fiber.yield

      # Wait for fiber to finish
      select
      when done.receive
      when timeout(100.milliseconds)
        fail "expected cancellation to unblock reader"
      end

      # Check read result
      n = read_bytes.receive
      err = read_error.receive
      n.should eq(0)
      err.should be_a(CancelReader::CanceledError)

      # Test that read is still possible after cancellation with new reader
      cancel_reader2 = CancelReader.new_reader(reader)
      slice = Bytes.new(5)
      n = cancel_reader2.read(slice)
      n.should eq(5)
      String.new(slice).should eq(msg)
    end
  end
{% end %}

{% if flag?(:linux) %}
  describe "Linux epoll reader", tags: "linux" do
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

    it "cancels a read with data available" do
      reader, writer = IO.pipe
      cancel_reader = CancelReader.new_reader(reader)

      # Write data to pipe
      msg = "hello"
      writer.write(msg.to_slice)
      writer.flush

      # Variables to capture read result
      read_bytes = Channel(Int32).new
      read_error = Channel(Exception?).new

      # Spawn a fiber that will read
      done = Channel(Nil).new
      spawn do
        slice = Bytes.new(1)
        begin
          n = cancel_reader.read(slice)
          read_bytes.send(n)
          read_error.send(nil)
        rescue e
          read_bytes.send(0)
          read_error.send(e)
        end
        done.send(nil)
      end

      # Cancel before yielding to fiber (so cancellation flag is set)
      cancel_reader.cancel.should be_true

      # Ensure cancellation signal is processed
      Fiber.yield

      # Give fiber a chance to run
      Fiber.yield

      # Wait for fiber to finish
      select
      when done.receive
      when timeout(500.milliseconds)
        fail "expected cancellation to unblock reader"
      end

      # Check read result
      n = read_bytes.receive
      err = read_error.receive
      n.should eq(0)
      err.should be_a(CancelReader::CanceledError)

      # Test that read is still possible after cancellation with new reader
      cancel_reader2 = CancelReader.new_reader(reader)
      slice = Bytes.new(5)
      n = cancel_reader2.read(slice)
      n.should eq(5)
      String.new(slice).should eq(msg)
    end
  end
{% end %}
