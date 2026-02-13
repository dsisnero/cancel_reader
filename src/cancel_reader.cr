# TODO: Write documentation for `CancelReader`
module CancelReader
  VERSION = "0.1.0"

  # Error returned when trying to read from a canceled reader.
  class CanceledError < Exception
    def initialize
      super("read canceled")
    end
  end

  ErrCanceled = CanceledError.new

  # cancelMixin represents a goroutine-safe cancellation status.
  class CancelMixin
    @canceled = false
    @lock = Mutex.new

    # Returns true if the reader has been canceled.
    def canceled? : Bool
      @lock.synchronize { @canceled }
    end

    # Marks the reader as canceled.
    def cancel : Nil
      @lock.synchronize { @canceled = true }
    end
  end

  # File represents an input/output resource with a file descriptor.
  abstract class File < IO
    abstract def fd : UInt64
    abstract def name : String
  end

  # CancelReader is a io.Reader whose Read() calls can be canceled without data
  # being consumed. The cancelReader has to be closed.
  abstract class Reader
    abstract def read(slice : Bytes) : Int32
    abstract def close : Nil
    abstract def cancel : Bool
  end

  # fallbackCancelReader implements CancelReader but does not actually support
  # cancellation during an ongoing Read() call. Thus, Cancel() always returns false.
  class FallbackReader < Reader
    def initialize(@reader : IO)
      @mixin = CancelMixin.new
    end

    def read(slice : Bytes) : Int32
      if @mixin.canceled?
        raise ErrCanceled
      end

      n = @reader.read(slice)
      # If the underlying reader is a blocking reader, a cancel may happen while
      # we are stuck in the read call. If that happens, we should still cancel.
      if @mixin.canceled?
        raise ErrCanceled
      end
      n
    end

    def close : Nil
      # nothing to close
    end

    def cancel : Bool
      @mixin.cancel
      false
    end
  end

  # NewReader returns a reader with a cancel function.
  def self.new_reader(reader : IO) : Reader
    FallbackReader.new(reader)
  end
end
