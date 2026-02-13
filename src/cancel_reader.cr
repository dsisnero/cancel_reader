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

  {% if flag?(:linux) %}
    lib LibC
      # epoll constants
      EPOLLIN       = 0x001_u32
      EPOLL_CTL_ADD =         1
      EPOLL_CTL_DEL =         2
      EPOLL_CTL_MOD =         3

      fun epoll_create1(flags : Int32) : Int32
      fun epoll_ctl(epfd : Int32, op : Int32, fd : Int32, event : EpollEvent*) : Int32
      fun epoll_wait(epfd : Int32, events : EpollEvent*, maxevents : Int32, timeout : Int32) : Int32

      struct EpollEvent
        events : UInt32
        data : UInt64
      end
    end
  {% end %}

  {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
    lib LibC
      # kqueue constants
      EVFILT_READ =  -1
      EV_ADD      = 0x1

      fun kqueue : Int32
      fun kevent(kq : Int32, changelist : Kevent*, nchanges : Int32, eventlist : Kevent*, nevents : Int32, timeout : Void*) : Int32

      struct Kevent
        ident : UInt64
        filter : Int16
        flags : UInt16
        fflags : UInt32
        data : Int64
        udata : Void*
      end
    end
  {% end %}

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

  # Wraps an IO::FileDescriptor to implement CancelReader::File interface.
  private class FileWrapper < File
    def initialize(@io : IO::FileDescriptor)
    end

    def fd : UInt64
      @io.fd.to_u64
    end

    def name : String
      @io.path.to_s
    end

    def read(slice : Bytes) : Int32
      @io.read(slice)
    end

    def write(slice : Bytes) : Nil
      @io.write(slice)
    end

    def flush : Nil
      @io.flush
    end

    def close : Nil
      @io.close
    end
  end

  # Converts an IO to CancelReader::File if possible (i.e., has a file descriptor).
  private def self.as_file(io : IO) : CancelReader::File?
    if io.is_a?(IO::FileDescriptor)
      FileWrapper.new(io)
    end
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

  {% if flag?(:linux) %}
    # epollCancelReader implements CancelReader using Linux epoll mechanism.
    class EpollCancelReader < Reader
      def initialize(file : CancelReader::File)
        @file = file
        @mixin = CancelMixin.new
        @epoll = LibC.epoll_create1(0)
        if @epoll == -1
          raise IO::Error.new("Failed to create epoll")
        end

        # create pipe for cancel signal
        reader, writer = IO.pipe
        @cancel_signal_reader = reader
        @cancel_signal_writer = writer

        # add file fd to epoll
        ev = LibC::EpollEvent.new
        ev.events = LibC::EPOLLIN
        ev.data = file.fd.to_u64
        if LibC.epoll_ctl(@epoll, LibC::EPOLL_CTL_ADD, file.fd.to_i32, pointerof(ev)) == -1
          LibC.close(@epoll)
          raise IO::Error.new("Failed to add file to epoll")
        end

        # add pipe read fd to epoll
        ev2 = LibC::EpollEvent.new
        ev2.events = LibC::EPOLLIN
        ev2.data = @cancel_signal_reader.fd.to_u64
        if LibC.epoll_ctl(@epoll, LibC::EPOLL_CTL_ADD, @cancel_signal_reader.fd, pointerof(ev2)) == -1
          LibC.close(@epoll)
          raise IO::Error.new("Failed to add pipe to epoll")
        end
      end

      def read(slice : Bytes) : Int32
        if @mixin.canceled?
          raise ErrCanceled
        end

        wait_for_readable
        @file.read(slice)
      end

      def cancel : Bool
        @mixin.cancel
        # send cancel signal
        begin
          @cancel_signal_writer.write(Bytes.new(1, 'c'.ord.to_u8))
          true
        rescue
          false
        end
      end

      def close : Nil
        # close epoll
        LibC.close(@epoll) if @epoll != -1
        @cancel_signal_reader.close
        @cancel_signal_writer.close
      end

      private def wait_for_readable
        event = LibC::EpollEvent.new
        loop do
          ret = LibC.epoll_wait(@epoll, pointerof(event), 1, -1)
          if ret == -1
            err = Errno.value
            if err == Errno::EINTR
              next
            else
              raise IO::Error.from_errno("epoll_wait failed")
            end
          end
          break
        end

        if event.data == @file.fd.to_u64
          return
        elsif event.data == @cancel_signal_reader.fd.to_u64
          # read the signal byte
          buf = Bytes.new(1)
          @cancel_signal_reader.read(buf)
          raise ErrCanceled
        else
          raise IO::Error.new("Unknown fd in epoll event")
        end
      end
    end
  {% end %}

  {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
    class KqueueCancelReader < Reader
      def initialize(file : CancelReader::File)
        @file = file
        @mixin = CancelMixin.new
        @kqueue = LibC.kqueue
        if @kqueue == -1
          raise IO::Error.new("Failed to create kqueue")
        end

        # create pipe for cancel signal
        reader, writer = IO.pipe
        @cancel_signal_reader = reader
        @cancel_signal_writer = writer

        # setup kevents array (2 events)
        @kqueue_events = StaticArray(LibC::Kevent, 2).new { LibC::Kevent.new }

        # set up kevent for file fd
        set_kevent(@kqueue_events[0], file.fd.to_i32, LibC::EVFILT_READ, LibC::EV_ADD)
        # set up kevent for pipe fd
        set_kevent(@kqueue_events[1], @cancel_signal_reader.fd, LibC::EVFILT_READ, LibC::EV_ADD)
      end

      def read(slice : Bytes) : Int32
        if @mixin.canceled?
          raise ErrCanceled
        end

        wait_for_readable
        @file.read(slice)
      end

      def cancel : Bool
        @mixin.cancel
        # send cancel signal
        begin
          @cancel_signal_writer.write(Bytes.new(1, 'c'.ord.to_u8))
          true
        rescue
          false
        end
      end

      def close : Nil
        # close kqueue
        LibC.close(@kqueue) if @kqueue != -1
        @cancel_signal_reader.close
        @cancel_signal_writer.close
      end

      private def set_kevent(kevent : LibC::Kevent*, fd : Int32, filter : Int16, flags : UInt16)
        kevent.value.ident = fd.to_u64
        kevent.value.filter = filter
        kevent.value.flags = flags
        kevent.value.fflags = 0_u32
        kevent.value.data = 0_i64
        kevent.value.udata = Pointer(Void).null
      end

      private def wait_for_readable
        events = StaticArray(LibC::Kevent, 1).new { LibC::Kevent.new }
        loop do
          ret = LibC.kevent(@kqueue, @kqueue_events.to_unsafe, 2, events.to_unsafe, 1, nil)
          if ret == -1
            err = Errno.value
            if err == Errno::EINTR
              next
            else
              raise IO::Error.from_errno("kevent failed")
            end
          end
          break
        end

        ident = events[0].ident
        if ident == @file.fd.to_u64
          return
        elsif ident == @cancel_signal_reader.fd.to_u64
          # read the signal byte
          buf = Bytes.new(1)
          @cancel_signal_reader.read(buf)
          raise ErrCanceled
        else
          raise IO::Error.new("Unknown fd in kevent")
        end
      end
    end
  {% end %}

  # NewReader returns a reader with a cancel function.
  def self.new_reader(reader : IO) : Reader
    # Try to get a CancelReader::File representation
    file = if reader.is_a?(CancelReader::File)
             reader
           else
             as_file(reader)
           end

    if file
      {% if flag?(:linux) %}
        return EpollCancelReader.new(file)
      {% end %}
      {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
        return KqueueCancelReader.new(file)
      {% end %}
    end

    FallbackReader.new(reader)
  end
end
