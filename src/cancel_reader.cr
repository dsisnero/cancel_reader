module CancelReader
  VERSION = "0.1.0"

  # DEBUG = ENV["CANCEL_READER_DEBUG"]?

  # Error returned when trying to read from a canceled reader.
  class CanceledError < Exception
    def initialize
      super("read canceled")
    end
  end

  ErrCanceled = CanceledError.new

  {% if flag?(:linux) %}
    # Use global ::LibC epoll bindings
  {% end %}

  {% if flag?(:unix) %}
    lib LibC
      struct FdSet
        fds_bits : StaticArray(Int32, 32)
      end

      fun select(nfds : Int32, readfds : FdSet*, writefds : FdSet*, errorfds : FdSet*, timeout : ::LibC::Timeval*) : Int32
    end
  {% end %}

  # Maximum file descriptor number for select (POSIX limitation).
  # File descriptors >= FD_SETSIZE cannot be used with select.
  FD_SETSIZE = 1024

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
      io = @io
      if io.is_a?(File)
        io.path.to_s
      else
        ""
      end
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
      @file : CancelReader::File
      @mixin : CancelMixin
      @epoll : Int32
      @cancel_signal_reader : IO::FileDescriptor
      @cancel_signal_writer : IO::FileDescriptor

      def initialize(file : CancelReader::File)
        @file = file
        @mixin = CancelMixin.new
        @epoll = ::LibC.epoll_create1(0)
        if @epoll == -1
          raise IO::Error.new("Failed to create epoll")
        end

        # create pipe for cancel signal
        reader, writer = IO.pipe
        @cancel_signal_reader = reader
        @cancel_signal_writer = writer

        begin
          # add file fd to epoll
          ev = ::LibC::EpollEvent.new
          ev.events = ::LibC::EPOLLIN
          ev.data.u64 = file.fd.to_u64
          if ::LibC.epoll_ctl(@epoll, ::LibC::EPOLL_CTL_ADD, file.fd.to_i32, pointerof(ev)) == -1
            raise IO::Error.new("Failed to add file to epoll")
          end

          # add pipe read fd to epoll
          ev2 = ::LibC::EpollEvent.new
          ev2.events = ::LibC::EPOLLIN
          ev2.data.u64 = @cancel_signal_reader.fd.to_u64
          if ::LibC.epoll_ctl(@epoll, ::LibC::EPOLL_CTL_ADD, @cancel_signal_reader.fd, pointerof(ev2)) == -1
            raise IO::Error.new("Failed to add pipe to epoll")
          end
        rescue ex
          # cleanup on error
          ::LibC.close(@epoll) if @epoll != -1
          @cancel_signal_reader.close
          @cancel_signal_writer.close
          raise ex
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
          puts "DEBUG: cancel writing to fd #{@cancel_signal_writer.fd}" if ENV["CANCEL_READER_DEBUG"]?
          @cancel_signal_writer.write(Bytes.new(1, 'c'.ord.to_u8))
          puts "DEBUG: cancel write succeeded" if ENV["CANCEL_READER_DEBUG"]?
          true
        rescue
          puts "DEBUG: cancel write failed" if ENV["CANCEL_READER_DEBUG"]?
          false
        end
      end

      def close : Nil
        # close epoll
        ::LibC.close(@epoll) if @epoll != -1
        @cancel_signal_reader.close
        @cancel_signal_writer.close
      end

      private def wait_for_readable
        event = ::LibC::EpollEvent.new
        loop do
          if @mixin.canceled?
            raise ErrCanceled
          end

          ret = ::LibC.epoll_wait(@epoll, pointerof(event), 1, 50)  # 50ms timeout
          if ret == -1
            err = Errno.value
            if err == Errno::EINTR
              Fiber.yield
              next
            else
              raise IO::Error.from_errno("epoll_wait failed")
            end
          elsif ret == 0
            # timeout
            Fiber.yield
            next
          end

          if event.data.u64 == @file.fd.to_u64
            return
          elsif event.data.u64 == @cancel_signal_reader.fd.to_u64
            buf = Bytes.new(1)
            @cancel_signal_reader.read(buf)
            raise ErrCanceled
          else
            raise IO::Error.new("Unknown fd in epoll event")
          end
        end
      end
    end
  {% end %}

  {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
    class KqueueCancelReader < Reader
      @file : CancelReader::File
      @mixin : CancelMixin
      @kqueue : Int32
      @cancel_signal_reader : IO::FileDescriptor
      @cancel_signal_writer : IO::FileDescriptor
      @kqueue_events : StaticArray(::LibC::Kevent, 2)

      def initialize(file : CancelReader::File)
        @file = file
        @mixin = CancelMixin.new
        @kqueue = ::LibC.kqueue
        puts "DEBUG: kqueue fd = #{@kqueue}" if ENV["CANCEL_READER_DEBUG"]?
        if @kqueue == -1
          raise IO::Error.new("Failed to create kqueue")
        end

        # create pipe for cancel signal
        reader, writer = IO.pipe
        @cancel_signal_reader = reader
        @cancel_signal_writer = writer

        # setup kevents array (2 events)
        @kqueue_events = StaticArray(::LibC::Kevent, 2).new { ::LibC::Kevent.new }

        # set up kevent for file fd
        set_kevent(@kqueue_events.to_unsafe, file.fd.to_i32, ::LibC::EVFILT_READ, ::LibC::EV_ADD)
        # set up kevent for pipe fd
        set_kevent(@kqueue_events.to_unsafe + 1, @cancel_signal_reader.fd, ::LibC::EVFILT_READ, ::LibC::EV_ADD)
      end

      def read(slice : Bytes) : Int32
        STDERR.puts "DEBUG read: canceled?=#{@mixin.canceled?}" if ENV["CANCEL_READER_DEBUG"]?
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
          puts "DEBUG: cancel writing to fd #{@cancel_signal_writer.fd}" if ENV["CANCEL_READER_DEBUG"]?
          @cancel_signal_writer.write(Bytes.new(1, 'c'.ord.to_u8))
          puts "DEBUG: cancel write succeeded" if ENV["CANCEL_READER_DEBUG"]?
          true
        rescue
          puts "DEBUG: cancel write failed" if ENV["CANCEL_READER_DEBUG"]?
          false
        end
      end

      def close : Nil
        # close kqueue
        ::LibC.close(@kqueue) if @kqueue != -1
        @cancel_signal_reader.close
        @cancel_signal_writer.close
      end

      private def set_kevent(kevent : ::LibC::Kevent*, fd : Int32, filter : Int16, flags : UInt16)
        kevent.value.ident = fd.to_u64
        kevent.value.filter = filter
        kevent.value.flags = flags
        kevent.value.fflags = 0_u32
        kevent.value.data = 0_i64
        kevent.value.udata = Pointer(Void).null
        puts "DEBUG: set_kevent fd=#{fd}, filter=#{filter}, flags=#{flags}" if ENV["CANCEL_READER_DEBUG"]?
      end

      private def wait_for_readable
        events = StaticArray(::LibC::Kevent, 1).new { ::LibC::Kevent.new }
        if ENV["CANCEL_READER_DEBUG"]?
          @kqueue_events.each_with_index do |ev, i|
            puts "DEBUG: changelist[#{i}] ident=#{ev.ident}, filter=#{ev.filter}, flags=#{ev.flags}"
          end
        end

        loop do
          if @mixin.canceled?
            raise ErrCanceled
          end

          timeout = ::LibC::Timespec.new
          timeout.tv_sec = 0
          timeout.tv_nsec = 100_000_000

          puts "DEBUG: calling kevent with kqueue #{@kqueue}, changelist size 2, timeout 10ms" if ENV["CANCEL_READER_DEBUG"]?
          ret = ::LibC.kevent(@kqueue, @kqueue_events.to_unsafe, 2, events.to_unsafe, 1, pointerof(timeout))
          puts "DEBUG: kevent returned #{ret}" if ENV["CANCEL_READER_DEBUG"]?
          if ret == -1
            err = Errno.value
            puts "DEBUG: kevent error #{err}" if ENV["CANCEL_READER_DEBUG"]?
            if err == Errno::EINTR
              Fiber.yield
              next
            else
              raise IO::Error.from_errno("kevent failed")
            end
          elsif ret == 0
            Fiber.yield
            next
          end

          ident = events[0].ident
          puts "DEBUG: kevent ident #{ident}, file fd #{@file.fd.to_u64}, pipe fd #{@cancel_signal_reader.fd.to_u64}" if ENV["CANCEL_READER_DEBUG"]?
          if ident == @file.fd.to_u64
            return
          elsif ident == @cancel_signal_reader.fd.to_u64
            buf = Bytes.new(1)
            @cancel_signal_reader.read(buf)
            raise ErrCanceled
          else
            raise IO::Error.new("Unknown fd in kevent")
          end
        end
      end
    end
  {% end %}

  {% if flag?(:unix) %}
    # selectCancelReader implements CancelReader using POSIX select syscall.
    class SelectCancelReader < Reader
      @file : CancelReader::File
      @mixin : CancelMixin
      @cancel_signal_reader : IO::FileDescriptor
      @cancel_signal_writer : IO::FileDescriptor

      def initialize(file : CancelReader::File)
        @file = file
        @mixin = CancelMixin.new

        # create pipe for cancel signal
        reader, writer = IO.pipe
        @cancel_signal_reader = reader
        @cancel_signal_writer = writer
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
          puts "DEBUG: cancel writing to fd #{@cancel_signal_writer.fd}" if ENV["CANCEL_READER_DEBUG"]?
          @cancel_signal_writer.write(Bytes.new(1, 'c'.ord.to_u8))
          puts "DEBUG: cancel write succeeded" if ENV["CANCEL_READER_DEBUG"]?
          true
        rescue
          puts "DEBUG: cancel write failed" if ENV["CANCEL_READER_DEBUG"]?
          false
        end
      end

      def close : Nil
        @cancel_signal_reader.close
        @cancel_signal_writer.close
      end

      private def wait_for_readable
        reader_fd = @file.fd.to_i32
        abort_fd = @cancel_signal_reader.fd
        max_fd = reader_fd > abort_fd ? reader_fd : abort_fd
        if max_fd >= FD_SETSIZE
          raise IO::Error.new("cannot select on file descriptor #{max_fd} which is larger than 1024")
        end

        loop do
          if @mixin.canceled?
            raise ErrCanceled
          end

          fd_set = LibC::FdSet.new
          fd_set.fds_bits = StaticArray(Int32, 32).new(0)
          set_fd(fd_set, reader_fd)
          set_fd(fd_set, abort_fd)

          timeout = ::LibC::Timeval.new
          timeout.tv_sec = 0
          timeout.tv_usec = 100_000 # 100ms

          ret = LibC.select(max_fd + 1, pointerof(fd_set), nil, nil, pointerof(timeout))
          if ret == -1
            err = Errno.value
            if err == Errno::EINTR
              Fiber.yield
              next
            else
              raise IO::Error.from_errno("select failed")
            end
          elsif ret == 0
            # timeout
            Fiber.yield
            next
          end

          if is_set(fd_set, abort_fd)
            buf = Bytes.new(1)
            @cancel_signal_reader.read(buf)
            raise ErrCanceled
          elsif is_set(fd_set, reader_fd)
            return
          else
            raise IO::Error.new("select returned without setting a file descriptor")
          end
        end
      end

      private def set_fd(fd_set : LibC::FdSet, fd : Int32)
        idx = fd // 32
        bit = fd % 32
        fd_set.fds_bits[idx] |= 1 << bit
      end

      private def is_set(fd_set : LibC::FdSet, fd : Int32) : Bool
        idx = fd // 32
        bit = fd % 32
        (fd_set.fds_bits[idx] & (1 << bit)) != 0
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
      {% if flag?(:windows) %}
        return FallbackReader.new(reader)
      {% end %}

      {% if flag?(:linux) %}
        return EpollCancelReader.new(file)
      {% end %}

      {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
        if file.name == "/dev/tty"
          # select can't handle fd >= FD_SETSIZE
          if file.fd >= FD_SETSIZE
            return FallbackReader.new(reader)
          end
          return SelectCancelReader.new(file)
        else
          return KqueueCancelReader.new(file)
        end
      {% end %}

      {% if flag?(:unix) %}
        # select can't handle fd >= FD_SETSIZE
        if file.fd >= FD_SETSIZE
          return FallbackReader.new(reader)
        end
        return SelectCancelReader.new(file)
      {% end %}
    end

    FallbackReader.new(reader)
  end
end
