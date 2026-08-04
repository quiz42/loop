# Proof of Loop adopts local-first + static sharing, not a hosted web SaaS

The distribution form of the Proof of Loop MVP is a locally generated Proof Bundle plus a purely static offline Explorer: no backend service, no account system, no cloud database. Building a hosted web platform for the first version was considered and rejected — Loop itself is a purely local CLI, and hosting would widen the scope from "compile / validate / browse evidence" to "accounts + storage + permissions", while the north-star metric (maintainer time-to-trust) is independent of whether anything is hosted. Hosting is deferred to a later stage, and it must be layered on without changing the `proof.json` contract.

## Consequences

- A Bundle must be copyable as an ordinary directory, transferable by email, and shareable as a CI artifact (AC-7).
- The Explorer must not depend on any network request or login, including the case of double-clicking it open over `file://` (see design decision D15: data is inlined through a `proof-data.js` file derived at export time). Direct opening is a portable display-only path; `loop proof open` is the verified viewing path and preflights the manifest-bound renderer plus the derived display data.
- Any future hosted version is another consumer of `proof.json`, not a new data source.
