# cancel_reader

A Crystal port of [muesli/cancelreader](https://github.com/muesli/cancelreader) Go library.

This library provides a cancelable reader that allows interrupting read operations.

**Source:** The original Go source is included as a git submodule in `vendor/` (commit [`245609e`](https://github.com/muesli/cancelreader/commit/245609eb8557cff32c56eed62b04a2d096c83e83)).

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     cancel_reader:
       github: dsisnero/cancel_reader
   ```

2. Run `shards install`

## Usage

```crystal
require "cancel_reader"

# Create a cancelable reader from any IO
reader = CancelReader.new_reader(some_io)

# Read from the reader (blocks until data available)
slice = Bytes.new(1024)
bytes_read = reader.read(slice)

# Cancel ongoing reads (returns true if cancellation succeeded)
cancelled = reader.cancel

# After cancellation, subsequent reads raise CancelReader::CanceledError
begin
  reader.read(slice)
rescue ex : CancelReader::CanceledError
  puts "Read was canceled"
end
```

### Platform Support

- **Linux**: Uses `epoll` for file descriptors.
- **BSD (macOS, FreeBSD, etc.)**: Uses `kqueue`, except for `/dev/tty` which falls back to `select`.
- **Other Unix**: Uses `select`.
- **Windows**: Falls back to a non‑interruptible reader (cancellation only prevents future reads).
- **FD_SETSIZE limit**: File descriptors ≥ 1024 cannot be used with `select`‑based implementations (BSD `/dev/tty` and other Unix); they automatically fall back to the non‑interruptible reader.

See the original [Go documentation](https://pkg.go.dev/github.com/muesli/cancelreader) for detailed usage.

## Development

This project uses standard Crystal development tools:

- `make install` – Install dependencies
- `make update` – Update dependencies
- `make format` – Check code formatting
- `make lint` – Run ameba linter (auto‑fix + check)
- `make test` – Run Crystal specs
- `make clean` – Remove temporary files

Always run `make lint` and `make test` before committing.

## Contributing

This is a port; changes should match the behavior of the original Go library.
If you find a discrepancy, please open an issue.

1. Fork it (<https://github.com/dsisnero/cancel_reader/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Dominic Sisneros](https://github.com/dsisnero) – creator and maintainer
- Original Go library by [Christian Muehlhaeuser](https://github.com/muesli)