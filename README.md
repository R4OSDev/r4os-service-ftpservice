# FTPSVC.R4X

`FTPSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.9`
- Image target: `/R4OS/SERVICES/FTPSVC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
UTF8 path profile (0.85.42)
--------------------------
Path arguments use strict complete UTF8 and the shared R4STD transport path
validator. The command consumes exactly one separating space; additional and
trailing pathname spaces remain part of the name. NUL, ASCII controls, illegal
path characters, oversized components/paths and malformed UTF8 fail before
normalization or filesystem operations. Unsupported legacy encodings are
rejected; no normalization or codepage guessing takes place.
FEAT advertises UTF8; OPTS UTF8 and UTF8 ON succeed, OFF/unknown parameters
are rejected. Oversized control records are discarded through LF. Listings
return an error if the bounded256-entry limit is reached or output fails.
STOR/RETR retain original file bytes and the existing staged transfer owner.
STOR accepts the data connection before sending150, including short and
empty uploads whose sender closes the data stream immediately afterwards.
Existing backend atomic-publication limits remain explicit failures; UTF8
support does not create new filesystem atomicity guarantees.
