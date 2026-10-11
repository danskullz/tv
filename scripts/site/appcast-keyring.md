# appcast-keyring.md -- the update keys pinned into the app

The app will only trust a manifest signed by a key that is **compiled into the binary**. There
is no key download and no TOFU: an attacker who controls the network still cannot serve a
manifest the app accepts, because the public key it checks against is in the executable.

## Current keys

| keyID | status | public key (base64, raw 32 bytes) |
| --- | --- | --- |
| `marquee-2026` | active | _(filled in below by `make-appcast.sh --print-keyring`)_ |

Generate the private key once, on the machine that signs releases:

```sh
openssl genpkey -algorithm ed25519 -out ~/.config/marquee/appcast-key.pem
chmod 600 ~/.config/marquee/appcast-key.pem
```

Then print the exact snippet to paste into the app:

```sh
scripts/make-appcast.sh --print-keyring --key ~/.config/marquee/appcast-key.pem --key-id marquee-2026
```

It prints something like:

```swift
// scripts/site/appcast-keyring.md -- pinned Ed25519 public keys for the update channel.
// Keep every key you have ever shipped; a client that finds no match must refuse to update.
enum AppcastKeyring {
    static let keys: [String: Data] = [
        "marquee-2026": Data(base64Encoded: "IE8u4XYNNFPKSeRuuzciH3lZ5DUhoYkkRHmBNxeycQ8=")!
    ]
}
```

Paste that into the Swift client (the other agent owns that file; this is the shape it should
expect) and update the table above.

## Where the base64 comes from

The raw 32-byte Ed25519 public key is the **last 32 bytes** of the DER SPKI encoding -- not the
whole thing, and not the PEM:

```sh
openssl pkey -in appcast-key.pem -pubout -outform DER | tail -c 32 | base64
```

Getting this wrong produces a key that is the right length, the right algorithm and simply
wrong, so every client rejects every manifest. `--print-keyring` performs exactly that
derivation and fails if it cannot get 32 bytes back, so prefer it over doing it by hand.

## Rotating a key

The client must keep every key it has ever shipped, or users on the old build can never update
again. Rotation is an overlap, in this order:

1. Add the **new** public key to `AppcastKeyring.keys` under a new `keyID` (e.g.
   `marquee-2027`) and ship that build. Nothing is signed with the new key yet.
2. Wait until that build is the one most users are running, and keep signing with the old key
   for as long as it takes for old builds to update (a few weeks at most, since the old key
   still validates everything).
3. Set `MARQUEE_APPCAST_KEY_PEM` to the new key and start signing with the new `keyID`.
4. Remove the old key **only** when no client that ships it is still in the field -- and keep
   it in this table, marked retired, for the record.

If a private key is ever exposed, steps 1–3 are the same; the exposure is the reason to hurry.
Losing a key without a replacement in the client is unrecoverable: you would have to ship a
build signed by the new key to people who cannot verify it.

## What the client does with these

For each release in the manifest, in order:

1. Fetch `signatureURL` (or `/appcast.json.sig`) and the manifest itself.
2. Look up `keyID` in the keyring. **No match means no update** -- do not fall back to
   verifying anything else.
3. Verify `signedSHA256` against the SHA-256 of the manifest bytes, then verify the Ed25519
   signature over **those exact bytes**. Never over a re-serialised or canonicalised form: a
   canonicalisation mismatch looks like a tamper and silently bricks every install.
4. Pick a build whose `arch` matches, skip releases with `yanked: true` and any newer than the
   running version, honour `minimumVersion` as a floor rather than a target.
