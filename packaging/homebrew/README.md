# Homebrew cask

`sidemoon.rb` is the cask for the notarized Sidemoon DMG served from sidemoon.app. It is not published
in a tap yet, so `brew install sidemoon` does not work today.

## For each release

1. Set `version` to the new version.
2. Compute the checksum of the released DMG and put it in `sha256` (`scripts/release.sh` prints it):

   ```sh
   shasum -a 256 Sidemoon-<version>.dmg
   ```

## Publish a tap

A tap is a GitHub repository named `homebrew-<name>`. With a repository `EdonZo/homebrew-sidemoon`:

```sh
brew tap-new EdonZo/sidemoon            # creates a local tap with the expected layout
mkdir -p "$(brew --repository EdonZo/sidemoon)/Casks"
cp packaging/homebrew/sidemoon.rb "$(brew --repository EdonZo/sidemoon)/Casks/"
brew audit --cask --strict --online EdonZo/sidemoon/sidemoon
brew style EdonZo/sidemoon/sidemoon
brew install --cask EdonZo/sidemoon/sidemoon   # test the install end to end
```

Then push the tap repository to GitHub. Users install with:

```sh
brew install --cask EdonZo/sidemoon/sidemoon
```

For each new release, update `version` and `sha256` in the tap and push again.
