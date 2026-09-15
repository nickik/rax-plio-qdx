#![forbid(unsafe_code)]

#[path = "lib.rs"]
mod encoding;
pub use encoding::*;

pub mod codec;
