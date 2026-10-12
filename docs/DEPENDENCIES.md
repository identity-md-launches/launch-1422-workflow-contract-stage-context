# Vendored dependencies

All required files are included as ordinary source files, with no Git submodules or network
installation step. Only imported OpenZeppelin source and the Forge standard library are kept.
No vendored source contents have been edited.

| Dependency | Version | Upstream archive | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.1.0 | https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0 | MIT, `lib/openzeppelin-contracts/LICENSE` |
| Forge Standard Library | v1.9.7 | https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7 | Apache-2.0 / MIT, `lib/forge-std/LICENSE-APACHE` and `LICENSE-MIT` |

OpenZeppelin provides ERC20, ERC721, SafeERC20, ReentrancyGuard, Base64, Strings and their transitive
imports. Library functions used by the production contracts are internal and compiler-inlined.
Forge Standard Library is used only by tests. Its cheatcode interface includes many capabilities;
the delivered tests do not read/set environment variables or use FFI or filesystem access.

`docs/dependencies.sha256` pins every vendored source/license file's content. Verify from the root:

```sh
sha256sum --check docs/dependencies.sha256
```

The build compiler is Solidity 0.8.26, selected by version in `foundry.toml`. A compiler binary is
not included, and the configuration does not point at an executable path. The verification worker
provides this compiler offline. Foundry is the externally supplied execution/check toolchain.
