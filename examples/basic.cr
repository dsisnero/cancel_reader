#!/usr/bin/env crystal
# Example usage of cancel_reader

require "../src/cancel_reader"

puts "CancelReader example: Canceling a blocking read"

# Create a pipe for testing
reader, _writer = IO.pipe
cancel_reader = CancelReader.new_reader(reader)

# Spawn a fiber that will block reading
done = Channel(Nil).new
spawn do
  slice = Bytes.new(10)
  begin
    puts "Fiber: Starting blocking read..."
    n = cancel_reader.read(slice)
    puts "Fiber: Read #{n} bytes"
  rescue ex : CancelReader::CanceledError
    puts "Fiber: Read canceled (expected)"
  end
  done.send(nil)
end

# Give fiber a chance to start blocking
Fiber.yield
sleep 0.01

puts "Main: Canceling reader..."
if cancel_reader.cancel
  puts "Main: Cancel succeeded"
else
  puts "Main: Cancel failed (non-file reader?)"
end

# Wait for fiber to finish
select
when done.receive
when timeout(1.second)
  puts "Main: Timeout waiting for fiber"
end

puts "\nExample 2: Reading data before cancellation"
reader2, writer2 = IO.pipe
cancel_reader2 = CancelReader.new_reader(reader2)

# Write some data
writer2.write("hello".to_slice)
writer2.flush

slice = Bytes.new(5)
n = cancel_reader2.read(slice)
puts "Read #{n} bytes: #{String.new(slice)}"

# Cancel after reading
cancel_reader2.cancel
begin
  cancel_reader2.read(Bytes.new(1))
  puts "ERROR: Should have raised CanceledError"
rescue ex : CancelReader::CanceledError
  puts "Correctly raised CanceledError after cancellation"
end

puts "\nExample 3: Non-file reader (fallback)"
io = IO::Memory.new("data")
cancel_reader3 = CancelReader.new_reader(io)
slice = Bytes.new(4)
n = cancel_reader3.read(slice)
puts "Read #{n} bytes from IO::Memory: #{String.new(slice[0, n])}"

# Cancellation on non-file readers returns false
if cancel_reader3.cancel
  puts "Unexpected: cancel succeeded on non-file reader"
else
  puts "Expected: cancel failed on non-file reader (fallback)"
end

puts "\nAll examples completed."
