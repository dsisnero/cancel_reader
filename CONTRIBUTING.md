# Contributing

This project is a port of the Go library [`muesli/cancelreader`](https://github.com/muesli/cancelreader). All contributions must maintain behavioral equivalence with the original Go library.

## Guidelines

### 1. Behavioral Equivalence

- **The Go code is the source of truth.** All logic must match the Go implementation exactly.
- Only Crystal language idioms and standard library usage may differ.
- Never change behavior for "idiomatic" reasons unless the change does not affect observable behavior.

### 2. Porting New Code

When porting additional Go code:

1. **Study the Go source** in the `vendor/` submodule.
2. **Preserve the original structure** (modules, classes, methods).
3. **Use Crystal types appropriately:**
   - Go `[]byte` → Crystal `Bytes` (alias for `Slice(UInt8)`)
   - Go `struct` → Crystal `struct` with getters
   - Go `interface` → Crystal `module` or abstract class
   - Go `const` → Crystal constant with explicit type (`_u8`, `_u32`, etc.)
4. **Error handling:** Go's multiple returns (value, error) become Crystal exceptions (`raise`). Use `CancelReader::CanceledError` for cancellation errors.
5. **Thread safety:** Use `Atomic` for shared state (matching Go's `sync.Mutex` semantics).

### 3. Adding Features

New features should first be implemented upstream in the Go library, then ported here. Exceptions:

- Crystal‑specific utilities (e.g., `#cancel?` predicate) that do not affect the core API.
- Documentation improvements.
- Build/test tooling.

### 4. Writing Tests

- Port **all** Go tests to Crystal specs.
- Keep test logic identical; only adjust syntax.
- Use `pending` for tests that cannot yet pass (e.g., platform‑specific issues).
- Run `make test` before submitting changes.

### 5. Code Style

- Follow Crystal conventions (snake_case, CamelCase for classes).
- Use `crystal tool format` to ensure consistent formatting.
- Run `ameba` linting and fix any issues.

### 6. Platform Support

This library supports multiple platforms:

- **Linux:** `epoll`
- **BSD (macOS, FreeBSD, etc.):** `kqueue` (except `/dev/tty` → `select`)
- **Other Unix:** `select`
- **Windows:** Fallback (non‑interruptible)

When modifying platform‑specific code, ensure all platforms still compile and pass tests.

## Workflow

1. **Fork** the repository.
2. **Create a feature branch** (`git checkout -b feature/your-change`).
3. **Make your changes**, following the guidelines above.
4. **Run quality gates:**
   ```bash
   make lint
   make test
   ```
5. **Commit** with a descriptive message (e.g., `feat: port XYZ from Go`).
6. **Push** to your fork and open a Pull Request.

## Reporting Issues

- For **behavioral discrepancies** with the Go library, include:
  - The Go version/commit from `vendor/`
  - Expected behavior (from Go)
  - Actual behavior (Crystal)
  - Minimal reproduction code
- For **build/test failures**, include:
  - OS and Crystal version (`crystal --version`)
  - Full error output
  - Steps to reproduce

## Code of Conduct

Be respectful and constructive. This is a porting project; discussions should focus on technical accuracy and compatibility.

## License

By contributing, you agree that your contributions will be licensed under the project's MIT License.