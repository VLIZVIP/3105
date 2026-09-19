# ZentryAuth setup

This fork gates the complete 3105 interface behind ZentryAuth license mode.
No exploit, container access, patch import, update check, or main interface is
started until the server accepts the license for this device.

## Configure the app

The supplied public `APP_KEY` is configured in both Debug and Release. If the
key is rotated later, open the 3105 target in Xcode, select **Build Settings**,
search for `ZENTRY_APP_KEY`, and update both configurations.

Build and sign with the enterprise provisioning setup required by 3105.

### Build from Windows using GitHub Actions

The repository includes `.github/workflows/build-unsigned-ipa.yml`. Push this
source to a private GitHub repository, open **Actions → Build unsigned IPA → Run
workflow**, and download the `EXTERNAL-CT-Zentry-unsigned` artifact when the job
finishes. The workflow runs only when manually requested and uses Xcode 26.2 on
a macOS runner.

The generated IPA is intentionally unsigned. Sign it with the enterprise
certificate and provisioning profile required by 3105 before installation.

The client uses only the documented API at `https://api.zentryauth.com/v1`:

- `POST /{app_key}/license/activate`
- `POST /{app_key}/license/validate`

Never add a Seller Key or Seller Secret to this application. Zentry documents
those credentials as server-only.

## Device binding

On first launch, the app creates a non-exportable P-256 private key in the
iPhone or iPad Secure Enclave. The SHA-256 hash of its public key is sent as the
Zentry `hwid`. The private key never leaves the device. The returned session
token is stored in Keychain with `ThisDeviceOnly` protection.

The app validates the saved session at launch and whenever it returns to the
foreground. It fails closed when validation cannot be completed. A license
already bound to a different device is rejected by Zentry with
`HWID_MISMATCH`. Moving a customer to another phone requires an authorized HWID
reset in the Zentry panel or Seller API.

The public-key hash is a stable application identity, not Apple's private UDID.
iOS does not expose a permanent hardware UDID to third-party applications. If
the Secure Enclave key becomes unavailable after device erase, Keychain access
group changes, or a materially different signing identity, reset that license's
HWID before reactivation.

## Distribution notice

3105 is GPLv3 software. If this modified IPA is distributed, provide recipients
the corresponding modified source and preserve the upstream license and
notices.
