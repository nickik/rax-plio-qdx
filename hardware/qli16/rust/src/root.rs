#![forbid(unsafe_code)]

#[path = "lib.rs"]
mod encoding;
pub use encoding::*;

// The production codec is compiled for normal library users, binaries and
// integration tests. Its behavioral tests live under rust/tests so they test
// the public crate surface rather than a second cfg(test) copy of the module.
#[cfg(not(test))]
pub mod codec;
