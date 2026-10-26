# Mac releases

Ferry for Mac is handed out as a `.dmg` and kept up to date by [Sparkle](https://sparkle-project.org). Every copy asks
the appcast at `https://nightdrive.sh/ferry/appcast.xml` once a day (the address is built into each copy, so it has to
stay ours), and installs a newer build only if its `.dmg` is signed with Ferry's EdDSA key. The `.dmg` itself is an
asset of the release's GitHub Release.

## Ferry's Sparkle key

The key is what lets a copy handed out trust an update. Its public half is `SUPublicEDKey` in `macos/Info.plist`, in
the repo. Its private half is never in the repo: it is in the login keychain of the Mac that makes releases, as a
password item of service `https://sparkle-project.org` and account `ferry`.

`macos/build.sh --release` signs with it and stops before building when the keychain's key isn't the one in
`Info.plist`. Sparkle's tools are in `macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/` once a build has
fetched the package (`macos/build.sh --release --dry-run` does).

**It was made** on 2026-10-21 with:

```sh
macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ferry
```

which saves the private key in the keychain and prints the public one for `Info.plist`. Run again, it only prints the
public key of the one already there.

**Keep a copy outside the Mac.** A Mac that is lost or reinstalled takes the keychain with it, and without the key no
copy handed out can be updated again: its users would have to download Ferry by hand. Export it once, put the file's
line in the password manager (a secure note named "Ferry Sparkle key"), and delete the file:

```sh
macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ferry -x ferry-sparkle-key.txt
rm -P ferry-sparkle-key.txt
```

**On another Mac** that makes releases, import it from that note:

```sh
macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ferry -f ferry-sparkle-key.txt
rm -P ferry-sparkle-key.txt
```

**If it leaks**, someone who can also change what the appcast serves can offer a signed update. Make a new key
(`generate_keys --account ferry-2`, then use that account in `build.sh`), put its public half in `Info.plist`, and ship
that build signed with the old key: copies that install it trust only the new key from then on.

## Making a release

```sh
macos/build.sh --release            # v<version>, for everyone
macos/build.sh --release --beta 1   # v<version>-beta.1, for beta installs
```

`MARKETING_VERSION` in the Xcode project is the version; the build number is `tools/build-number.sh`'s (a base plus the commit
count, so it only grows). The build is Developer ID signed, notarized and stapled, and leaves two files in `macos/build/`:

- `Ferry-<version>-<build>.dmg`: the GitHub Release's asset, under the tag the build printed (`v1.0.0`, or
  `v1.0.0-beta.1` as a pre-release).
- `Ferry-<version>-<build>.appcast-item.xml`: the `<item>` that offers it. It goes at the top of the `<channel>` of
  `ferry/appcast.xml` in the website's repo, **after** the `.dmg` is on GitHub, because the item points to it.

`--dry-run` makes the same two files in `macos/build/dry-run/` without sending anything to Apple, so that `.dmg` isn't
notarized and is not for handing out.

### The beta channel

A beta's item has `<sparkle:channel>beta</sparkle:channel>`. Sparkle shows such items only to a copy that asks for the
channel, and a copy asks for it when it was built with `--beta` (`FerryUpdateChannel` in its `Info.plist`). So:

- a beta install gets the next beta and the next full release;
- a full install gets only full releases;
- a beta install that updates to a full release is a full install from then on.

Old items can stay in the feed: Sparkle takes the newest build a copy may have.

## Trying an update before the feed is live

`--local-feed` builds a copy that reads a feed on this Mac instead of nightdrive.sh's, and collects the builds and an
`appcast.xml` of them in `macos/build/local-feed/`. Use a build number for each step (a commit between them):

```sh
macos/build.sh --release --dry-run --local-feed http://127.0.0.1:8484   # the older build: copy its Ferry.app somewhere
# … commit …
macos/build.sh --release --dry-run --local-feed http://127.0.0.1:8484   # the newer one, left in the folder
python3 -m http.server 8484 --bind 127.0.0.1 --directory macos/build/local-feed
```

Quit the Ferry that is running (both serve on 127.0.0.1:47270), open the older copy, and use ⋯ › Check for Updates….
It finds the newer build, downloads it, checks its signature, replaces itself and opens again. Afterwards, open the
Ferry in Applications again.
