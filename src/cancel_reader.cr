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
end
